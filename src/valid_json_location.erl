%% Печать локаций. Пути instance/keyword внутри вычисления — обратные стеки,
%% адрес schema node уже содержит compiled pointer. Escaping и percent-encoding
%% выполняются здесь при проекции output.
%% Правила заданы в okf/architecture/validator-core.md, раздел «Output unit и
%% локации».
-module(valid_json_location).

-include("valid_json_core.hrl").

-export([pointer/1, segments/1, fragment/1, fragment/2]).

%% Символы, разрешённые во fragment без экранирования: pchar плюс "/" и "?"
%% (rfc3986.txt:1308). Буквы и цифры проверяются отдельно диапазонами.
-define(IS_FRAGMENT_SAFE(Byte),
        (((Byte) >= $A andalso (Byte) =< $Z) orelse
         ((Byte) >= $a andalso (Byte) =< $z) orelse
         ((Byte) >= $0 andalso (Byte) =< $9) orelse
         (Byte) =:= $- orelse (Byte) =:= $. orelse (Byte) =:= $_ orelse
         (Byte) =:= $~ orelse (Byte) =:= $! orelse (Byte) =:= $$ orelse
         (Byte) =:= $& orelse (Byte) =:= $' orelse (Byte) =:= $( orelse
         (Byte) =:= $) orelse (Byte) =:= $* orelse (Byte) =:= $+ orelse
         (Byte) =:= $, orelse (Byte) =:= $; orelse (Byte) =:= $= orelse
         (Byte) =:= $: orelse (Byte) =:= $@ orelse (Byte) =:= $/ orelse
         (Byte) =:= $?)).

%% JSON Pointer от корня: сегменты идут от последнего к первому, каждому
%% предшествует "/", пустой стек печатается пустым указателем.
-spec pointer([binary()]) -> pointer().
pointer(Segments) ->
    << <<"/", (escape(Segment))/binary>> || Segment <- lists:reverse(Segments) >>.

%% Обратная операция: pointer готовым указателем хранится в addr(), а стек
%% сегментов нужен, чтобы дописать к нему имя keyword. Пустой указатель — корень
%% resource, то есть пустой стек.
-spec segments(pointer()) -> [binary()].
segments(<<>>) ->
    [];
segments(<<"/", Pointer/binary>>) ->
    [unescape(Segment) || Segment <- lists:reverse(binary:split(Pointer, <<"/">>, [global]))].

%% URI fragment identifier form указателя (rfc6901.txt:261): сначала pointer
%% escaping, затем percent-encoding недопустимых во fragment символов.
-spec fragment({uri(), [binary()]}) -> uri().
fragment({Uri, Segments}) ->
    <<Uri/binary, "#", (percent(pointer(Segments)))/binary>>.

%% Быстрый вход для output projection: Pointer уже прошёл JSON Pointer escaping
%% при компиляции. Schema unit не добавляет сегмент, keyword unit дописывает
%% только имя самого keyword. Разбирать Pointer обратно в сегменты не нужно.
-spec fragment({uri(), pointer()}, none | binary()) -> uri().
fragment({Uri, Pointer}, none) ->
    <<Uri/binary, "#", (percent(Pointer))/binary>>;
fragment({Uri, Pointer}, Segment) ->
    <<Uri/binary, "#", (percent(Pointer))/binary,
      "/", (percent(escape(Segment)))/binary>>.

%% "~" и "/" — единственные символы, экранируемые в сегменте (rfc6901.txt:95).
%% Обычный сегмент возвращается без копирования. Медленный путь встречается
%% только при реальном escaping; порядок замен сохраняет смысл "~01".
-spec escape(binary()) -> binary().
escape(Segment) ->
    case binary:match(Segment, [<<"~">>, <<"/">>]) of
        nomatch -> Segment;
        {_Position, _Length} ->
            binary:replace(binary:replace(Segment, <<"~">>, <<"~0">>, [global]),
                           <<"/">>, <<"~1">>, [global])
    end.

%% "~1" разбирается раньше "~0", иначе "~01" в имени свойства превратилось бы в
%% косую черту (rfc6901.txt:95).
-spec unescape(binary()) -> binary().
unescape(Segment) ->
    binary:replace(binary:replace(Segment, <<"~1">>, <<"/">>, [global]),
                   <<"~0">>, <<"~">>, [global]).

-spec percent(binary()) -> binary().
percent(Text) ->
    case fragment_safe(Text) of
        true  -> Text;
        false -> << <<(encoded(Byte))/binary>> || <<Byte>> <= Text >>
    end.

%% Большинство schema pointers состоят только из fragment-safe ASCII. Этот
%% проход ничего не выделяет и позволяет итоговой сборке URI скопировать такой
%% pointer ровно один раз.
-spec fragment_safe(binary()) -> boolean().
fragment_safe(<<>>) ->
    true;
fragment_safe(<<Byte, Rest/binary>>) when ?IS_FRAGMENT_SAFE(Byte) ->
    fragment_safe(Rest);
fragment_safe(_Text) ->
    false.

encoded(Byte) when ?IS_FRAGMENT_SAFE(Byte) ->
    <<Byte>>;
encoded(Byte) ->
    <<"%", (hex(Byte bsr 4)), (hex(Byte band 15))>>.

hex(Digit) when Digit < 10 -> $0 + Digit;
hex(Digit)                 -> $A + Digit - 10.
