%% Текст ошибки проверяется слабо: машинный контракт — это reason и location,
%% а формулировка остаётся политикой реализации и меняется свободно. Проверяется
%% только то, что текст строится, называет локацию и упоминает виновника.
-module(valid_json_error_tests).

-include_lib("eunit/include/eunit.hrl").
-include("valid_json_core.hrl").

%% Тесты модуля независимы, поэтому eunit прогоняет их параллельно.
eunit_wrapper_(Tests) -> {inparallel, Tests}.

format_test_() ->
    [?_assert(contains(format({bad_keyword_value, null}, {anonymous, <<"/maximum">>}),
                       <<"#/maximum">>)),
     ?_assert(contains(format({not_implemented, <<"properties">>},
                              {anonymous, <<"/properties">>}),
                       <<"properties">>)),
     %% У названного resource в локации остаётся его URI.
     ?_assert(contains(format({bad_keyword_value, 1}, {<<"https://example.com/s">>, <<"/type">>}),
                       <<"https://example.com/s#/type">>)),
     %% Причина от re структуры не имеет, но печататься обязана.
     ?_assertMatch(<<_:8, _/binary>>,
                   format({bad_pattern, {"missing )", 1}}, {anonymous, <<"/pattern">>}))].

%% У ошибки регистрации локации нет, и текст обходится без неё.
without_location_test() ->
    ?assert(contains(format({not_implemented, <<"$ref">>}, undefined), <<"$ref">>)).

store_reason_test_() ->
    [?_assert(contains(format(invalid_uri, undefined), <<"URI">>)),
     ?_assert(contains(format(invalid_percent_encoding, undefined), <<"percent">>)),
     ?_assert(contains(format(relative_uri_without_base, undefined), <<"base">>)),
     ?_assert(contains(format({unknown_dialect,
                               <<"https://example.com/dialect">>}, undefined),
                       <<"https://example.com/dialect">>)),
     ?_assert(contains(format({name_taken, <<"https://example.com/schema">>}, undefined),
                       <<"https://example.com/schema">>))].

reference_reason_test_() ->
    Target = {<<"https://example.com/schema">>, <<"/$defs/value">>},
    [?_assert(contains(format(unresolved_anchor, {anonymous, <<"/$ref">>}),
                       <<"anchor">>)),
     ?_assert(contains(format({dangling_ref, Target}, {anonymous, <<"/$ref">>}),
                       <<"https://example.com/schema#/$defs/value">>)),
     ?_assert(contains(format({non_schema_target, Target},
                              {anonymous, <<"/$ref">>}),
                       <<"not a schema">>)),
     ?_assert(contains(format({unknown_document,
                               <<"https://example.com/missing">>},
                              {anonymous, <<"/$ref">>}),
                       <<"https://example.com/missing">>))].

metaschema_reason_test() ->
    Unit = #output_unit{valid = false, keyword_location = [],
                        absolute_location = undefined,
                        instance_location = [], detail = none, nested = []},
    ?assert(contains(format({schema_invalid, Unit}, {anonymous, <<>>}),
                     <<"meta-schema">>)).

format(Reason, Location) ->
    iolist_to_binary(
      valid_json_error:format_error(#schema_error{reason = Reason, location = Location})).

contains(Text, Fragment) ->
    binary:match(Text, Fragment) =/= nomatch.
