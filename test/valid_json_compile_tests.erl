%% Compiler fixtures: точное равенство полного compiled() и явные compile errors.
-module(valid_json_compile_tests).

-include_lib("eunit/include/eunit.hrl").
-include("valid_json_core.hrl").

%% Тесты модуля независимы, поэтому eunit прогоняет их параллельно.
eunit_wrapper_(Tests) -> {inparallel, Tests}.

-define(DIALECT, <<"https://json-schema.org/draft/2020-12/schema">>).
-define(LEGACY, <<"https://json-schema.org/draft/2019-09/schema">>).

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
    [?_assertEqual(schema_error({bad_keyword_value, 0}, <<"/multipleOf">>),
                   compile(#{<<"multipleOf">> => 0})),
     ?_assertEqual(schema_error({bad_keyword_value, -1.5}, <<"/multipleOf">>),
                   compile(#{<<"multipleOf">> => -1.5})),
     ?_assertEqual(schema_error({bad_keyword_value, <<"2">>}, <<"/multipleOf">>),
                   compile(#{<<"multipleOf">> => <<"2">>})),
     ?_assertEqual(schema_error({bad_keyword_value, null}, <<"/maximum">>),
                   compile(#{<<"maximum">> => null})),
     ?_assertEqual(schema_error({bad_keyword_value, true}, <<"/minimum">>),
                   compile(#{<<"minimum">> => true}))].

%% Скомпилированный re:mp() попадает прямо в IR, поэтому точное равенство
%% артефактов должно сохраниться: одинаковый исходный текст даёт равные термы.
pattern_test_() ->
    [?_assertEqual({ok, artifact(schema_node([{pattern, regex(<<"^a+$">>)}]))},
                   compile(#{<<"pattern">> => <<"^a+$">>})),
     ?_assertEqual({ok, artifact(schema_node([{pattern, regex(<<"[0-9]">>)}]))},
                   compile(#{<<"pattern">> => <<"[0-9]">>}))].

%% Некомпилируемое выражение останавливает компиляцию схемы. Причина от re
%% проверяется по форме: её текст принадлежит библиотеке и может меняться.
bad_pattern_test_() ->
    [?_assertMatch({error, #schema_error{reason   = {bad_pattern, _},
                                         location = {anonymous, <<"/pattern">>}}},
                   compile(#{<<"pattern">> => <<"(">>})),
     ?_assertMatch({error, #schema_error{reason   = {bad_pattern, _},
                                         location = {anonymous, <<"/pattern">>}}},
                   compile(#{<<"pattern">> => <<"[z-a]">>})),
     %% Нестроковое значение — обычная ошибка значения keyword, не regex.
     ?_assertEqual(schema_error({bad_keyword_value, 1}, <<"/pattern">>),
                   compile(#{<<"pattern">> => 1}))].

counted_test_() ->
    [?_assertEqual({ok, artifact(schema_node([{max_length, 2}]))},
                   compile(#{<<"maxLength">> => 2})),
     ?_assertEqual({ok, artifact(schema_node([{min_items, 1}]))},
                   compile(#{<<"minItems">> => 1})),
     ?_assertEqual({ok, artifact(schema_node([{max_properties, 0}]))},
                   compile(#{<<"maxProperties">> => 0})),
     %% Десятичная форма — то же целое, и в IR попадает целым.
     ?_assertEqual({ok, artifact(schema_node([{min_length, 2}]))},
                   compile(#{<<"minLength">> => 2.0})),
     ?_assertEqual({ok, artifact(schema_node([{max_items, 2}]))},
                   compile(#{<<"maxItems">> => 2.0}))].

collections_test_() ->
    [?_assertEqual({ok, artifact(schema_node([{unique_items, true}]))},
                   compile(#{<<"uniqueItems">> => true})),
     %% Написанный no-op сохраняется в IR, а не выбрасывается.
     ?_assertEqual({ok, artifact(schema_node([{unique_items, false}]))},
                   compile(#{<<"uniqueItems">> => false})),
     ?_assertEqual({ok, artifact(schema_node([{required, [<<"a">>, <<"b">>]}]))},
                   compile(#{<<"required">> => [<<"a">>, <<"b">>]})),
     ?_assertEqual({ok, artifact(schema_node([{required, []}]))},
                   compile(#{<<"required">> => []})),
     ?_assertEqual({ok, artifact(schema_node([{dependent_required,
                                               #{<<"bar">> => [<<"foo">>]}}]))},
                   compile(#{<<"dependentRequired">> => #{<<"bar">> => [<<"foo">>]}}))].

bad_counted_test_() ->
    [?_assertEqual(schema_error({bad_keyword_value, -1}, <<"/maxLength">>),
                   compile(#{<<"maxLength">> => -1})),
     ?_assertEqual(schema_error({bad_keyword_value, 1.5}, <<"/minItems">>),
                   compile(#{<<"minItems">> => 1.5})),
     ?_assertEqual(schema_error({bad_keyword_value, <<"2">>}, <<"/maxProperties">>),
                   compile(#{<<"maxProperties">> => <<"2">>})),
     ?_assertEqual(schema_error({bad_keyword_value, 1}, <<"/uniqueItems">>),
                   compile(#{<<"uniqueItems">> => 1})),
     ?_assertEqual(schema_error({bad_keyword_value, [1]}, <<"/required">>),
                   compile(#{<<"required">> => [1]})),
     ?_assertEqual(schema_error({bad_keyword_value, null}, <<"/required">>),
                   compile(#{<<"required">> => null})),
     ?_assertEqual(schema_error({bad_keyword_value, #{<<"bar">> => <<"foo">>}},
                                <<"/dependentRequired">>),
                   compile(#{<<"dependentRequired">> => #{<<"bar">> => <<"foo">>}}))].

%% Дочерняя schema становится отдельным node, а constraint хранит её полный
%% адрес. Сегменты локации — фактические keywords и десятичные индексы ветвей.
logical_test_() ->
    [?_assertEqual({ok, artifact(#{<<>>          => schema_node([{all_of, [addr(<<"/allOf/0">>)]}]),
                                   <<"/allOf/0">> => schema_node([{type, [integer]}])})},
                   compile(#{<<"allOf">> => [#{<<"type">> => <<"integer">>}]})),
     %% Boolean-подсхема — такой же адресуемый node.
     ?_assertEqual({ok, artifact(#{<<>>           => schema_node([{any_of, [addr(<<"/anyOf/0">>),
                                                                           addr(<<"/anyOf/1">>)]}]),
                                   <<"/anyOf/0">> => true,
                                   <<"/anyOf/1">> => false})},
                   compile(#{<<"anyOf">> => [true, false]})),
     ?_assertEqual({ok, artifact(#{<<>>           => schema_node([{one_of, [addr(<<"/oneOf/0">>)]}]),
                                   <<"/oneOf/0">> => schema_node([])})},
                   compile(#{<<"oneOf">> => [#{}]})),
     %% У `not` ветвь одна, поэтому индекса в её локации нет.
     ?_assertEqual({ok, artifact(#{<<>>        => schema_node([{'not', addr(<<"/not">>)}]),
                                   <<"/not">>  => schema_node([{const, 1}])})},
                   compile(#{<<"not">> => #{<<"const">> => 1}})),
     %% Пустой список ветвей метасхема запрещает, но в IR он ложится.
     ?_assertEqual({ok, artifact(schema_node([{all_of, []}]))},
                   compile(#{<<"allOf">> => []}))].

%% Три object applicators дают один constraint, но каждый со своим слотом:
%% ненаписанный keyword остаётся `undefined`.
object_test_() ->
    [?_assertEqual({ok, artifact(#{<<>> => schema_node([{properties,
                                                         #{<<"a">> => addr(<<"/properties/a">>)},
                                                         undefined, undefined}]),
                                   <<"/properties/a">> => schema_node([{type, [integer]}])})},
                   compile(#{<<"properties">> => #{<<"a">> => #{<<"type">> => <<"integer">>}}})),
     %% Сегмент локации паттерна — его исходный текст.
     ?_assertEqual({ok, artifact(#{<<>> => schema_node([{properties, undefined,
                                                         [{regex(<<"^a">>),
                                                           addr(<<"/patternProperties/^a">>)}],
                                                         undefined}]),
                                   <<"/patternProperties/^a">> => true})},
                   compile(#{<<"patternProperties">> => #{<<"^a">> => true}})),
     %% У additionalProperties своего сегмента нет: ветвь стоит на keyword.
     ?_assertEqual({ok, artifact(#{<<>> => schema_node([{properties, undefined, undefined,
                                                         addr(<<"/additionalProperties">>)}]),
                                   <<"/additionalProperties">> => false})},
                   compile(#{<<"additionalProperties">> => false})),
     %% Написанный пустой properties — пустая map, а не отсутствие keyword.
     ?_assertEqual({ok, artifact(schema_node([{properties, #{}, undefined, undefined}]))},
                   compile(#{<<"properties">> => #{}})),
     ?_assertEqual({ok, artifact(schema_node([{properties, undefined, [], undefined}]))},
                   compile(#{<<"patternProperties">> => #{}})),
     %% Имя свойства экранируется в указателе как обычный сегмент.
     ?_assertEqual({ok, artifact(#{<<>> => schema_node([{properties,
                                                         #{<<"a/b">> => addr(<<"/properties/a~1b">>)},
                                                         undefined, undefined}]),
                                   <<"/properties/a~1b">> => true})},
                   compile(#{<<"properties">> => #{<<"a/b">> => true}}))].

%% Три keyword'а собираются в один constraint, а список паттернов упорядочен по
%% их тексту: от порядка обхода map наблюдаемый IR зависеть не должен.
object_group_test() ->
    Schema = #{<<"additionalProperties">> => false,
               <<"patternProperties">> => #{<<"^b">> => true, <<"^a">> => true},
               <<"properties">> => #{<<"x">> => true}},
    Expected = schema_node([{properties,
                             #{<<"x">> => addr(<<"/properties/x">>)},
                             [{regex(<<"^a">>), addr(<<"/patternProperties/^a">>)},
                              {regex(<<"^b">>), addr(<<"/patternProperties/^b">>)}],
                             addr(<<"/additionalProperties">>)}]),
    ?assertEqual({ok, artifact(#{<<>>                        => Expected,
                                 <<"/properties/x">>         => true,
                                 <<"/patternProperties/^a">> => true,
                                 <<"/patternProperties/^b">> => true,
                                 <<"/additionalProperties">> => false})},
                 compile(Schema)).

object_error_test_() ->
    [?_assertEqual(schema_error({bad_keyword_value, 42}, <<"/properties">>),
                   compile(#{<<"properties">> => 42})),
     ?_assertEqual(schema_error({bad_keyword_value, []}, <<"/patternProperties">>),
                   compile(#{<<"patternProperties">> => []})),
     %% Некомпилируемый паттерн называет свою собственную позицию.
     ?_assertMatch({error, #schema_error{reason   = {bad_pattern, _},
                                         location = {anonymous, <<"/patternProperties/(">>}}},
                   compile(#{<<"patternProperties">> => #{<<"(">> => true}})),
     ?_assertEqual(schema_error({bad_keyword_value, null}, <<"/properties/a/maximum">>),
                   compile(#{<<"properties">> => #{<<"a">> => #{<<"maximum">> => null}}})),
     ?_assertEqual(schema_error({bad_keyword_value, 1}, <<"/additionalProperties">>),
                   compile(#{<<"additionalProperties">> => 1}))].

%% Своего сегмента у ветви нет: она стоит на самом keyword.
property_names_test_() ->
    [?_assertEqual({ok, artifact(#{<<>> => schema_node([{property_names,
                                                         addr(<<"/propertyNames">>)}]),
                                   <<"/propertyNames">> => schema_node([{max_length, 3}])})},
                   compile(#{<<"propertyNames">> => #{<<"maxLength">> => 3}})),
     ?_assertEqual({ok, artifact(#{<<>> => schema_node([{property_names,
                                                         addr(<<"/propertyNames">>)}]),
                                   <<"/propertyNames">> => false})},
                   compile(#{<<"propertyNames">> => false}))].

property_names_error_test_() ->
    [?_assertEqual(schema_error({bad_keyword_value, 42}, <<"/propertyNames">>),
                   compile(#{<<"propertyNames">> => 42})),
     ?_assertEqual(schema_error({bad_keyword_value, null}, <<"/propertyNames/maxLength">>),
                   compile(#{<<"propertyNames">> => #{<<"maxLength">> => null}}))].

%% Раскладка та же, что у `properties`: имя свойства становится сегментом
%% локации и экранируется в указателе как обычный сегмент.
dependent_schemas_test_() ->
    [?_assertEqual({ok, artifact(#{<<>> => schema_node([{dependent_schemas,
                                                         #{<<"a">> => addr(<<"/dependentSchemas/a">>)}}]),
                                   <<"/dependentSchemas/a">> =>
                                       schema_node([{required, [<<"b">>]}])})},
                   compile(#{<<"dependentSchemas">> =>
                                 #{<<"a">> => #{<<"required">> => [<<"b">>]}}})),
     %% Написанный пустой keyword — пустая map, а не отсутствие keyword.
     ?_assertEqual({ok, artifact(schema_node([{dependent_schemas, #{}}]))},
                   compile(#{<<"dependentSchemas">> => #{}})),
     ?_assertEqual({ok, artifact(#{<<>> => schema_node([{dependent_schemas,
                                                         #{<<"a/b">> =>
                                                               addr(<<"/dependentSchemas/a~1b">>)}}]),
                                   <<"/dependentSchemas/a~1b">> => true})},
                   compile(#{<<"dependentSchemas">> => #{<<"a/b">> => true}}))].

dependent_schemas_error_test_() ->
    [?_assertEqual(schema_error({bad_keyword_value, 42}, <<"/dependentSchemas">>),
                   compile(#{<<"dependentSchemas">> => 42})),
     ?_assertEqual(schema_error({bad_keyword_value, null},
                                <<"/dependentSchemas/a/maximum">>),
                   compile(#{<<"dependentSchemas">> =>
                                 #{<<"a">> => #{<<"maximum">> => null}}}))].

%% Одиночный `items` — своя раскладка: ветвь одна и стоит на самом keyword.
%% Вместе с `prefixItems` он становится хвостом составного constraint, а сегмент
%% каждой схемы префикса — её десятичный индекс.
array_test_() ->
    [?_assertEqual({ok, artifact(#{<<>>        => schema_node([{items, addr(<<"/items">>)}]),
                                   <<"/items">> => schema_node([{type, [integer]}])})},
                   compile(#{<<"items">> => #{<<"type">> => <<"integer">>}})),
     ?_assertEqual({ok, artifact(#{<<>>        => schema_node([{items, addr(<<"/items">>)}]),
                                   <<"/items">> => false})},
                   compile(#{<<"items">> => false})),
     ?_assertEqual({ok, artifact(#{<<>> => schema_node([{prefix_items,
                                                         [addr(<<"/prefixItems/0">>),
                                                          addr(<<"/prefixItems/1">>)],
                                                         undefined}]),
                                   <<"/prefixItems/0">> => true,
                                   <<"/prefixItems/1">> => schema_node([{const, 1}])})},
                   compile(#{<<"prefixItems">> => [true, #{<<"const">> => 1}]})),
     %% У хвостового `items` своего сегмента нет, как и у additionalProperties.
     ?_assertEqual({ok, artifact(#{<<>> => schema_node([{prefix_items,
                                                         [addr(<<"/prefixItems/0">>)],
                                                         addr(<<"/items">>)}]),
                                   <<"/prefixItems/0">> => true,
                                   <<"/items">>         => false})},
                   compile(#{<<"prefixItems">> => [true], <<"items">> => false})),
     %% Пустой префикс метасхема запрещает, но в IR он ложится, как `allOf: []`.
     ?_assertEqual({ok, artifact(schema_node([{prefix_items, [], undefined}]))},
                   compile(#{<<"prefixItems">> => []}))].

array_error_test_() ->
    [?_assertEqual(schema_error({bad_keyword_value, 42}, <<"/prefixItems">>),
                   compile(#{<<"prefixItems">> => 42})),
     %% В Draft 2020-12 массив на позиции `items` схемой не является.
     ?_assertEqual(schema_error({bad_keyword_value, [true]}, <<"/items">>),
                   compile(#{<<"items">> => [true]})),
     ?_assertEqual(schema_error({bad_keyword_value, null}, <<"/items/maximum">>),
                   compile(#{<<"items">> => #{<<"maximum">> => null}})),
     ?_assertEqual(schema_error({bad_keyword_value, null},
                                <<"/prefixItems/1/maximum">>),
                   compile(#{<<"prefixItems">> => [true, #{<<"maximum">> => null}]}))].

%% Раскладку выбирает dialect: schema-form `items` одинаков в обоих, а
%% `prefixItems` и array-form `items` принадлежат разным фазам и пока отвергаются
%% наравне с остальными неизвестными keywords.
array_dialect_test_() ->
    [?_assertEqual({ok, legacy_artifact(#{<<>>        => schema_node([{items,
                                                                       addr(<<"/items">>)}]),
                                          <<"/items">> => true})},
                   legacy(#{<<"items">> => true})),
     ?_assertEqual(schema_error({not_implemented, <<"items">>}, <<"/items">>),
                   legacy(#{<<"items">> => [true]})),
     ?_assertEqual(schema_error({not_implemented, <<"prefixItems">>}, <<"/prefixItems">>),
                   legacy(#{<<"prefixItems">> => [true]})),
     ?_assertEqual(schema_error({not_implemented, <<"prefixItems">>}, <<"/prefixItems">>),
                   legacy(#{<<"prefixItems">> => [true], <<"items">> => true}))].

%% Границы попадают в тот же constraint отдельными слотами, а ненаписанная
%% остаётся `undefined`. Последнее поле — покрывает ли `contains` индексы: это
%% решение dialect, и evaluator его уже не пересматривает.
contains_test_() ->
    [?_assertEqual({ok, artifact(#{<<>> => schema_node([{contains, addr(<<"/contains">>),
                                                         undefined, undefined, true}]),
                                   <<"/contains">> => schema_node([{type, [integer]}])})},
                   compile(#{<<"contains">> => #{<<"type">> => <<"integer">>}})),
     ?_assertEqual({ok, artifact(#{<<>> => schema_node([{contains, addr(<<"/contains">>),
                                                         0, 2, true}]),
                                   <<"/contains">> => true})},
                   compile(#{<<"contains">> => true,
                             <<"minContains">> => 0, <<"maxContains">> => 2})),
     %% Десятичная форма — то же целое, как и у остальных nonNegativeInteger.
     ?_assertEqual({ok, artifact(#{<<>> => schema_node([{contains, addr(<<"/contains">>),
                                                         2, undefined, true}]),
                                   <<"/contains">> => true})},
                   compile(#{<<"contains">> => true, <<"minContains">> => 2.0})),
     ?_assertEqual({ok, legacy_artifact(#{<<>> => schema_node([{contains,
                                                                addr(<<"/contains">>),
                                                                undefined, undefined, false}]),
                                          <<"/contains">> => true})},
                   legacy(#{<<"contains">> => true}))].

%% Без `contains` границы спецификация оставляет без эффекта, поэтому constraint
%% не собирается. Значение всё равно разбирается: ошибка в нём обязана
%% останавливать компиляцию.
contains_without_schema_test_() ->
    [?_assertEqual({ok, artifact(schema_node([]))},
                   compile(#{<<"minContains">> => 1, <<"maxContains">> => 3})),
     ?_assertEqual(schema_error({bad_keyword_value, -1}, <<"/minContains">>),
                   compile(#{<<"minContains">> => -1}))].

contains_error_test_() ->
    [?_assertEqual(schema_error({bad_keyword_value, 42}, <<"/contains">>),
                   compile(#{<<"contains">> => 42})),
     ?_assertEqual(schema_error({bad_keyword_value, null}, <<"/contains/maximum">>),
                   compile(#{<<"contains">> => #{<<"maximum">> => null}})),
     ?_assertEqual(schema_error({bad_keyword_value, 1.5}, <<"/minContains">>),
                   compile(#{<<"contains">> => true, <<"minContains">> => 1.5})),
     ?_assertEqual(schema_error({bad_keyword_value, <<"2">>}, <<"/maxContains">>),
                   compile(#{<<"contains">> => true, <<"maxContains">> => <<"2">>}))].

%% Условные keywords тоже дают один constraint, и своего сегмента у ветви нет:
%% каждая стоит на собственном keyword.
conditional_test_() ->
    [?_assertEqual({ok, artifact(#{<<>>       => schema_node([{if_then_else, addr(<<"/if">>),
                                                               addr(<<"/then">>),
                                                               addr(<<"/else">>)}]),
                                   <<"/if">>   => schema_node([{type, [integer]}]),
                                   <<"/then">> => schema_node([{minimum, 0}]),
                                   <<"/else">> => false})},
                   compile(#{<<"if">> => #{<<"type">> => <<"integer">>},
                             <<"then">> => #{<<"minimum">> => 0},
                             <<"else">> => false})),
     %% `if` без ветвей остаётся constraint'ом: аннотации он собирает и один.
     ?_assertEqual({ok, artifact(#{<<>>      => schema_node([{if_then_else, addr(<<"/if">>),
                                                              undefined, undefined}]),
                                   <<"/if">> => true})},
                   compile(#{<<"if">> => true})),
     ?_assertEqual({ok, artifact(#{<<>>        => schema_node([{if_then_else, addr(<<"/if">>),
                                                                undefined, addr(<<"/else">>)}]),
                                   <<"/if">>   => true,
                                   <<"/else">> => true})},
                   compile(#{<<"if">> => true, <<"else">> => true}))].

%% `then` и `else` без `if` спецификация велит игнорировать целиком, поэтому
%% constraint не собирается. Nodes у них всё равно есть: это адресуемые schema
%% positions известных keywords.
conditional_without_if_test() ->
    Schema = #{<<"then">> => #{<<"type">> => <<"null">>}, <<"else">> => true},
    ?assertEqual({ok, artifact(#{<<>>        => schema_node([]),
                                 <<"/then">> => schema_node([{type, [null]}]),
                                 <<"/else">> => true})},
                 compile(Schema)).

%% Раз позиция компилируется, ошибка в ней останавливает компиляцию — и тогда,
%% когда вычислять эту ветвь никто не станет.
conditional_error_test_() ->
    [?_assertEqual(schema_error({bad_keyword_value, 42}, <<"/if">>),
                   compile(#{<<"if">> => 42})),
     ?_assertEqual(schema_error({bad_keyword_value, null}, <<"/then/maximum">>),
                   compile(#{<<"then">> => #{<<"maximum">> => null}}))].

%% Все nodes строятся до вычисления, поэтому вложенность произвольной глубины
%% полностью лежит в одной map, а не разворачивается на ходу.
nested_test() ->
    Schema = #{<<"not">> => #{<<"allOf">> => [#{<<"anyOf">> => [#{<<"type">> => <<"null">>}]},
                                              true]}},
    Expected =
        #{<<>>                       => schema_node([{'not', addr(<<"/not">>)}]),
          <<"/not">>                 => schema_node([{all_of, [addr(<<"/not/allOf/0">>),
                                                               addr(<<"/not/allOf/1">>)]}]),
          <<"/not/allOf/0">>         => schema_node([{any_of, [addr(<<"/not/allOf/0/anyOf/0">>)]}]),
          <<"/not/allOf/0/anyOf/0">> => schema_node([{type, [null]}]),
          <<"/not/allOf/1">>         => true},
    ?assertEqual({ok, artifact(Expected)}, compile(Schema)).

%% Ошибка внутри ветви называет позицию внутри неё, а не корень схемы.
nested_error_test() ->
    ?assertEqual(schema_error({bad_keyword_value, null}, <<"/allOf/1/not/maximum">>),
                 compile(#{<<"allOf">> => [true, #{<<"not">> => #{<<"maximum">> => null}}]})).

%% Порядок constraints задан компилятором и не зависит от порядка ключей.
order_test() ->
    Schema = #{<<"exclusiveMinimum">> => 0, <<"const">> => 1, <<"enum">> => [1],
               <<"maximum">> => 4, <<"type">> => <<"number">>,
               <<"multipleOf">> => 1, <<"pattern">> => <<"a">>,
               <<"required">> => [<<"a">>], <<"uniqueItems">> => true,
               <<"maxLength">> => 5, <<"not">> => true, <<"allOf">> => [true],
               <<"if">> => true, <<"propertyNames">> => true,
               <<"dependentSchemas">> => #{<<"a">> => true},
               <<"items">> => true, <<"prefixItems">> => [true],
               <<"contains">> => true, <<"maxContains">> => 2},
    Expected = schema_node([{type, [number]}, {enum, [1]}, {const, 1},
                            {multiple_of, 1}, {maximum, 4},
                            {exclusive_minimum, 0}, {max_length, 5},
                            {pattern, regex(<<"a">>)}, {unique_items, true},
                            {required, [<<"a">>]},
                            {prefix_items, [addr(<<"/prefixItems/0">>)], addr(<<"/items">>)},
                            {contains, addr(<<"/contains">>), undefined, 2, true},
                            {property_names, addr(<<"/propertyNames">>)},
                            {all_of, [addr(<<"/allOf/0">>)]}, {'not', addr(<<"/not">>)},
                            {if_then_else, addr(<<"/if">>), undefined, undefined},
                            {dependent_schemas,
                             #{<<"a">> => addr(<<"/dependentSchemas/a">>)}}]),
    ?assertEqual({ok, artifact(#{<<>>                      => Expected,
                                 <<"/allOf/0">>            => true,
                                 <<"/not">>                => true,
                                 <<"/if">>                 => true,
                                 <<"/items">>              => true,
                                 <<"/prefixItems/0">>      => true,
                                 <<"/contains">>           => true,
                                 <<"/propertyNames">>      => true,
                                 <<"/dependentSchemas/a">> => true})},
                 compile(Schema)).

%% Потребляются компилятором и собственного constraint не дают.
consumed_keywords_test() ->
    Schema = #{<<"$schema">> => ?DIALECT,
               <<"$comment">> => <<"note">>,
               <<"type">> => <<"boolean">>},
    ?assertEqual({ok, artifact(schema_node([{type, [boolean]}]))}, compile(Schema)).

bad_keyword_value_test_() ->
    [?_assertEqual(schema_error({bad_keyword_value, <<"int">>}, <<"/type">>),
                   compile(#{<<"type">> => <<"int">>})),
     ?_assertEqual(schema_error({bad_keyword_value, [<<"string">>, 1]}, <<"/type">>),
                   compile(#{<<"type">> => [<<"string">>, 1]})),
     ?_assertEqual(schema_error({bad_keyword_value, null}, <<"/type">>),
                   compile(#{<<"type">> => null})),
     ?_assertEqual(schema_error({bad_keyword_value, 1}, <<"/enum">>),
                   compile(#{<<"enum">> => 1}))].

%% Ещё не реализованный keyword обязан останавливать компиляцию, а не молча
%% исчезать: иначе преждевременно подключённый файл сьюта пройдёт по недоразумению.
not_implemented_test_() ->
    [?_assertEqual(schema_error({not_implemented, <<"unevaluatedItems">>},
                                <<"/unevaluatedItems">>),
                   compile(#{<<"unevaluatedItems">> => #{}})),
     ?_assertEqual(schema_error({not_implemented, <<"$ref">>}, <<"/$ref">>),
                   compile(#{<<"$ref">> => <<"#">>, <<"type">> => <<"object">>}))].

%% На позиции schema стоит значение, которое schema не является: отдельной
%% причины у него нет, для slot IR оно просто невозможно.
not_a_schema_test_() ->
    [?_assertEqual(schema_error({bad_keyword_value, 42}, <<>>), compile(42)),
     ?_assertEqual(schema_error({bad_keyword_value, null}, <<>>), compile(null)),
     ?_assertEqual(schema_error({bad_keyword_value, []}, <<>>), compile([])),
     %% Позицию называет её собственная локация, а не имя ближайшего keyword.
     ?_assertEqual(schema_error({bad_keyword_value, 42}, <<"/allOf/1">>),
                   compile(#{<<"allOf">> => [true, 42]})),
     ?_assertEqual(schema_error({bad_keyword_value, <<"x">>}, <<"/not">>),
                   compile(#{<<"not">> => <<"x">>}))].

compile(Schema) ->
    valid_json_compile:compile(Schema, ?DIALECT).

%% Тот же вход с другим dialect: раскладку array applicators выбирает компилятор,
%% и это единственное место, где она видна.
legacy(Schema) ->
    valid_json_compile:compile(Schema, ?LEGACY).

schema_node(Constraints) ->
    #node{constraints = Constraints, unevaluated = []}.

%% Локация называет позицию, значение которой виновато: сам keyword либо schema
%% position. Resource пока всегда один и анонимный.
schema_error(Reason, Pointer) ->
    {error, #schema_error{reason = Reason, location = {anonymous, Pointer}}}.

addr(Pointer) ->
    {anonymous, Pointer}.

%% Опции повторяют validator-core.md: без них терм не совпал бы с компиляторным.
regex(Source) ->
    {ok, Compiled} = re:compile(Source, [unicode, dollar_endonly]),
    {Source, Compiled}.

%% Схема без подсхем даёт единственный node в корне resource, поэтому один node
%% принимается вместо готовой map.
artifact(Node) ->
    artifact(Node, ?DIALECT).

legacy_artifact(Node) ->
    artifact(Node, ?LEGACY).

artifact(Node, Dialect) when not is_map(Node) ->
    artifact(#{<<>> => Node}, Dialect);
artifact(Nodes, Dialect) ->
    #{root      => anonymous,
      sources   => [],
      resources => #{anonymous =>
          #resource{id               = undefined,
                    dialect          = Dialect,
                    anchors          = #{},
                    dynamic_anchors  = #{},
                    recursive_anchor = false,
                    nodes            = Nodes}}}.
