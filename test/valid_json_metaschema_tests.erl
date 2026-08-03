%% Bootstrap, публикация и production meta-schema gate. Точные emitter fixtures
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

published_bundles_test() ->
    %% Первый API lookup также покрывает fallback для embedded-режима, где OTP
    %% application вызывающий мог ещё не стартовать явно.
    Modern = valid_json_metaschema:compiled(?DRAFT_2020_12),
    Legacy = valid_json_metaschema:compiled(?DRAFT_2019_09),
    ModernBundle = persistent_term:get({valid_json_metaschema, ?DRAFT_2020_12}),
    LegacyBundle = persistent_term:get({valid_json_metaschema, ?DRAFT_2019_09}),
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

builtin_metaschemas_compile_through_production_test_() ->
    Store = valid_json_store:new([]),
    [?_assertMatch({ok, #{root := ?DRAFT_2020_12, sources := []}},
                   valid_json_compile:compile_uri(Store, ?DRAFT_2020_12, [])),
     ?_assertMatch({ok, #{root := ?DRAFT_2019_09, sources := []}},
                   valid_json_compile:compile_uri(Store, ?DRAFT_2019_09, []))].

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
       {error, #schema_error{reason = {schema_invalid, _},
                             location = {anonymous, <<>>}}},
       valid_json_compile:compile(#{<<"type">> => []}, ?DRAFT_2020_12)).

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
                 production(ValidCompound, ?DRAFT_2020_12)),
    InvalidCompound =
        #{<<"$id">> => Root,
          <<"$schema">> => ?DRAFT_2019_09,
          <<"$defs">> =>
              #{<<"child">> =>
                    #{<<"$id">> => Child,
                      <<"$schema">> => ?DRAFT_2020_12,
                      <<"items">> => [true]}}},
    {error, #schema_error{reason = {schema_invalid, _},
                          location = {Child, <<>>}}} =
        production(InvalidCompound, ?DRAFT_2019_09).

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
        valid_json_store:add(valid_json_store:new([]),
                             [{Meta, MetaJson}, {Rules, RulesJson}]),
    Bad = #{<<"$schema">> => Meta, <<"x-extension">> => 1},
    {error, #schema_error{reason = {schema_invalid, _},
                          location = {anonymous, <<>>}}} =
        valid_json_compile:compile(Store, Bad, []),
    Good = Bad#{<<"x-extension">> => <<"value">>},
    {ok, Compiled} = valid_json_compile:compile(Store, Good, []),
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
        valid_json_store:add(valid_json_store:new([]), Documents),
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

recursive_metaschema(Id, DecisiveBranch) ->
    #{<<"$id">> => Id,
      <<"$schema">> => ?DRAFT_2020_12,
      <<"$vocabulary">> =>
          #{<<"https://json-schema.org/draft/2020-12/vocab/core">> => true,
            <<"https://json-schema.org/draft/2020-12/vocab/applicator">> => true},
      <<"anyOf">> => [DecisiveBranch, #{<<"$ref">> => <<"#">>}]}.

assert_schema_invalid(Schema, Draft, InstancePointer, AbsoluteUri) ->
    {error, #schema_error{
              reason = {schema_invalid,
                        #output_unit{valid = false,
                                     keyword_location = [],
                                     absolute_location = {Draft, []},
                                     instance_location = []} = Root},
              location = {anonymous, <<>>}}} = production(Schema, Draft),
    ?assert(has_error(InstancePointer, AbsoluteUri, Root)).

has_error(InstancePointer, AbsoluteUri,
          #output_unit{detail = Detail,
                       absolute_location = Absolute,
                       instance_location = Instance,
                       nested = Nested}) ->
    Here = case {Detail, Absolute} of
               {{error, _}, {AbsoluteUri, _}} ->
                   valid_json_location:pointer(Instance) =:= InstancePointer;
               _ ->
                   false
           end,
    Here orelse lists:any(fun(Unit) ->
                                  has_error(InstancePointer, AbsoluteUri, Unit)
                          end,
                          Nested).

production(Schema, Draft) ->
    valid_json_compile:compile(valid_json_store:new([]), Schema,
                               [{default_dialect, Draft}]).
