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

format(Reason, Location) ->
    iolist_to_binary(
      valid_json_error:format_error(#schema_error{reason = Reason, location = Location})).

contains(Text, Fragment) ->
    binary:match(Text, Fragment) =/= nomatch.
