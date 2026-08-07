%% Draft 6/7 compatibility: profiles, legacy identifiers and transitions to
%% every supported dialect. These tests intentionally use production closure
%% and evaluator paths; exact resource-index fixtures remain in their module.
-module(valid_json_legacy_draft_tests).

-include_lib("eunit/include/eunit.hrl").
-include("valid_json_core.hrl").
-include("valid_json_resources.hrl").

-define(DIALECTS, [?DRAFT_06, ?DRAFT_07, ?DRAFT_2019_09, ?DRAFT_2020_12]).

ensure_app() ->
    {ok, _Started} = application:ensure_all_started(valid_json),
    ok.

eunit_wrapper_(Tests) ->
    {setup, fun ensure_app/0, {inparallel, Tests}}.

dependencies_test_() ->
    Schema = #{<<"dependencies">> =>
                   #{<<"needs_b">> => [<<"b">>],
                     <<"needs_d">> => #{<<"required">> => [<<"d">>]}}},
    [{atom_to_list(Name), fun() ->
                                  Compiled = compile(Schema, Draft),
                                  ?assert(valid(Compiled,
                                                #{<<"needs_b">> => true,
                                                  <<"b">> => true,
                                                  <<"needs_d">> => true,
                                                  <<"d">> => true})),
                                  ?assertNot(valid(Compiled, #{<<"needs_b">> => true})),
                                  ?assertNot(valid(Compiled, #{<<"needs_d">> => true})),
                                  ?assert(valid(Compiled, <<"not an object">>))
                          end}
     || {Name, Draft} <- [{draft6, ?DRAFT_06}, {draft7, ?DRAFT_07}]].

draft7_conditionals_and_draft6_unknowns_test() ->
    Schema = #{<<"if">> => true, <<"then">> => false},
    ?assert(valid(compile(Schema, ?DRAFT_06), null)),
    ?assertNot(valid(compile(Schema, ?DRAFT_07), null)).

legacy_ref_ignores_siblings_test() ->
    Schema = #{<<"definitions">> => #{<<"integer">> => #{<<"type">> => <<"integer">>}},
               <<"properties">> =>
                   #{<<"value">> => #{<<"$ref">> => <<"#/definitions/integer">>,
                                        <<"type">> => <<"string">>}}},
    Instance = #{<<"value">> => 1},
    ?assert(valid(compile(Schema, ?DRAFT_06), Instance)),
    ?assert(valid(compile(Schema, ?DRAFT_07), Instance)),
    ?assertNot(valid(compile(Schema, ?DRAFT_2020_12), Instance)).

legacy_ref_ignores_misplaced_schema_test() ->
    Schema = #{<<"definitions">> => #{<<"integer">> => #{<<"type">> => <<"integer">>}},
               <<"properties">> =>
                   #{<<"value">> => #{<<"$ref">> => <<"#/definitions/integer">>,
                                        <<"$schema">> => 42,
                                        <<"definitions">> => 42,
                                        <<"type">> => <<"string">>}}},
    Compiled = compile(Schema, ?DRAFT_07),
    ?assert(valid(Compiled, #{<<"value">> => 1})).

legacy_contains_ignores_modern_bounds_test_() ->
    [{atom_to_list(Name),
      fun() ->
              Compiled = compile(#{<<"contains">> => true,
                                   <<"minContains">> => 2,
                                   <<"maxContains">> => 2}, Draft),
              ?assert(valid(Compiled, [1])),
              ?assert(valid(Compiled, [1, 2, 3])),
              ?assertNot(valid(Compiled, [])),
              Ignored = compile(#{<<"contains">> => true,
                                  <<"minContains">> => <<"unknown keyword">>,
                                  <<"maxContains">> => null}, Draft),
              ?assert(valid(Ignored, [1]))
      end}
     || {Name, Draft} <- [{draft6, ?DRAFT_06}, {draft7, ?DRAFT_07}]].

legacy_ref_ignores_fragment_id_sibling_test_() ->
    Root = <<"https://example.com/legacy-ref-sibling">>,
    [{atom_to_list(Name),
      fun() ->
              Ignored = #{<<"$id">> => Root,
                          <<"definitions">> =>
                              #{<<"integer">> => #{<<"type">> => <<"integer">>},
                                <<"hidden">> =>
                                    #{<<"$ref">> => <<"#/definitions/integer">>,
                                      <<"$id">> => <<"#not valid">>}}},
              #{resources := Resources} = compile(Ignored, Draft),
              #resource{anchors = Anchors} = maps:get(Root, Resources),
              ?assertEqual(#{}, Anchors),

              Referenced = #{<<"$id">> => Root,
                             <<"definitions">> =>
                                 #{<<"integer">> => #{<<"type">> => <<"integer">>},
                                   <<"hidden">> =>
                                       #{<<"$ref">> => <<"#/definitions/integer">>,
                                         <<"$id">> => <<"#shadow">>}},
                             <<"allOf">> => [#{<<"$ref">> => <<"#shadow">>}]},
              ?assertMatch(
                 {error, #schema_error{reason = unresolved_anchor}},
                 valid_json_compile:compile(
                   valid_json_store:temporary(), Referenced,
                   [{default_dialect, Draft}, {trust_schema, true}]))
      end}
     || {Name, Draft} <- [{draft6, ?DRAFT_06}, {draft7, ?DRAFT_07}]].

legacy_fragment_id_anchor_test() ->
    Root = <<"https://example.com/draft7-anchor">>,
    Schema = #{<<"$id">> => Root,
               <<"definitions">> =>
                   #{<<"integer">> => #{<<"$id">> => <<"#integer">>,
                                          <<"type">> => <<"integer">>}},
               <<"properties">> => #{<<"value">> => #{<<"$ref">> => <<"#integer">>}}},
    #{resources := Resources} = Compiled = compile(Schema, ?DRAFT_07),
    #resource{anchors = Anchors} = maps:get(Root, Resources),
    ?assertEqual(#{<<"integer">> => <<"/definitions/integer">>}, Anchors),
    ?assertEqual([Root], maps:keys(Resources)),
    ?assert(valid(Compiled, #{<<"value">> => 1})),
    ?assertNot(valid(Compiled, #{<<"value">> => <<"one">>})).

legacy_fragment_id_rejects_misplaced_schema_test_() ->
    Schema = #{<<"definitions">> =>
                   #{<<"integer">> => #{<<"$id">> => <<"#integer">>,
                                          <<"$schema">> => ?DRAFT_07}}},
    [?_assertMatch({error,
                    #schema_error{reason = {misplaced_keyword, <<"$schema">>},
                                  location = {anonymous,
                                              <<"/definitions/integer/$schema">>}}},
                   valid_json_compile:compile(valid_json_store:temporary(), Schema,
                                              [{default_dialect, Draft},
                                               {trust_schema, true}]))
     || Draft <- [?DRAFT_06, ?DRAFT_07]].

legacy_unknown_anchor_test() ->
    Compiled = compile(#{<<"$anchor">> => 42}, ?DRAFT_06),
    ?assert(valid(Compiled, null)).

legacy_output_modes_test_() ->
    [{atom_to_list(DraftName) ++ " " ++ atom_to_list(Mode),
      fun() ->
              Compiled = compile(#{<<"type">> => <<"integer">>}, Draft),
              ?assertMatch({ok, #{<<"valid">> := true}},
                           valid_json_core:validate(Compiled, 1, [{output, Mode}]))
      end}
     || {DraftName, Draft} <- [{draft6, ?DRAFT_06}, {draft7, ?DRAFT_07}],
        Mode <- [flag, basic, detailed, verbose]].

cross_dialect_matrix_test_() ->
    [{lists:flatten(io_lib:format("~p to ~p", [SourceName, TargetName])),
      fun() -> cross_dialect(Source, Target) end}
     || {SourceName, Source} <- named_dialects(),
        {TargetName, Target} <- named_dialects()].

cross_dialect_legacy_anchor_test_() ->
    [{"2020-12 to Draft 7 legacy $id", fun() -> cross_legacy_anchor(?DRAFT_2020_12,
                                                                      ?DRAFT_07) end},
     {"Draft 7 to 2020-12 anchor", fun() -> cross_modern_anchor(?DRAFT_07,
                                                                  ?DRAFT_2020_12) end}].

named_dialects() ->
    [{draft6, ?DRAFT_06}, {draft7, ?DRAFT_07},
     {draft2019_09, ?DRAFT_2019_09}, {draft2020_12, ?DRAFT_2020_12}].

cross_dialect(SourceDraft, TargetDraft) ->
    Source = <<"https://example.com/source">>,
    Target = <<"https://example.com/target">>,
    SourceSchema = #{<<"$id">> => Source, <<"$schema">> => SourceDraft,
                     <<"$ref">> => Target},
    TargetSchema = #{<<"$id">> => Target, <<"$schema">> => TargetDraft,
                     <<"type">> => <<"integer">>},
    {ok, _Names, Store} = valid_json_store:add(valid_json_store:temporary(),
                                                [{Source, SourceSchema},
                                                 {Target, TargetSchema}]),
    {ok, #{resources := Resources} = Compiled} =
        valid_json_compile:compile_uri(Store, Source, [{trust_schema, true}]),
    ?assertEqual(SourceDraft, (maps:get(Source, Resources))#resource.dialect),
    ?assertEqual(TargetDraft, (maps:get(Target, Resources))#resource.dialect),
    ?assert(valid(Compiled, 1)),
    ?assertNot(valid(Compiled, <<"one">>)).

cross_legacy_anchor(SourceDraft, TargetDraft) ->
    Source = <<"https://example.com/modern-source">>,
    Target = <<"https://example.com/draft7-target">>,
    SourceSchema = #{<<"$id">> => Source, <<"$schema">> => SourceDraft,
                     <<"$ref">> => <<Target/binary, "#integer">>},
    TargetSchema = #{<<"$id">> => Target, <<"$schema">> => TargetDraft,
                     <<"definitions">> =>
                         #{<<"integer">> => #{<<"$id">> => <<"#integer">>,
                                                <<"type">> => <<"integer">>}}},
    cross_anchor(Source, SourceSchema, Target, TargetSchema).

cross_modern_anchor(SourceDraft, TargetDraft) ->
    Source = <<"https://example.com/draft7-source">>,
    Target = <<"https://example.com/modern-target">>,
    SourceSchema = #{<<"$id">> => Source, <<"$schema">> => SourceDraft,
                     <<"$ref">> => <<Target/binary, "#integer">>},
    TargetSchema = #{<<"$id">> => Target, <<"$schema">> => TargetDraft,
                     <<"$defs">> =>
                         #{<<"integer">> => #{<<"$anchor">> => <<"integer">>,
                                                <<"type">> => <<"integer">>}}},
    cross_anchor(Source, SourceSchema, Target, TargetSchema).

cross_anchor(Source, SourceSchema, Target, TargetSchema) ->
    {ok, _Names, Store} = valid_json_store:add(valid_json_store:temporary(),
                                                [{Source, SourceSchema},
                                                 {Target, TargetSchema}]),
    {ok, Compiled} = valid_json_compile:compile_uri(
                       Store, Source, [{trust_schema, true}]),
    ?assert(valid(Compiled, 1)),
    ?assertNot(valid(Compiled, <<"one">>)).

compile(Schema, Draft) ->
    {ok, Compiled} = valid_json_compile:compile(valid_json_store:temporary(), Schema,
                                                 [{default_dialect, Draft},
                                                  {trust_schema, true}]),
    Compiled.

valid(Compiled, Instance) ->
    {ok, #eval_result{valid = Valid}} = valid_json_eval:run(Compiled, Instance, flag),
    Valid.
