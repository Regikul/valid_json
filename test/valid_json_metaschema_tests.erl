%% Bootstrap, публикация и публичная проверка метасхемой. Точные emitter fixtures
%% живут отдельно: здесь проверяется именно пользовательский compile contract.
-module(valid_json_metaschema_tests).

-include_lib("eunit/include/eunit.hrl").
-include("valid_json_resources.hrl").

-define(META_2020_VALIDATION,
        <<"https://json-schema.org/draft/2020-12/meta/validation">>).
-define(META_2020_APPLICATOR,
        <<"https://json-schema.org/draft/2020-12/meta/applicator">>).
-define(META_2020_DATA,
        <<"https://json-schema.org/draft/2020-12/meta/meta-data">>).
-define(META_2019_VALIDATION,
        <<"https://json-schema.org/draft/2019-09/meta/validation">>).
-define(META_2019_APPLICATOR,
        <<"https://json-schema.org/draft/2019-09/meta/applicator">>).

%% Встроенные метасхемы поднимает дерево приложения, и без него компиляция
%% схемы не идёт.
ensure_app() ->
    {ok, _Started} = application:ensure_all_started(valid_json),
    ok.

eunit_wrapper_(Tests) ->
    {setup, fun ensure_app/0, Tests}.

published_bundles_test() ->
    %% Первый lookup идёт после старта приложения: встроенную область поднимает
    %% дерево, и фолбэка на ленивую публикацию больше нет.
    Modern = valid_json_metaschema:compiled(?DRAFT_2020_12),
    Legacy = valid_json_metaschema:compiled(?DRAFT_2019_09),
    [{bundles, Bundles}] = ets:lookup(valid_json_metaschema, bundles),
    ModernBundle = maps:get(?DRAFT_2020_12, Bundles),
    LegacyBundle = maps:get(?DRAFT_2019_09, Bundles),
    ?assertEqual(8, map_size(maps:get(resources, Modern))),
    ?assertEqual(7, map_size(maps:get(resources, Legacy))),
    ?assertEqual([], maps:get(sources, Modern)),
    ?assertEqual([], maps:get(sources, Legacy)),
    %% Format-Assertion входит в immutable документы, но не в root closure.
    ?assertEqual(9, map_size(maps:get(documents, ModernBundle))),
    ?assertEqual(7, map_size(maps:get(documents, LegacyBundle))),
    ?assertEqual(Modern, maps:get(compiled, ModernBundle)),
    ?assertEqual(Legacy, maps:get(compiled, LegacyBundle)).

builtin_documents_are_published_test() ->
    ?assertMatch(#document{canonical = ?DRAFT_2020_12},
                 valid_json_metaschema:fetch(?DRAFT_2020_12)),
    ?assertMatch(
       #document{canonical =
                     <<"https://json-schema.org/draft/2020-12/meta/format-assertion">>},
       valid_json_metaschema:fetch(
         <<"https://json-schema.org/draft/2020-12/meta/format-assertion">>)),
    ?assertEqual(undefined,
                 valid_json_metaschema:fetch(
                   <<"https://json-schema.org/draft/2020-12/output/schema">>)).

builtin_metaschemas_compile_through_public_api_test_() ->
    Store = valid_json_store:temporary(),
    [?_assertMatch({ok, #{root := ?DRAFT_2020_12, sources := []}},
                   valid_json_compile:compile_uri(
                     Store, ?DRAFT_2020_12, [{schema_validation, flag}])),
     ?_assertMatch({ok, #{root := ?DRAFT_2019_09, sources := []}},
                   valid_json_compile:compile_uri(
                     Store, ?DRAFT_2019_09, [{schema_validation, flag}]))].

canonical_metaschema_rejection_test_() ->
    [?_test(assert_schema_invalid(
              #{<<"type">> => []}, ?DRAFT_2020_12,
              <<"/type">>, ?META_2020_VALIDATION)),
     ?_test(assert_schema_invalid(
              #{<<"type">> => []}, ?DRAFT_2019_09,
              <<"/type">>, ?META_2019_VALIDATION)),
     ?_test(assert_schema_invalid(
              #{<<"allOf">> => []}, ?DRAFT_2020_12,
              <<"/allOf">>, ?META_2020_APPLICATOR)),
     ?_test(assert_schema_invalid(
              #{<<"allOf">> => []}, ?DRAFT_2019_09,
              <<"/allOf">>, ?META_2019_APPLICATOR)),
     ?_test(assert_schema_invalid(
              #{<<"prefixItems">> => []}, ?DRAFT_2020_12,
              <<"/prefixItems">>, ?META_2020_APPLICATOR)),
     ?_test(assert_schema_invalid(
              #{<<"items">> => []}, ?DRAFT_2019_09,
              <<"/items">>, ?META_2019_APPLICATOR)),
     ?_test(assert_schema_invalid(
              #{<<"title">> => 1}, ?DRAFT_2020_12,
              <<"/title">>, ?META_2020_DATA))].

inline_compile_entry_uses_metaschema_test() ->
    ?assertMatch(
       {error, #schema_error{reason = schema_invalid,
                             validation_output = #{<<"valid">> := false},
                             location = {anonymous, <<>>}}},
       valid_json_compile:compile(#{<<"type">> => []}, ?DRAFT_2020_12)).

schema_validation_modes_test_() ->
    Store = valid_json_store:temporary(),
    Schema = #{<<"type">> => []},
    Compile = fun(Options) ->
                      valid_json_compile:compile(Store, Schema, Options)
              end,
    [?_assertEqual(Compile([{schema_validation, basic}]), Compile([])),
     ?_assertEqual(
        {error, #schema_error{reason = schema_invalid,
                              location = {anonymous, <<>>},
                              validation_output = #{<<"valid">> => false}}},
        Compile([{schema_validation, flag}])),
     ?_assertMatch(
        {error, #schema_error{reason = schema_invalid,
                              validation_output =
                                  #{<<"valid">> := false,
                                    <<"errors">> := [_ | _]}}},
        Compile([{schema_validation, basic}])),
     ?_assertMatch(
        {error, #schema_error{reason = schema_invalid,
                              validation_output =
                                  #{<<"valid">> := false,
                                    <<"errors">> := [_ | _]}}},
        Compile([{schema_validation, detailed}])),
     ?_assertMatch(
        {error, #schema_error{reason = schema_invalid,
                              validation_output =
                                  #{<<"valid">> := false,
                                    <<"errors">> := [_ | _]}}},
        Compile([{schema_validation, verbose}])),
     ?_assertMatch({ok, #{root := anonymous}},
                   Compile([{schema_validation, trusted}]))].

invalid_schema_validation_mode_test_() ->
    Store = valid_json_store:temporary(),
    [?_assertError(badarg,
                   valid_json_compile:compile(
                     Store, true, [{schema_validation, unknown}])),
     ?_assertError(badarg,
                   valid_json_compile:compile_uri(
                     Store, ?DRAFT_2020_12,
                     [{schema_validation, unknown}]))].

trusted_still_checks_references_test() ->
    Missing = <<"https://example.com/missing">>,
    ?assertEqual(
       {error, #schema_error{reason = {unknown_document, Missing},
                             location = {anonymous, <<"/$ref">>}}},
       valid_json_compile:compile(
         valid_json_store:temporary(), #{<<"$ref">> => Missing},
         [{schema_validation, trusted}])).

non_schema_position_rejection_test_() ->
    [?_test(assert_schema_invalid(42, ?DRAFT_2020_12, <<>>, ?DRAFT_2020_12)),
     ?_test(assert_schema_invalid(
              #{<<"not">> => 42}, ?DRAFT_2020_12,
              <<"/not">>, ?DRAFT_2020_12))].

%% Внешний 2020-12 resource не должен отвергать array-form `items` вложенного
%% 2019-09 resource; reverse case обязан отвергнуть child уже его dialect.
cross_draft_resources_are_checked_separately_test() ->
    Root = <<"https://example.com/root">>,
    Child = <<"https://example.com/child">>,
    ValidCompound =
        #{<<"$id">> => Root,
          <<"$schema">> => ?DRAFT_2020_12,
          <<"$defs">> =>
              #{<<"child">> =>
                    #{<<"$id">> => Child,
                      <<"$schema">> => ?DRAFT_2019_09,
                      <<"items">> => [true]}}},
    ?assertMatch({ok, #{resources := #{Root := _, Child := _}}},
                 checked_compile(ValidCompound, ?DRAFT_2020_12, flag)),
    InvalidCompound =
        #{<<"$id">> => Root,
          <<"$schema">> => ?DRAFT_2019_09,
          <<"$defs">> =>
              #{<<"child">> =>
                    #{<<"$id">> => Child,
                      <<"$schema">> => ?DRAFT_2020_12,
                      <<"items">> => [true]}}},
    {error, #schema_error{reason = schema_invalid,
                          location = {Child, <<>>}}} =
        checked_compile(InvalidCompound, ?DRAFT_2019_09, flag).

custom_metaschema_is_an_ordinary_store_document_test() ->
    Meta = <<"https://example.com/meta">>,
    Rules = <<"https://example.com/meta-rules">>,
    MetaJson = #{<<"$id">> => Meta,
                 <<"$schema">> => ?DRAFT_2020_12,
                 <<"$ref">> => Rules},
    RulesJson = #{<<"$id">> => Rules,
                  <<"$schema">> => ?DRAFT_2020_12,
                  <<"properties">> =>
                      #{<<"x-extension">> => #{<<"type">> => <<"string">>}}},
    {ok, [Meta, Rules], Store} =
        valid_json_store:add(valid_json_store:temporary(),
                             [{Meta, MetaJson}, {Rules, RulesJson}]),
    Bad = #{<<"$schema">> => Meta, <<"x-extension">> => 1},
    {error, #schema_error{reason = schema_invalid,
                          location = {anonymous, <<>>}}} =
        valid_json_compile:compile(Store, Bad, [{schema_validation, flag}]),
    Good = Bad#{<<"x-extension">> => <<"value">>},
    {ok, Compiled} =
        valid_json_compile:compile(Store, Good, [{schema_validation, flag}]),
    ?assertEqual([Meta, Rules], maps:get(sources, Compiled)),
    %% `$schema` использует метасхему для проверки, но не втягивает её nodes в
    %% пользовательский artifact как обычный `$ref`.
    ?assertEqual([anonymous], maps:keys(maps:get(resources, Compiled))).

%% Meta-schema gate использует тот же evaluator contract, что публичная
%% валидация: полный basic-обход может увидеть рекурсивную ветвь, но она не
%% меняет уже определённый успех `anyOf`. Если успешной ветви нет, no_progress
%% остаётся ошибкой вычисления метасхемы, а не превращается в schema_invalid.
custom_metaschema_no_progress_outcome_test() ->
    Accepting = <<"https://example.com/meta/accepting-cycle">>,
    Unknown = <<"https://example.com/meta/unknown-cycle">>,
    Documents = [{Accepting, recursive_metaschema(Accepting, true)},
                 {Unknown, recursive_metaschema(Unknown, false)}],
    {ok, [Accepting, Unknown], Store} =
        valid_json_store:add(valid_json_store:temporary(), Documents),
    ?assertMatch(
       {ok, #{root := anonymous}},
       valid_json_compile:compile(Store, #{<<"$schema">> => Accepting}, [])),
    ?assertEqual(
       {error,
        #schema_error{
          reason = {metaschema_evaluation_failed, Unknown,
                    {no_progress, {Unknown, <<>>}}},
          location = {anonymous, <<>>}}},
       valid_json_compile:compile(Store, #{<<"$schema">> => Unknown}, [])).

%% Смерть владельца таблицу не рушит: она возвращается хранителю по `heir`
%% вместе с bundle, и перезапущенный владелец её просто забирает.
-ifdef(CAP_ETS_INFO_ID).
owner_restart_keeps_bundle_test() ->
    with_branch(fun() ->
        Table = ets:info(valid_json_metaschema, id),
        [{bundles, Before}] = ets:lookup(valid_json_metaschema, bundles),
        Owner = ets:info(valid_json_metaschema, owner),
        _Restarted = kill_and_wait(Owner, Owner),
        ?assertEqual(Table, ets:info(valid_json_metaschema, id)),
        ?assertEqual([{bundles, Before}],
                     ets:lookup(valid_json_metaschema, bundles))
    end).

%% Смерть хранителя гасит и владельца: таблица уничтожается и создаётся заново,
%% а bundle собирается заново вместе с ней.
keeper_restart_rebuilds_bundle_test() ->
    with_branch(fun() ->
        Table = ets:info(valid_json_metaschema, id),
        Owner = ets:info(valid_json_metaschema, owner),
        Keeper = whereis(
                   valid_json_ets_keeper:keeper_name(valid_json_metaschema)),
        _Restarted = kill_and_wait(Keeper, Owner),
        ?assertNotEqual(Table, ets:info(valid_json_metaschema, id)),
        ?assertEqual(8, map_size(maps:get(
                                   resources,
                                   valid_json_metaschema:compiled(
                                     ?DRAFT_2020_12))))
    end).
-endif.

schema_validation_is_propagated_to_custom_metaschema_test() ->
    Meta = <<"https://example.com/meta/invalid">>,
    MetaJson = #{<<"$id">> => Meta,
                 <<"$schema">> => ?DRAFT_2020_12,
                 <<"type">> => []},
    {ok, Meta, Store} =
        valid_json_store:add(valid_json_store:temporary(), Meta, MetaJson),
    Schema = #{<<"$schema">> => Meta},
    ?assertEqual(
       {error, #schema_error{reason = schema_invalid,
                             location = {Meta, <<>>},
                             validation_output = #{<<"valid">> => false}}},
       valid_json_compile:compile(Store, Schema,
                                  [{schema_validation, flag}])),
    {ok, Compiled} =
        valid_json_compile:compile(Store, Schema,
                                   [{schema_validation, trusted}]),
    ?assertEqual([Meta], maps:get(sources, Compiled)).

%% Перезапуски идут на отдельной ветке: intensity супервизора равна единице, и
%% двух убийств подряд он не переживает, а имя таблицы глобально и второй ветки
%% рядом с приложением не допускает. Приложение возвращается на место, потому
%% что остальные проверки модуля его ждут.
-ifdef(CAP_ETS_INFO_ID).
with_branch(Fun) ->
    _ = application:stop(valid_json),
    {ok, Sup} = valid_json_metaschema_sup:start_link(),
    try Fun()
    after
        stop_branch(Sup),
        ok = ensure_app()
    end.

%% Ветка связана с процессом теста, поэтому её гасят явно: иначе она пережила бы
%% проверку и следующая не смогла бы создать таблицу под тем же именем.
stop_branch(Sup) ->
    unlink(Sup),
    Ref = erlang:monitor(process, Sup),
    exit(Sup, shutdown),
    receive
        {'DOWN', Ref, process, Sup, _Reason} -> ok
    after
        5000 -> erlang:error(branch_alive)
    end.

%% Ждём опубликованный bundle: claim таблицы и `publish/0` идут последовательно,
%% поэтому смена владельца сама по себе ещё не означает готовность ветки.
kill_and_wait(Pid, Owner) ->
    Ref = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', Ref, process, Pid, killed} -> ok
    after
        1000 -> erlang:error(process_alive)
    end,
    wait_bundle(Owner, 100).

wait_bundle(_Owner, 0) ->
    erlang:error(no_restart);
wait_bundle(Owner, Attempts) ->
    Keeper = whereis(valid_json_ets_keeper:keeper_name(valid_json_metaschema)),
    case ets:info(valid_json_metaschema, owner) of
        undefined ->
            retry_bundle(Owner, Attempts);
        Owner ->
            retry_bundle(Owner, Attempts);
        Keeper ->
            retry_bundle(Owner, Attempts);
        Pid ->
            try ets:lookup(valid_json_metaschema, bundles) of
                [{bundles, _}] ->
                    Pid;
                [] ->
                    retry_bundle(Owner, Attempts)
            catch
                error:badarg ->
                    retry_bundle(Owner, Attempts)
            end
    end.

retry_bundle(Owner, Attempts) ->
    timer:sleep(10),
    wait_bundle(Owner, Attempts - 1).
-endif.

recursive_metaschema(Id, DecisiveBranch) ->
    #{<<"$id">> => Id,
      <<"$schema">> => ?DRAFT_2020_12,
      <<"$vocabulary">> =>
          #{<<"https://json-schema.org/draft/2020-12/vocab/core">> => true,
            <<"https://json-schema.org/draft/2020-12/vocab/applicator">> => true},
      <<"anyOf">> => [DecisiveBranch, #{<<"$ref">> => <<"#">>}]}.

assert_schema_invalid(Schema, Draft, InstancePointer, AbsoluteUri) ->
    {error, #schema_error{
              reason = schema_invalid,
              validation_output =
                  #{<<"valid">> := false,
                    <<"absoluteKeywordLocation">> := RootLocation,
                    <<"instanceLocation">> := <<>>,
                    <<"errors">> := Errors},
              location = {anonymous, <<>>}}} =
        checked_compile(Schema, Draft, basic),
    ?assertEqual(<<Draft/binary, "#">>, RootLocation),
    ?assert(lists:any(
              fun(#{<<"instanceLocation">> := Instance,
                    <<"absoluteKeywordLocation">> := Absolute}) ->
                      Instance =:= InstancePointer andalso
                          absolute_uri(Absolute) =:= AbsoluteUri;
                 (_) ->
                      false
              end,
              Errors)).

absolute_uri(Fragment) ->
    [Uri, _Pointer] = binary:split(Fragment, <<"#">>),
    Uri.

checked_compile(Schema, Draft, Mode) ->
    valid_json_compile:compile(valid_json_store:temporary(), Schema,
                               [{default_dialect, Draft},
                                {schema_validation, Mode}]).
