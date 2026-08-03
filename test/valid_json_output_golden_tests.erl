%% End-to-end golden tests standard output: schema проходит compiler и evaluator,
%% а проверка сравнивает уже публичный JSON результата.
-module(valid_json_output_golden_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DRAFTS, [{<<"2020-12">>,
                  <<"https://json-schema.org/draft/2020-12/schema">>},
                 {<<"2019-09">>,
                  <<"https://json-schema.org/draft/2019-09/schema">>}]).

eunit_wrapper_(Tests) -> {inparallel, Tests}.

%% keywordLocation продолжает written path через $ref, а absolute location
%% строится от фактически применённой target schema.
reference_test_() ->
    [?_assertEqual(
        root(false, Id, <<"errors">>,
             [unit(false, <<"/$ref/type">>,
                   <<Id/binary, "#/$defs/value/type">>,
                   <<"error">>, <<"expected string, got integer">>)]),
        basic(schema(Dialect, Id,
                     #{<<"$defs">> =>
                           #{<<"value">> => #{<<"type">> => <<"string">>}},
                       <<"$ref">> => <<"#/$defs/value">>}),
              1))
     || {Tag, Dialect} <- ?DRAFTS,
        Id <- [id(Tag, <<"reference">>)]].

%% Написанный, но неприменимый к типу instance assertion остаётся unit в дереве,
%% однако detail не несёт и в плоской проекции basic отсутствует.
no_op_test_() ->
    [?_assertEqual(
        root(true, Id, <<"annotations">>, []),
        basic(schema(Dialect, Id, #{<<"minLength">> => 2}), 1))
     || {Tag, Dialect} <- ?DRAFTS,
        Id <- [id(Tag, <<"no-op">>)]].

%% Аннотация успешного keyword внутри провалившейся ветви остаётся в diagnostic
%% tree, но провалившийся schema object её не производит в effective basic.
dropped_annotation_test_() ->
    Branch = #{<<"properties">> => #{<<"a">> => true},
               <<"type">> => <<"string">>},
    [?_assertEqual(
        root(true, Id, <<"annotations">>, []),
        basic(schema(Dialect, Id, #{<<"anyOf">> => [Branch, true]}),
              #{<<"a">> => 1}))
     || {Tag, Dialect} <- ?DRAFTS,
        Id <- [id(Tag, <<"dropped-annotation">>)]].

%% Constraint order задан emitter'ом, а не внутренним порядком map. Golden
%% фиксирует наблюдаемый порядок всех одновременно провалившихся assertions.
error_order_test_() ->
    [?_assertEqual(
        root(false, Id, <<"errors">>,
             [unit(false, <<"/type">>, <<Id/binary, "#/type">>,
                   <<"error">>, <<"expected string, got integer">>),
              unit(false, <<"/enum">>, <<Id/binary, "#/enum">>,
                   <<"error">>, <<"value is not one of the enumerated values">>),
              unit(false, <<"/const">>, <<Id/binary, "#/const">>,
                   <<"error">>, <<"value is not equal to the constant">>),
              unit(false, <<"/maximum">>, <<Id/binary, "#/maximum">>,
                   <<"error">>, <<"value is greater than the maximum 5">>)]),
        basic(schema(Dialect, Id,
                     #{<<"maximum">> => 5,
                       <<"const">> => 2,
                       <<"enum">> => [1],
                       <<"type">> => <<"string">>}),
              10))
     || {Tag, Dialect} <- ?DRAFTS,
        Id <- [id(Tag, <<"error-order">>)]].

%% Annotation-only keywords тоже идут в статическом порядке, независимо от map.
annotation_order_test_() ->
    [?_assertEqual(
        root(true, Id, <<"annotations">>,
             [unit(true, <<"/title">>, <<Id/binary, "#/title">>,
                   <<"annotation">>, <<"title">>),
              unit(true, <<"/description">>, <<Id/binary, "#/description">>,
                   <<"annotation">>, <<"description">>),
              unit(true, <<"/default">>, <<Id/binary, "#/default">>,
                   <<"annotation">>, 42)]),
        basic(schema(Dialect, Id,
                     #{<<"default">> => 42,
                       <<"description">> => <<"description">>,
                       <<"title">> => <<"title">>}),
              null))
     || {Tag, Dialect} <- ?DRAFTS,
        Id <- [id(Tag, <<"annotation-order">>)]].

schema(Dialect, Id, Keywords) ->
    Keywords#{<<"$schema">> => Dialect, <<"$id">> => Id}.

id(Tag, Case) ->
    <<"https://example.com/output/", Tag/binary, "/", Case/binary>>.

basic(Schema, Instance) ->
    Dialect = maps:get(<<"$schema">>, Schema),
    {ok, Artifact} =
        valid_json_compile:compile(valid_json_store:new([]), Schema,
                                   [{default_dialect, Dialect}]),
    valid_json:validate(Artifact, Instance, [{output, basic}]).

root(Valid, Id, Key, Nested) ->
    {ok, #{<<"valid">>                    => Valid,
           <<"keywordLocation">>          => <<>>,
           <<"absoluteKeywordLocation">>  => <<Id/binary, "#">>,
           <<"instanceLocation">>         => <<>>,
           Key                             => Nested}}.

unit(Valid, Keyword, Absolute, DetailKey, Detail) ->
    #{<<"valid">>                    => Valid,
      <<"keywordLocation">>          => Keyword,
      <<"absoluteKeywordLocation">>  => Absolute,
      <<"instanceLocation">>         => <<>>,
      DetailKey                       => Detail}.
