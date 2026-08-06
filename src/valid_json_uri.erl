%% Слой URI: разрешение ссылки относительно базы, каноническая форма имени,
%% разбор fragment и поиск цели внутри resource. Собственного парсера здесь нет,
%% весь разбор по RFC 3986 делает `uri_string` из stdlib. Правила заданы в
%% okf/architecture/validator-resources-runtime.md, раздел «Слой URI».
%%
%% `uri_string` типизирован по chardata и на каждом шаге допускает ошибку, хотя
%% на binary-входе всегда возвращает binary. Поэтому результат каждого вызова
%% сужается охраной прямо на месте: дальше по слою ходят только binary, как и
%% требует uri().
-module(valid_json_uri).

-include("valid_json_core.hrl").

-export([resolve/2, normalize/1, lookup/2]).

-export_type([target/0, uri_error/0]).

%% Куда ссылка указывает внутри найденного resource. `root` — same-document
%% reference, то есть отсутствующий или пустой fragment (rfc3986.txt:1482).
%% Сегменты указателя лежат обратным стеком, как и остальные локации ядра:
%% в таком виде их принимает valid_json_location:pointer/1.
-type target() :: root | {pointer, [binary()]} | {anchor, binary()}.

%% Ошибки самого слоя. В каталог причин `#schema_error{}` их укладывает
%% компилятор: локацию виноватого keyword знает он, а не разбор имени.
-type uri_error() :: invalid_uri | relative_uri_without_base
                   | invalid_percent_encoding.

%% Разрешает ссылку относительно базы и возвращает имя документа отдельно от
%% цели внутри него. База `anonymous` — корень без абсолютной локации.
-spec resolve(binary(), rid()) -> {ok, rid(), target()} | {error, uri_error()}.
resolve(Reference, Base) ->
    case valid_json_uri_backend:parse(Reference) of
        {error, _, _} -> {error, invalid_uri};
        Parsed        -> resolve_parts(Parsed, Base)
    end.

%% Порядок шагов обязателен. Fragment отделяется до разрешения, потому что в
%% registry lookup он не участвует. Нормализация идёт после resolve, а не до: на
%% относительной ссылке `uri_string:normalize` молча возвращает вход неизменным,
%% поэтому ранняя нормализация не выявила бы отсутствие базы, а замаскировала бы
%% его.
-spec resolve_parts(valid_json_uri_backend:uri_map(), rid()) ->
          {ok, rid(), target()} | {error, uri_error()}.
resolve_parts(Parsed, Base) ->
    case document(Parsed, Base) of
        {error, _} = Error -> Error;
        {ok, Uri}          -> attach(Uri, maps:get(fragment, Parsed, undefined))
    end.

-spec attach(rid(), unicode:chardata() | undefined) ->
          {ok, rid(), target()} | {error, uri_error()}.
attach(Uri, Fragment) ->
    case target(Fragment) of
        {error, _} = Error -> Error;
        Target             -> {ok, Uri, Target}
    end.

%% Имя документа — ссылка без fragment, разрешённая и приведённая к канонической
%% форме. Ошибка recompose здесь недостижима: карта только что получена удачным
%% разбором, — но ветвь оставлена, чтобы слой оставался тотальным.
-spec document(valid_json_uri_backend:uri_map(), rid()) ->
          {ok, rid()} | {error, uri_error()}.
document(Parsed, Base) ->
    case valid_json_uri_backend:recompose(maps:remove(fragment, Parsed)) of
        Document when is_binary(Document) -> resolved(Document, Parsed, Base);
        _Error                            -> {error, invalid_uri}
    end.

%% Fragment-only ссылка проходит общим путём без отдельной ветки: у неё пустой
%% path, `recompose` даёт пустую строку, а разрешение пустой ссылки возвращает
%% сам base URI (rfc3986.txt:1482). У anonymous root базы нет вовсе, поэтому
%% такая ссылка остаётся внутри него и абсолютного имени не получает.
-spec resolved(binary(), valid_json_uri_backend:uri_map(), rid()) ->
          {ok, rid()} | {error, uri_error()}.
resolved(<<>>, _Parsed, anonymous) ->
    {ok, anonymous};
resolved(Document, Parsed, anonymous) ->
    %% Абсолютная ссылка уходит от anonymous root наружу обычным именем, а
    %% относительной не с чем разрешаться.
    case maps:is_key(scheme, Parsed) of
        true  -> normalize(Document);
        false -> {error, relative_uri_without_base}
    end;
resolved(Document, _Parsed, Base) ->
    case valid_json_uri_backend:resolve(Document, Base) of
        {error, invalid_scheme, _}        -> {error, relative_uri_without_base};
        {error, _, _}                     -> {error, invalid_uri};
        Absolute when is_binary(Absolute) -> normalize(Absolute)
    end.

%% Каноническая форма имени — scheme-based normalization (rfc3986.txt:2259). Она
%% приводит схему и хост к нижнему регистру, убирает порт по умолчанию и
%% dot-сегменты и раскрывает percent-encoding unreserved-символов. Ключом
%% реестра служит именно её результат.
-spec normalize(uri()) -> {ok, uri()} | {error, uri_error()}.
normalize(Uri) ->
    case valid_json_uri_backend:normalize(Uri) of
        Normalized when is_binary(Normalized) -> {ok, Normalized};
        _Error                                -> {error, invalid_uri}
    end.

%% Fragment декодируется целиком и ровно один раз, и лишь затем читается как
%% JSON Pointer (rfc6901.txt:261): указатель кодируется в октеты, а
%% percent-encoding накладывается поверх, значит снимать его нужно первым.
%% Отсюда `#/$defs/a%2Fb` даёт три сегмента, а не один сегмент `a/b`.
%% Синтаксической проверки anchor здесь нет: его грамматика зависит от диалекта
%% цели, который в момент разбора ссылки ещё не выбран.
-spec target(unicode:chardata() | undefined) -> target() | {error, uri_error()}.
target(undefined) ->
    root;
target(<<>>) ->
    root;
target(Fragment) ->
    case decode(Fragment) of
        {error, _} = Error      -> Error;
        <<>>                    -> root;
        <<"/", _/binary>> = Ptr -> {pointer, valid_json_location:segments(Ptr)};
        Anchor                  -> {anchor, Anchor}
    end.

%% Документированный контракт `percent_decode/1` допускает возврат ошибки, но
%% современные OTP сообщают об ошибке throw'ом. Битая escape-последовательность
%% и октеты, не складывающиеся в UTF-8, означают для fragment одно и то же:
%% прочитать его как текст нельзя.
-spec decode(unicode:chardata()) -> binary() | {error, uri_error()}.

-ifdef(CAP_URI_PERCENT_DECODE).
decode(Fragment) ->
    try uri_string:percent_decode(Fragment) of
        Decoded when is_binary(Decoded) -> Decoded;
        _Error                          -> {error, invalid_percent_encoding}
    catch
        throw:{error, _, _} -> {error, invalid_percent_encoding}
    end.

-else.

decode(Fragment) ->
    percent_decode_legacy(Fragment).

%% OTP 20-22 expose the URI parser, but not percent_decode/1. Keep this small
%% compatibility path local: it is used only for fragments and mirrors the
%% raw byte decoding semantics of newer uri_string releases.
-spec percent_decode_legacy(unicode:chardata()) -> binary() | {error, uri_error()}.
percent_decode_legacy(Fragment) when is_binary(Fragment) ->
    try check_decoded_utf8(decode_percent(Fragment, <<>>)) of
        Decoded -> Decoded
    catch
        throw:{error, invalid_percent_encoding} ->
            {error, invalid_percent_encoding};
        throw:{error, invalid_utf8} ->
            {error, invalid_percent_encoding}
    end;
percent_decode_legacy(Fragment) when is_list(Fragment) ->
    try percent_decode_legacy(unicode:characters_to_binary(Fragment)) of
        Decoded when is_binary(Decoded) -> unicode:characters_to_list(Decoded);
        Error                              -> Error
    catch
        _:_ -> {error, invalid_percent_encoding}
    end.

decode_percent(<<$%, C0, C1, Rest/binary>>, Acc) ->
    case {hex_digit(C0), hex_digit(C1)} of
        {A, B} when is_integer(A), is_integer(B) ->
            decode_percent(Rest, <<Acc/binary, (A * 16 + B)>>);
        _ ->
            throw({error, invalid_percent_encoding})
    end;
decode_percent(<<C, Rest/binary>>, Acc) ->
    decode_percent(Rest, <<Acc/binary, C>>);
decode_percent(<<>>, Acc) ->
    Acc.

hex_digit(C) when $0 =< C, C =< $9 -> C - $0;
hex_digit(C) when $A =< C, C =< $F -> C - $A + 10;
hex_digit(C) when $a =< C, C =< $f -> C - $a + 10;
hex_digit(_) -> invalid.

check_decoded_utf8(Binary) ->
    case unicode:characters_to_list(Binary) of
        {incomplete, _, _} -> throw({error, invalid_utf8});
        {error, _, _}      -> throw({error, invalid_utf8});
        _                  -> Binary
    end.

-endif.

%% Цель ищется только среди заранее построенных schema nodes и объявленных
%% anchors: существующий JSON value в non-schema position допустимой целью не
%% является. Промах возвращается голым `error`. Какой причиной каталога он
%% станет, решает компилятор: отличить отсутствующую позицию от позиции, где
%% значение есть, но схемой не является, можно только по документу, которого у
%% resource уже нет.
-spec lookup(target(), #resource{}) -> {ok, pointer()} | error.
lookup(root, #resource{nodes = Nodes}) ->
    node_at(<<>>, Nodes);
lookup({pointer, Segments}, #resource{nodes = Nodes}) ->
    node_at(valid_json_location:pointer(Segments), Nodes);
lookup({anchor, Name}, #resource{anchors = Anchors, nodes = Nodes}) ->
    case Anchors of
        #{Name := Pointer} -> node_at(Pointer, Nodes);
        #{}                -> error
    end.

-spec node_at(pointer(), #{pointer() => schema_node()}) -> {ok, pointer()} | error.
node_at(Pointer, Nodes) ->
    case maps:is_key(Pointer, Nodes) of
        true  -> {ok, Pointer};
        false -> error
    end.
