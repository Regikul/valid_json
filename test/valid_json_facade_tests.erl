%% Фасад обоих режимов: тонкие делегирующие вызовы для именованного и
%% стандартного хранилищ и разовый вход встроенного режима.
-module(valid_json_facade_tests).

-include_lib("eunit/include/eunit.hrl").
-include("valid_json_resources.hrl").

-define(STORE, valid_json_facade_test_store).
-define(BASE, <<"https://example.com/schemas/">>).

%% Встроенные метасхемы поднимает дерево приложения, и без него компиляция
%% схемы не идёт.
ensure_app() ->
    {ok, _Started} = application:ensure_all_started(valid_json),
    ok.

%% Таблица именована глобально, поэтому каждая проверка поднимает своё дерево и
%% гасит его за собой.
store_add_and_validate_test() ->
    with_store(fun(Store) ->
        Uri = <<"https://example.com/integer">>,
        Schema = #{<<"type">> => <<"integer">>},
        ?assertEqual({ok, [Uri]},
                     valid_json:store_add_at(Store, Uri, Schema)),
        ?assertEqual({ok, #{<<"valid">> => true}},
                     valid_json:store_validate(
                       Store, Uri, 1, [{output, flag}])),
        ?assertMatch(
          {ok, #{<<"valid">> := false, <<"errors">> := [_ | _]}},
          valid_json:store_validate(
            Store, Uri, <<"not an integer">>, [{output, detailed}]))
    end).

store_add_at_mutual_refs_test() ->
    with_store(fun(Store) ->
        First = <<"https://example.com/first">>,
        Second = <<"https://example.com/second">>,
        Entries = [{First, ref_property(<<"second">>, Second)},
                   {Second, ref_property(<<"first">>, First)}],
        ?assertEqual({ok, [First, Second]},
                     valid_json:store_add_at(Store, Entries)),
        ?assertEqual({ok, #{<<"valid">> => true}},
                     valid_json:store_validate(
                       Store, First, #{<<"second">> => 1}, [{output, flag}]))
    end).

store_remove_test() ->
    with_store(fun(Store) ->
        Uri = <<"https://example.com/integer">>,
        {ok, [Uri]} = valid_json:store_add_at(
                        Store, Uri, #{<<"type">> => <<"integer">>}),
        ?assertEqual(ok, valid_json:store_remove(Store, [Uri])),
        ?assertEqual({error, not_found},
                     valid_json:store_validate(Store, Uri, 1, []))
    end).

store_validate_unknown_test() ->
    with_store(fun(Store) ->
        ?assertEqual({error, not_found},
                     valid_json:store_validate(
                       Store, <<"https://example.com/missing">>,
                       bad_instance, [{output, invalid}]))
    end).

store_errors_are_unchanged_test() ->
    with_store(fun(Store) ->
        Fragment = <<"weight#leaf">>,
        ?assertEqual(
          {error, {registration,
                   [{Fragment, #schema_error{reason = invalid_uri,
                                             location = undefined}}]}},
          valid_json:store_add_at(Store, Fragment, #{})),

        Leaf = <<"https://example.com/leaf">>,
        Root = <<"https://example.com/root">>,
        {ok, [Leaf]} = valid_json:store_add_at(
                         Store, Leaf, #{<<"type">> => <<"integer">>}),
        {ok, [Root]} = valid_json:store_add_at(
                         Store, Root, #{<<"$ref">> => Leaf}),
        ?assertEqual(
          {error, [{Leaf, #schema_error{reason = {referenced_by, Leaf, [Root]},
                                       location = undefined}}]},
          valid_json:store_remove(Store, [Leaf]))
    end).

%% Короткое имя годится и для валидации: `add` вернул каноническое, но вызывающий
%% вправе называть документ так же, как называл при регистрации.
store_short_name_test() ->
    with_store([{base_uri, ?BASE}], fun(Store) ->
        Canonical = <<"https://example.com/schemas/allow">>,
        ?assertEqual({ok, [Canonical]},
                     valid_json:store_add_at(Store, <<"allow">>, true)),
        ?assertEqual({ok, #{<<"valid">> => true}},
                     valid_json:store_validate(
                       Store, <<"allow">>, #{}, [{output, flag}])),
        ?assertEqual({ok, #{<<"valid">> => true}},
                     valid_json:store_validate(
                       Store, Canonical, #{}, [{output, flag}])),
        %% Неизвестное короткое имя остаётся промахом, а не ошибкой разрешения.
        ?assertEqual({error, not_found},
                     valid_json:store_validate(
                       Store, <<"missing">>, #{}, [{output, flag}]))
    end).

standard_store_test() ->
    {ok, _Started} = application:ensure_all_started(valid_json),
    try
        Uri = <<"https://example.com/standard">>,
        ?assertEqual({ok, [Uri]},
                     valid_json:add_at(Uri, #{<<"type">> => <<"integer">>})),
        ?assertEqual({ok, #{<<"valid">> => true}},
                     valid_json:validate(Uri, 1, [{output, flag}])),
        ?assertEqual(ok, valid_json:remove([Uri]))
    after
        ok = application:stop(valid_json)
    end.

%% `base_uri` стандартного хранилища называет сама библиотека, поэтому короткое
%% имя работает и в форме без имени хранилища.
standard_store_short_name_test() ->
    {ok, _Started} = application:ensure_all_started(valid_json),
    try
        Canonical = <<"https://valid_json.internal/schemas/allow">>,
        ?assertEqual({ok, [Canonical]}, valid_json:add_at(<<"allow">>, true)),
        ?assertEqual({ok, #{<<"valid">> => true}},
                     valid_json:validate(<<"allow">>, #{}, [{output, flag}])),
        ?assertEqual(ok, valid_json:remove([<<"allow">>]))
    after
        ok = application:stop(valid_json)
    end.

%% Схема, назвавшая себя сама, добавляется без имени рядом: `$id` и есть её имя,
%% и по нему же она валидирует.
store_add_self_named_test() ->
    with_store(fun(Store) ->
        Canonical = <<"https://example.com/integer">>,
        Schema = #{<<"$id">> => Canonical, <<"type">> => <<"integer">>},
        ?assertEqual({ok, [Canonical]}, valid_json:store_add(Store, Schema)),
        ?assertEqual({ok, #{<<"valid">> => true}},
                     valid_json:store_validate(
                       Store, Canonical, 1, [{output, flag}]))
    end).

%% Относительный `$id` разрешается от `base_uri` хранилища, и коротким именем
%% схема после этого тоже доступна.
store_add_relative_id_test() ->
    with_store(fun(Store) ->
        Canonical = <<"https://example.com/schemas/weight">>,
        ?assertEqual({ok, [Canonical]},
                     valid_json:store_add(
                       Store, #{<<"$id">> => <<"weight">>,
                                <<"type">> => <<"number">>})),
        ?assertEqual({ok, #{<<"valid">> => true}},
                     valid_json:store_validate(
                       Store, <<"weight">>, 1, [{output, flag}]))
    end).

%% Схеме, которая себя не назвала, имени взять неоткуда. Boolean отвергается по
%% той же причине: `$id` в него не написать, и годится ему только `add_at/2`.
store_add_unnamed_test() ->
    with_store(fun(Store) ->
        Unnamed = {error, {registration,
                           [{anonymous,
                             #schema_error{reason = unnamed_schema,
                                           location = undefined}}]}},
        ?assertEqual(Unnamed,
                     valid_json:store_add(Store, #{<<"type">> => <<"integer">>})),
        ?assertEqual(Unnamed, valid_json:store_add(Store, true))
    end).

%% Взаимные ссылки сходятся и без путей: имена дают сами схемы, а одним вызовом
%% набор идёт потому, что резолв не ленивый.
store_add_self_named_mutual_refs_test() ->
    with_store(fun(Store) ->
        First = <<"https://example.com/first">>,
        Second = <<"https://example.com/second">>,
        Entries = [maps:merge(#{<<"$id">> => First},
                              ref_property(<<"second">>, Second)),
                   maps:merge(#{<<"$id">> => Second},
                              ref_property(<<"first">>, First))],
        ?assertEqual({ok, [First, Second]}, valid_json:store_add(Store, Entries)),
        ?assertEqual({ok, #{<<"valid">> => true}},
                     valid_json:store_validate(
                       Store, First, #{<<"second">> => 1}, [{output, flag}]))
    end).

%% `add_at/2` даёт имя снаружи, но назвавшую себя схему оно не переименовывает:
%% адресом остаётся `$id`. Путь живёт вторым ключом чистого реестра, где нужен
%% компиляции для `$ref`, написанных относительно него, а адресом не становится.
store_add_at_yields_to_id_test() ->
    with_store(fun(Store) ->
        Canonical = <<"https://example.com/canonical">>,
        Path = <<"https://example.com/schemas/path">>,
        ?assertEqual({ok, [Canonical]},
                     valid_json:store_add_at(Store, <<"path">>,
                                             #{<<"$id">> => Canonical})),
        ?assertEqual({ok, #{<<"valid">> => true}},
                     valid_json:store_validate(
                       Store, Canonical, 1, [{output, flag}])),
        ?assertEqual({error, not_found},
                     valid_json:store_validate(Store, Path, 1, [{output, flag}]))
    end).

%% Стандартное хранилище знает свой `base_uri`, поэтому схема с относительным
%% `$id` доходит до валидации и в форме без имени хранилища.
standard_store_self_named_test() ->
    {ok, _Started} = application:ensure_all_started(valid_json),
    try
        Canonical = <<"https://valid_json.internal/schemas/weight">>,
        ?assertEqual({ok, [Canonical]},
                     valid_json:add(#{<<"$id">> => <<"weight">>,
                                      <<"type">> => <<"number">>})),
        ?assertEqual({ok, #{<<"valid">> => true}},
                     valid_json:validate(<<"weight">>, 1, [{output, flag}])),
        ?assertEqual(ok, valid_json:remove([Canonical]))
    after
        ok = application:stop(valid_json)
    end.

%% Встроенный режим: схема компилируется в процессе вызывающего, и хранилища ему
%% не нужно. Приложение нужно: проверка метасхемой идёт при каждой компиляции.
run_schema_test() ->
    ok = ensure_app(),
    Schema = #{<<"type">> => <<"integer">>},
    ?assertEqual({ok, #{<<"valid">> => true}},
                 valid_json:run_schema(Schema, 1, [{output, flag}])),
    ?assertMatch({ok, #{<<"valid">> := false, <<"errors">> := [_ | _]}},
                 valid_json:run_schema(Schema, <<"not an integer">>,
                                       [{output, detailed}])),
    %% Формат по умолчанию тот же, что и у `validate/3`.
    ?assertEqual({ok, #{<<"valid">> => false}},
                 valid_json:run_schema(Schema, <<"not an integer">>, [])).

%% Булев корень имени не требует, поэтому встроенному режиму он доступен прямо.
run_schema_boolean_test() ->
    ok = ensure_app(),
    ?assertEqual({ok, #{<<"valid">> => true}},
                 valid_json:run_schema(true, 1, [])),
    ?assertEqual({ok, #{<<"valid">> => false}},
                 valid_json:run_schema(false, 1, [])).

%% Негодная схема отвергается до вычисления, и ошибка у неё та же, что у
%% регистрации: инстанса она не касается.
run_schema_invalid_schema_test() ->
    ok = ensure_app(),
    ?assertMatch({error, #schema_error{reason = schema_invalid}},
                 valid_json:run_schema(#{<<"type">> => 42}, 1, [])).

run_schema_trust_schema_test() ->
    ok = ensure_app(),
    Schema = #{<<"type">> => []},
    ?assertMatch({error, #schema_error{reason = schema_invalid}},
                 valid_json:run_schema(Schema, 1, [])),
    ?assertEqual({ok, #{<<"valid">> => false}},
                 valid_json:run_schema(
                   Schema, 1,
                   [{trust_schema, true}, {schema_validation, verbose}])).

%% Реестр у этой компиляции временный: документ стандартного хранилища ей не
%% виден, и `$ref` до него не дотягивается даже при живом хранилище.
run_schema_does_not_see_store_test() ->
    {ok, _Started} = application:ensure_all_started(valid_json),
    try
        Uri = <<"https://example.com/registered">>,
        ?assertEqual({ok, [Uri]},
                     valid_json:add_at(Uri, #{<<"type">> => <<"integer">>})),
        ?assertEqual({ok, #{<<"valid">> => true}},
                     valid_json:validate(Uri, 1, [{output, flag}])),
        ?assertMatch({error, #schema_error{reason = {unknown_document, Uri}}},
                     valid_json:run_schema(#{<<"$ref">> => Uri}, 1, [])),
        ?assertEqual(ok, valid_json:remove([Uri]))
    after
        ok = application:stop(valid_json)
    end.

%% Встроенные метасхемы временному реестру видны: они лежат отдельной областью,
%% а не в хранилище.
run_schema_builtin_metaschema_test() ->
    ok = ensure_app(),
    Schema = #{<<"$ref">> => ?DRAFT_2020_12},
    ?assertEqual({ok, #{<<"valid">> => true}},
                 valid_json:run_schema(Schema, #{<<"type">> => <<"string">>}, [])),
    ?assertEqual({ok, #{<<"valid">> => false}},
                 valid_json:run_schema(Schema, #{<<"type">> => 42}, [])).

%% Относительное имя разрешать не от чего: базы у временного реестра нет.
run_schema_relative_id_test() ->
    ok = ensure_app(),
    ?assertMatch({error, #schema_error{reason = relative_uri_without_base}},
                 valid_json:run_schema(#{<<"$id">> => <<"weight">>}, 1, [])).

%% Опции обоих слоёв идут одним списком. `default_dialect` виден по массиву в
%% `items`: 2020-12 такую схему отвергает метасхемой, 2019-09 принимает.
run_schema_default_dialect_test() ->
    ok = ensure_app(),
    Schema = #{<<"items">> => [#{<<"type">> => <<"integer">>}]},
    ?assertMatch({error, #schema_error{reason = schema_invalid}},
                 valid_json:run_schema(Schema, [1], [])),
    ?assertEqual({ok, #{<<"valid">> => true}},
                 valid_json:run_schema(Schema, [1],
                                       [{default_dialect, ?DRAFT_2019_09}])).

%% `assert_format` меняет IR, поэтому доехать он должен до компиляции, а не до
%% вычисления: без него `format` только аннотирует.
run_schema_assert_format_test() ->
    ok = ensure_app(),
    Schema = #{<<"format">> => <<"ipv4">>},
    ?assertEqual({ok, #{<<"valid">> => true}},
                 valid_json:run_schema(Schema, <<"999.1.1.1">>, [])),
    ?assertEqual({ok, #{<<"valid">> => false}},
                 valid_json:run_schema(Schema, <<"999.1.1.1">>,
                                       [{assert_format, true}])).

%% Незнакомый ключ и негодное значение — ошибка вызова API, и падают они там же,
%% где падали бы при прямом вызове слоя, которому принадлежат.
run_schema_bad_option_test() ->
    ok = ensure_app(),
    ?assertError(badarg, valid_json:run_schema(true, 1, [{quiet, true}])),
    ?assertError(badarg, valid_json:run_schema(true, 1, [{output, invalid}])),
    ?assertError(badarg, valid_json:run_schema(true, 1,
                                               [{trust_schema, yes}])).

%% Спека собственного хранилища берётся с фасада, а не из супервизора: за ней
%% незачем идти в исходники. Пересказ должен быть дословным, и по этой спеке
%% хранилище должно подниматься.
store_child_spec_test() ->
    ok = ensure_app(),
    Options = [{base_uri, ?BASE}],
    Spec = valid_json:store_child_spec(?STORE, Options),
    ?assertEqual(valid_json_store_sup:child_spec(?STORE, Options), Spec),
    #{id := ?STORE, type := supervisor, start := {Module, Function, Args}} = Spec,
    {ok, Sup} = apply(Module, Function, Args),
    try
        Uri = <<"https://example.com/integer">>,
        {ok, [Uri]} = valid_json:store_add_at(?STORE, Uri,
                                              #{<<"type">> => <<"integer">>}),
        ?assertEqual({ok, #{<<"valid">> => true}},
                     valid_json:store_validate(?STORE, Uri, 1, [{output, flag}]))
    after
        stop_store(Sup)
    end.

with_store(Fun) ->
    with_store([{base_uri, ?BASE}], Fun).

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
    receive
        {'DOWN', Ref, process, Sup, _Reason} -> ok
    after
        5000 -> erlang:error(store_alive)
    end.

ref_property(Name, Uri) ->
    #{<<"properties">> => #{Name => #{<<"$ref">> => Uri}}}.
