%% Управляющий хранилища: реестр, публикация артефактов, инвалидация по
%% пересечению sources, откат при ошибке компиляции, опции и перезапуск.
-module(valid_json_store_manager_tests).

-include_lib("eunit/include/eunit.hrl").
-include("valid_json_resources.hrl").

%% Хранилище именованное, а имя таблицы глобально, поэтому проверки идут по
%% одной: каждая поднимает собственное дерево и гасит его за собой.
-define(STORE, valid_json_test_managed_store).
-define(BASE, <<"https://example.com/schemas/">>).

%% Добавленный документ публикуется под своим именем и годен к вычислению сразу.
add_test() ->
    with_store([], fun(Store) ->
        Uri = <<"https://example.com/integer">>,
        ?assertEqual({ok, [Uri]},
                     valid_json_store_manager:add(
                       Store, [{Uri, #{<<"type">> => <<"integer">>}}])),
        ?assertEqual(true, valid(Store, Uri, 1)),
        ?assertEqual(false, valid(Store, Uri, <<"a">>))
    end).

%% Имя артефакта — каноническое имя документа. Адрес загрузки остаётся ключом
%% реестра и в таблицу не попадает.
canonical_name_test() ->
    with_store([], fun(Store) ->
        Retrieval = <<"https://example.com/retrieval">>,
        Canonical = <<"https://example.com/canonical">>,
        Schema = #{<<"$id">> => Canonical, <<"type">> => <<"integer">>},
        ?assertEqual({ok, [Canonical]},
                     valid_json_store_manager:add(Store, [{Retrieval, Schema}])),
        ?assertMatch({ok, _}, valid_json_store_manager:lookup(Store, Canonical)),
        ?assertEqual({error, not_found},
                     valid_json_store_manager:lookup(Store, Retrieval))
    end).

%% Резолв не ленивый, поэтому взаимно ссылающиеся документы обязаны прийти одним
%% вызовом; артефакт заводится на каждый из них.
mutual_refs_test() ->
    with_store([], fun(Store) ->
        First = <<"https://example.com/first">>,
        Second = <<"https://example.com/second">>,
        Entries = [{First, ref_property(<<"second">>, Second)},
                   {Second, ref_property(<<"first">>, First)}],
        ?assertEqual({ok, [First, Second]},
                     valid_json_store_manager:add(Store, Entries)),
        ?assertMatch({ok, _}, valid_json_store_manager:lookup(Store, First)),
        ?assertMatch({ok, _}, valid_json_store_manager:lookup(Store, Second))
    end).

%% Замена документа пересобирает чужой артефакт, у которого изменённое имя стоит
%% в sources. Обратного индекса для этого не нужно.
invalidation_test() ->
    with_store([], fun(Store) ->
        Leaf = <<"https://example.com/leaf">>,
        Root = <<"https://example.com/root">>,
        {ok, [Leaf]} = valid_json_store_manager:add(
                         Store, [{Leaf, #{<<"type">> => <<"integer">>}}]),
        {ok, [Root]} = valid_json_store_manager:add(
                         Store, [{Root, #{<<"$ref">> => Leaf}}]),
        ?assertEqual(true, valid(Store, Root, 1)),
        ?assertEqual(false, valid(Store, Root, <<"a">>)),
        {ok, [Leaf]} = valid_json_store_manager:add(
                         Store, [{Leaf, #{<<"type">> => <<"string">>}}]),
        ?assertEqual(false, valid(Store, Root, 1)),
        ?assertEqual(true, valid(Store, Root, <<"a">>))
    end).

%% Замена по тому же адресу загрузки освобождает прежнее каноническое имя, и
%% артефакт под ним снимается: множество ключей таблицы следует за реестром.
replacement_test() ->
    with_store([], fun(Store) ->
        Retrieval = <<"https://example.com/document">>,
        First = <<"https://example.com/first">>,
        Second = <<"https://example.com/second">>,
        {ok, [First]} = valid_json_store_manager:add(
                          Store, [{Retrieval, #{<<"$id">> => First}}]),
        {ok, [Second]} = valid_json_store_manager:add(
                           Store, [{Retrieval, #{<<"$id">> => Second}}]),
        ?assertEqual({error, not_found},
                     valid_json_store_manager:lookup(Store, First)),
        ?assertMatch({ok, _}, valid_json_store_manager:lookup(Store, Second))
    end).

%% Ошибка компиляции оставляет прежними и таблицу, и реестр. Второе проверяется
%% косвенно: если бы сломанный документ остался в реестре, следующий добавленный
%% документ починил бы его и артефакт появился бы сам собой.
rollback_test() ->
    with_store([], fun(Store) ->
        Good = <<"https://example.com/good">>,
        Broken = <<"https://example.com/broken">>,
        Missing = <<"https://example.com/missing">>,
        {ok, [Good]} = valid_json_store_manager:add(
                         Store, [{Good, #{<<"type">> => <<"integer">>}}]),
        ?assertMatch({error,
                      {compilation,
                       [{Broken, #schema_error{reason = {unknown_document, Missing}}}]}},
                     valid_json_store_manager:add(
                       Store, [{Broken, #{<<"$ref">> => Missing}}])),
        ?assertEqual({error, not_found},
                     valid_json_store_manager:lookup(Store, Broken)),
        ?assertEqual(true, valid(Store, Good, 1)),
        {ok, [Missing]} = valid_json_store_manager:add(
                            Store, [{Missing, #{<<"type">> => <<"integer">>}}]),
        ?assertEqual({error, not_found},
                     valid_json_store_manager:lookup(Store, Broken))
    end).

%% Ошибка регистрации относится к вызову целиком и приходит одна, без списка.
name_taken_test() ->
    with_store([], fun(Store) ->
        Taken = <<"https://example.com/taken">>,
        Other = <<"https://example.com/other">>,
        {ok, [Taken]} = valid_json_store_manager:add(
                          Store, [{Taken, #{<<"type">> => <<"integer">>}}]),
        %% Ключ ошибки регистрации — имя записи, а не занятое имя: их тут два
        %% разных, и путать их нельзя.
        ?assertEqual({error, {registration,
                              [{Other, #schema_error{reason = {name_taken, Taken},
                                                     location = undefined}}]}},
                     valid_json_store_manager:add(
                       Store, [{Other, #{<<"$id">> => Taken}}])),
        ?assertEqual(true, valid(Store, Taken, 1)),
        ?assertEqual({error, not_found},
                     valid_json_store_manager:lookup(Store, Other))
    end).

%% Опция хранилища доходит до реестра: короткое имя разрешается от базы.
base_uri_test() ->
    with_store([{base_uri, ?BASE}], fun(Store) ->
        Canonical = <<"https://example.com/schemas/product/banana">>,
        ?assertEqual({ok, [Canonical]},
                     valid_json_store_manager:add(
                       Store, [{<<"product/banana">>,
                                #{<<"type">> => <<"integer">>}}])),
        ?assertEqual(true, valid(Store, Canonical, 1))
    end).

%% Опция доходит и до компиляции: assert_format меняет IR, поэтому один и тот же
%% документ в двух хранилищах ведёт себя по-разному.
assert_format_test() ->
    Uri = <<"https://example.com/address">>,
    Schema = #{<<"format">> => <<"ipv4">>},
    with_store([{assert_format, true}], fun(Store) ->
        {ok, [Uri]} = valid_json_store_manager:add(Store, [{Uri, Schema}]),
        ?assertEqual(false, valid(Store, Uri, <<"not an address">>))
    end),
    with_store([], fun(Store) ->
        {ok, [Uri]} = valid_json_store_manager:add(Store, [{Uri, Schema}]),
        ?assertEqual(true, valid(Store, Uri, <<"not an address">>))
    end).

%% default_dialect выбирается для документа без `$schema`. Массив в `items`
%% допустим только в Draft 2019-09, поэтому диалект виден по результату:
%% при умолчании 2020-12 такой документ отвергает метасхема.
default_dialect_test() ->
    Uri = <<"https://example.com/tuple">>,
    Schema = #{<<"items">> => [#{<<"type">> => <<"integer">>}]},
    with_store([{default_dialect, ?DRAFT_2019_09}], fun(Store) ->
        {ok, [Uri]} = valid_json_store_manager:add(Store, [{Uri, Schema}]),
        ?assertEqual(true, valid(Store, Uri, [1])),
        ?assertEqual(false, valid(Store, Uri, [<<"a">>]))
    end),
    with_store([], fun(Store) ->
        ?assertMatch({error,
                      {compilation, [{Uri, #schema_error{reason = schema_invalid}}]}},
                     valid_json_store_manager:add(Store, [{Uri, Schema}]))
    end).

%% Незнакомая опция — ошибка конфигурации: хранилище не поднимается вовсе.
unknown_option_test() ->
    process_flag(trap_exit, true),
    ?assertMatch({error, _}, valid_json_store_sup:start_link(?STORE, [{oops, 1}])),
    process_flag(trap_exit, false).

%% Таблица переживает смерть управляющего по heir: читатели ничего не замечают,
%% новый управляющий забирает её по claim и снова пишет. Реестр при этом
%% начинается пустым, поэтому прежний артефакт остаётся в таблице сиротой — это
%% принятая цена схемы, а не случайность.
restart_test() ->
    with_store([], fun(Store) ->
        Old = <<"https://example.com/old">>,
        New = <<"https://example.com/new">>,
        {ok, [Old]} = valid_json_store_manager:add(
                        Store, [{Old, #{<<"type">> => <<"integer">>}}]),
        Name = valid_json_store_manager:manager_name(Store),
        Manager = whereis(Name),
        Ref = monitor(process, Manager),
        exit(Manager, kill),
        receive {'DOWN', Ref, process, Manager, killed} -> ok
        after 1000 -> erlang:error(manager_alive) end,
        Restarted = wait_restart(Name, Manager),
        ?assertEqual(Restarted, ets:info(Store, owner)),
        ?assertEqual(true, valid(Store, Old, 1)),
        ?assertEqual({ok, [New]},
                     valid_json_store_manager:add(
                       Store, [{New, #{<<"type">> => <<"integer">>}}])),
        ?assertEqual(true, valid(Store, Old, 1))
    end).

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
    Ref = monitor(process, Sup),
    exit(Sup, shutdown),
    receive {'DOWN', Ref, process, Sup, _Reason} -> ok
    after 5000 -> erlang:error(store_alive) end.

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

valid(Store, Uri, Instance) ->
    {ok, Compiled} = valid_json_store_manager:lookup(Store, Uri),
    {ok, #{<<"valid">> := Valid}} =
        valid_json:validate(Compiled, Instance, [{output, flag}]),
    Valid.

ref_property(Name, Uri) ->
    #{<<"properties">> => #{Name => #{<<"$ref">> => Uri}}}.
