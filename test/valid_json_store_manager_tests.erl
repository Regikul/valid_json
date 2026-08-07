%% Управляющий хранилища: реестр, публикация артефактов, инвалидация по
%% пересечению sources, откат при ошибке компиляции, опции и перезапуск.
-module(valid_json_store_manager_tests).

-include_lib("eunit/include/eunit.hrl").
-include("valid_json_resources.hrl").

%% Хранилище именованное, а имя таблицы глобально, поэтому проверки идут по
%% одной: каждая поднимает собственное дерево и гасит его за собой.
-define(STORE, valid_json_test_managed_store).
-define(BASE, <<"https://example.com/schemas/">>).

%% Встроенные метасхемы поднимает дерево приложения, и без него компиляция
%% схемы не идёт.
ensure_app() ->
    {ok, _Started} = application:ensure_all_started(valid_json),
    ok.

eunit_wrapper_(Tests) ->
    {setup, fun ensure_app/0, Tests}.

%% Добавленный документ публикуется под своим именем и годен к вычислению сразу.
add_test() ->
    with_store([{base_uri, ?BASE}], fun(Store) ->
        Uri = <<"https://example.com/integer">>,
        ?assertEqual({ok, [Uri]},
                     valid_json_store_manager:add_at(
                       Store, [{Uri, #{<<"type">> => <<"integer">>}}])),
        ?assertEqual(true, valid(Store, Uri, 1)),
        ?assertEqual(false, valid(Store, Uri, <<"a">>))
    end).

%% Имя артефакта — каноническое имя документа. Адрес загрузки остаётся ключом
%% реестра и в таблицу не попадает.
canonical_name_test() ->
    with_store([{base_uri, ?BASE}], fun(Store) ->
        Registered = <<"https://example.com/registered">>,
        Canonical = <<"https://example.com/canonical">>,
        Schema = #{<<"$id">> => Canonical, <<"type">> => <<"integer">>},
        ?assertEqual({ok, [Canonical]},
                     valid_json_store_manager:add_at(Store, [{Registered, Schema}])),
        ?assertMatch({ok, _}, valid_json_store_manager:lookup(Store, Canonical)),
        ?assertEqual({error, not_found},
                     valid_json_store_manager:lookup(Store, Registered))
    end).

%% Резолв не ленивый, поэтому взаимно ссылающиеся документы обязаны прийти одним
%% вызовом; артефакт заводится на каждый из них.
mutual_refs_test() ->
    with_store([{base_uri, ?BASE}], fun(Store) ->
        First = <<"https://example.com/first">>,
        Second = <<"https://example.com/second">>,
        Entries = [{First, ref_property(<<"second">>, Second)},
                   {Second, ref_property(<<"first">>, First)}],
        ?assertEqual({ok, [First, Second]},
                     valid_json_store_manager:add_at(Store, Entries)),
        ?assertMatch({ok, _}, valid_json_store_manager:lookup(Store, First)),
        ?assertMatch({ok, _}, valid_json_store_manager:lookup(Store, Second))
    end).

%% Замена документа пересобирает чужой артефакт, у которого изменённое имя стоит
%% в sources. Обратного индекса для этого не нужно.
invalidation_test() ->
    with_store([{base_uri, ?BASE}], fun(Store) ->
        Leaf = <<"https://example.com/leaf">>,
        Root = <<"https://example.com/root">>,
        {ok, [Leaf]} = valid_json_store_manager:add_at(
                         Store, [{Leaf, #{<<"type">> => <<"integer">>}}]),
        {ok, [Root]} = valid_json_store_manager:add_at(
                         Store, [{Root, #{<<"$ref">> => Leaf}}]),
        ?assertEqual(true, valid(Store, Root, 1)),
        ?assertEqual(false, valid(Store, Root, <<"a">>)),
        {ok, [Leaf]} = valid_json_store_manager:add_at(
                         Store, [{Leaf, #{<<"type">> => <<"string">>}}]),
        ?assertEqual(false, valid(Store, Root, 1)),
        ?assertEqual(true, valid(Store, Root, <<"a">>))
    end).

%% Замена по тому же адресу загрузки освобождает прежнее каноническое имя, и
%% артефакт под ним снимается: множество ключей таблицы следует за реестром.
replacement_test() ->
    with_store([{base_uri, ?BASE}], fun(Store) ->
        Registered = <<"https://example.com/document">>,
        First = <<"https://example.com/first">>,
        Second = <<"https://example.com/second">>,
        {ok, [First]} = valid_json_store_manager:add_at(
                          Store, [{Registered, #{<<"$id">> => First}}]),
        {ok, [Second]} = valid_json_store_manager:add_at(
                           Store, [{Registered, #{<<"$id">> => Second}}]),
        ?assertEqual({error, not_found},
                     valid_json_store_manager:lookup(Store, First)),
        ?assertMatch({ok, _}, valid_json_store_manager:lookup(Store, Second))
    end).

%% Ошибка компиляции оставляет прежними и таблицу, и реестр. Второе проверяется
%% косвенно: если бы сломанный документ остался в реестре, следующий добавленный
%% документ починил бы его и артефакт появился бы сам собой.
rollback_test() ->
    with_store([{base_uri, ?BASE}], fun(Store) ->
        Good = <<"https://example.com/good">>,
        Broken = <<"https://example.com/broken">>,
        Missing = <<"https://example.com/missing">>,
        {ok, [Good]} = valid_json_store_manager:add_at(
                         Store, [{Good, #{<<"type">> => <<"integer">>}}]),
        ?assertMatch({error,
                      {compilation,
                       [{Broken, #schema_error{reason = {unknown_document, Missing}}}]}},
                     valid_json_store_manager:add_at(
                       Store, [{Broken, #{<<"$ref">> => Missing}}])),
        ?assertEqual({error, not_found},
                     valid_json_store_manager:lookup(Store, Broken)),
        ?assertEqual(true, valid(Store, Good, 1)),
        {ok, [Missing]} = valid_json_store_manager:add_at(
                            Store, [{Missing, #{<<"type">> => <<"integer">>}}]),
        ?assertEqual({error, not_found},
                     valid_json_store_manager:lookup(Store, Broken))
    end).

%% Ошибка регистрации относится к вызову целиком и приходит одна, без списка.
name_taken_test() ->
    with_store([{base_uri, ?BASE}], fun(Store) ->
        Taken = <<"https://example.com/taken">>,
        Other = <<"https://example.com/other">>,
        {ok, [Taken]} = valid_json_store_manager:add_at(
                          Store, [{Taken, #{<<"type">> => <<"integer">>}}]),
        %% Ключ ошибки регистрации — имя записи, а не занятое имя: их тут два
        %% разных, и путать их нельзя.
        ?assertEqual({error, {registration,
                              [{Other, #schema_error{reason = {name_taken, Taken},
                                                     location = undefined}}]}},
                     valid_json_store_manager:add_at(
                       Store, [{Other, #{<<"$id">> => Taken}}])),
        ?assertEqual(true, valid(Store, Taken, 1)),
        ?assertEqual({error, not_found},
                     valid_json_store_manager:lookup(Store, Other))
    end).

%% Удаление снимает и документ, и его артефакт.
remove_test() ->
    with_store([{base_uri, ?BASE}], fun(Store) ->
        Uri = <<"https://example.com/integer">>,
        {ok, [Uri]} = valid_json_store_manager:add_at(
                        Store, [{Uri, #{<<"type">> => <<"integer">>}}]),
        ?assertEqual(ok, valid_json_store_manager:remove(Store, [Uri])),
        ?assertEqual({error, not_found},
                     valid_json_store_manager:lookup(Store, Uri)),
        %% Реестр освободился вместе с таблицей: имя снова свободно.
        ?assertEqual({ok, [Uri]},
                     valid_json_store_manager:add_at(
                       Store, [{Uri, #{<<"type">> => <<"integer">>}}]))
    end).

%% Неизвестное имя удалять нечего, и это не ошибка.
remove_unknown_test() ->
    with_store([{base_uri, ?BASE}], fun(Store) ->
        ?assertEqual(ok, valid_json_store_manager:remove(
                           Store, [<<"https://example.com/missing">>]))
    end).

%% Документ, на который ссылаются, снять нельзя: ошибка называет ссылающихся, а
%% ни таблица, ни реестр не меняются.
remove_referenced_test() ->
    with_store([{base_uri, ?BASE}], fun(Store) ->
        Leaf = <<"https://example.com/leaf">>,
        Root = <<"https://example.com/root">>,
        {ok, [Leaf]} = valid_json_store_manager:add_at(
                         Store, [{Leaf, #{<<"type">> => <<"integer">>}}]),
        {ok, [Root]} = valid_json_store_manager:add_at(
                         Store, [{Root, #{<<"$ref">> => Leaf}}]),
        ?assertEqual({error, [{Leaf, #schema_error{reason = {referenced_by, Leaf,
                                                             [Root]},
                                                   location = undefined}}]},
                     valid_json_store_manager:remove(Store, [Leaf])),
        ?assertEqual(true, valid(Store, Leaf, 1)),
        ?assertEqual(false, valid(Store, Root, <<"a">>)),
        %% Весь конус одним вызовом снимается: ссылающийся уходит вместе с целью.
        ?assertEqual(ok, valid_json_store_manager:remove(Store, [Leaf, Root])),
        ?assertEqual({error, not_found},
                     valid_json_store_manager:lookup(Store, Leaf)),
        ?assertEqual({error, not_found},
                     valid_json_store_manager:lookup(Store, Root))
    end).

%% Ключ ошибки — написание вызывающего, а имя внутри причины — каноническое: по
%% нему лежит артефакт, и это разные строки.
remove_by_registered_name_test() ->
    with_store([{base_uri, ?BASE}], fun(Store) ->
        Registered = <<"https://example.com/registered">>,
        Canonical = <<"https://example.com/canonical">>,
        Root = <<"https://example.com/root">>,
        {ok, [Canonical]} = valid_json_store_manager:add_at(
                              Store, [{Registered, #{<<"$id">> => Canonical,
                                                    <<"type">> => <<"integer">>}}]),
        {ok, [Root]} = valid_json_store_manager:add_at(
                         Store, [{Root, #{<<"$ref">> => Canonical}}]),
        ?assertEqual({error, [{Registered,
                               #schema_error{reason = {referenced_by, Canonical,
                                                       [Root]},
                                             location = undefined}}]},
                     valid_json_store_manager:remove(Store, [Registered])),
        ok = valid_json_store_manager:remove(Store, [Root]),
        ?assertEqual(ok, valid_json_store_manager:remove(Store, [Registered])),
        ?assertEqual({error, not_found},
                     valid_json_store_manager:lookup(Store, Canonical))
    end).

%% Неразрешимое имя — ошибка того же списка: тега у удаления нет, потому что
%% фаза одна. Fragment в registry lookup не участвует, поэтому имя с ним именем
%% документа не бывает.
remove_bad_name_test() ->
    with_store([{base_uri, ?BASE}], fun(Store) ->
        ?assertEqual({error, [{<<"a#leaf">>,
                               #schema_error{reason = invalid_uri,
                                             location = undefined}}]},
                     valid_json_store_manager:remove(Store, [<<"a#leaf">>]))
    end).

%% Опция хранилища доходит до реестра: короткое имя разрешается от `base_uri`.
base_uri_test() ->
    with_store([{base_uri, ?BASE}], fun(Store) ->
        Canonical = <<"https://example.com/schemas/product/banana">>,
        ?assertEqual({ok, [Canonical]},
                     valid_json_store_manager:add_at(
                       Store, [{<<"product/banana">>,
                                #{<<"type">> => <<"integer">>}}])),
        ?assertEqual(true, valid(Store, Canonical, 1))
    end).

%% Опция доходит и до компиляции: assert_format меняет IR, поэтому один и тот же
%% документ в двух хранилищах ведёт себя по-разному.
assert_format_test() ->
    Uri = <<"https://example.com/address">>,
    Schema = #{<<"format">> => <<"ipv4">>},
    with_store([{base_uri, ?BASE}, {assert_format, true}], fun(Store) ->
        {ok, [Uri]} = valid_json_store_manager:add_at(Store, [{Uri, Schema}]),
        ?assertEqual(false, valid(Store, Uri, <<"not an address">>))
    end),
    with_store([{base_uri, ?BASE}], fun(Store) ->
        {ok, [Uri]} = valid_json_store_manager:add_at(Store, [{Uri, Schema}]),
        ?assertEqual(true, valid(Store, Uri, <<"not an address">>))
    end).

%% default_dialect выбирается для документа без `$schema`. Массив в `items`
%% допустим только в Draft 2019-09, поэтому диалект виден по результату:
%% при умолчании 2020-12 такой документ отвергает метасхема.
default_dialect_test() ->
    Uri = <<"https://example.com/tuple">>,
    Schema = #{<<"items">> => [#{<<"type">> => <<"integer">>}]},
    with_store([{base_uri, ?BASE}, {default_dialect, ?DRAFT_2019_09}], fun(Store) ->
        {ok, [Uri]} = valid_json_store_manager:add_at(Store, [{Uri, Schema}]),
        ?assertEqual(true, valid(Store, Uri, [1])),
        ?assertEqual(false, valid(Store, Uri, [<<"a">>]))
    end),
    with_store([{base_uri, ?BASE}], fun(Store) ->
        ?assertMatch({error,
                      {compilation, [{Uri, #schema_error{reason = schema_invalid}}]}},
                     valid_json_store_manager:add_at(Store, [{Uri, Schema}]))
    end).

trust_schema_store_policy_test() ->
    Uri = <<"https://example.com/trusted-invalid">>,
    Schema = #{<<"type">> => []},
    with_store([{base_uri, ?BASE}, {trust_schema, true}], fun(Store) ->
        ?assertEqual({ok, [Uri]},
                     valid_json_store_manager:add_at(Store, [{Uri, Schema}])),
        ?assertMatch({ok, _}, valid_json_store_manager:lookup(Store, Uri))
    end),
    with_store([{base_uri, ?BASE}], fun(Store) ->
        ?assertMatch({error,
                      {compilation,
                       [{Uri, #schema_error{reason = schema_invalid}}]}},
                     valid_json_store_manager:add_at(Store, [{Uri, Schema}]))
    end).

%% Незнакомая опция — ошибка конфигурации: хранилище не поднимается вовсе.
unknown_option_test() ->
    ?assertMatch({error, _},
                 isolated_start([{base_uri, ?BASE}, {oops, 1}])).

%% Хранилищу без `base_uri` нечем называть свои схемы, и это та же ошибка
%% конфигурации: подставить умолчание за разработчика нельзя.
missing_base_uri_test() ->
    ?assertMatch({error, _}, isolated_start([])),
    ?assertMatch({error, _},
                 isolated_start([{assert_format, true}])).

%% Короткое имя разрешается и на чтении: артефакт лежит под каноническим именем,
%% а вызывающий вправе называть документ так же, как называл при регистрации.
short_name_lookup_test() ->
    with_store([{base_uri, ?BASE}], fun(Store) ->
        Canonical = <<"https://example.com/schemas/product/banana">>,
        {ok, [Canonical]} = valid_json_store_manager:add_at(
                              Store, [{<<"product/banana">>,
                                       #{<<"type">> => <<"integer">>}}]),
        ?assertMatch({ok, _},
                     valid_json_store_manager:lookup(Store, <<"product/banana">>)),
        ?assertEqual(valid_json_store_manager:lookup(Store, Canonical),
                     valid_json_store_manager:lookup(Store, <<"product/banana">>)),
        ?assertEqual({error, not_found},
                     valid_json_store_manager:lookup(Store, <<"product/missing">>))
    end).

%% Обе таблицы переживают смерть управляющего по heir: читатели ничего не
%% замечают, новый управляющий забирает их по claim, поднимает реестр из его
%% таблицы и снова пишет. Сирот при этом не остаётся — прежний документ реестру
%% известен, и снять его можно как обычно.
-ifdef(CAP_ETS_INFO_ID).
restart_manager_test() ->
    with_store([{base_uri, ?BASE}], fun(Store) ->
        Old = <<"https://example.com/old">>,
        {ok, [Old]} = valid_json_store_manager:add_at(
                        Store, [{Old, #{<<"type">> => <<"integer">>}}]),
        Tables = tables(Store),
        Restarted = restart(Store, manager(Store)),
        %% Обе таблицы те же самые: не пересозданы, а переданы по heir.
        ?assertEqual(Tables, tables(Store)),
        ?assertEqual(Restarted, ets:info(Store, owner)),
        ?assertEqual(true, valid(Store, Old, 1)),
        %% Реестр помнит прежнее имя: повторная регистрация видит его занятым
        %% тем же документом, а снятие проходит и убирает артефакт.
        ?assertEqual(ok, valid_json_store_manager:remove(Store, [Old])),
        ?assertEqual({error, not_found},
                     valid_json_store_manager:lookup(Store, Old))
    end).

%% Смерть хранителя артефактов уносит его таблицу вместе с управляющим, а
%% таблица реестра переживает: документы известны, и артефакты пересобираются
%% при старте.
restart_artifacts_keeper_test() ->
    with_store([{base_uri, ?BASE}], fun(Store) ->
        Leaf = <<"https://example.com/leaf">>,
        Root = <<"https://example.com/root">>,
        {ok, [Leaf]} = valid_json_store_manager:add_at(
                         Store, [{Leaf, #{<<"type">> => <<"integer">>}}]),
        {ok, [Root]} = valid_json_store_manager:add_at(
                         Store, [{Root, #{<<"$ref">> => Leaf}}]),
        {Artifacts, Registry} = tables(Store),
        _Restarted = restart(Store, keeper(artifacts_table(Store))),
        %% Таблица артефактов именно пересоздана, поэтому всё, что в ней сейчас
        %% лежит, положила пересборка. Таблица реестра при этом та же.
        ?assertNotEqual(Artifacts, element(1, tables(Store))),
        ?assertEqual(Registry, element(2, tables(Store))),
        ?assertEqual(true, valid(Store, Root, 1)),
        ?assertEqual(false, valid(Store, Root, <<"a">>)),
        %% Ссылки пересобранных артефактов на месте: снять цель по-прежнему
        %% нельзя, а весь конус — можно.
        ?assertMatch({error, [{Leaf, _}]},
                     valid_json_store_manager:remove(Store, [Leaf])),
        ?assertEqual(ok, valid_json_store_manager:remove(Store, [Leaf, Root]))
    end).

trust_schema_survives_artifact_rebuild_test() ->
    with_store([{base_uri, ?BASE}, {trust_schema, true}], fun(Store) ->
        Uri = <<"https://example.com/trusted-rebuild">>,
        {ok, [Uri]} = valid_json_store_manager:add_at(
                        Store, [{Uri, #{<<"type">> => []}}]),
        _Restarted = restart(Store, keeper(artifacts_table(Store))),
        ?assertMatch({ok, _}, valid_json_store_manager:lookup(Store, Uri))
    end).

%% Смерть хранителя реестра уносит обе таблицы: восстанавливать не из чего, и
%% хранилище начинается пустым. Имя после этого снова свободно.
restart_registry_keeper_test() ->
    with_store([{base_uri, ?BASE}], fun(Store) ->
        Uri = <<"https://example.com/integer">>,
        {ok, [Uri]} = valid_json_store_manager:add_at(
                        Store, [{Uri, #{<<"type">> => <<"integer">>}}]),
        {Artifacts, Registry} = tables(Store),
        _Restarted = restart(Store, keeper(registry_table(Store))),
        %% Пересозданы обе: реестр уносит с собой и артефакты.
        ?assertNotEqual(Artifacts, element(1, tables(Store))),
        ?assertNotEqual(Registry, element(2, tables(Store))),
        ?assertEqual({error, not_found},
                     valid_json_store_manager:lookup(Store, Uri)),
        ?assertEqual({ok, [Uri]},
                     valid_json_store_manager:add_at(
                       Store, [{Uri, #{<<"type">> => <<"integer">>}}]))
    end).
-endif.

with_store(Options, Fun) ->
    {ok, Sup} = valid_json_store_sup:start_link(?STORE, Options),
    try Fun(?STORE)
    after
        stop_store(Sup)
    end.

%% Дерево связано с процессом теста, поэтому его гасят явно: иначе оно пережило
%% бы проверку и следующая не смогла бы создать таблицу под тем же именем.
stop_store(Sup) ->
    unlink(Sup),
    Ref = erlang:monitor(process, Sup),
    exit(Sup, shutdown),
    receive {'DOWN', Ref, process, Sup, _Reason} -> ok
    after 5000 -> erlang:error(store_alive) end.

isolated_start(Options) ->
    Parent = self(),
    {Worker, WorkerRef} = spawn_monitor(fun() ->
        process_flag(trap_exit, true),
        Result = try valid_json_store_sup:start_link(?STORE, Options) of
                     Started -> Started
                 catch
                     throw:Thrown -> Thrown;
                     _Class:Reason -> {'EXIT', Reason}
                 end,
        Parent ! {isolated_start, self(), Result},
        receive stop -> ok end
    end),
    Result = receive
                 {isolated_start, Worker, Value} -> Value
             after 5000 -> {error, timeout}
             end,
    case Result of
        {ok, Sup} -> exit(Sup, kill);
        _          -> ok
    end,
    Worker ! stop,
    receive {'DOWN', WorkerRef, process, Worker, _WorkerReason} -> ok
    after 5000 -> exit(Worker, kill) end,
    Result.

-ifdef(CAP_ETS_INFO_ID).
manager(Store) ->
    whereis(valid_json_store_manager:manager_name(Store)).

%% Имя таблицы переживает пересоздание, а идентификатор — нет, поэтому
%% пересозданную от переданной по heir отличают именно по нему.
tables(Store) ->
    {ets:info(artifacts_table(Store), id), ets:info(registry_table(Store), id)}.

keeper(Table) ->
    whereis(valid_json_ets_keeper:keeper_name(Table)).

artifacts_table(Store) ->
    valid_json_store_manager:artifacts_table(Store).

registry_table(Store) ->
    valid_json_store_manager:registry_table(Store).

%% Убитый процесс уносит с собой управляющего: оба хранителя стоят в rest_for_one
%% перед ним. Поэтому ждём именно нового управляющего, а затем и того, чтобы он
%% договорил свой старт: пересборка идёт в init/1, то есть до первого
%% сообщения, и системный вызов встаёт в очередь за ней.
restart(Store, Pid) ->
    Name = valid_json_store_manager:manager_name(Store),
    Manager = manager(Store),
    Ref = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, process, Pid, killed} -> ok
    after 1000 -> erlang:error(process_alive) end,
    Restarted = wait_restart(Name, Manager),
    _State = sys:get_state(Restarted),
    Restarted.

wait_restart(Name, Old) ->
    wait_restart(Name, Old, 100).

wait_restart(_Name, _Old, 0) ->
    erlang:error(no_restart);
wait_restart(Name, Old, Attempts) ->
    case whereis(Name) of
        undefined -> timer:sleep(10), wait_restart(Name, Old, Attempts - 1);
        Old       -> timer:sleep(10), wait_restart(Name, Old, Attempts - 1);
        Pid       -> Pid
    end.
-endif.

valid(Store, Uri, Instance) ->
    {ok, Compiled} = valid_json_store_manager:lookup(Store, Uri),
    {ok, #{<<"valid">> := Valid}} =
        valid_json_core:validate(Compiled, Instance, [{output, flag}]),
    Valid.

ref_property(Name, Uri) ->
    #{<<"properties">> => #{Name => #{<<"$ref">> => Uri}}}.
