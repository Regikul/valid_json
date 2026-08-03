%% Фасад размещённого режима: тонкие делегирующие вызовы для именованного и
%% стандартного хранилищ.
-module(valid_json_facade_tests).

-include_lib("eunit/include/eunit.hrl").
-include("valid_json_core.hrl").

-define(STORE, valid_json_facade_test_store).

%% Таблица именована глобально, поэтому каждая проверка поднимает своё дерево и
%% гасит его за собой.
store_add_and_validate_test() ->
    with_store(fun(Store) ->
        Uri = <<"https://example.com/integer">>,
        Schema = #{<<"type">> => <<"integer">>},
        ?assertEqual({ok, [Uri]},
                     valid_json:store_add(Store, Uri, Schema)),
        ?assertEqual({ok, #{<<"valid">> => true}},
                     valid_json:store_validate(
                       Store, Uri, 1, [{output, flag}])),
        ?assertMatch(
          {ok, #{<<"valid">> := false, <<"errors">> := [_ | _]}},
          valid_json:store_validate(
            Store, Uri, <<"not an integer">>, [{output, detailed}]))
    end).

store_add_mutual_refs_test() ->
    with_store(fun(Store) ->
        First = <<"https://example.com/first">>,
        Second = <<"https://example.com/second">>,
        Entries = [{First, ref_property(<<"second">>, Second)},
                   {Second, ref_property(<<"first">>, First)}],
        ?assertEqual({ok, [First, Second]},
                     valid_json:store_add(Store, Entries)),
        ?assertEqual({ok, #{<<"valid">> => true}},
                     valid_json:store_validate(
                       Store, First, #{<<"second">> => 1}, [{output, flag}]))
    end).

store_remove_test() ->
    with_store(fun(Store) ->
        Uri = <<"https://example.com/integer">>,
        {ok, [Uri]} = valid_json:store_add(
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
        Relative = <<"relative">>,
        ?assertEqual(
          {error, {registration,
                   [{Relative, #schema_error{reason = relative_uri_without_base,
                                             location = undefined}}]}},
          valid_json:store_add(Store, Relative, #{})),

        Leaf = <<"https://example.com/leaf">>,
        Root = <<"https://example.com/root">>,
        {ok, [Leaf]} = valid_json:store_add(
                         Store, Leaf, #{<<"type">> => <<"integer">>}),
        {ok, [Root]} = valid_json:store_add(
                         Store, Root, #{<<"$ref">> => Leaf}),
        ?assertEqual(
          {error, [{Leaf, #schema_error{reason = {referenced_by, Leaf, [Root]},
                                       location = undefined}}]},
          valid_json:store_remove(Store, [Leaf]))
    end).

standard_store_test() ->
    {ok, _Started} = application:ensure_all_started(valid_json),
    try
        Uri = <<"https://example.com/standard">>,
        ?assertEqual({ok, [Uri]},
                     valid_json:add(Uri, #{<<"type">> => <<"integer">>})),
        ?assertEqual({ok, #{<<"valid">> => true}},
                     valid_json:validate(Uri, 1, [{output, flag}])),
        ?assertEqual(ok, valid_json:remove([Uri]))
    after
        ok = application:stop(valid_json)
    end.

with_store(Fun) ->
    {ok, Sup} = valid_json_store_sup:start_link(?STORE),
    try Fun(?STORE)
    after
        stop_store(Sup)
    end.

stop_store(Sup) ->
    unlink(Sup),
    Ref = monitor(process, Sup),
    exit(Sup, shutdown),
    receive
        {'DOWN', Ref, process, Sup, _Reason} -> ok
    after
        5000 -> erlang:error(store_alive)
    end.

ref_property(Name, Uri) ->
    #{<<"properties">> => #{Name => #{<<"$ref">> => Uri}}}.
