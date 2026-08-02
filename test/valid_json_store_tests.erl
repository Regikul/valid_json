%% Чистый registry: регистрация документов, два имени, upsert, batch atomicity,
%% удаление и встроенная immutable область.
-module(valid_json_store_tests).

-include_lib("eunit/include/eunit.hrl").
-include("valid_json_resources.hrl").

%% Тесты не меняют глобального состояния и могут выполняться параллельно.
eunit_wrapper_(Tests) -> {inparallel, Tests}.

-define(BASE, <<"https://example.com/schemas/">>).
-define(BUILTIN, <<"https://json-schema.org/draft/2020-12/schema">>).

new_test_() ->
    [?_assertEqual(#store{}, valid_json_store:new([])),
     ?_assertEqual(#store{base = ?BASE}, valid_json_store:new([{base_uri, ?BASE}])),
     %% База проходит ту же URI normalization, что и имена документов.
     ?_assertEqual(#store{base = <<"http://example.com/schemas/">>},
                   valid_json_store:new([{base_uri,
                                          <<"HTTP://Example.COM:80/a/../schemas/">>}])),
     %% Hierarchical URI без authority тоже допустим.
     ?_assertEqual(#store{base = <<"file:/schemas/">>},
                   valid_json_store:new([{base_uri, <<"file:/schemas/">>}]))].

new_error_test_() ->
    [?_assertError(badarg, valid_json_store:new([{base_uri, <<"relative/path">>}])),
     ?_assertError(badarg, valid_json_store:new([{base_uri, <<"urn:example:root">>}])),
     ?_assertError(badarg, valid_json_store:new([{base_uri,
                                                  <<"https://example.com/#x">>}])),
     ?_assertError(badarg, valid_json_store:new([{unknown, true}])),
     ?_assertError(badarg, valid_json_store:new(not_a_list))].

%% Без `$id` canonical URI совпадает с retrieval. Сам JSON сохраняется как есть.
absolute_test() ->
    Json = #{<<"type">> => <<"integer">>},
    Uri = <<"https://example.com/integer">>,
    {ok, Uri, Store} = valid_json_store:add(valid_json_store:new([]), Uri, Json),
    Expected = #document{retrieval = Uri, canonical = Uri, json = Json},
    ?assertEqual(Expected, valid_json_store:fetch(Uri, Store)).

%% Retrieval разрешается от store base, а корневой `$id` — от retrieval URI.
%% Оба ключа указывают на один и тот же immutable document term.
canonical_test() ->
    Json = #{<<"$id">> => <<"../canonical/banana">>,
             <<"$defs">> => #{<<"embedded">> =>
                                   #{<<"$id">> => <<"embedded">>}}},
    {ok, Canonical, Store} =
        valid_json_store:add(valid_json_store:new([{base_uri, ?BASE}]),
                             <<"product/banana">>, Json),
    Retrieval = <<"https://example.com/schemas/product/banana">>,
    ?assertEqual(<<"https://example.com/schemas/canonical/banana">>, Canonical),
    RetrievalDocument = valid_json_store:fetch(Retrieval, Store),
    CanonicalDocument = valid_json_store:fetch(Canonical, Store),
    ?assertEqual(#document{retrieval = Retrieval, canonical = Canonical, json = Json},
                 RetrievalDocument),
    ?assert(RetrievalDocument =:= CanonicalDocument),
    %% Вложенный `$id` создаст resource при компиляции, но третьего имени
    %% document в store не образует.
    ?assertEqual(undefined,
                 valid_json_store:fetch(
                   <<"https://example.com/schemas/product/embedded">>, Store)).

normalization_test() ->
    Written = <<"HTTP://Example.COM:80/a/./b/../schema">>,
    Canonical = <<"http://example.com/a/schema">>,
    {ok, Canonical, Store} =
        valid_json_store:add(valid_json_store:new([]), Written, true),
    ?assertMatch(#document{retrieval = Canonical, canonical = Canonical},
                 valid_json_store:fetch(Canonical, Store)),
    %% Исходное написание отдельным alias не хранится.
    ?assertEqual(undefined, valid_json_store:fetch(Written, Store)).

registration_error_test_() ->
    Empty = valid_json_store:new([]),
    [?_assertEqual(schema_error(relative_uri_without_base),
                   valid_json_store:add(Empty, <<"relative.json">>, true)),
     ?_assertEqual(schema_error(invalid_uri),
                   valid_json_store:add(Empty, <<"http://[::1">>, true)),
     ?_assertEqual(schema_error(invalid_uri),
                   valid_json_store:add(Empty, <<"https://example.com/s#anchor">>, true)),
     ?_assertEqual(schema_error({bad_keyword_value, 42}),
                   valid_json_store:add(Empty, <<"https://example.com/s">>,
                                        #{<<"$id">> => 42})),
     ?_assertEqual(schema_error({bad_keyword_value, <<"#anchor">>}),
                   valid_json_store:add(Empty, <<"https://example.com/s">>,
                                        #{<<"$id">> => <<"#anchor">>})),
     ?_assertEqual(schema_error(invalid_uri),
                   valid_json_store:add(Empty, <<"https://example.com/s">>,
                                        #{<<"$id">> => <<"bad%zz">>})),
     ?_assertEqual(schema_error(invalid_percent_encoding),
                   valid_json_store:add(Empty, <<"https://example.com/s#%zz">>, true))].

%% Повтор того же retrieval заменяет документ, меняет canonical alias и снимает
%% старое имя.
upsert_test() ->
    Retrieval = <<"https://example.com/retrieval">>,
    OldCanonical = <<"https://example.com/old">>,
    NewCanonical = <<"https://example.com/new">>,
    {ok, OldCanonical, OldStore} =
        valid_json_store:add(valid_json_store:new([]), Retrieval,
                             #{<<"$id">> => OldCanonical, <<"const">> => 1}),
    NewJson = #{<<"$id">> => NewCanonical, <<"const">> => 2},
    {ok, NewCanonical, NewStore} = valid_json_store:add(OldStore, Retrieval, NewJson),
    ?assertEqual(undefined, valid_json_store:fetch(OldCanonical, NewStore)),
    ?assertEqual(#document{retrieval = Retrieval,
                           canonical = NewCanonical,
                           json = NewJson},
                 valid_json_store:fetch(Retrieval, NewStore)).

%% Canonical alias не становится retrieval адресом существующего document:
%% заменить запись можно только через её настоящий retrieval URI.
alias_is_not_upsert_test() ->
    Retrieval = <<"https://example.com/retrieval">>,
    Canonical = <<"https://example.com/canonical">>,
    {ok, Canonical, Store} =
        valid_json_store:add(valid_json_store:new([]), Retrieval,
                             #{<<"$id">> => Canonical}),
    ?assertEqual(schema_error({name_taken, Canonical}),
                 valid_json_store:add(Store, Canonical, false)).

conflict_test() ->
    First = <<"https://example.com/first">>,
    Second = <<"https://example.com/second">>,
    Shared = <<"https://example.com/shared">>,
    FirstJson = #{<<"$id">> => Shared},
    {ok, Shared, Store} =
        valid_json_store:add(valid_json_store:new([]), First, FirstJson),
    ?assertEqual(schema_error({name_taken, Shared}),
                 valid_json_store:add(Store, Second, #{<<"$id">> => Shared})),
    %% Провал не изменяет исходное immutable значение.
    ?assertEqual(#document{retrieval = First, canonical = Shared, json = FirstJson},
                 valid_json_store:fetch(Shared, Store)),
    ?assertEqual(undefined, valid_json_store:fetch(Second, Store)).

batch_test() ->
    Store0 = valid_json_store:new([{base_uri, ?BASE}]),
    Entries = [{<<"a">>, #{<<"$id">> => <<"canonical/a">>}},
               {<<"b">>, true}],
    A = <<"https://example.com/schemas/canonical/a">>,
    B = <<"https://example.com/schemas/b">>,
    {ok, [A, B], Store} = valid_json_store:add(Store0, Entries),
    ?assertMatch(#document{canonical = A}, valid_json_store:fetch(A, Store)),
    ?assertMatch(#document{canonical = B}, valid_json_store:fetch(B, Store)).

%% Все заменяемые записи снимаются до проверки нового набора, поэтому batch
%% допускает безопасную перестановку canonical имён.
batch_swap_test() ->
    RA = <<"https://example.com/a">>,
    RB = <<"https://example.com/b">>,
    CA = <<"https://example.com/canonical-a">>,
    CB = <<"https://example.com/canonical-b">>,
    {ok, [_CA, _CB], Store0} =
        valid_json_store:add(valid_json_store:new([]),
                             [{RA, #{<<"$id">> => CA}},
                              {RB, #{<<"$id">> => CB}}]),
    {ok, [CB, CA], Store} =
        valid_json_store:add(Store0,
                             [{RA, #{<<"$id">> => CB}},
                              {RB, #{<<"$id">> => CA}}]),
    ?assertMatch(#document{retrieval = RA}, valid_json_store:fetch(CB, Store)),
    ?assertMatch(#document{retrieval = RB}, valid_json_store:fetch(CA, Store)).

batch_atomic_test() ->
    Existing = <<"https://example.com/existing">>,
    Free = <<"https://example.com/free">>,
    Conflict = <<"https://example.com/conflict">>,
    {ok, Conflict, Store} =
        valid_json_store:add(valid_json_store:new([]), Existing,
                             #{<<"$id">> => Conflict}),
    ?assertEqual(schema_error({name_taken, Conflict}),
                 valid_json_store:add(Store, [{Free, true},
                                              {<<"https://example.com/other">>,
                                               #{<<"$id">> => Conflict}}])),
    ?assertEqual(undefined, valid_json_store:fetch(Free, Store)).

remove_test() ->
    Retrieval = <<"https://example.com/retrieval">>,
    Canonical = <<"https://example.com/canonical">>,
    {ok, Canonical, Store0} =
        valid_json_store:add(valid_json_store:new([]), Retrieval,
                             #{<<"$id">> => Canonical}),
    %% Удалить можно по любому из двух внешних имён.
    {ok, Store1} = valid_json_store:remove(Store0, [Canonical]),
    ?assertEqual(undefined, valid_json_store:fetch(Retrieval, Store1)),
    ?assertEqual(undefined, valid_json_store:fetch(Canonical, Store1)),
    %% Неизвестное и встроенное имя операция не видит.
    ?assertEqual({ok, Store1},
                 valid_json_store:remove(
                   Store1, [<<"https://example.com/missing">>, ?BUILTIN])).

remove_relative_test() ->
    Store0 = valid_json_store:new([{base_uri, ?BASE}]),
    {ok, Canonical, Store1} = valid_json_store:add(Store0, <<"a">>, true),
    {ok, Store2} = valid_json_store:remove(Store1, [<<"a">>]),
    ?assertEqual(undefined, valid_json_store:fetch(Canonical, Store2)).

builtin_test() ->
    Empty = valid_json_store:new([]),
    Document = valid_json_store:fetch(?BUILTIN, Empty),
    ?assertMatch(#document{retrieval = ?BUILTIN,
                           canonical = ?BUILTIN,
                           json = #{<<"$id">> := ?BUILTIN}},
                 Document),
    %% format-assertion входит в 16 встроенных документов, хотя корневая
    %% meta-schema на него по умолчанию не ссылается.
    ?assertMatch(#document{},
                 valid_json_store:fetch(
                   <<"https://json-schema.org/draft/2020-12/meta/format-assertion">>,
                   Empty)),
    %% Output schema лежит в priv рядом, но в immutable область не входит.
    ?assertEqual(undefined,
                 valid_json_store:fetch(
                   <<"https://json-schema.org/draft/2020-12/output/schema">>, Empty)),
    ?assertEqual(schema_error({name_taken, ?BUILTIN}),
                 valid_json_store:add(Empty, ?BUILTIN, true)),
    ?assertEqual(schema_error({name_taken, ?BUILTIN}),
                 valid_json_store:add(Empty, <<"https://example.com/schema">>,
                                      #{<<"$id">> => ?BUILTIN})).

schema_error(Reason) ->
    {error, #schema_error{reason = Reason, location = undefined}}.
