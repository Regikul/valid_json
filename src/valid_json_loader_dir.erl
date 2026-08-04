%% Загрузчик каталога: рекурсивный обход, чтение файлов по расширению и имя
%% документа из пути относительно корня. Нормативное описание —
%% okf/architecture/validator-resources-runtime.md, раздел «Каталог».
%%
%% Аргумент — proplist: обязательный `root` и необязательное `extension`
%% (по умолчанию `.json`). Негодный аргумент завершается badarg: это ошибка
%% конфигурации разработчика, а не отказ чтения.
-module(valid_json_loader_dir).

-behaviour(valid_json_loader).

-include("valid_json_resources.hrl").

-export([base_uri/1, load/1]).
-export_type([dir_option/0, error/0]).

-type dir_option() :: {root, file:filename_all()} | {extension, binary()}.
-type error() :: {list, file:filename_all(), file:posix()}
               | {read, file:filename_all(), file:posix()}
               | {invalid_json, file:filename_all()}.

%% Символы, которые в сегменте пути разрешены без экранирования: sub-delims,
%% двоеточие и `@`. Всё остальное сверх unreserved уходит в percent-encoding,
%% поэтому обычное имя вроде `product/banana.json` не меняется ни на байт, а
%% пробел, процент и слэш внутри имени файла экранируются.
-define(SAFE, "!$&'()*+,;=:@").
%% В первом сегменте относительной ссылки двоеточие запрещено: с ним начало
%% имени прочиталось бы как scheme.
-define(SAFE_FIRST, "!$&'()*+,;=@").

%% Каталог сам по себе базой не является: базой становится его `file://` URI,
%% и завершающий слэш здесь обязателен — без него разрешение относительного
%% имени съело бы последний сегмент пути.
-spec base_uri([dir_option()]) -> {ok, uri()}.
base_uri(Options) ->
    Root = unicode:characters_to_binary(filename:absname(root(Options))),
    Segments = [quote(Segment, ?SAFE) || Segment <- split(Root), Segment =/= <<>>],
    %% Пустой хвостовой сегмент и даёт завершающий слэш.
    {ok, join([<<"file://">> | Segments] ++ [<<>>])}.

-spec load([dir_option()]) -> {ok, [{uri(), json()}]} | {error, error()}.
load(Options) ->
    Root = root(Options),
    Extension = extension(Options),
    case collect(Root, [], Extension, []) of
        {ok, Files}        -> documents(Root, lists:reverse(Files));
        {error, _} = Error -> Error
    end.

%% Обход рекурсивный и отсортированный: порядок набора не значит ничего, но
%% воспроизводимость сообщений об ошибке стоит дешевле, чем стоит её отсутствие.
%% Segments накапливаются от корня и служат потом именем документа.
-spec collect(file:filename_all(), [binary()], binary(), [[binary()]]) ->
          {ok, [[binary()]]} | {error, error()}.
collect(Root, Segments, Extension, Acc) ->
    case file:list_dir(path(Root, Segments)) of
        {ok, Names} ->
            entries(Root, Segments, Extension, lists:sort(Names), Acc);
        {error, Reason} ->
            {error, {list, path(Root, Segments), Reason}}
    end.

-spec entries(file:filename_all(), [binary()], binary(), [file:filename_all()],
              [[binary()]]) -> {ok, [[binary()]]} | {error, error()}.
entries(_Root, _Segments, _Extension, [], Acc) ->
    {ok, Acc};
entries(Root, Segments, Extension, [Name | Rest], Acc) ->
    Nested = Segments ++ [unicode:characters_to_binary(Name)],
    Path = path(Root, Nested),
    case filelib:is_dir(Path) of
        true ->
            case collect(Root, Nested, Extension, Acc) of
                {ok, Deeper}       -> entries(Root, Segments, Extension, Rest, Deeper);
                {error, _} = Error -> Error
            end;
        false ->
            entries(Root, Segments, Extension, Rest,
                    keep(Nested, Extension, Acc))
    end.

%% Файл без нужного расширения не ошибка: рядом со схемами обычно лежит и
%% что-нибудь ещё.
-spec keep([binary()], binary(), [[binary()]]) -> [[binary()]].
keep(Segments, Extension, Acc) ->
    case ends_with(lists:last(Segments), Extension) of
        true  -> [Segments | Acc];
        false -> Acc
    end.

-spec ends_with(binary(), binary()) -> boolean().
ends_with(Name, Extension) ->
    Size = byte_size(Name) - byte_size(Extension),
    Size > 0 andalso binary:part(Name, Size, byte_size(Extension)) =:= Extension.

-spec documents(file:filename_all(), [[binary()]]) ->
          {ok, [{uri(), json()}]} | {error, error()}.
documents(Root, Files) ->
    Read = fun(Segments, {ok, Acc}) ->
                   case document(Root, Segments) of
                       {ok, Entry}        -> {ok, [Entry | Acc]};
                       {error, _} = Error -> Error
                   end;
              (_Segments, {error, _} = Error) ->
                   Error
           end,
    case lists:foldl(Read, {ok, []}, Files) of
        {ok, Entries}      -> {ok, lists:reverse(Entries)};
        {error, _} = Error -> Error
    end.

-spec document(file:filename_all(), [binary()]) ->
          {ok, {uri(), json()}} | {error, error()}.
document(Root, Segments) ->
    Path = path(Root, Segments),
    case file:read_file(Path) of
        {ok, Encoded} ->
            case decode(Encoded) of
                {ok, Json}    -> {ok, {name(Segments), Json}};
                invalid       -> {error, {invalid_json, Path}}
            end;
        {error, Reason} ->
            {error, {read, Path, Reason}}
    end.

-spec decode(binary()) -> {ok, json()} | invalid.
decode(Encoded) ->
    try {ok, json:decode(Encoded)}
    catch error:_ -> invalid
    end.

%% Имя документа относительное, поэтому абсолютным его делает база хранилища:
%% та же схема годится и под базой загрузчика, и под базой, заданной опцией.
-spec name([binary()]) -> uri().
name([First | Rest]) ->
    join([quote(First, ?SAFE_FIRST) | [quote(Segment, ?SAFE) || Segment <- Rest]]).

-spec quote(binary(), [byte()]) -> binary().
quote(Segment, Safe) ->
    uri_string:quote(Segment, Safe).

-spec join([binary()]) -> binary().
join(Segments) ->
    lists:foldl(fun(Segment, <<>>) -> Segment;
                   (Segment, Acc)  -> <<Acc/binary, "/", Segment/binary>>
                end, <<>>, Segments).

-spec split(binary()) -> [binary()].
split(Path) ->
    binary:split(Path, <<"/">>, [global]).

-spec path(file:filename_all(), [binary()]) -> file:filename_all().
path(Root, []) ->
    Root;
path(Root, Segments) ->
    filename:join([Root | Segments]).

-spec root([dir_option()]) -> file:filename_all().
root(Options) ->
    case lists:keyfind(root, 1, Options) of
        {root, Root} when is_binary(Root); is_list(Root) -> Root;
        _Other -> erlang:error(badarg, [Options])
    end.

-spec extension([dir_option()]) -> binary().
extension(Options) ->
    case lists:keyfind(extension, 1, Options) of
        {extension, Extension} when is_binary(Extension), Extension =/= <<>> ->
            Extension;
        false ->
            <<".json">>;
        _Other ->
            erlang:error(badarg, [Options])
    end.
