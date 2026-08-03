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

%% Стандартные корневые метасхемы сохраняют `definitions` как совместимый
%% location-reserving alias `$defs`. Физическое имя контейнера остаётся частью
%% pointer: алиас относится к семантике, а не к переписыванию адреса.
definitions_schema_positions_test_() ->
    Schema = #{<<"$defs">> => #{<<"current">> => true},
               <<"definitions">> => #{<<"legacy">> => false}},
    Check = fun(Dialect) ->
                    {ok, Index} = discover(Schema, anonymous, Dialect),
                    ?assertEqual(
                       #{anonymous => #{<<>> => Schema,
                                        <<"/$defs/current">> => true,
                                        <<"/definitions/legacy">> => false}},
                       valid_json_resource_index:resources(Index))
            end,
    [{atom_to_list(Name), fun() -> Check(Dialect) end}
     || {Name, Dialect} <- [{current, ?DIALECT}, {legacy, ?LEGACY}]].

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

anchor_index_test() ->
    Root = <<"https://example.com/root">>,
    Schema = #{<<"$id">> => Root,
               <<"$anchor">> => <<"root_anchor">>,
               <<"$defs">> =>
                   #{<<"leaf">> => #{<<"$anchor">> => <<"leaf.anchor">>,
                                      <<"type">> => <<"integer">>}}},
    {ok, Index} = discover(Schema, <<"https://example.com/retrieval">>),
    ?assertEqual(#{Root => #{<<"root_anchor">> => <<>>,
                             <<"leaf.anchor">> => <<"/$defs/leaf">>}},
                 valid_json_resource_index:anchors(Index)),
    ?assertEqual({ok, {Root, <<>>}},
                 resolve_ref(Index, Root, <<"#root_anchor">>)),
    ?assertEqual({ok, {Root, <<"/$defs/leaf">>}},
                 resolve_ref(Index, Root, <<"#leaf.anchor">>)),
    %% Retrieval alias выбирает тот же canonical resource и его anchors.
    ?assertEqual({ok, {Root, <<"/$defs/leaf">>}},
                 resolve_ref(Index, <<"https://example.com/retrieval">>,
                             <<"#leaf.anchor">>)).

anchor_resource_boundary_test() ->
    Root = <<"https://example.com/root">>,
    Child = <<"https://example.com/child">>,
    Schema = #{<<"$id">> => Root,
               <<"$anchor">> => <<"same">>,
               <<"$defs">> =>
                   #{<<"child">> => #{<<"$id">> => Child,
                                        <<"$anchor">> => <<"same">>}}},
    {ok, Index} = discover(Schema, anonymous),
    ?assertEqual(#{Root => #{<<"same">> => <<>>},
                   Child => #{<<"same">> => <<>>}},
                 valid_json_resource_index:anchors(Index)),
    ?assertEqual({ok, {Root, <<>>}}, resolve_ref(Index, Root, <<"#same">>)),
    ?assertEqual({ok, {Child, <<>>}}, resolve_ref(Index, Child, <<"#same">>)).

%% `$dynamicAnchor` объявляет ещё и обычный plain-name fragment, поэтому имя
%% видно в обеих картах, а `$ref` на него разрешается как на статический anchor.
dynamic_anchor_index_test() ->
    Root = <<"https://example.com/root">>,
    Child = <<"https://example.com/child">>,
    Schema = #{<<"$id">> => Root,
               <<"$dynamicAnchor">> => <<"node">>,
               <<"$defs">> =>
                   #{<<"child">> => #{<<"$id">> => Child,
                                      <<"$anchor">> => <<"plain">>,
                                      <<"$dynamicAnchor">> => <<"node">>}}},
    {ok, Index} = discover(Schema, anonymous),
    ?assertEqual(#{Root => #{<<"node">> => <<>>},
                   Child => #{<<"node">> => <<>>}},
                 valid_json_resource_index:dynamic_anchors(Index)),
    ?assertEqual(#{Root => #{<<"node">> => <<>>},
                   Child => #{<<"plain">> => <<>>, <<"node">> => <<>>}},
                 valid_json_resource_index:anchors(Index)),
    ?assertEqual({ok, {Root, <<>>}}, resolve_ref(Index, Root, <<"#node">>)),
    ?assertEqual({ok, {Child, <<>>}}, resolve_ref(Index, Child, <<"#node">>)).

%% В Draft 2019-09 keyword не существует, и dialect не индексирует его вовсе —
%% включая имя, недопустимое по правилу Draft 2020-12.
dynamic_anchor_legacy_test() ->
    Schema = #{<<"$dynamicAnchor">> => <<"bad:name">>},
    {ok, Index} = discover(Schema, anonymous, ?LEGACY),
    ?assertEqual(#{anonymous => #{}},
                 valid_json_resource_index:dynamic_anchors(Index)),
    ?assertEqual(#{anonymous => #{}},
                 valid_json_resource_index:anchors(Index)),
    ?assertEqual(error, resolve_ref(Index, anonymous, <<"#bad:name">>)).

%% Некорневой recursive anchor не меняет объемлющий resource. `$id` сначала
%% создаёт новую границу и только затем превращает объявление в корневое.
recursive_anchor_resource_roots_test() ->
    Root = <<"https://example.com/root">>,
    Child = <<"https://example.com/child">>,
    Schema = #{<<"$id">> => Root,
               <<"$recursiveAnchor">> => false,
               <<"definitions">> =>
                   #{<<"nested">> => #{<<"$recursiveAnchor">> => true},
                     <<"resource">> => #{<<"$id">> => Child,
                                          <<"$recursiveAnchor">> => true}}},
    {ok, Index} = discover(Schema, anonymous, ?LEGACY),
    ?assertEqual(#{Root => false, Child => true},
                 valid_json_resource_index:recursive_anchors(Index)).

recursive_anchor_dialect_test_() ->
    [?_assertEqual(
         schema_error({bad_keyword_value, <<"yes">>},
                      {anonymous, <<"/$recursiveAnchor">>}),
         discover(#{<<"$recursiveAnchor">> => <<"yes">>}, anonymous, ?LEGACY)),
     ?_assertEqual(
         schema_error({bad_keyword_value, 1},
                      {anonymous, <<"/definitions/x/$recursiveAnchor">>}),
         discover(#{<<"definitions">> =>
                        #{<<"x">> => #{<<"$recursiveAnchor">> => 1}}},
                  anonymous, ?LEGACY)),
     %% В 2020-12 это неизвестная annotation, а index её значение не толкует.
     ?_assertMatch(
         {ok, _},
         discover(#{<<"$recursiveAnchor">> => <<"any-json">>},
                  anonymous, ?DIALECT))].

dynamic_anchor_value_test_() ->
    [?_assertEqual(
         schema_error({bad_keyword_value, <<"bad:name">>},
                      {anonymous, <<"/$dynamicAnchor">>}),
         discover(#{<<"$dynamicAnchor">> => <<"bad:name">>}, anonymous)),
     ?_assertEqual(
         schema_error({bad_keyword_value, 42},
                      {anonymous, <<"/$dynamicAnchor">>}),
         discover(#{<<"$dynamicAnchor">> => 42}, anonymous)),
     %% Имя проверяется на своей позиции, а не только в корне resource.
     ?_assertEqual(
         schema_error({bad_keyword_value, <<"9bad">>},
                      {anonymous, <<"/$defs/leaf/$dynamicAnchor">>}),
         discover(#{<<"$defs">> =>
                        #{<<"leaf">> => #{<<"$dynamicAnchor">> => <<"9bad">>}}},
                  anonymous))].

anchor_value_test_() ->
    [?_assertEqual(
         schema_error({bad_keyword_value, <<"bad:name">>},
                      {anonymous, <<"/$anchor">>}),
         discover(#{<<"$anchor">> => <<"bad:name">>}, anonymous)),
     ?_assertEqual(
         schema_error({bad_keyword_value, <<"9bad">>},
                      {anonymous, <<"/$anchor">>}),
         discover(#{<<"$anchor">> => <<"9bad">>}, anonymous)),
     ?_assertEqual(
         schema_error({bad_keyword_value, 42},
                      {anonymous, <<"/$anchor">>}),
         discover(#{<<"$anchor">> => 42}, anonymous)),
     %% Draft 2019-09 допускает двоеточие в имени anchor.
     ?_assertMatch({ok, _},
                   discover(#{<<"$anchor">> => <<"valid:name">>},
                            anonymous, ?LEGACY)),
     ?_assertEqual(
         schema_error({bad_keyword_value, <<"_legacy">>},
                      {anonymous, <<"/$anchor">>}),
         discover(#{<<"$anchor">> => <<"_legacy">>}, anonymous, ?LEGACY)),
     %% Похожее объявление вне schema position не индексируется и не проверяется.
     ?_assertMatch({ok, _},
                   discover(#{<<"const">> =>
                                  #{<<"$anchor">> => <<"bad:name">>}},
                            anonymous))].

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

%% Встроенный resource без `$schema` наследует dialect объемлющего: набор
%% schema positions у него тот же, что у корня документа.
embedded_dialect_inheritance_test() ->
    Root = <<"https://example.com/root.json">>,
    Embedded = <<"https://example.com/embedded.json">>,
    Tail = <<"https://example.com/tail.json">>,
    Schema = #{<<"$id">> => Root,
               <<"$defs">> =>
                   #{<<"e">> => #{<<"$id">> => Embedded,
                                  <<"items">> => [#{<<"$id">> => <<"item.json">>}],
                                  <<"additionalItems">> => #{<<"$id">> => Tail}}}},
    {ok, Legacy} = discover(Schema, anonymous, ?LEGACY),
    ?assertEqual(#{Root => ?LEGACY, Embedded => ?LEGACY, Tail => ?LEGACY,
                   <<"https://example.com/item.json">> => ?LEGACY},
                 valid_json_resource_index:dialects(Legacy)),

    %% Тот же документ под Draft 2020-12: array-form `items` и `additionalItems`
    %% не являются schema positions, поэтому `$id` внутри них resource не создаёт.
    {ok, Current} = discover(Schema, anonymous, ?DIALECT),
    ?assertEqual(#{Root => ?DIALECT, Embedded => ?DIALECT},
                 valid_json_resource_index:dialects(Current)).

%% Собственный `$schema` встроенного resource меняет dialect его поддерева и
%% только его: соседняя ветка остаётся при dialect объемлющего.
embedded_dialect_switch_test() ->
    Root = <<"https://example.com/root.json">>,
    Embedded = <<"https://example.com/embedded.json">>,
    Schema = #{<<"$id">> => Root,
               <<"$defs">> =>
                   #{<<"legacy">> =>
                         #{<<"$id">> => Embedded,
                           <<"$schema">> => ?LEGACY,
                           %% В 2019-09 keyword неизвестен: обход внутрь не идёт.
                           <<"prefixItems">> => [#{<<"$id">> => <<"prefix.json">>}],
                           <<"additionalItems">> => #{<<"$id">> => <<"tail.json">>}},
                     <<"current">> =>
                         #{<<"prefixItems">> => [#{<<"$id">> => <<"sibling.json">>}]}}},
    {ok, Index} = discover(Schema, anonymous, ?DIALECT),
    ?assertEqual(#{Root => ?DIALECT,
                   Embedded => ?LEGACY,
                   <<"https://example.com/tail.json">> => ?LEGACY,
                   <<"https://example.com/sibling.json">> => ?DIALECT},
                 valid_json_resource_index:dialects(Index)),
    ?assertEqual(error, resolve_ref(Index, Embedded, <<"#/prefixItems/0">>)),
    ?assertEqual({ok, {<<"https://example.com/tail.json">>, <<>>}},
                 resolve_ref(Index, Embedded, <<"#/additionalItems">>)).

%% Anchors тоже подчиняются dialect своего resource, а не документа:
%% `$dynamicAnchor` в 2019-09-ресурсе не индексируется, `$recursiveAnchor` в нём,
%% наоборот, начинает действовать.
embedded_dialect_anchors_test() ->
    Root = <<"https://example.com/root.json">>,
    Embedded = <<"https://example.com/embedded.json">>,
    Schema = #{<<"$id">> => Root,
               <<"$dynamicAnchor">> => <<"node">>,
               <<"$defs">> =>
                   #{<<"legacy">> => #{<<"$id">> => Embedded,
                                       <<"$schema">> => ?LEGACY,
                                       <<"$dynamicAnchor">> => <<"node">>,
                                       <<"$recursiveAnchor">> => true}}},
    {ok, Index} = discover(Schema, anonymous, ?DIALECT),
    ?assertEqual(#{Root => #{<<"node">> => <<>>}, Embedded => #{}},
                 valid_json_resource_index:dynamic_anchors(Index)),
    ?assertEqual(#{Root => false, Embedded => true},
                 valid_json_resource_index:recursive_anchors(Index)).

%% Ошибка dialect встроенного resource называет его собственный `$schema`, а не
%% корень документа.
embedded_dialect_error_test_() ->
    Embedded = <<"https://example.com/embedded.json">>,
    Discover = fun(Dialect) ->
                       discover(#{<<"$defs">> =>
                                      #{<<"e">> => #{<<"$id">> => Embedded,
                                                     <<"$schema">> => Dialect}}},
                                anonymous)
               end,
    Unknown = <<"https://example.com/dialect">>,
    [?_assertEqual(schema_error({unknown_dialect, Unknown},
                                {Embedded, <<"/$schema">>}),
                   Discover(Unknown)),
     ?_assertEqual(schema_error({bad_keyword_value, 42},
                                {Embedded, <<"/$schema">>}),
                   Discover(42))].

%% Оба dialects запрещают `$schema` вне корня schema resource: 2020-12 —
%% core.txt:1377, 2019-09 — core.txt:1320.
misplaced_schema_test_() ->
    Nested = #{<<"$defs">> => #{<<"x">> => #{<<"$schema">> => ?DIALECT}}},
    [?_assertEqual(schema_error({misplaced_keyword, <<"$schema">>},
                                {anonymous, <<"/$defs/x/$schema">>}),
                   discover(Nested, anonymous, ?DIALECT)),
     ?_assertEqual(schema_error({misplaced_keyword, <<"$schema">>},
                                {anonymous, <<"/$defs/x/$schema">>}),
                   discover(Nested, anonymous, ?LEGACY)),
     %% Корень документа своим `$schema` уже прочитан вызывающим, и запрет его
     %% не касается.
     ?_assertMatch({ok, _}, discover(#{<<"$schema">> => ?DIALECT}, anonymous)),
     %% Вне schema position keyword не проверяется: туда обход не спускается.
     ?_assertMatch({ok, _},
                   discover(#{<<"const">> => #{<<"$schema">> => ?DIALECT}},
                            anonymous))].

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

%% Тесты этой границы называют dialect, а профиль строится по встроенной
%% таблице: собственные vocabulary-tests лежат рядом с их разбором. Резолвер
%% берётся над пустым store: пользовательские метасхемы проверяются compiler
%% fixtures, где реестр есть.
discover(Schema, Retrieval, Dialect) ->
    Profile = valid_json_vocabulary:canonical(Dialect),
    valid_json_resource_index:discover(
      Schema, Retrieval, Profile,
      valid_json_compile_closure:dialect_resolver(valid_json_store:new([]),
                                                  Profile)).

resolve_ref(Index, Base, Reference) ->
    {ok, ResolvedBase, Target} = valid_json_uri:resolve(Reference, Base),
    valid_json_resource_index:resolve(ResolvedBase, Target, Index).

schema_error(Reason, Location) ->
    {error, #schema_error{reason = Reason, location = Location}}.
