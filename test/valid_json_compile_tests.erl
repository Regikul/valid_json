%% Compiler fixtures: точное равенство полного compiled() и явные compile errors.
-module(valid_json_compile_tests).

-include_lib("eunit/include/eunit.hrl").
-include("valid_json_core.hrl").

-define(DIALECT, <<"https://json-schema.org/draft/2020-12/schema">>).

boolean_schema_test_() ->
    [?_assertEqual({ok, artifact(true)},  compile(true)),
     ?_assertEqual({ok, artifact(false)}, compile(false))].

%% {} и true семантически равны, но дают разный IR.
empty_object_test() ->
    ?assertEqual({ok, artifact(schema_node([]))}, compile(#{})).

type_test_() ->
    [?_assertEqual({ok, artifact(schema_node([{type, [integer]}]))},
                   compile(#{<<"type">> => <<"integer">>})),
     ?_assertEqual({ok, artifact(schema_node([{type, [string, null]}]))},
                   compile(#{<<"type">> => [<<"string">>, <<"null">>]})),
     ?_assertEqual({ok, artifact(schema_node([{type, []}]))},
                   compile(#{<<"type">> => []}))].

enum_and_const_test_() ->
    [?_assertEqual({ok, artifact(schema_node([{enum, [1, <<"a">>, null]}]))},
                   compile(#{<<"enum">> => [1, <<"a">>, null]})),
     ?_assertEqual({ok, artifact(schema_node([{enum, []}]))},
                   compile(#{<<"enum">> => []})),
     ?_assertEqual({ok, artifact(schema_node([{const, #{<<"a">> => [1]}}]))},
                   compile(#{<<"const">> => #{<<"a">> => [1]}})),
     ?_assertEqual({ok, artifact(schema_node([{const, null}]))},
                   compile(#{<<"const">> => null}))].

numeric_test_() ->
    [?_assertEqual({ok, artifact(schema_node([{multiple_of, 2}]))},
                   compile(#{<<"multipleOf">> => 2})),
     ?_assertEqual({ok, artifact(schema_node([{multiple_of, 0.0001}]))},
                   compile(#{<<"multipleOf">> => 0.0001})),
     ?_assertEqual({ok, artifact(schema_node([{maximum, 3.0}]))},
                   compile(#{<<"maximum">> => 3.0})),
     ?_assertEqual({ok, artifact(schema_node([{exclusive_maximum, 3}]))},
                   compile(#{<<"exclusiveMaximum">> => 3})),
     ?_assertEqual({ok, artifact(schema_node([{minimum, -2}]))},
                   compile(#{<<"minimum">> => -2})),
     ?_assertEqual({ok, artifact(schema_node([{exclusive_minimum, 1.1}]))},
                   compile(#{<<"exclusiveMinimum">> => 1.1}))].

%% Неположительный делитель запрещён метасхемой, поэтому не доходит до IR.
bad_multiple_of_test_() ->
    [?_assertEqual({error, {bad_keyword_value, <<"multipleOf">>, 0}},
                   compile(#{<<"multipleOf">> => 0})),
     ?_assertEqual({error, {bad_keyword_value, <<"multipleOf">>, -1.5}},
                   compile(#{<<"multipleOf">> => -1.5})),
     ?_assertEqual({error, {bad_keyword_value, <<"multipleOf">>, <<"2">>}},
                   compile(#{<<"multipleOf">> => <<"2">>})),
     ?_assertEqual({error, {bad_keyword_value, <<"maximum">>, null}},
                   compile(#{<<"maximum">> => null})),
     ?_assertEqual({error, {bad_keyword_value, <<"minimum">>, true}},
                   compile(#{<<"minimum">> => true}))].

%% Порядок constraints задан компилятором и не зависит от порядка ключей.
order_test() ->
    Schema = #{<<"exclusiveMinimum">> => 0, <<"const">> => 1, <<"enum">> => [1],
               <<"maximum">> => 4, <<"type">> => <<"number">>,
               <<"multipleOf">> => 1},
    Expected = schema_node([{type, [number]}, {enum, [1]}, {const, 1},
                            {multiple_of, 1}, {maximum, 4},
                            {exclusive_minimum, 0}]),
    ?assertEqual({ok, artifact(Expected)}, compile(Schema)).

%% Потребляются компилятором и собственного constraint не дают.
consumed_keywords_test() ->
    Schema = #{<<"$schema">> => ?DIALECT,
               <<"$comment">> => <<"note">>,
               <<"type">> => <<"boolean">>},
    ?assertEqual({ok, artifact(schema_node([{type, [boolean]}]))}, compile(Schema)).

bad_keyword_value_test_() ->
    [?_assertEqual({error, {bad_keyword_value, <<"type">>, <<"int">>}},
                   compile(#{<<"type">> => <<"int">>})),
     ?_assertEqual({error, {bad_keyword_value, <<"type">>, [<<"string">>, 1]}},
                   compile(#{<<"type">> => [<<"string">>, 1]})),
     ?_assertEqual({error, {bad_keyword_value, <<"type">>, null}},
                   compile(#{<<"type">> => null})),
     ?_assertEqual({error, {bad_keyword_value, <<"enum">>, 1}},
                   compile(#{<<"enum">> => 1}))].

%% Ещё не реализованный keyword обязан останавливать компиляцию, а не молча
%% исчезать: иначе преждевременно подключённый файл сьюта пройдёт по недоразумению.
not_implemented_test_() ->
    [?_assertEqual({error, {not_implemented, {keyword, <<"properties">>}}},
                   compile(#{<<"properties">> => #{}})),
     ?_assertEqual({error, {not_implemented, {keyword, <<"$ref">>}}},
                   compile(#{<<"$ref">> => <<"#">>, <<"type">> => <<"object">>}))].

not_a_schema_test_() ->
    [?_assertEqual({error, {not_a_schema, 42}}, compile(42)),
     ?_assertEqual({error, {not_a_schema, null}}, compile(null)),
     ?_assertEqual({error, {not_a_schema, []}}, compile([]))].

compile(Schema) ->
    valid_json_compile:compile(Schema, ?DIALECT).

schema_node(Constraints) ->
    #node{constraints = Constraints, unevaluated = []}.

artifact(Node) ->
    #{root      => anonymous,
      sources   => [],
      resources => #{anonymous =>
          #resource{id               = undefined,
                    dialect          = ?DIALECT,
                    anchors          = #{},
                    dynamic_anchors  = #{},
                    recursive_anchor = false,
                    nodes            = #{<<>> => Node}}}}.
