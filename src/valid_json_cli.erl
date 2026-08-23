%% Командная проверка каталога JSON Schema documents. Рабочий вход `run/1`
%% возвращает код возврата и вывод значением; писать в устройство и завершать
%% VM позволено только `main/1`, поэтому проверять поведение команды можно
%% обычным тестом.
%%
%% Первичное дело команды — валидация, и её продукт — output units, поэтому в
%% stdout уходят документы вывода спецификации как есть, по одному на строку. Всё, до чего валидация
%% не добралась — негодный аргумент, нечитаемый каталог, документ, который не
%% удалось зарегистрировать или скомпилировать, — идёт прозой в stderr и
%% машинным выводом не является. Разделитель ровно один: есть ли у ошибки
%% output units.
%%
%% Приложение команде не нужно: набор регистрируется в чистом store и
%% проверяется одним проходом `valid_json_schema_set:check/2`, а встроенные
%% метасхемы приходят значением. Ни ETS, ни дерева супервизоров при этом не
%% возникает, и escript обходится одним запуском VM.
-module(valid_json_cli).

-include("valid_json_core.hrl").

-export([main/1, run/1]).

-type destination() :: stdout | stderr.
-type result() :: {non_neg_integer(), [{destination(), unicode:chardata()}]}.
-type command() :: help | version | {check, map()} | {error, unicode:chardata()}.

-define(EXIT_OK, 0).
-define(EXIT_INVALID, 1).
-define(EXIT_USAGE, 2).

-spec main([string()]) -> no_return().
main(Arguments) ->
    {Code, Outputs} = run(Arguments),
    ok = emit(Outputs),
    erlang:halt(Code).

-spec run([unicode:chardata()]) -> result().
run(Arguments) when is_list(Arguments) ->
    case arguments(Arguments, []) of
        {ok, Parsed} ->
            dispatch(parse(Parsed));
        error ->
            {?EXIT_USAGE, [{stderr, "valid-json: arguments are not valid UTF-8\n"}]}
    end;
run(Arguments) ->
    erlang:error(badarg, [Arguments]).

%% Аргументы приходят байтами операционной системы, и годными для UTF-8 они
%% быть не обязаны. Имя, которое сама VM разобрать не сумела, доходит сюда тем,
%% что от разбора осталось: читать в нём нечего, и отказ здесь честнее падения
%% ниже по течению.
-spec arguments([term()], [binary()]) -> {ok, [binary()]} | error.
arguments([], Acc) ->
    {ok, lists:reverse(Acc)};
arguments([Argument | Rest], Acc) when is_list(Argument); is_binary(Argument) ->
    case unicode:characters_to_binary(Argument) of
        Binary when is_binary(Binary) -> arguments(Rest, [Binary | Acc]);
        _Error                        -> error
    end;
arguments([_Argument | _Rest], _Acc) ->
    error.

-spec dispatch(command()) -> result().
dispatch(help) ->
    {?EXIT_OK, [{stdout, help()}]};
dispatch(version) ->
    {?EXIT_OK, [{stdout, version()}]};
dispatch({check, Options}) ->
    check(Options);
dispatch({error, Message}) ->
    {?EXIT_USAGE, [{stderr, ["valid-json: ", Message, "\n", usage()]}]}.

-spec emit([{destination(), unicode:chardata()}]) -> ok.
emit([]) ->
    ok;
emit([{stdout, Text} | Rest]) ->
    io:put_chars(standard_io, Text),
    emit(Rest);
emit([{stderr, Text} | Rest]) ->
    io:put_chars(standard_error, Text),
    emit(Rest).

-spec parse([binary()]) -> command().
parse([]) ->
    {error, "a command is required"};
parse([<<"--help">>]) ->
    help;
parse([<<"-h">>]) ->
    help;
parse([<<"--version">>]) ->
    version;
parse([<<"check">> | Rest]) ->
    parse_check(Rest, #{default_dialect => undefined, directory => undefined});
parse([Command | _Rest]) ->
    {error, ["unknown command: ", Command]}.

-spec parse_check([binary()], map()) -> command().
parse_check([], #{directory := undefined}) ->
    {error, "check requires a directory"};
parse_check([], Options) ->
    {check, Options};
parse_check([<<"--default-dialect">>, Uri | Rest], Options) ->
    parse_check(Rest, Options#{default_dialect => Uri});
parse_check([<<"-", _/binary>> = Option | _Rest], _Options) ->
    {error, ["unknown option or missing value: ", Option]};
parse_check([Directory | Rest], #{directory := undefined} = Options) ->
    parse_check(Rest, Options#{directory => Directory});
parse_check([Directory | _Rest], _Options) ->
    {error, ["unexpected argument: ", Directory]}.

-spec check(map()) -> result().
check(#{directory := Directory} = Options) ->
    Root = unicode:characters_to_list(Directory),
    case valid_json_loader_dir:load([{root, Root}]) of
        {ok, []} ->
            %% Проверить нечего — значит работа не сделана, а не сделана
            %% успешно: молчаливый ноль здесь неотличим от проверенного
            %% каталога и потому лжёт.
            {?EXIT_USAGE, [{stderr, ["valid-json: no schema documents below ",
                                     path(Root), "\n"]}]};
        {ok, Entries} ->
            checked(valid_json_schema_set:check(
                      Entries, check_options(base_uri(Root), Options)));
        {error, Error} ->
            {?EXIT_USAGE, [{stderr, ["valid-json: ", loader_error(Error), "\n"]}]}
    end.

%% Схема, прочитанная из файла, называется своим адресом получения, и адрес
%% этот команда знает: каталог она приняла аргументом. Путь известен ей, а
%% правила URI — нет, поэтому кодирует сегменты `uri_string` через
%% совместимую обёртку библиотеки.
-spec base_uri(file:filename_all()) -> uri().
base_uri(Root) ->
    Absolute = unicode:characters_to_binary(filename:absname(Root)),
    Uri = valid_json_uri_backend:recompose(#{scheme => <<"file">>,
                                             host => <<>>,
                                             path => escape(Absolute)}),
    trailing_slash(Uri).

%% `recompose` кодирует то, что в path запрещено, но процент считает началом
%% уже готовой последовательности и не трогает. В пути файла это обычный
%% символ, и записывается он `%25`.
-spec escape(binary()) -> binary().
escape(Path) ->
    binary:replace(Path, <<"%">>, <<"%25">>, [global]).

-spec trailing_slash(uri()) -> uri().
trailing_slash(<<>>) ->
    <<"/">>;
trailing_slash(Uri) ->
    case binary:last(Uri) of
        $/    -> Uri;
        _Byte -> <<Uri/binary, "/">>
    end.

%% Формат вывода зафиксирован на `detailed`: узлы без детей удалены, узлы с
%% единственным ребёнком заменены им, и по дереву видно, какие ошибки связаны
%% между собой, — плоский `basic` этой связи не показывает. Выбора формата
%% команда не предлагает: он принадлежит тому, кто зовёт библиотеку.
-spec check_options(uri(), map()) -> [valid_json_schema_set:check_option()].
check_options(Base, #{default_dialect := undefined}) ->
    [{base_uri, Base}, {schema_validation, detailed}];
check_options(Base, #{default_dialect := Dialect}) ->
    [{base_uri, Base}, {default_dialect, Dialect}, {schema_validation, detailed}].

-spec checked({ok, [uri()]} | {error, valid_json_schema_set:error()}) -> result().
checked({ok, _Names}) ->
    {?EXIT_OK, []};
checked({error, {registration, Errors}}) ->
    %% До валидации такая запись не дожила: предъявить по ней нечего.
    outputs([], unique(Errors));
checked({error, {validation, Errors}}) ->
    {Invalid, Broken} = lists:partition(fun reported/1, unique(Errors)),
    outputs(Invalid, Broken).

%% Отчёт о валидации — это тот случай, когда схему вычислили её метасхемой и
%% получили вердикт. Заполненный `validation_output` и есть признак: другого
%% источника у него нет.
-spec reported({uri(), #schema_error{}}) -> boolean().
reported({_Uri, #schema_error{validation_output = Output}}) ->
    Output =/= undefined.

%% Код 2 перебивает код 1: проверка была неполной, даже если отчёт составить
%% удалось.
-spec outputs([{uri(), #schema_error{}}], [{uri(), #schema_error{}}]) -> result().
outputs(Invalid, Broken) ->
    {code(Invalid, Broken), report(Invalid) ++ diagnostics(Broken)}.

-spec code([term()], [term()]) -> non_neg_integer().
code(_Invalid, [_ | _]) -> ?EXIT_USAGE;
code([_ | _], [])       -> ?EXIT_INVALID;
code([], [])            -> ?EXIT_OK.

%% Схем N, проверок N и результатов N: сводить их во что-то одно незачем, в
%% одну схему они не превращались. Поэтому stdout — поток документов, по одному
%% на строку.
-spec report([{uri(), #schema_error{}}]) -> [{destination(), unicode:chardata()}].
report([]) ->
    [];
report(Invalid) ->
    [{stdout, [result(Error) || Error <- Invalid]}].

%% Документ вывода уходит как есть, и своего в нём один ключ: какой инстанс
%% проверяли. Слота под это у вывода нет — `instanceLocation` указывает внутрь
%% инстанса, а `absoluteKeywordLocation` называет метасхему, — зато лишние
%% ключи выходная схема спецификации не запрещает, и документ остаётся годным
%% по ней.
-spec result({uri(), #schema_error{}}) -> unicode:chardata().
result({Uri, #schema_error{location = Location, validation_output = Output}}) ->
    [json:encode(Output#{<<"instance">> => document(Uri, Location)}), "\n"].

%% Виноватый документ называет локация: до схемы могли дойти по ссылке из
%% другой, и ключом проверки оказалась бы она.
-spec document(uri(), addr() | undefined) -> uri().
document(_Uri, {Rid, _Pointer}) when is_binary(Rid) -> Rid;
document(Uri, _Location)                            -> Uri.

%% Диагностика — это слова библиотеки: свой словарь причин команде заводить
%% незачем. Имя записи печатается только там, где у ошибки нет локации и
%% сообщение потому не называет документ само.
-spec diagnostics([{uri(), #schema_error{}}]) ->
          [{destination(), unicode:chardata()}].
diagnostics([]) ->
    [];
diagnostics(Broken) ->
    [{stderr, [diagnostic(Error) || Error <- Broken]}].

-spec diagnostic({uri(), #schema_error{}}) -> unicode:chardata().
diagnostic({Uri, #schema_error{location = undefined} = Error}) ->
    ["valid-json: ", Uri, ": ", valid_json:format_error(Error), "\n"];
diagnostic({_Uri, Error}) ->
    ["valid-json: ", valid_json:format_error(Error), "\n"].

%% Схема попадает под проверку дважды: своим именем и в составе closure того,
%% кто на неё сослался. Ошибка выходит та же самая, и печатать её второй раз
%% незачем. Различает записи их содержимое, а не имя, под которым проверка до
%% них дошла; порядок первого появления сохраняется.
-spec unique([{uri(), #schema_error{}}]) -> [{uri(), #schema_error{}}].
unique(Errors) ->
    {Unique, _Seen} =
        lists:foldl(fun({_Uri, Error} = Entry, {Acc, Seen}) ->
                            case maps:is_key(Error, Seen) of
                                true  -> {Acc, Seen};
                                false -> {[Entry | Acc], Seen#{Error => []}}
                            end
                    end, {[], #{}}, Errors),
    lists:reverse(Unique).

%% Ошибки чтения печатает команда: они называют файл и системную причину, и
%% ничего сверх этого о них знать не нужно.
-spec loader_error(valid_json_loader_dir:error()) -> unicode:chardata().
loader_error({list, Path, Reason}) ->
    ["cannot list ", path(Path), ": ", file:format_error(Reason)];
loader_error({read, Path, Reason}) ->
    ["cannot read ", path(Path), ": ", file:format_error(Reason)];
loader_error({link, Path}) ->
    ["symbolic link is not followed: ", path(Path)];
loader_error({invalid_json, Path}) ->
    ["not valid JSON: ", path(Path)].

-spec path(file:filename_all()) -> unicode:chardata().
path(Path) when is_binary(Path) -> Path;
path(Path)                      -> unicode:characters_to_binary(Path).

-spec usage() -> unicode:chardata().
usage() ->
    "usage: valid-json check [--default-dialect URI] DIRECTORY\n".

-spec help() -> unicode:chardata().
help() ->
    [usage(),
     "       valid-json --help\n",
     "       valid-json --version\n",
     "\n",
     "check   Check every .json document below DIRECTORY against its meta-schema.\n"
     "        Documents are registered together, so cross-file $ref resolves. A\n"
     "        schema is named by its own $id, and by its path below DIRECTORY when\n"
     "        it has none.\n"
     "\n"
     "Nothing to report is silence and exit code 0. Exit code 1 means a schema\n"
     "failed its meta-schema: stdout carries one standard output document per\n"
     "line in the spec's \"detailed\" format, one line per schema, each naming the\n"
     "schema it describes in an extra \"instance\" member. Exit code 2 means the\n"
     "tool could not check something -- bad arguments, an unreadable or empty\n"
     "directory, a document that could not be registered or compiled -- and the\n"
     "reason goes to stderr.\n"].

-spec version() -> unicode:chardata().
version() ->
    case application:load(valid_json) of
        ok                                    -> ok;
        {error, {already_loaded, valid_json}} -> ok
    end,
    {ok, Version} = application:get_key(valid_json, vsn),
    ["valid-json ", Version, "\n"].
