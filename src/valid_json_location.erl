%% Печать локаций. Внутри вычисления локация — обратный стек сегментов, поэтому
%% escaping и percent-encoding делаются здесь, один раз, при проекции output.
%% Правила заданы в okf/architecture/validator-core.md, раздел «Output unit и
%% локации».
-module(valid_json_location).

-include("valid_json_core.hrl").

-export([pointer/1, segments/1, fragment/1]).

%% Символы, разрешённые во fragment без экранирования: pchar плюс "/" и "?"
%% (rfc3986.txt:1308). Буквы и цифры проверяются отдельно диапазонами.
-define(FRAGMENT_SAFE, "-._~!$&'()*+,;=:@/?").

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

%% "~" и "/" — единственные символы, экранируемые в сегменте (rfc6901.txt:95).
%% Обход побайтовый: продолжения UTF-8 не меньше 0x80 и с ними не совпадают.
-spec escape(binary()) -> binary().
escape(Segment) ->
    << <<(escaped(Byte))/binary>> || <<Byte>> <= Segment >>.

escaped($~) -> <<"~0">>;
escaped($/) -> <<"~1">>;
escaped(Byte) -> <<Byte>>.

%% "~1" разбирается раньше "~0", иначе "~01" в имени свойства превратилось бы в
%% косую черту (rfc6901.txt:95).
-spec unescape(binary()) -> binary().
unescape(Segment) ->
    binary:replace(binary:replace(Segment, <<"~1">>, <<"/">>, [global]),
                   <<"~0">>, <<"~">>, [global]).

-spec percent(binary()) -> binary().
percent(Text) ->
    << <<(encoded(Byte))/binary>> || <<Byte>> <= Text >>.

encoded(Byte) when Byte >= $A, Byte =< $Z;
                   Byte >= $a, Byte =< $z;
                   Byte >= $0, Byte =< $9 ->
    <<Byte>>;
encoded(Byte) ->
    case lists:member(Byte, ?FRAGMENT_SAFE) of
        true  -> <<Byte>>;
        false -> <<"%", (hex(Byte bsr 4)), (hex(Byte band 15))>>
    end.

hex(Digit) when Digit < 10 -> $0 + Digit;
hex(Digit)                 -> $A + Digit - 10.
