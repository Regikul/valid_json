%% Точные tests первой compiler phase: resource boundaries, исходные schemas и
%% canonicalization физических pointer aliases.
-module(valid_json_resource_index_tests).

-include_lib("eunit/include/eunit.hrl").
-include("valid_json_core.hrl").

%% Значения immutable и глобального состояния нет.
eunit_wrapper_(Tests) -> {inparallel, Tests}.

-define(DIALECT, <<"https://json-schema.org/draft/2020-12/schema">>).
-define(LEGACY, <<"https://json-schema.org/draft/2019-09/schema">>).

anonymous_root_test() ->
    Schema = #{<<"properties">> => #{<<"a">> => true},
               <<"unknown">> => #{<<"not-a-node">> => false}},
    {ok, Index} = discover(Schema, anonymous),
    ?assertEqual(anonymous, valid_json_resource_index:root(Index)),
    ?assertEqual(
       #{anonymous => #{<<>> => Schema, <<"/properties/a">> => true}},
       valid_json_resource_index:resources(Index)),
    ?assertEqual({ok, {anonymous, <<"/properties/a">>}},
                 resolve_ref(Index, anonymous, <<"#/properties/a">>)),
    ?assertEqual(error,
                 resolve_ref(Index, anonymous, <<"#/unknown/not-a-node">>)).

embedded_resource_test() ->
    Foo = <<"https://example.com/foo">>,
    Bar = <<"https://example.com/bar">>,
    Child = #{<<"$id">> => Bar, <<"additionalProperties">> => #{}},
    Schema = #{<<"$id">> => Foo, <<"items">> => Child},
    {ok, Index} = discover(Schema, anonymous),
    ?assertEqual(Foo, valid_json_resource_index:root(Index)),
    ?assertEqual(
       #{Foo => #{<<>> => Schema},
         Bar => #{<<>> => Child, <<"/additionalProperties">> => #{}}},
       valid_json_resource_index:resources(Index)),
    %% Parent-pointer и canonical URI выбирают один физический node.
    ?assertEqual({ok, {Bar, <<>>}}, resolve_ref(Index, Foo, <<"#/items">>)),
    ?assertEqual({ok, {Bar, <<"/additionalProperties">>}},
                 resolve_ref(Index, Foo,
                             <<"#/items/additionalProperties">>)),
    ?assertEqual({ok, {Bar, <<"/additionalProperties">>}},
                 resolve_ref(Index, Bar, <<"#/additionalProperties">>)).

nested_parent_aliases_test() ->
    A = <<"https://example.com/root.json">>,
    B = <<"https://example.com/folder/b.json">>,
    C = <<"https://example.com/folder/c.json">>,
    Leaf = #{<<"type">> => <<"integer">>},
    CSchema = #{<<"$id">> => <<"c.json">>,
                <<"properties">> => #{<<"x">> => Leaf}},
    BSchema = #{<<"$id">> => <<"folder/b.json">>,
                <<"$defs">> => #{<<"c">> => CSchema}},
    Schema = #{<<"$id">> => A,
               <<"$defs">> => #{<<"b">> => BSchema}},
    {ok, Index} = discover(Schema, anonymous),
    ?assertEqual(lists:sort([A, B, C]),
                 lists:sort(maps:keys(valid_json_resource_index:resources(Index)))),
    Canonical = {C, <<"/properties/x">>},
    ?assertEqual({ok, Canonical},
                 resolve_ref(Index, A,
                             <<"#/$defs/b/$defs/c/properties/x">>)),
    ?assertEqual({ok, Canonical},
                 resolve_ref(Index, B, <<"#/$defs/c/properties/x">>)),
    ?assertEqual({ok, Canonical},
                 resolve_ref(Index, C, <<"#/properties/x">>)).

retrieval_alias_test() ->
    Retrieval = <<"https://example.com/download/schema.json">>,
    Foo = <<"https://example.com/canonical/root.json">>,
    Bar = <<"https://example.com/canonical/child.json">>,
    Child = #{<<"$id">> => <<"child.json">>, <<"not">> => false},
    Schema = #{<<"$id">> => Foo,
               <<"$defs">> => #{<<"child">> => Child}},
    {ok, Index} = discover(Schema, Retrieval),
    ?assertEqual({ok, {Foo, <<>>}}, resolve_ref(Index, Retrieval, <<"#">>)),
    ?assertEqual({ok, {Bar, <<>>}},
                 resolve_ref(Index, Retrieval, <<"#/$defs/child">>)),
    ?assertEqual({ok, {Bar, <<"/not">>}},
                 resolve_ref(Index, Retrieval, <<"#/$defs/child/not">>)),
    ?assertEqual({ok, {Bar, <<"/not">>}},
                 resolve_ref(Index, Foo, <<"#/$defs/child/not">>)).

anonymous_parent_alias_test() ->
    Bar = <<"https://example.com/bar">>,
    Child = #{<<"$id">> => Bar, <<"contains">> => true},
    Schema = #{<<"$defs">> => #{<<"child">> => Child}},
    {ok, Index} = discover(Schema, anonymous),
    ?assertEqual({ok, {Bar, <<>>}},
                 resolve_ref(Index, anonymous, <<"#/$defs/child">>)),
    ?assertEqual({ok, {Bar, <<"/contains">>}},
                 resolve_ref(Index, anonymous,
                             <<"#/$defs/child/contains">>)).

escaped_physical_pointer_test() ->
    Root = <<"https://example.com/root">>,
    Child = <<"https://example.com/child">>,
    Name = <<"a/b~c">>,
    Schema = #{<<"$id">> => Root,
               <<"$defs">> => #{Name => #{<<"$id">> => Child}}},
    {ok, Index} = discover(Schema, anonymous),
    ?assertEqual({ok, {Child, <<>>}},
                 resolve_ref(Index, Root, <<"#/$defs/a~1b~0c">>)),
    %% `$defs` — контейнер, но не schema node.
    ?assertEqual(error, resolve_ref(Index, Root, <<"#/$defs">>)).

schema_positions_only_test() ->
    Ghost = <<"https://example.com/ghost">>,
    Schema = #{<<"unknown">> => #{<<"$id">> => Ghost,
                                   <<"not">> => false},
               <<"const">> => #{<<"$id">> => Ghost},
               <<"default">> => #{<<"$id">> => Ghost}},
    {ok, Index} = discover(Schema, anonymous),
    ?assertEqual(#{anonymous => #{<<>> => Schema}},
                 valid_json_resource_index:resources(Index)),
    ?assertEqual(error, resolve_ref(Index, anonymous, <<"#/unknown">>)).

dialect_schema_positions_test() ->
    Root = <<"https://example.com/root.json">>,
    Item = #{<<"$id">> => <<"item.json">>},
    Tail = #{<<"$id">> => <<"tail.json">>},
    LegacySchema = #{<<"$id">> => Root,
                     <<"items">> => [Item],
                     <<"additionalItems">> => Tail},
    {ok, Legacy} = discover(LegacySchema, anonymous, ?LEGACY),
    ?assertEqual({ok, {<<"https://example.com/item.json">>, <<>>}},
                 resolve_ref(Legacy, Root, <<"#/items/0">>)),
    ?assertEqual({ok, {<<"https://example.com/tail.json">>, <<>>}},
                 resolve_ref(Legacy, Root, <<"#/additionalItems">>)),

    Prefix = #{<<"$id">> => <<"prefix.json">>},
    CurrentSchema = #{<<"$id">> => Root,
                      <<"prefixItems">> => [Prefix],
                      %% Array-form items не является schema position в 2020-12.
                      <<"items">> => [Item]},
    {ok, Current} = discover(CurrentSchema, anonymous),
    ?assertEqual({ok, {<<"https://example.com/prefix.json">>, <<>>}},
                 resolve_ref(Current, Root, <<"#/prefixItems/0">>)),
    ?assertEqual(error, resolve_ref(Current, Root, <<"#/items/0">>)).

id_error_test_() ->
    Root = <<"https://example.com/root.json">>,
    Duplicate = <<"https://example.com/duplicate">>,
    DuplicateSchema =
        #{<<"$id">> => Root,
          <<"$defs">> =>
              #{<<"a">> => #{<<"$id">> => Duplicate},
                <<"b">> => #{<<"$id">> => Duplicate}}},
    [?_assertEqual(
         schema_error(relative_uri_without_base, {anonymous, <<"/$id">>}),
         discover(#{<<"$id">> => <<"relative.json">>}, anonymous)),
     ?_assertEqual(
         schema_error({bad_keyword_value, 42}, {anonymous, <<"/$id">>}),
         discover(#{<<"$id">> => 42}, anonymous)),
     ?_assertEqual(
         schema_error({bad_keyword_value, <<"#anchor">>},
                      {Root, <<"/$defs/x/$id">>}),
         discover(#{<<"$id">> => Root,
                    <<"$defs">> =>
                        #{<<"x">> => #{<<"$id">> => <<"#anchor">>}}},
                  anonymous)),
     ?_assertEqual(
         schema_error({name_taken, Duplicate},
                      {Root, <<"/$defs/b/$id">>}),
         discover(DuplicateSchema, anonymous)),
     ?_assertEqual(
         schema_error({name_taken, <<"https://example.com/retrieval">>},
                      {Root, <<"/$defs/x/$id">>}),
         discover(#{<<"$id">> => Root,
                    <<"$defs">> =>
                        #{<<"x">> =>
                              #{<<"$id">> =>
                                    <<"https://example.com/retrieval">>}}},
                  <<"https://example.com/retrieval">>))].

schema_value_error_test() ->
    ?assertEqual(schema_error({bad_keyword_value, 42},
                              {anonymous, <<"/not">>}),
                 discover(#{<<"not">> => 42}, anonymous)).

retrieval_error_test() ->
    ?assertEqual({error, #schema_error{reason = invalid_uri,
                                      location = undefined}},
                 discover(true, <<"https://example.com/root#anchor">>)).

discover(Schema, Retrieval) ->
    discover(Schema, Retrieval, ?DIALECT).

discover(Schema, Retrieval, Dialect) ->
    valid_json_resource_index:discover(Schema, Retrieval, Dialect).

resolve_ref(Index, Base, Reference) ->
    {ok, ResolvedBase, Target} = valid_json_uri:resolve(Reference, Base),
    valid_json_resource_index:resolve(ResolvedBase, Target, Index).

schema_error(Reason, Location) ->
    {error, #schema_error{reason = Reason, location = Location}}.
