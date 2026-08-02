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
    case uri_string:parse(Reference) of
        {error, _, _} -> {error, invalid_uri};
        Parsed        -> resolve_parts(Parsed, Base)
    end.

%% Порядок шагов обязателен. Fragment отделяется до разрешения, потому что в
%% registry lookup он не участвует. Нормализация идёт после resolve, а не до: на
%% относительной ссылке `uri_string:normalize` молча возвращает вход неизменным,
%% поэтому ранняя нормализация не выявила бы отсутствие базы, а замаскировала бы
%% его.
-spec resolve_parts(uri_string:uri_map(), rid()) ->
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
-spec document(uri_string:uri_map(), rid()) -> {ok, rid()} | {error, uri_error()}.
document(Parsed, Base) ->
    case uri_string:recompose(maps:remove(fragment, Parsed)) of
        Document when is_binary(Document) -> resolved(Document, Parsed, Base);
        _Error                            -> {error, invalid_uri}
    end.

%% Fragment-only ссылка проходит общим путём без отдельной ветки: у неё пустой
%% path, `recompose` даёт пустую строку, а разрешение пустой ссылки возвращает
%% сам base URI (rfc3986.txt:1482). У anonymous root базы нет вовсе, поэтому
%% такая ссылка остаётся внутри него и абсолютного имени не получает.
-spec resolved(binary(), uri_string:uri_map(), rid()) ->
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
    case uri_string:resolve(Document, Base) of
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
    case uri_string:normalize(Uri) of
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

%% Документированный контракт `percent_decode/1` допускает возврат ошибки, но на
%% binary OTP 27 сообщает о ней throw'ом, поэтому закрыты оба пути. Битая
%% escape-последовательность и октеты, не складывающиеся в UTF-8, означают для
%% fragment одно и то же: прочитать его как текст нельзя.
-spec decode(unicode:chardata()) -> binary() | {error, uri_error()}.
decode(Fragment) ->
    try uri_string:percent_decode(Fragment) of
        Decoded when is_binary(Decoded) -> Decoded;
        _Error                          -> {error, invalid_percent_encoding}
    catch
        throw:{error, _, _} -> {error, invalid_percent_encoding}
    end.

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
    case is_map_key(Pointer, Nodes) of
        true  -> {ok, Pointer};
        false -> error
    end.
