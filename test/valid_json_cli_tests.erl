-module(valid_json_cli_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").
-include("valid_json_resources.hrl").

-define(VALID, #{<<"$schema">> => ?DRAFT_2020_12, <<"type">> => <<"object">>}).
-define(INVALID, #{<<"$schema">> => ?DRAFT_2020_12, <<"type">> => <<"objekt">>}).

%% Команда не поднимает приложение: набор проверяется чистым проходом, и ни
%% дерева супервизоров, ни таблиц после неё не остаётся.
check_runs_without_application_test() ->
    stop_application(),
    try
        Tables = lists:sort(ets:all()),
        with_dir(fun(Dir) ->
                         write(Dir, "schema.json", ?VALID),
                         ?assertEqual({0, []}, run(["check", Dir]))
                 end),
        ?assertEqual(undefined, whereis(valid_json_sup)),
        ?assertEqual(Tables, lists:sort(ets:all()))
    after
        {ok, _Started} = application:ensure_all_started(valid_json)
    end.

valid_directory_is_silent_test() ->
    with_dir(fun(Dir) ->
                     write(Dir, "root.json", referring()),
                     write(Dir, "sub/leaf.json", ?VALID),
                     ?assertEqual({0, []}, run(["check", Dir]))
             end).

%% Проверить нечего — это не успех: молчаливый ноль был бы неотличим от
%% проверенного каталога.
empty_directory_test() ->
    with_dir(fun(Dir) ->
                     {2, [{stderr, Text}]} = run(["check", Dir]),
                     ?assert(match(iolist_to_binary(Text),
                                   <<"no schema documents below ">>))
             end),
    with_dir(fun(Dir) ->
                     ok = file:write_file(filename:join(Dir, "notes.txt"),
                                          <<"not a schema">>),
                     ?assertMatch({2, [{stderr, _Text}]}, run(["check", Dir]))
             end).

%% Отчёт о валидации идёт в stdout: код 1, документ вывода и имя инстанса.
%% Что лежит внутри units, держат тесты вывода библиотеки.
invalid_schema_goes_to_stdout_test() ->
    with_dir(fun(Dir) ->
                     write(Dir, "sub/leaf.json", ?INVALID),
                     {1, [{stdout, Text}]} = run(["check", Dir]),
                     [#{<<"instance">> := Instance,
                        <<"errors">> := _Units}] = documents(Text),
                     ?assert(match(Instance, <<"sub/leaf.json">>))
             end).

%% Схем N — значит и документов N: сводить их во что-то одно незачем, в одну
%% схему они не превращались.
n_schemas_give_n_documents_test() ->
    with_dir(fun(Dir) ->
                     write(Dir, "a.json", ?INVALID),
                     write(Dir, "sub/b.json", ?INVALID),
                     write(Dir, "sub/c.json", ?INVALID),
                     {1, [{stdout, Text}]} = run(["check", Dir]),
                     Instances = [maps:get(<<"instance">>, Document)
                                  || Document <- documents(Text)],
                     ?assertEqual(3, length(Instances)),
                     ?assertEqual(3, length(lists:usort(Instances)))
             end).

%% Схема проверяется дважды: своим именем и в составе closure сославшегося на
%% неё документа. Ошибка при этом одна, и печатается она один раз.
closure_error_is_reported_once_test() ->
    with_dir(fun(Dir) ->
                     write(Dir, "root.json", referring()),
                     write(Dir, "sub/leaf.json", ?INVALID),
                     {1, [{stdout, Text}]} = run(["check", Dir]),
                     [#{<<"instance">> := Instance}] = documents(Text),
                     ?assert(match(Instance, <<"sub/leaf.json">>))
             end).

%% До валидации такая схема не дожила: предъявить по ней нечего, и в stdout не
%% уходит ничего. Слова — у `valid_json:format_error/1`, своё здесь только имя
%% команды.
dangling_reference_goes_to_stderr_test() ->
    with_dir(fun(Dir) ->
                     write(Dir, "root.json",
                           #{<<"$schema">> => ?DRAFT_2020_12,
                             <<"$ref">> => <<"missing.json">>}),
                     {2, [{stderr, Text}]} = run(["check", Dir]),
                     [Line | _] = lines(Text),
                     ?assert(match(Line, <<"valid-json: ">>))
             end).

%% У записи, не дожившей до регистрации, локации нет, и сообщение документ не
%% называет — имя приписывает команда.
registration_error_goes_to_stderr_test() ->
    with_dir(fun(Dir) ->
                     Schema = maps:put(<<"$id">>, <<"https://ex.test/same">>,
                                       ?VALID),
                     write(Dir, "first.json", Schema),
                     write(Dir, "second.json", Schema),
                     {2, [{stderr, Text}]} = run(["check", Dir]),
                     ?assert(match(iolist_to_binary(Text),
                                   <<"valid-json: second.json: ">>))
             end).

%% Оба рода ошибок в одном прогоне: отчёт всё равно печатается, но код говорит,
%% что проверка была неполной.
mixed_run_splits_streams_test() ->
    with_dir(fun(Dir) ->
                     write(Dir, "invalid.json", ?INVALID),
                     write(Dir, "broken.json",
                           #{<<"$schema">> => ?DRAFT_2020_12,
                             <<"$ref">> => <<"missing.json">>}),
                     {2, [{stdout, Report}, {stderr, Diagnostic}]} =
                         run(["check", Dir]),
                     ?assertMatch([#{<<"errors">> := _Units}], documents(Report)),
                     ?assert(match(iolist_to_binary(Diagnostic),
                                   <<"broken.json#/$ref: ">>))
             end).

%% Своего в документе ровно один ключ: имя проверенного инстанса. Всё
%% остальное — вывод спецификации, каким его составила библиотека.
report_adds_only_the_instance_test() ->
    with_dir(fun(Dir) ->
                     write(Dir, "sub/leaf.json", ?INVALID),
                     {1, [{stdout, Text}]} = run(["check", Dir]),
                     [Document] = documents(Text),
                     Instance = maps:get(<<"instance">>, Document),
                     ?assert(match(Instance, <<"file:///">>)),
                     ?assert(match(Instance, <<"sub/leaf.json">>)),
                     ?assertEqual([<<"absoluteKeywordLocation">>, <<"errors">>,
                                   <<"instanceLocation">>, <<"keywordLocation">>,
                                   <<"valid">>],
                                  lists:sort(maps:keys(
                                               maps:remove(<<"instance">>,
                                                           Document))))
             end).

%% Схема без `$schema` берёт умолчание: массив в `items` для Draft 2020-12
%% схемой не является, а для Draft 7 это обычная форма.
default_dialect_test() ->
    with_dir(fun(Dir) ->
                     Schema = #{<<"items">> => [#{<<"type">> => <<"string">>}]},
                     write(Dir, "schema.json", Schema),
                     ?assertMatch({1, [{stdout, _Text}]}, run(["check", Dir])),
                     ?assertEqual({0, []},
                                  run(["check", "--default-dialect",
                                       binary_to_list(?DRAFT_07), Dir]))
             end).

%% Отказы обхода держат тесты загрузчика; команда формулирует их сама, и
%% проверяется здесь только это.
loader_errors_test() ->
    with_dir(fun(Dir) ->
                     Missing = filename:join(Dir, "nowhere"),
                     {2, [{stderr, Listing}]} = run(["check", Missing]),
                     ?assert(match(iolist_to_binary(Listing), <<"cannot list ">>))
             end),
    with_dir(fun(Dir) ->
                     ok = file:write_file(filename:join(Dir, "broken.json"),
                                          <<"{oops">>),
                     {2, [{stderr, Text}]} = run(["check", Dir]),
                     ?assert(match(iolist_to_binary(Text), <<"not valid JSON: ">>))
             end).

usage_errors_test() ->
    ?assertMatch({2, [{stderr, _}]}, run([])),
    ?assertMatch({2, [{stderr, _}]}, run(["check"])),
    ?assertMatch({2, [{stderr, _}]}, run(["frobnicate", "."])),
    ?assertMatch({2, [{stderr, _}]}, run(["check", "--format", "json", "."])),
    ?assertMatch({2, [{stderr, _}]}, run(["check", "--nonsense", "."])),
    ?assertMatch({2, [{stderr, _}]}, run(["check", ".", "extra"])).

%% Имя, которое VM разобрать не сумела, приходит остатком разбора; команда
%% отказывает, а не падает.
non_unicode_argument_test() ->
    Argument = {error, "dir/bad", <<128>>},
    ?assertMatch({2, [{stderr, _}]}, valid_json_cli:run(["check", Argument])).

help_and_version_test() ->
    {0, [{stdout, Help}]} = run(["--help"]),
    ?assert(match(iolist_to_binary(Help), <<"usage: valid-json check">>)),
    {0, [{stdout, Version}]} = run(["--version"]),
    {ok, Vsn} = application:get_key(valid_json, vsn),
    Expected = iolist_to_binary(["valid-json ", Vsn, "\n"]),
    ?assertEqual(Expected, iolist_to_binary(Version)).

bad_arguments_test() ->
    ?assertError(badarg, valid_json_cli:run(not_a_list)).

%% Вспомогательное

run(Arguments) ->
    valid_json_cli:run(Arguments).

referring() ->
    #{<<"$schema">> => ?DRAFT_2020_12,
      <<"properties">> => #{<<"a">> => #{<<"$ref">> => <<"sub/leaf.json">>}}}.

%% В stdout идёт поток документов вывода, по одному на строку.
documents(Text) ->
    [json:decode(Line) || Line <- lines(Text)].

lines(Text) ->
    binary:split(iolist_to_binary(Text), <<"\n">>, [global, trim_all]).

match(Subject, Pattern) ->
    binary:match(Subject, Pattern) =/= nomatch.

write(Dir, Name, Json) ->
    Path = filename:join(Dir, Name),
    ok = filelib:ensure_dir(Path),
    ok = file:write_file(Path, json:encode(Json)).

stop_application() ->
    _ = application:stop(valid_json),
    ok.

%% Каталоги собираются на месте: держать в fixtures испорченный JSON и файлы с
%% экзотическими именами незачем.
with_dir(Fun) ->
    Dir = filename:join(scratch(),
                        "cli_" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(Dir, "placeholder")),
    try Fun(Dir)
    after
        ok = delete_dir(Dir)
    end.

delete_dir(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            lists:foreach(fun(Name) -> delete_path(filename:join(Dir, Name)) end,
                          Names),
            file:del_dir(Dir);
        {error, enoent} ->
            ok
    end.

delete_path(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} -> delete_dir(Path);
        {ok, _Info}                        -> file:delete(Path);
        {error, enoent}                    -> ok
    end.

scratch() ->
    case code:lib_dir(valid_json) of
        {error, _Reason} -> ".";
        AppDir           -> AppDir
    end.
