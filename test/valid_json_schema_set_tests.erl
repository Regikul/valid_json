-module(valid_json_schema_set_tests).

-include_lib("eunit/include/eunit.hrl").
-include("valid_json_resources.hrl").

-define(BASE, <<"https://example.com/schemas/">>).

pure_check_without_application_test() ->
    stop_application(),
    try
        ?assertEqual(undefined, whereis(valid_json_sup)),
        ?assertEqual(undefined, ets:info(valid_json_metaschema)),
        Tables = lists:sort(ets:all()),
        Root = <<"https://example.com/schemas/root.json">>,
        Child = <<"https://example.com/schemas/child.json">>,
        Entries =
            [{<<"root.json">>,
              #{<<"$schema">> => ?DRAFT_2020_12,
                <<"$ref">> => <<"child.json">>}},
             {<<"child.json">>,
              #{<<"$schema">> => ?DRAFT_2020_12,
                <<"type">> => <<"string">>}}],
        ?assertEqual({ok, [Root, Child]}, check(Entries)),
        ?assertEqual(undefined, whereis(valid_json_sup)),
        ?assertEqual(undefined, ets:info(valid_json_metaschema)),
        ?assertEqual(Tables, lists:sort(ets:all()))
    after
        {ok, _Started} = application:ensure_all_started(valid_json)
    end.

invalid_schemas_are_collected_test() ->
    First = <<"https://example.com/schemas/first.json">>,
    Second = <<"https://example.com/schemas/second.json">>,
    {error, {validation, Errors}} =
        check([{<<"first.json">>, invalid_schema()},
               {<<"second.json">>, invalid_schema()}]),
    ?assertMatch([{First, #schema_error{reason = schema_invalid}},
                  {Second, #schema_error{reason = schema_invalid}}],
                 Errors).

registration_errors_are_distinct_test() ->
    {error, {registration, [{<<"#fragment">>, Error}]}} =
        check([{<<"#fragment">>, true}]),
    ?assertMatch(#schema_error{reason = invalid_uri}, Error).

missing_reference_test() ->
    Root = <<"https://example.com/schemas/root.json">>,
    Missing = <<"https://example.com/schemas/missing.json">>,
    {error, {validation, [{Root, Error}]}} =
        check([{<<"root.json">>,
                #{<<"$schema">> => ?DRAFT_2020_12,
                  <<"$ref">> => <<"missing.json">>}}]),
    ?assertMatch(#schema_error{reason = {unknown_document, Missing}}, Error).

all_builtin_dialects_test() ->
    Drafts = [{<<"draft6.json">>, ?DRAFT_06},
              {<<"draft7.json">>, ?DRAFT_07},
              {<<"draft2019.json">>, ?DRAFT_2019_09},
              {<<"draft2020.json">>, ?DRAFT_2020_12}],
    Entries = [{Name, #{<<"$schema">> => Draft, <<"type">> => []}}
               || {Name, Draft} <- Drafts],
    {error, {validation, Errors}} = check(Entries),
    ?assertEqual([<<"https://example.com/schemas/", Name/binary>>
                  || {Name, _Draft} <- Drafts],
                 [Name || {Name, #schema_error{reason = schema_invalid}}
                              <- Errors]).

custom_metaschema_test() ->
    Meta = <<"https://example.com/schemas/meta.json">>,
    Root = <<"https://example.com/schemas/root.json">>,
    MetaJson =
        #{<<"$id">> => Meta,
          <<"$schema">> => ?DRAFT_2020_12,
          <<"$vocabulary">> =>
              #{<<"https://json-schema.org/draft/2020-12/vocab/core">> => true,
                <<"https://json-schema.org/draft/2020-12/vocab/applicator">>
                    => true,
                <<"https://json-schema.org/draft/2020-12/vocab/validation">>
                    => true},
          <<"properties">> =>
              #{<<"x-extension">> => #{<<"type">> => <<"string">>}}},
    RootJson = #{<<"$schema">> => Meta, <<"x-extension">> => 1},
    {error, {validation, Errors}} =
        check([{<<"meta.json">>, MetaJson}, {<<"root.json">>, RootJson}]),
    ?assertMatch([{Root, #schema_error{reason = schema_invalid}}], Errors).

bad_options_test_() ->
    [?_assertError(badarg, valid_json_schema_set:check([], [])),
     ?_assertError(badarg,
                   valid_json_schema_set:check([], [{base_uri, ?BASE},
                                                    {unknown, true}])),
     ?_assertError(badarg,
                   valid_json_schema_set:check([], [{base_uri, ?BASE},
                                                    {schema_validation, full}]))].

check(Entries) ->
    valid_json_schema_set:check(
      Entries, [{base_uri, ?BASE}, {schema_validation, flag}]).

invalid_schema() ->
    #{<<"$schema">> => ?DRAFT_2020_12, <<"type">> => 1}.

stop_application() ->
    case application:stop(valid_json) of
        ok -> ok;
        {error, {not_started, valid_json}} -> ok
    end.
