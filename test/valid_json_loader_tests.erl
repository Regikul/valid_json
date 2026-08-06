%% Загрузчик схем: контракт поведения, загрузчик каталога и его место в жизни
%% хранилища — чтение на холодном старте, готовность, отметки и перезапуски.
-module(valid_json_loader_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").
-include("valid_json_resources.hrl").

-define(STORE, valid_json_loader_test_store).
-define(PROBE, valid_json_loader_test_probe).
-define(BASE, <<"https://example.com/schemas/">>).

%% Встроенные метасхемы поднимает дерево приложения, и без него компиляция
%% схемы не идёт.
ensure_app() ->
    {ok, _Started} = application:ensure_all_started(valid_json),
    ok.

stop_app() ->
    case application:stop(valid_json) of
        ok ->
            ok;
        {error, {not_started, valid_json}} ->
            ok
    end.

%% -------------------------------------------------------------------
%% Загрузчик каталога
%% -------------------------------------------------------------------

%% Имя документа — путь относительно корня; вложенный каталог даёт составное
%% имя, а файл с другим расширением в набор не попадает.
dir_names_test() ->
    {ok, Entries} = valid_json_loader_dir:load([{root, fixtures()}]),
    ?assertEqual([<<"product/banana.json">>, <<"root.json">>, <<"weight.json">>],
                 [Name || {Name, _Json} <- Entries]),
    ?assertMatch([{_, #{<<"type">> := <<"object">>}} | _], Entries).

%% Расширение — опция, и с другим значением тот же каталог даёт другой набор.
dir_extension_test() ->
    ?assertEqual({ok, []},
                 valid_json_loader_dir:load([{root, fixtures()},
                                             {extension, <<".yaml">>}])),
    with_dir(fun(Dir) ->
        ok = file:write_file(filename:join(Dir, "kept.schema"), <<"true">>),
        ok = file:write_file(filename:join(Dir, "skipped.json"), <<"true">>),
        {ok, Entries} = valid_json_loader_dir:load([{root, Dir},
                                                    {extension, <<".schema">>}]),
        ?assertEqual([<<"kept.schema">>], [Name || {Name, _Json} <- Entries])
    end).

%% Имена набора относительные: путь к файлу адресом схемы не становится, и
%% абсолютным имя делает `base_uri` хранилища.
dir_names_are_relative_test() ->
    {ok, Entries} = valid_json_loader_dir:load([{root, fixtures()}]),
    [?assertMatch({ok, _, root}, valid_json_uri:resolve(Name, ?BASE))
     || {Name, _Json} <- Entries],
    [?assertEqual({error, relative_uri_without_base},
                  valid_json_uri:resolve(Name, anonymous))
     || {Name, _Json} <- Entries].

%% Пробел экранируется, двоеточие в первом сегменте — тоже, иначе имя
%% прочиталось бы как scheme. Обычное имя при этом не меняется ни на байт.
dir_escaping_test() ->
    with_dir(fun(Dir) ->
        ok = file:write_file(filename:join(Dir, "a b.json"), <<"true">>),
        ok = file:write_file(filename:join(Dir, "c:d.json"), <<"true">>),
        ok = file:make_dir(filename:join(Dir, "e f")),
        ok = file:write_file(filename:join([Dir, "e f", "g:h.json"]), <<"true">>),
        {ok, Entries} = valid_json_loader_dir:load([{root, Dir}]),
        ?assertEqual([<<"a%20b.json">>, <<"c%3Ad.json">>, <<"e%20f/g:h.json">>],
                     [Name || {Name, _Json} <- Entries])
    end).

%% Отсутствующий каталог и испорченный файл называют путь: разбираться с
%% конфигурацией будет человек.
dir_errors_test() ->
    ?assertMatch({error, {list, _Path, enoent}},
                 valid_json_loader_dir:load([{root, "no/such/directory"}])),
    with_dir(fun(Dir) ->
        ok = file:write_file(filename:join(Dir, "broken.json"), <<"{oops">>),
        {error, {invalid_json, Path}} = valid_json_loader_dir:load([{root, Dir}]),
        ?assertEqual(<<"broken.json">>, filename:basename(Path))
    end).

%% Корень можно назвать и путём внутри `priv` приложения: в релизе рабочий
%% каталог заранее не известен, а `priv` известен всегда.
dir_priv_dir_test() ->
    Relative = "json_schema/draft-2020-12/output",
    Options = [{priv_dir, valid_json, Relative}],
    {ok, Entries} = valid_json_loader_dir:load(Options),
    ?assertEqual([<<"schema.json">>], [Name || {Name, _Json} <- Entries]).

%% Символьная ссылка — отказ, называющий путь: обходить её значило бы выйти за
%% пределы объявленной области, а молча пропустить — потерять документ, который
%% по имени от схемы не отличается.
dir_symlink_test() ->
    with_dir(fun(Dir) ->
        Inside = filename:join(Dir, "inside"),
        ok = filelib:ensure_dir(filename:join(Inside, "placeholder")),
        ok = file:write_file(filename:join(Inside, "weight.json"), <<"true">>),
        %% Ссылка, не покидающая области, отвергается наравне с прочими:
        %% положить схему в область дешевле, чем проверять цель ссылки.
        Alias = filename:join(Dir, "alias"),
        ok = file:make_symlink("inside", Alias),
        ?assertMatch({error, {link, _Path}},
                     valid_json_loader_dir:load([{root, Dir}])),
        ok = file:delete(Alias),
        ok = file:make_symlink("/etc/hosts", filename:join(Dir, "escape.json")),
        {error, {link, Path}} = valid_json_loader_dir:load([{root, Dir}]),
        ?assertEqual(<<"escape.json">>, filename:basename(Path))
    end).

%% Аргумент без корня — ошибка конфигурации разработчика, а не отказ чтения.
dir_bad_argument_test() ->
    ?assertError(badarg, valid_json_loader_dir:load([])),
    ?assertError(badarg, valid_json_loader_dir:load([{root, fixtures()},
                                                     {extension, oops}])),
    %% Две опции корня сразу — не выбор из двух, а ошибка.
    ?assertError(badarg,
                 valid_json_loader_dir:load([{root, fixtures()},
                                             {priv_dir, valid_json, "json_schema"}])),
    %% Путь, уводящий из `priv` наружу, областью не объявляется: ни `..`, ни
    %% абсолютный, ни путь приложения, которого нет в коде.
    ?assertError(badarg, valid_json_loader_dir:load([{priv_dir, valid_json, "../.."}])),
    ?assertError(badarg, valid_json_loader_dir:load([{priv_dir, valid_json, "/etc"}])),
    ?assertError(badarg, valid_json_loader_dir:load([{priv_dir, no_such_app, "schemas"}])),
    ?assertError(badarg, valid_json_loader_dir:load([{priv_dir, valid_json, oops}])).

%% -------------------------------------------------------------------
%% Загрузчик в хранилище
%% -------------------------------------------------------------------

%% Холодный старт наполняет хранилище целиком: ссылки между файлами каталога
%% сошлись, потому что набор ушёл в реестр одним вызовом.
dir_store_test() ->
    with_store([{base_uri, ?BASE}, {loader, dir_loader()}], fun(Store) ->
        {ok, _Ref} = valid_json_store_manager:wait(Store, 5000),
        ?assertEqual(true, valid(Store, <<"root.json">>,
                                 #{<<"banana">> => #{<<"weight">> => 3}})),
        ?assertEqual(false, valid(Store, <<"root.json">>,
                                  #{<<"banana">> => #{<<"weight">> => 0}})),
        %% Требование `weight` живёт в соседнем файле, а `minimum` — в третьем.
        ?assertEqual(false, valid(Store, <<"root.json">>,
                                  #{<<"banana">> => #{}})),
        ?assertEqual(true, valid(Store, <<"weight.json">>, 1))
    end).

%% Имена набора называет хранилище: относительное имя файла ложится под
%% `base_uri` и адресуется только получившимся именем.
store_base_uri_test() ->
    with_store([{base_uri, ?BASE}, {loader, dir_loader()}], fun(Store) ->
        {ok, _Ref} = valid_json_store_manager:wait(Store, 5000),
        ?assertMatch({ok, _},
                     valid_json_store_manager:lookup(
                       Store, <<"https://example.com/schemas/weight.json">>)),
        ?assertEqual(true, valid(Store, <<"root.json">>,
                                 #{<<"banana">> => #{<<"weight">> => 3}}))
    end).

%% Один и тот же набор под двумя хранилищами получает разные имена: `base_uri`
%% и есть способ заявить о принадлежности схем сервису.
two_stores_name_apart_test() ->
    Shop = <<"https://shop.service/schemas/">>,
    with_store([{base_uri, Shop}, {loader, dir_loader()}], fun(Store) ->
        {ok, _Ref} = valid_json_store_manager:wait(Store, 5000),
        ?assertMatch({ok, _},
                     valid_json_store_manager:lookup(
                       Store, <<"https://shop.service/schemas/weight.json">>)),
        %% Имя чужого хранилища здесь не значит ничего.
        ?assertEqual({error, not_found},
                     valid_json_store_manager:lookup(
                       Store, <<"https://example.com/schemas/weight.json">>))
    end).

%% Хранилище без `base_uri` называть свои схемы нечем, и старт его кончается
%% badarg.
missing_base_uri_test() ->
    ?assertEqual(dead, tree_outcome([{loader, dir_loader()}])).

%% Загрузчик отдаёт только относительные имена, а абсолютными их делает
%% хранилище: собственному загрузчику для этого не нужно знать ничего.
relative_names_test() ->
    Entries = [{<<"weight">>, #{<<"type">> => <<"integer">>}}],
    Loader = {valid_json_test_loader, #{load => fun() -> {ok, Entries} end}},
    with_store([{base_uri, ?BASE}, {loader, Loader}], fun(Store) ->
        {ok, _Ref} = valid_json_store_manager:wait(Store, 5000),
        ?assertMatch({ok, _},
                     valid_json_store_manager:lookup(
                       Store, <<"https://example.com/schemas/weight">>))
    end).

%% Загрузчик стандартного хранилища задаётся только через app env: его дерево
%% поднимает библиотека, и опций ему передать неоткуда.
standard_store_loader_test() ->
    ok = stop_app(),
    ok = application:set_env(valid_json, loader, dir_loader()),
    {ok, _Started} = application:ensure_all_started(valid_json),
    try
        {ok, _Ref} = valid_json:wait(5000),
        ?assertEqual({ok, #{<<"valid">> => true}},
                     valid_json:validate(<<"weight.json">>, 5,
                                             [{output, flag}]))
    after
        ok = application:stop(valid_json),
        ok = application:unset_env(valid_json, loader)
    end.

%% -------------------------------------------------------------------
%% Чтение загрузчика и отказы
%% -------------------------------------------------------------------

%% Холодный старт читает загрузчик ровно один раз, и набор сразу годен к
%% вычислению.
%%
%% Проверки перезапуска идут по одной и каждая поднимает своё дерево: intensity
%% супервизора хранилища равна единице, и два убийства подряд оно не переживает.
cold_start_reads_loader_test() ->
    with_loaded(fun(Store) ->
        ?assertEqual(1, calls()),
        ?assertEqual(true, valid(Store, ?BASE, 1))
    end).

%% Умер управляющий: целы обе таблицы и обе отметки, поэтому загрузчик молчит.
restart_manager_test() ->
    with_loaded(fun(Store) ->
        restart(Store, manager(Store)),
        ?assertEqual(1, calls()),
        ?assertEqual(true, valid(Store, ?BASE, 1))
    end).

%% Умер хранитель артефактов: отметка `loaded` пережила вместе с таблицей
%% реестра, поэтому артефакты пересобираются из документов, а загрузчик молчит.
restart_artifacts_keeper_test() ->
    with_loaded(fun(Store) ->
        restart(Store, keeper(valid_json_store_manager:artifacts_table(Store))),
        ?assertEqual(1, calls()),
        ?assertEqual(true, valid(Store, ?BASE, 1))
    end).

%% Умер хранитель реестра: исчезли обе таблицы и обе отметки, и восстановить
%% набор может только сам загрузчик. Это та полная пересборка, которая без него
%% доставалась приложению.
restart_registry_keeper_test() ->
    with_loaded(fun(Store) ->
        restart(Store, keeper(valid_json_store_manager:registry_table(Store))),
        ?assertEqual(2, calls()),
        ?assertEqual(true, valid(Store, ?BASE, 1))
    end).

%% Снятый документ повторным чтением не возвращается: загрузчик молчит, пока
%% реестр цел. Ради этого признаком и служит отметка, а не пустота реестра.
removed_document_stays_removed_test() ->
    with_loaded(fun(Store) ->
        ?assertEqual(ok, valid_json_store_manager:remove(Store, [?BASE])),
        restart(Store, manager(Store)),
        ?assertEqual(1, calls()),
        ?assertEqual({error, not_found},
                     valid_json_store_manager:lookup(Store, ?BASE))
    end).

%% Отказ загрузчика — расхождение конфигурации, а не ошибка вызывающего:
%% хранилище с дырой в наборе не поднимается вовсе.
loader_failure_test() ->
    Failing = {valid_json_test_loader,
               #{load => fun() -> {error, no_such_directory} end}},
    ?assertEqual(dead, tree_outcome([{base_uri, ?BASE}, {loader, Failing}])).

%% Отказ компиляции набора разбирается там же и так же.
loader_compilation_failure_test() ->
    Broken = {valid_json_test_loader,
              #{load => fun() -> {ok, [{<<"broken">>, #{<<"type">> => 1}}]} end}},
    ?assertEqual(dead, tree_outcome([{base_uri, ?BASE}, {loader, Broken}])).

%% Негодная опция загрузчика останавливает старт так же громко, как любая
%% другая.
bad_loader_option_test() ->
    ?assertEqual(dead, tree_outcome([{base_uri, ?BASE}, {loader, not_a_loader}])).

%% -------------------------------------------------------------------
%% Готовность
%% -------------------------------------------------------------------

%% На OTP 20 загрузка выполняется в init/1, поэтому стартующий supervisor не
%% возвращается до завершения загрузчика; первое сообщение к дереву поэтому не
%% может обогнать загрузку.
startup_waits_for_loader_test() ->
    ok = ensure_app(),
    Parent = self(),
    Blocking = {valid_json_test_loader,
                #{load => fun() ->
                                  Parent ! {loading, self()},
                                  receive release -> {ok, entries()} end
                          end}},
    Starter = spawn(fun() ->
        process_flag(trap_exit, true),
        Result = valid_json_store_sup:start_link(
                   ?STORE, [{base_uri, ?BASE}, {loader, Blocking}]),
        Parent ! {started, self(), Result},
        receive stop -> ok end
    end),
    Manager = receive {loading, Pid} -> Pid
              after 5000 -> erlang:error(no_loading) end,
    Manager ! release,
    Sup = receive
              {started, Starter, {ok, SupPid}} -> SupPid
          after 5000 -> erlang:error(start_timeout)
          end,
    Ref = erlang:monitor(process, Sup),
    exit(Sup, kill),
    receive {'DOWN', Ref, process, Sup, _Reason} -> ok
    after 5000 -> erlang:error(store_alive) end,
    Starter ! stop.

%% Хранилища нет вовсе: чтение отвечает тем же `unavailable` и не падает, потому
%% что исполняется в процессе вызывающего.
unavailable_without_store_test() ->
    ?assertEqual({error, unavailable},
                 valid_json_store_manager:lookup(valid_json_loader_no_store,
                                                 <<"https://example.com/x">>)).

%% Монитор ставится до подтверждения готовности, поэтому смерть управляющего
%% после ответа не проходит мимо вызывающего.
wait_monitor_test() ->
    with_store([{base_uri, ?BASE}], fun(Store) ->
        {ok, Ref} = valid_json_store_manager:wait(Store, 5000),
        Manager = manager(Store),
        exit(Manager, kill),
        receive
            {'DOWN', Ref, process, Manager, killed} -> ok
        after 5000 ->
            erlang:error(no_down)
        end,
        %% Хранилище живо и после этого: следующий `wait` подтверждает нового
        %% управляющего и отдаёт новый монитор.
        ?assertMatch({ok, _NewRef}, valid_json_store_manager:wait(Store, 5000))
    end).

%% Управляющего нет и не будет: `wait` не падает, а исчерпывает свой таймаут.
wait_timeout_test() ->
    Started = erlang:monotonic_time(millisecond),
    ?assertEqual({error, timeout},
                 valid_json_store_manager:wait(valid_json_loader_no_store, 150)),
    Spent = erlang:monotonic_time(millisecond) - Started,
    ?assert(Spent >= 150),
    ?assert(Spent < 5000).

%% -------------------------------------------------------------------
%% Вспомогательное
%% -------------------------------------------------------------------

dir_loader() ->
    {valid_json_loader_dir, [{root, fixtures()}]}.

%% Единственный документ набора назван полным именем: так проверке не нужно
%% пересчитывать короткое имя под `base_uri` хранилища.
entries() ->
    [{?BASE, #{<<"type">> => <<"integer">>}}].

counting_loader() ->
    {valid_json_test_loader,
     #{load => fun() ->
                       ets:update_counter(?PROBE, calls, 1),
                       {ok, entries()}
               end}}.

calls() ->
    ets:lookup_element(?PROBE, calls, 2).

%% Хранилище со считающим загрузчиком, договорившее свой старт.
with_loaded(Fun) ->
    ok = ensure_app(),
    with_probe(fun() ->
        with_store([{base_uri, ?BASE}, {loader, counting_loader()}], fun(Store) ->
            {ok, _Ref} = valid_json_store_manager:wait(Store, 5000),
            Fun(Store)
        end)
    end).

%% Счётчик живёт в таблице, потому что загрузчик исполняется в управляющем, а
%% считает вызовы проверка.
with_probe(Fun) ->
    ?PROBE = ets:new(?PROBE, [named_table, public, set]),
    true = ets:insert(?PROBE, {calls, 0}),
    try Fun()
    after
        true = ets:delete(?PROBE)
    end.

with_store(Options, Fun) ->
    ok = ensure_app(),
    {ok, Sup} = valid_json_store_sup:start_link(?STORE, Options),
    try Fun(?STORE)
    after
        stop_store(Sup)
    end.

stop_store(Sup) ->
    unlink(Sup),
    Ref = erlang:monitor(process, Sup),
    exit(Sup, shutdown),
    receive {'DOWN', Ref, process, Sup, _Reason} -> ok
    after 5000 -> erlang:error(store_alive) end.

%% Дерево с негодной конфигурацией либо не поднимается вовсе, либо умирает сразу
%% после старта. Проверке важно ровно то, что живым оно не остаётся.
tree_outcome(Options) ->
    ok = ensure_app(),
    Parent = self(),
    {Worker, WorkerRef} = spawn_monitor(fun() ->
        process_flag(trap_exit, true),
        Result = (catch valid_json_store_sup:start_link(?STORE, Options)),
        Parent ! {tree_outcome, self(), Result},
        receive stop -> ok end
    end),
    Outcome = receive
                  {tree_outcome, Worker, {ok, Sup}} ->
                      Ref = erlang:monitor(process, Sup),
                      exit(Sup, kill),
                      receive {'DOWN', Ref, process, Sup, _SupReason} -> dead
                      after 5000 -> alive end;
                  {tree_outcome, Worker, {error, _StartReason}} ->
                      dead;
                  {tree_outcome, Worker, {'EXIT', _ExitReason}} ->
                      dead
              after 5000 ->
                  alive
              end,
    Worker ! stop,
    receive {'DOWN', WorkerRef, process, Worker, _WorkerReason} -> ok
    after 5000 -> exit(Worker, kill) end,
    Outcome.

manager(Store) ->
    whereis(valid_json_store_manager:manager_name(Store)).

keeper(Table) ->
    whereis(valid_json_ets_keeper:keeper_name(Table)).

%% Убитый процесс уносит с собой управляющего: оба хранителя стоят в rest_for_one
%% перед ним. Ждём именно нового управляющего и договорившего старт.
restart(Store, Pid) ->
    Name = valid_json_store_manager:manager_name(Store),
    Manager = manager(Store),
    Ref = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, process, Pid, killed} -> ok
    after 1000 -> erlang:error(process_alive) end,
    Restarted = wait_restart(Name, Manager, 200),
    _State = sys:get_state(Restarted),
    Restarted.

wait_restart(_Name, _Old, 0) ->
    erlang:error(no_restart);
wait_restart(Name, Old, Attempts) ->
    case whereis(Name) of
        undefined -> timer:sleep(10), wait_restart(Name, Old, Attempts - 1);
        Old       -> timer:sleep(10), wait_restart(Name, Old, Attempts - 1);
        Pid       -> Pid
    end.

valid(Store, Uri, Instance) ->
    {ok, #{<<"valid">> := Valid}} =
        valid_json:store_validate(Store, Uri, Instance, [{output, flag}]),
    Valid.

fixtures() ->
    Relative = ["test", "fixtures", "loader_dir"],
    Candidates =
        case code:lib_dir(valid_json) of
            {error, _} -> [filename:join(Relative)];
            AppDir     -> [filename:join([AppDir | Relative]), filename:join(Relative)]
        end,
    case [Dir || Dir <- Candidates, filelib:is_dir(Dir)] of
        [Dir | _] -> Dir;
        []        -> erlang:error({fixtures_not_found, Candidates})
    end.

%% Каталоги под отдельные случаи собираются на месте: держать в fixtures
%% испорченный JSON и файлы с экзотическими именами незачем.
with_dir(Fun) ->
    Dir = filename:join(scratch(),
                        "loader_" ++ integer_to_list(erlang:unique_integer([positive]))),
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
        {ok, _}                            -> file:delete(Path);
        {error, enoent}                     -> ok
    end.

scratch() ->
    case code:lib_dir(valid_json) of
        {error, _} -> ".";
        AppDir     -> AppDir
    end.
