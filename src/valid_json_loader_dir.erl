%% Загрузчик каталога: рекурсивный обход, чтение файлов по расширению и имя
%% документа из пути относительно корня. Имя это относительное, и адресом схемы
%% оно само по себе не становится: как схемы называются, решает хранилище.
%% Нормативное описание — okf/architecture/validator-resources-runtime.md,
%% раздел «Каталог».
%%
%% Аргумент — proplist: корень каталога и необязательное `extension`
%% (по умолчанию `.json`). Корень задаётся либо прямо, `{root, Path}`, либо
%% путём внутри приватного каталога приложения, `{priv_dir, App, Path}`: в
%% релизе рабочий каталог заранее не известен, а `priv` приложения известен
%% всегда. Негодный аргумент завершается badarg: это ошибка конфигурации
%% разработчика, а не отказ чтения.
%%
%% За пределы корня загрузчик не выходит: символьные ссылки он не обходит и не
%% читает, а называет отказом.
-module(valid_json_loader_dir).

-behaviour(valid_json_loader).

-include_lib("kernel/include/file.hrl").

-include("valid_json_resources.hrl").

-export([load/1]).
-export_type([dir_option/0, error/0]).

-type dir_option() :: {root, file:filename_all()}
                    | {priv_dir, atom(), file:filename_all()}
                    | {extension, binary()}.
-type error() :: {list, file:filename_all(), file:posix()}
               | {read, file:filename_all(), file:posix()}
               | {link, file:filename_all()}
               | {invalid_json, file:filename_all()}.

%% Символы, которые в сегменте пути разрешены без экранирования: sub-delims,
%% двоеточие и `@`. Всё остальное сверх unreserved уходит в percent-encoding,
%% поэтому обычное имя вроде `product/banana.json` не меняется ни на байт, а
%% пробел, процент и слэш внутри имени файла экранируются.
-define(SAFE, "!$&'()*+,;=:@").
%% В первом сегменте относительной ссылки двоеточие запрещено: с ним начало
%% имени прочиталось бы как scheme.
-define(SAFE_FIRST, "!$&'()*+,;=@").

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
    case type(Path) of
        {ok, directory} ->
            case collect(Root, Nested, Extension, Acc) of
                {ok, Deeper}       -> entries(Root, Segments, Extension, Rest, Deeper);
                {error, _} = Error -> Error
            end;
        {ok, regular} ->
            entries(Root, Segments, Extension, Rest,
                    keep(Nested, Extension, Acc));
        {ok, symlink} ->
            {error, {link, Path}};
        {ok, _Other} ->
            %% Устройство или сокет схемой быть не могут, и читать их нечего.
            entries(Root, Segments, Extension, Rest, Acc);
        {error, Reason} ->
            {error, {read, Path, Reason}}
    end.

%% Тип берётся `read_link_info/1`, которая по ссылке не идёт. Отсюда и граница
%% области: обходятся только настоящие каталоги, читаются только настоящие
%% файлы, а ссылка наружу или на собственный предок невозможна как таковая.
%% Молча пропустить ссылку нельзя — с именем вроде `weight.json` она выглядит
%% ровно как схема, и потерянный документ обошёлся бы дороже отказа.
-spec type(file:filename_all()) -> {ok, atom()} | {error, file:posix()}.
type(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = Type}} -> {ok, Type};
        {error, Reason}               -> {error, Reason}
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

%% Имя документа относительное, поэтому абсолютным его делает `base_uri`
%% хранилища: один и тот же каталог годится любому хранилищу, а под каким именем
%% схема окажется, решает не путь к файлу.
-spec name([binary()]) -> uri().
name([First | Rest]) ->
    join([quote(First, ?SAFE_FIRST) | [quote(Segment, ?SAFE) || Segment <- Rest]]).

-spec quote(binary(), [byte()]) -> binary().

-ifdef(CAP_URI_QUOTE).
quote(Segment, Safe) ->
    uri_string:quote(Segment, Safe).

-else.

quote(Segment, Safe) ->
    quote_legacy(Segment, Safe).

quote_legacy(Segment, Safe) ->
    quote_legacy(Segment, Safe, <<>>).

quote_legacy(<<Char/utf8, Rest/binary>>, Safe, Acc) ->
    Encoded = case is_unreserved(Char) orelse lists:member(Char, Safe) of
                  true  -> <<Char>>;
                  false -> percent_encode(Char)
              end,
    quote_legacy(Rest, Safe, <<Acc/binary, Encoded/binary>>);
quote_legacy(<<>>, _Safe, Acc) ->
    Acc.

is_unreserved(C) when $A =< C, C =< $Z -> true;
is_unreserved(C) when $a =< C, C =< $z -> true;
is_unreserved(C) when $0 =< C, C =< $9 -> true;
is_unreserved($- ) -> true;
is_unreserved($_) -> true;
is_unreserved($.) -> true;
is_unreserved($~) -> true;
is_unreserved(_) -> false.

percent_encode(Codepoint) ->
    percent_encode(<<Codepoint/utf8>>, <<>>).

percent_encode(<<Byte, Rest/binary>>, Acc) ->
    Hex = <<"0123456789ABCDEF">>,
    A = binary:at(Hex, Byte div 16),
    B = binary:at(Hex, Byte rem 16),
    percent_encode(Rest, <<Acc/binary, $%, A, B>>);
percent_encode(<<>>, Acc) ->
    Acc.

-endif.

-spec join([binary()]) -> binary().
join(Segments) ->
    lists:foldl(fun(Segment, <<>>) -> Segment;
                   (Segment, Acc)  -> <<Acc/binary, "/", Segment/binary>>
                end, <<>>, Segments).

-spec path(file:filename_all(), [binary()]) -> file:filename_all().
path(Root, []) ->
    Root;
path(Root, Segments) ->
    filename:join([Root | Segments]).

%% Корень задают две взаимоисключающие опции, и требовать ровно одну проще, чем
%% объяснять, какая из двух победила.
-spec root([dir_option()]) -> file:filename_all().
root(Options) ->
    case {lists:keyfind(root, 1, Options), lists:keyfind(priv_dir, 1, Options)} of
        {{root, Root}, false} when is_binary(Root); is_list(Root) ->
            Root;
        {false, {priv_dir, App, Path}} when is_atom(App), is_binary(Path);
                                            is_atom(App), is_list(Path) ->
            priv_root(App, Path, Options);
        _Other ->
            erlang:error(badarg, [Options])
    end.

%% Приложение без приватного каталога и путь, уводящий из него наружу, — та же
%% ошибка конфигурации, что и корень не той формы: область объявляет
%% разработчик, и объявить её мимо `priv` он не вправе. `safe_relative_path/2`
%% отвергает и абсолютный путь, и `..`, и символьную ссылку наружу, а прочее
%% приводит к нормальному виду.
-spec priv_root(atom(), file:filename_all(), [dir_option()]) -> file:filename_all().
priv_root(App, Path, Options) ->
    Priv = priv_dir(App, Options),
    case safe_relative_path(Path, Priv) of
        unsafe -> erlang:error(badarg, [Options]);
        Safe when Safe =:= []; Safe =:= <<>> -> Priv;
        Safe -> filename:join(Priv, Safe)
    end.

priv_dir(App, Options) ->
    case code:priv_dir(App) of
        {error, bad_name} ->
            case code:which(App) of
                Beam when is_list(Beam) ->
                    filename:join(filename:dirname(Beam), "../priv");
                _Other ->
                    erlang:error(badarg, [Options])
            end;
        Directory ->
            Directory
    end.

%% OTP 23 added filelib:safe_relative_path/2. This local copy keeps the same
%% path and symlink rules on OTP 20: absolute paths, escapes above Cwd and
%% symlink loops are unsafe, while a safe relative path is returned normalized.
-spec safe_relative_path(file:filename_all(), file:filename_all()) ->
          unsafe | file:filename_all().
safe_relative_path(Path, "") ->
    safe_relative_path(Path, ".");
safe_relative_path(Path, Cwd) ->
    srp_path(filename:split(Path), Cwd, sets:new(), []).

srp_path([], _Cwd, _Seen, []) ->
    "";
srp_path([], _Cwd, _Seen, Acc) ->
    filename:join(Acc);
srp_path(["." | Segments], Cwd, Seen, Acc) ->
    srp_path(Segments, Cwd, Seen, Acc);
srp_path([<<".">> | Segments], Cwd, Seen, Acc) ->
    srp_path(Segments, Cwd, Seen, Acc);
srp_path([".." | _Segments], _Cwd, _Seen, []) ->
    unsafe;
srp_path([".." | Segments], Cwd, Seen, [_ | _] = Acc) ->
    srp_path(Segments, Cwd, Seen, lists:droplast(Acc));
srp_path([<<"..">> | _Segments], _Cwd, _Seen, []) ->
    unsafe;
srp_path([<<"..">> | Segments], Cwd, Seen, [_ | _] = Acc) ->
    srp_path(Segments, Cwd, Seen, lists:droplast(Acc));
srp_path([clear | Segments], Cwd, _Seen, Acc) ->
    srp_path(Segments, Cwd, sets:new(), Acc);
srp_path([Segment | _] = Segments, Cwd, Seen, Acc) ->
    case filename:pathtype(Segment) of
        relative -> srp_segment(Segments, Cwd, Seen, Acc);
        _        -> unsafe
    end.

srp_segment([Segment | Segments], Cwd, Seen, Acc) ->
    Path = filename:join([Cwd | Acc]),
    case file:read_link(filename:join(Path, Segment)) of
        {ok, LinkPath} ->
            srp_link(Path, LinkPath, Segments, Cwd, Seen, Acc);
        {error, _} ->
            srp_path(Segments, Cwd, Seen, Acc ++ [Segment])
    end.

srp_link(Path, LinkPath, Segments, Cwd, Seen, Acc) ->
    FullLinkPath = filename:join(Path, LinkPath),
    case sets:is_element(FullLinkPath, Seen) of
        true ->
            unsafe;
        false ->
            srp_path(filename:split(LinkPath) ++ [clear | Segments],
                     Cwd, sets:add_element(FullLinkPath, Seen), Acc)
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
