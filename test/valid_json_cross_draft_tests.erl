%% Собственная cross-draft матрица: каждый source dialect ссылается на каждый
%% target dialect, плюс multi-hop цепочки и циклы между всеми четырьмя drafts.
%% Цель — закрепить инвариант: target компилируется своим dialect, source
%% `$ref`-семантика остаётся семантикой source dialect, а cycle guard не
%% зависит от предположения об одном dialect замыкания.
-module(valid_json_cross_draft_tests).

-include_lib("eunit/include/eunit.hrl").
-include("valid_json_resources.hrl").

-define(D6, <<"http://json-schema.org/draft-06/schema#">>).
-define(D7, <<"http://json-schema.org/draft-07/schema#">>).
-define(D2019, <<"https://json-schema.org/draft/2019-09/schema">>).
-define(D2020, <<"https://json-schema.org/draft/2020-12/schema">>).

%% Каждый target-документ валидирует объекты/массивы keyword'ом своего dialect:
%% dependencies (6), if/then (7), dependentSchemas (2019-09), prefixItems
%% (2020-12). Только правильный dialect интерпретирует keyword.
-define(TARGETS,
        [{?D6, <<"https://example.com/d6">>,
          #{<<"dependencies">> => #{<<"a">> => [<<"b">>]}}},
         {?D7, <<"https://example.com/d7">>,
          #{<<"if">> => #{<<"required">> => [<<"x">>]},
            <<"then">> => #{<<"required">> => [<<"y">>]}}},
         {?D2019, <<"https://example.com/d2019">>,
          #{<<"dependentSchemas">> =>
                #{<<"m">> => #{<<"required">> => [<<"n">>]}}}},
         {?D2020, <<"https://example.com/d2020">>,
          #{<<"prefixItems">> => [#{<<"type">> => <<"integer">>}]}}]).

%% Встроенные метасхемы поднимает дерево приложения, и без него компиляция
%% схемы не идёт.
ensure_app() ->
    {ok, _Started} = application:ensure_all_started(valid_json),
    ok.

eunit_wrapper_(Tests) ->
    {setup, fun ensure_app/0, Tests}.

store(Targets) ->
    Entries = [{Id, document(Dialect, Id, Schema)}
               || {Dialect, Id, Schema} <- Targets],
    {ok, _Names, Store} = valid_json_store:add(valid_json_store:temporary(),
                                               Entries),
    Store.

document(Dialect, Id, Schema) ->
    maps:merge(#{<<"$schema">> => Dialect, <<"$id">> => Id}, Schema).

compile(Store, Schema) ->
    valid_json_compile:compile(Store, Schema, [{schema_validation, trusted}]).

compile_ok(Store, Schema) ->
    {ok, Compiled} = compile(Store, Schema),
    Compiled.

verdict(Compiled, Instance) ->
    valid_json_core:validate(Compiled, Instance, [{output, flag}]).

%% Полная матрица 4x4: source Draft ссылается на target Draft. У classic
%% sources sibling `type: integer` обязан игнорироваться: target-значение
%% (объект или массив) остаётся валидным, а провал определяет target keyword.
%% У modern sources sibling `minLength: 0` безвреден, и вердикт тоже целиком
%% определяется target.
cross_draft_matrix_test_() ->
    Store = store(?TARGETS),
    [matrix_case(Store, Source, TargetDialect, Target)
     || {Source, _, _} <- ?TARGETS,
        {TargetDialect, Target, _} <- ?TARGETS].

matrix_case(Store, Source, TargetDialect, Target) ->
    Schema = case Source of
                 ?D6 ->
                     #{<<"$schema">> => Source, <<"$ref">> => Target,
                       <<"type">> => <<"integer">>};
                 ?D7 ->
                     #{<<"$schema">> => Source, <<"$ref">> => Target,
                       <<"type">> => <<"integer">>};
                 _Modern ->
                     #{<<"$schema">> => Source, <<"$ref">> => Target,
                       <<"minLength">> => 0}
             end,
    {ok, Compiled} = compile(Store, Schema),
    {Pass, Fail} = instances(TargetDialect),
    {title(Source, TargetDialect),
     [?_assertEqual({ok, #{<<"valid">> => true}}, verdict(Compiled, Pass)),
      ?_assertEqual({ok, #{<<"valid">> => false}}, verdict(Compiled, Fail))]}.

instances(?D6)      -> {#{<<"a">> => 1, <<"b">> => 2}, #{<<"a">> => 1}};
instances(?D7)      -> {#{<<"x">> => 1, <<"y">> => 2}, #{<<"x">> => 1}};
instances(?D2019)   -> {#{<<"m">> => 1, <<"n">> => 2}, #{<<"m">> => 1}};
instances(?D2020)   -> {[1], [<<"x">>]}.

title(Source, Target) ->
    unicode:characters_to_list(
      <<(short(Source))/binary, " -> ", (short(Target))/binary>>).

short(?D6)    -> <<"6">>;
short(?D7)    -> <<"7">>;
short(?D2019) -> <<"2019">>;
short(?D2020) -> <<"2020">>.

%% Source семантика остаётся семантикой source: classic `$ref` игнорирует
%% sibling даже когда target modern, а modern source применяет sibling даже
%% когда target classic.
cross_draft_source_semantics_test_() ->
    Store = store(?TARGETS),
    [?_assertEqual(
        {ok, #{<<"valid">> => true}},
        verdict(compile_ok(Store,
                           #{<<"$schema">> => ?D7,
                             <<"$ref">> => <<"https://example.com/d2020">>,
                             <<"type">> => <<"string">>}),
               [1])),
     ?_assertEqual(
        {ok, #{<<"valid">> => false}},
        verdict(compile_ok(Store,
                           #{<<"$schema">> => ?D2020,
                             <<"$ref">> => <<"https://example.com/d6">>,
                             <<"type">> => <<"object">>}),
               <<"not an object">>))].

%% Multi-hop цепочки: каждая ссылка переходит в документ своего dialect, а
%% финальный keyword работает по dialect последнего документа.
multi_hop_test_() ->
    lists:append(
      [chain(?D6,
             [{?D7, <<"https://example.com/h7">>,
               #{<<"$ref">> => <<"https://example.com/h2019">>}},
              {?D2019, <<"https://example.com/h2019">>,
               #{<<"$ref">> => <<"https://example.com/h2020">>}},
              {?D2020, <<"https://example.com/h2020">>,
               #{<<"prefixItems">> => [#{<<"type">> => <<"integer">>}]}}],
             ?D2020),
       chain(?D2020,
             [{?D6, <<"https://example.com/k6">>,
               #{<<"$ref">> => <<"https://example.com/k2019">>}},
              {?D2019, <<"https://example.com/k2019">>,
               #{<<"$ref">> => <<"https://example.com/k7">>}},
              {?D7, <<"https://example.com/k7">>,
               #{<<"if">> => #{<<"required">> => [<<"x">>]},
                 <<"then">> => #{<<"required">> => [<<"y">>]}}}],
             ?D7),
       chain(?D7,
             [{?D2020, <<"https://example.com/j2020">>,
               #{<<"$ref">> => <<"https://example.com/j6">>}},
              {?D6, <<"https://example.com/j6">>,
               #{<<"$ref">> => <<"https://example.com/j7">>}},
              {?D7, <<"https://example.com/j7">>,
               #{<<"if">> => #{<<"required">> => [<<"x">>]},
                 <<"then">> => #{<<"required">> => [<<"y">>]}}}],
             ?D7)]).

chain(Source, Hops, Final) ->
    Entries = [{Id, document(Dialect, Id, Schema)}
               || {Dialect, Id, Schema} <- Hops],
    {ok, _Names, Store} = valid_json_store:add(
                            valid_json_store:temporary(), Entries),
    {ok, Compiled} = compile(Store, #{<<"$schema">> => Source,
                                      <<"$ref">> =>
                                          element(2, hd(Hops))}),
    {Pass, Fail} = instances(Final),
    [?_assertEqual({ok, #{<<"valid">> => true}}, verdict(Compiled, Pass)),
     ?_assertEqual({ok, #{<<"valid">> => false}}, verdict(Compiled, Fail))].

%% Цикл между dialects: замыкание строится без предположения об одном dialect,
%% а вычисление охраняется тем же cycle guard, что и одно-dialect циклы.
cross_dialect_cycle_test() ->
    A = <<"https://example.com/cycle-a">>,
    B = <<"https://example.com/cycle-b">>,
    Documents = [{A, document(?D6, A,
                              #{<<"$ref">> => B})},
                 {B, document(?D2020, B,
                              #{<<"$ref">> => A})}],
    {ok, _Names, Store} = valid_json_store:add(
                            valid_json_store:temporary(), Documents),
    {ok, Compiled} = compile(Store, #{<<"$schema">> => ?D6,
                                      <<"$ref">> => A}),
    ?assertEqual([anonymous, A, B],
                 lists:sort(maps:keys(maps:get(resources, Compiled)))),
    ?assertMatch({error, {no_progress, _}},
                 verdict(Compiled, 1)).

%% Охраняемый цикл через свойства: рекурсия конечна на конечном инстансе, и
%% переходы между dialects работают внутри неё.
guarded_cross_dialect_cycle_test() ->
    A = <<"https://example.com/guarded-a">>,
    B = <<"https://example.com/guarded-b">>,
    Documents = [{A, document(?D6, A,
                              #{<<"properties">> =>
                                    #{<<"x">> => #{<<"$ref">> => B}},
                                <<"additionalProperties">> => false})},
                 {B, document(?D7, B,
                              #{<<"properties">> =>
                                    #{<<"x">> => #{<<"$ref">> => A}}})}],
    {ok, _Names, Store} = valid_json_store:add(
                            valid_json_store:temporary(), Documents),
    {ok, Compiled} = compile(Store, #{<<"$schema">> => ?D6,
                                      <<"$ref">> => A}),
    ?assertEqual({ok, #{<<"valid">> => true}},
                 verdict(Compiled, #{<<"x">> => #{<<"x">> => #{}}})),
    ?assertEqual({ok, #{<<"valid">> => false}},
                 verdict(Compiled, #{<<"x">> => #{<<"x">> => #{<<"y">> => 1}}})).

%% URI-resolution через dialects: retrieval != canonical, relative `$id`,
%% classic plain-name `$id` из modern source, modern `$anchor` из classic source,
%% JSON Pointer между dialects и вложенный resource.
uri_resolution_across_dialects_test() ->
    Retrieval = <<"https://retrieval.example/d">>,
    Canonical = <<"https://canonical.example/d">>,
    Classic = <<"https://example.com/classic">>,
    Modern = <<"https://example.com/modern">>,
    Documents = [{Retrieval,
                  document(?D6, Canonical,
                           #{<<"definitions">> =>
                                 #{<<"A">> => #{<<"$id">> => <<"#foo">>,
                                                <<"type">> => <<"integer">>}}})},
                 {Classic,
                  document(?D7, Classic,
                           #{<<"definitions">> =>
                                 #{<<"T">> => #{<<"type">> => <<"string">>}}})},
                 {Modern,
                  document(?D2020, Modern,
                           #{<<"$defs">> =>
                                 #{<<"T">> =>
                                       #{<<"$anchor">> => <<"bar">>,
                                         <<"type">> => <<"boolean">>}}})}],
    {ok, _Names, Store} = valid_json_store:add(
                            valid_json_store:temporary(), Documents),
    %% Retrieval alias и каноническое имя ведут к одному документу.
    {ok, ByCanonical} = compile(
                          Store,
                          #{<<"$schema">> => ?D6,
                            <<"$ref">> => <<Canonical/binary, "#foo">>}),
    ?assertEqual({ok, #{<<"valid">> => true}},
                 verdict(ByCanonical, 3)),
    %% Classic plain-name target из modern source.
    {ok, FromModern} = compile(
                         Store,
                         #{<<"$schema">> => ?D2020,
                           <<"$ref">> => <<Canonical/binary, "#foo">>}),
    ?assertEqual({ok, #{<<"valid">> => true}},
                 verdict(FromModern, 5)),
    %% Modern `$anchor` target из classic source.
    {ok, FromClassic} = compile(
                          Store,
                          #{<<"$schema">> => ?D7,
                            <<"$ref">> => <<Modern/binary, "#bar">>}),
    ?assertEqual({ok, #{<<"valid">> => false}},
                 verdict(FromClassic, 3)),
    %% JSON Pointer между dialects.
    {ok, PointerRef} = compile(
                         Store,
                         #{<<"$schema">> => ?D2020,
                           <<"$ref">> =>
                               <<Classic/binary, "#/definitions/T">>}),
    ?assertEqual({ok, #{<<"valid">> => true}},
                 verdict(PointerRef, <<"text">>)).

%% Встроенный resource с относительным `$id` внутри classic документа:
%% modern `$ref` разрешается от retrieval URI и попадает во вложенный resource.
relative_id_across_dialects_test() ->
    Root = <<"https://example.com/root">>,
    Child = <<"https://example.com/child">>,
    Documents = [{Root,
                  document(?D7, Root,
                           #{<<"definitions">> =>
                                 #{<<"X">> =>
                                       #{<<"$id">> => <<"child">>,
                                         <<"type">> => <<"integer">>}}})}],
    {ok, _Names, Store} = valid_json_store:add(
                            valid_json_store:temporary(), Documents),
    {ok, Compiled} = compile(
                       Store,
                       #{<<"$schema">> => ?D2020,
                         <<"allOf">> =>
                             [#{<<"$ref">> => Root},
                              #{<<"$ref">> => Child}]}),
    ?assertEqual({ok, #{<<"valid">> => true}},
                 verdict(Compiled, 1)),
    ?assertEqual({ok, #{<<"valid">> => false}},
                 verdict(Compiled, <<"x">>)).
