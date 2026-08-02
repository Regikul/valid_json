%% Compiler fixtures: точное равенство полного compiled() и явные compile errors.
-module(valid_json_compile_tests).

-include_lib("eunit/include/eunit.hrl").
-include("valid_json_core.hrl").
-include("valid_json_resources.hrl").

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

%% Раскладку выбирает dialect: schema-form `items` одинаков в обоих, array-form
%% ждёт P6, а неизвестный для 2019-09 `prefixItems` игнорируется и не мешает
%% соседнему `items`.
array_dialect_test_() ->
    [?_assertEqual({ok, legacy_artifact(#{<<>>        => schema_node([{items,
                                                                       addr(<<"/items">>)}]),
                                          <<"/items">> => true})},
                   legacy(#{<<"items">> => true})),
     ?_assertEqual(schema_error({not_implemented, <<"items">>}, <<"/items">>),
                   legacy(#{<<"items">> => [true]})),
     ?_assertEqual({ok, legacy_artifact(schema_node([]))},
                   legacy(#{<<"prefixItems">> => [true]})),
     ?_assertEqual({ok, legacy_artifact(#{<<>> => schema_node([{items,
                                                                 addr(<<"/items">>)}]),
                                          <<"/items">> => true})},
                   legacy(#{<<"prefixItems">> => [false], <<"items">> => true}))].

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

%% Корневой `$id` меняет entry rid, но не создаёт constraint. В compiled()
%% остаётся уже именованный resource, а anonymous resource исчезает.
named_root_resource_test() ->
    Root = <<"https://example.com/root">>,
    Schema = #{<<"$id">> => Root, <<"type">> => <<"integer">>},
    Expected =
        compiled(Root,
                 #{Root => resource(Root,
                                    #{<<>> => schema_node([{type, [integer]}])})}),
    ?assertEqual({ok, Expected}, compile(Schema)).

%% `$defs` собственного constraint не даёт, но каждая entry становится node.
%% Имя definition экранируется как обычный JSON Pointer segment.
definitions_resource_test() ->
    Name = <<"a/b~c">>,
    Schema = #{<<"$defs">> => #{Name => #{<<"type">> => <<"string">>}}},
    Expected =
        artifact(#{<<>> => schema_node([]),
                   <<"/$defs/a~1b~0c">> => schema_node([{type, [string]}])}),
    ?assertEqual({ok, Expected}, compile(Schema)).

%% Anchor index строится до emission, поэтому корневой `$ref` разрешает цель,
%% объявленную позже в `$defs`, и хранит в IR только canonical addr().
anchor_ref_resource_test() ->
    Schema = #{<<"$ref">> => <<"#number">>,
               <<"$defs">> =>
                   #{<<"value">> => #{<<"$anchor">> => <<"number">>,
                                      <<"type">> => <<"integer">>}}},
    Nodes = #{<<>> => schema_node([{ref, {anonymous, <<"/$defs/value">>}}]),
              <<"/$defs/value">> => schema_node([{type, [integer]}])},
    Expected = compiled(
                 anonymous,
                 #{anonymous => resource(
                                  anonymous,
                                  #{<<"number">> => <<"/$defs/value">>},
                                  Nodes)}),
    ?assertEqual({ok, Expected}, compile(Schema)).

pointer_ref_resource_test() ->
    Schema = #{<<"$ref">> => <<"#/$defs/value">>,
               <<"$defs">> => #{<<"value">> => false}},
    Expected = artifact(
                 #{<<>> => schema_node([{ref, {anonymous,
                                                <<"/$defs/value">>}}]),
                   <<"/$defs/value">> => false}),
    ?assertEqual({ok, Expected}, compile(Schema)).

self_ref_finite_ir_test() ->
    Expected = artifact(schema_node([{ref, {anonymous, <<>>}}])),
    ?assertEqual({ok, Expected}, compile(#{<<"$ref">> => <<"#">>})).

parent_pointer_ref_resource_test() ->
    Child = <<"https://example.com/child">>,
    Schema = #{<<"$ref">> => <<"#/$defs/child">>,
               <<"$defs">> =>
                   #{<<"child">> => #{<<"$id">> => Child,
                                        <<"type">> => <<"integer">>}}},
    Expected = compiled(
                 anonymous,
                 #{anonymous => resource(
                                  anonymous,
                                  #{<<>> => schema_node([{ref, {Child, <<>>}}])}),
                   Child => resource(
                              Child,
                              #{<<>> => schema_node([{type, [integer]}])})}),
    ?assertEqual({ok, Expected}, compile(Schema)).

%% Absolute/relative URI может выбрать embedded resource того же compound
%% document; store для такого локального перехода не нужен.
embedded_anchor_ref_resource_test() ->
    Root = <<"https://example.com/schemas/root.json">>,
    Child = <<"https://example.com/schemas/child.json">>,
    Schema = #{<<"$id">> => Root,
               <<"$ref">> => <<"child.json#leaf">>,
               <<"$defs">> =>
                   #{<<"child">> =>
                         #{<<"$id">> => <<"child.json">>,
                           <<"$anchor">> => <<"leaf">>,
                           <<"type">> => <<"string">>}}},
    Expected = compiled(
                 Root,
                 #{Root => resource(
                            Root,
                            #{<<>> => schema_node([{ref, {Child, <<>>}}])}),
                   Child => resource(
                             Child, #{<<"leaf">> => <<>>},
                             #{<<>> => schema_node([{type, [string]}])})}),
    ?assertEqual({ok, Expected}, compile(Schema)).

local_ref_error_test_() ->
    Root = <<"https://example.com/root.json">>,
    Missing = <<"https://example.com/missing.json">>,
    [?_assertEqual(schema_error({bad_keyword_value, 42}, <<"/$ref">>),
                   compile(#{<<"$ref">> => 42})),
     ?_assertEqual(schema_error(unresolved_anchor, <<"/$ref">>),
                   compile(#{<<"$ref">> => <<"#missing">>})),
     ?_assertEqual(schema_error({dangling_ref,
                                 {anonymous, <<"/$defs/missing">>}},
                                <<"/$ref">>),
                   compile(#{<<"$ref">> => <<"#/$defs/missing">>,
                             <<"$defs">> => #{}})),
     ?_assertEqual(schema_error({non_schema_target,
                                 {anonymous, <<"/const/value">>}},
                                <<"/$ref">>),
                   compile(#{<<"$ref">> => <<"#/const/value">>,
                             <<"const">> => #{<<"value">> => true}})),
     ?_assertEqual(
         {error, #schema_error{reason = {unknown_document, Missing},
                               location = {Root, <<"/$ref">>}}},
         compile(#{<<"$id">> => Root, <<"$ref">> => <<"missing.json">>})),
     ?_assertEqual(schema_error(invalid_percent_encoding, <<"/$ref">>),
                   compile(#{<<"$ref">> => <<"#%zz">>}))].

%% Store lookup использует retrieval URI, но IR, resources и sources сразу
%% переходят на canonical URI корневого `$id` remote document.
remote_anchor_via_retrieval_test() ->
    Retrieval = <<"https://example.com/download/string.json">>,
    Canonical = <<"https://example.com/schemas/string">>,
    Remote = #{<<"$id">> => Canonical,
               <<"$anchor">> => <<"leaf">>,
               <<"type">> => <<"string">>},
    {ok, Canonical, Store} =
        valid_json_store:add(valid_json_store:new([]), Retrieval, Remote),
    Schema = #{<<"$ref">> => <<Retrieval/binary, "#leaf">>},
    Expected =
        #{root => anonymous,
          sources => [Canonical],
          resources =>
              #{anonymous => resource(
                              anonymous,
                              #{<<>> => schema_node([{ref, {Canonical, <<>>}}])}),
                Canonical => resource(
                               Canonical, #{<<"leaf">> => <<>>},
                               #{<<>> => schema_node([{type, [string]}])})}},
    ?assertEqual({ok, Expected}, valid_json_compile:compile(Store, Schema, [])).

%% Все documents загружаются до emission, поэтому цикл A <-> B даёт конечный
%% IR и не зависит от порядка batch-регистрации.
remote_cycle_finite_ir_test() ->
    A = <<"https://example.com/a">>,
    B = <<"https://example.com/b">>,
    {ok, [A, B], Store} =
        valid_json_store:add(valid_json_store:new([]),
                             [{A, #{<<"$id">> => A, <<"$ref">> => B}},
                              {B, #{<<"$id">> => B, <<"$ref">> => A}}]),
    Expected =
        #{root => A,
          sources => [A, B],
          resources =>
              #{A => resource(A, #{<<>> => schema_node([{ref, {B, <<>>}}])}),
                B => resource(B, #{<<>> => schema_node([{ref, {A, <<>>}}])})}},
    ?assertEqual({ok, Expected}, valid_json_compile:compile_uri(Store, A, [])).

%% Замыкание строится транзитивно, а sources содержит документы, не resources:
%% embedded `$id` отдельным source не становится.
remote_transitive_sources_test() ->
    A = <<"https://example.com/a">>,
    B = <<"https://example.com/b">>,
    C = <<"https://example.com/c">>,
    Embedded = <<"https://example.com/embedded">>,
    {ok, [A, B, C], Store} =
        valid_json_store:add(
          valid_json_store:new([]),
          [{A, #{<<"$ref">> => B}},
           {B, #{<<"$ref">> => C,
                 <<"$defs">> => #{<<"local">> => #{<<"$id">> => Embedded}}}},
           {C, #{<<"type">> => <<"integer">>}}]),
    {ok, Compiled} = valid_json_compile:compile_uri(Store, A, []),
    ?assertEqual(A, maps:get(root, Compiled)),
    ?assertEqual([A, B, C], maps:get(sources, Compiled)),
    ?assertEqual([A, B, C, Embedded],
                 lists:sort(maps:keys(maps:get(resources, Compiled)))).

%% Remote pointer разрешается по retrieval alias, но evaluator получает уже
%% замкнутый canonical artifact и store больше не читает.
remote_pointer_evaluation_test() ->
    Retrieval = <<"https://example.com/download/types.json">>,
    Canonical = <<"https://example.com/types">>,
    Remote = #{<<"$id">> => Canonical,
               <<"$defs">> =>
                   #{<<"integer">> => #{<<"type">> => <<"integer">>}}},
    {ok, Canonical, Store} =
        valid_json_store:add(valid_json_store:new([]), Retrieval, Remote),
    Schema = #{<<"$ref">> => <<Retrieval/binary, "#/$defs/integer">>},
    {ok, Compiled} = valid_json_compile:compile(Store, Schema, []),
    ?assertMatch({ok, #eval_result{valid = true}},
                 valid_json_eval:run(Compiled, 1, flag)),
    ?assertMatch({ok, #eval_result{valid = false}},
                 valid_json_eval:run(Compiled, <<"1">>, flag)).

%% Physical pointer space удалённого document сохраняется при объединении
%% индексов: pointer через parent URI канонизируется внутрь embedded resource.
remote_parent_pointer_alias_test() ->
    Retrieval = <<"https://example.com/download/compound.json">>,
    Root = <<"https://example.com/compound">>,
    Child = <<"https://example.com/child">>,
    Remote = #{<<"$id">> => Root,
               <<"$defs">> =>
                   #{<<"child">> =>
                         #{<<"$id">> => Child,
                           <<"properties">> => #{<<"x">> => false}}}},
    {ok, Root, Store} =
        valid_json_store:add(valid_json_store:new([]), Retrieval, Remote),
    Ref = <<Retrieval/binary, "#/$defs/child/properties/x">>,
    {ok, Compiled} =
        valid_json_compile:compile(Store, #{<<"$ref">> => Ref}, []),
    #resource{nodes = #{<<>> := #node{constraints = [{ref, Target}]}}} =
        maps:get(anonymous, maps:get(resources, Compiled)),
    ?assertEqual({Child, <<"/properties/x">>}, Target).

compile_uri_alias_and_base_test() ->
    Retrieval = <<"https://example.com/download/root.json">>,
    Canonical = <<"https://example.com/schema/root.json">>,
    Target = <<"https://example.com/schema/target.json">>,
    Store0 = valid_json_store:new([{base_uri, <<"https://example.com/download/">>}]),
    {ok, [_Canonical, _Target], Store} =
        valid_json_store:add(
          Store0,
          [{<<"root.json">>, #{<<"$id">> => Canonical,
                                <<"$ref">> => <<"target.json">>}},
           {Target, #{<<"type">> => <<"boolean">>}}]),
    {ok, Compiled} = valid_json_compile:compile_uri(Store, <<"root.json">>, []),
    ?assertEqual(Canonical, maps:get(root, Compiled)),
    ?assertEqual([Canonical, Target], maps:get(sources, Compiled)),
    #resource{nodes = #{<<>> := #node{constraints = [{ref, {Target, <<>>}}]}}} =
        maps:get(Canonical, maps:get(resources, Compiled)),
    %% Retrieval alias действительно был входом, хотя root artifact canonical.
    ?assertEqual(Retrieval,
                 (valid_json_store:fetch(Retrieval, Store))#document.retrieval).

production_dialect_test() ->
    Legacy = #{<<"$schema">> => ?LEGACY, <<"type">> => <<"integer">>},
    {ok, Compiled} =
        valid_json_compile:compile(valid_json_store:new([]), Legacy, []),
    #resource{dialect = ?LEGACY} =
        maps:get(anonymous, maps:get(resources, Compiled)),
    {ok, Defaulted} =
        valid_json_compile:compile(valid_json_store:new([]), #{},
                                   [{default_dialect, ?LEGACY}]),
    #resource{dialect = ?LEGACY} =
        maps:get(anonymous, maps:get(resources, Defaulted)).

production_reference_error_test_() ->
    Missing = <<"https://example.com/missing">>,
    Remote = <<"https://example.com/remote">>,
    Store = valid_json_store:new([]),
    TakenStore = begin
                     {ok, Missing, AddedTaken} =
                         valid_json_store:add(Store, Missing, true),
                     AddedTaken
                 end,
    RemoteStore = begin
                      {ok, Remote, AddedRemote} =
                          valid_json_store:add(Store, Remote,
                                               #{<<"$defs">> => #{}}),
                      AddedRemote
                  end,
    [?_assertEqual(
        {error, #schema_error{reason = {unknown_document, Missing},
                              location = {anonymous, <<"/$ref">>}}},
        valid_json_compile:compile(Store, #{<<"$ref">> => Missing}, [])),
     ?_assertEqual(
        {error, #schema_error{reason = {dangling_ref,
                                        {Remote, <<"/$defs/missing">>}},
                              location = {anonymous, <<"/$ref">>}}},
        valid_json_compile:compile(
          RemoteStore,
          #{<<"$ref">> => <<Remote/binary, "#/$defs/missing">>}, [])),
     ?_assertEqual(
        {error, #schema_error{reason = {unknown_document, Missing},
                              location = undefined}},
        valid_json_compile:compile_uri(Store, Missing, [])),
     ?_assertEqual(
        {error, #schema_error{reason = {name_taken, Missing},
                              location = {anonymous, <<"/$id">>}}},
        valid_json_compile:compile(TakenStore, #{<<"$id">> => Missing}, [])),
     ?_assertEqual(
        {error, #schema_error{reason = {name_taken, Missing},
                              location = {anonymous, <<"/$defs/x/$id">>}}},
        valid_json_compile:compile(
          TakenStore,
          #{<<"$defs">> => #{<<"x">> => #{<<"$id">> => Missing}}}, [])),
     ?_assertEqual(
        {error, #schema_error{reason = {unknown_dialect,
                                        <<"https://example.com/dialect">>},
                              location = {anonymous, <<"/$schema">>}}},
        valid_json_compile:compile(
          Store, #{<<"$schema">> => <<"https://example.com/dialect">>}, [])),
     ?_assertEqual(
        {error, #schema_error{reason = {unknown_dialect,
                                        <<"https://example.com/dialect">>},
                              location = {Remote, <<"/$schema">>}}},
        valid_json_compile:compile(
          Store, #{<<"$id">> => Remote,
                   <<"$schema">> => <<"https://example.com/dialect">>}, []))].

%% Подсхема с `$id` начинает новый resource: адрес в parent constraint сразу
%% канонический, а указатели внутри child считаются от его собственного корня.
embedded_resource_test() ->
    Foo = <<"https://example.com/foo">>,
    Bar = <<"https://example.com/bar">>,
    Schema = #{<<"$id">> => Foo,
               <<"items">> =>
                   #{<<"$id">> => Bar,
                     <<"additionalProperties">> => #{}}},
    Expected =
        compiled(
          Foo,
          #{Foo => resource(Foo,
                            #{<<>> => schema_node([{items, {Bar, <<>>}}])}),
            Bar => resource(
                     Bar,
                     #{<<>> => schema_node([{properties, undefined, undefined,
                                             {Bar, <<"/additionalProperties">>}}]),
                       <<"/additionalProperties">> => schema_node([])})}),
    ?assertEqual({ok, Expected}, compile(Schema)).

%% Anonymous parent тоже имеет physical pointer space на время компиляции, хотя
%% в итоговом artifact абсолютного id у него нет.
anonymous_parent_resource_test() ->
    Child = <<"https://example.com/child">>,
    Schema = #{<<"$defs">> =>
                   #{<<"child">> =>
                         #{<<"$id">> => Child, <<"contains">> => true}}},
    Expected =
        compiled(
          anonymous,
          #{anonymous => resource(anonymous, #{<<>> => schema_node([])}),
            Child => resource(
                       Child,
                       #{<<>> => schema_node([{contains,
                                               {Child, <<"/contains">>},
                                               undefined, undefined, true}]),
                         <<"/contains">> => true})}),
    ?assertEqual({ok, Expected}, compile(Schema)).

%% Relative `$id` разрешается от ближайшего resource, а не от anonymous root.
relative_embedded_resource_test() ->
    Root = <<"https://example.com/schemas/root.json">>,
    Child = <<"https://example.com/schemas/child.json">>,
    Schema = #{<<"$id">> => Root,
               <<"$defs">> =>
                   #{<<"child">> =>
                         #{<<"$id">> => <<"child.json">>,
                           <<"properties">> => #{<<"x">> => true}}}},
    Expected =
        compiled(
          Root,
          #{Root => resource(Root, #{<<>> => schema_node([])}),
            Child => resource(
                       Child,
                       #{<<>> => schema_node([{properties,
                                               #{<<"x">> => {Child,
                                                              <<"/properties/x">>}},
                                               undefined, undefined}]),
                         <<"/properties/x">> => true})}),
    ?assertEqual({ok, Expected}, compile(Schema)).

%% После resource boundary ошибка тоже получает каноническую location.
embedded_resource_error_test() ->
    Root = <<"https://example.com/root">>,
    Child = <<"https://example.com/child">>,
    Schema = #{<<"$id">> => Root,
               <<"not">> => #{<<"$id">> => Child, <<"maximum">> => null}},
    ?assertEqual({error, #schema_error{reason = {bad_keyword_value, null},
                                      location = {Child, <<"/maximum">>}}},
                 compile(Schema)).

definitions_error_test() ->
    ?assertEqual(schema_error({bad_keyword_value, 42}, <<"/$defs">>),
                 compile(#{<<"$defs">> => 42})).

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

%% Annotation-only keyword доносит своё значение до IR как есть. Типы этих
%% keywords ограничивает метасхема, которую валидатор не применяет, поэтому
%% запрещённое ею значение всё равно компилируется.
annotation_test_() ->
    [?_assertEqual({ok, artifact(schema_node([{annotation, <<"title">>, <<"t">>}]))},
                   compile(#{<<"title">> => <<"t">>})),
     ?_assertEqual({ok, artifact(schema_node([{annotation, <<"readOnly">>, true}]))},
                   compile(#{<<"readOnly">> => true})),
     ?_assertEqual({ok, artifact(schema_node([{annotation, <<"examples">>, [1, null]}]))},
                   compile(#{<<"examples">> => [1, null]})),
     ?_assertEqual({ok, artifact(schema_node([{annotation, <<"default">>, []}]))},
                   compile(#{<<"default">> => []})),
     ?_assertEqual({ok, artifact(schema_node([{annotation, <<"title">>, 1}]))},
                   compile(#{<<"title">> => 1})),
     %% Внутрь значения компилятор не спускается: schema positions там нет, и
     %% похожий на схему объект остаётся обычными данными.
     ?_assertEqual({ok, artifact(schema_node([{annotation, <<"default">>,
                                               #{<<"unevaluatedItems">> => #{}}}]))},
                   compile(#{<<"default">> => #{<<"unevaluatedItems">> => #{}}}))].

%% Аннотации стоят в конце порядка обхода: сначала идёт то, что определяет
%% вердикт, потом то, что только описывает значение.
annotation_order_test() ->
    Schema = #{<<"deprecated">> => true,
               <<"title">>      => <<"t">>,
               <<"type">>       => <<"integer">>},
    Constraints = [{type, [integer]},
                   {annotation, <<"title">>, <<"t">>},
                   {annotation, <<"deprecated">>, true}],
    ?assertEqual({ok, artifact(schema_node(Constraints))}, compile(Schema)).

%% Настоящее расширение становится annotation только в 2020-12. Его значение
%% остаётся непрозрачными данными: вложенные объекты не становятся nodes.
unknown_keyword_test_() ->
    Value = #{<<"sub">> => #{<<"type">> => <<"string">>}},
    Schema = #{<<"zCustom">> => 2,
               <<"aCustom">> => Value,
               <<"type">> => <<"integer">>},
    [?_assertEqual(
        {ok, artifact(schema_node([{type, [integer]},
                                   {annotation, <<"aCustom">>, Value},
                                   {annotation, <<"zCustom">>, 2}]))},
        compile(Schema)),
     ?_assertEqual({ok, legacy_artifact(schema_node([{type, [integer]}]))},
                   legacy(Schema))].

%% `$id` под unknown keyword не резервирует resource. У настоящей schema с тем
%% же URI нет конфликта, и в артефакт попадают только корень и `$defs/real`.
unknown_keyword_is_not_schema_position_test() ->
    Child = <<"https://example.com/real">>,
    Schema = #{<<"custom">> => #{<<"$id">> => Child,
                                   <<"$anchor">> => <<"hidden">>,
                                   <<"type">> => <<"null">>},
               <<"$defs">> => #{<<"real">> => #{<<"$id">> => Child,
                                                    <<"type">> => <<"string">>}}},
    {ok, Compiled} = compile(Schema),
    #{resources := Resources} = Compiled,
    ?assertEqual([anonymous, Child], lists:sort(maps:keys(Resources))),
    #resource{nodes = AnonymousNodes} = maps:get(anonymous, Resources),
    ?assertEqual([<<>>], maps:keys(AnonymousNodes)),
    #resource{anchors = ChildAnchors, nodes = ChildNodes} =
        maps:get(Child, Resources),
    ?assertEqual(#{}, ChildAnchors),
    ?assertEqual([<<>>], maps:keys(ChildNodes)).

%% Ещё не реализованный keyword обязан останавливать компиляцию, а не молча
%% исчезать: иначе преждевременно подключённый файл сьюта пройдёт по недоразумению.
not_implemented_test_() ->
    [?_assertEqual(schema_error({not_implemented, <<"unevaluatedItems">>},
                                <<"/unevaluatedItems">>),
                   compile(#{<<"unevaluatedItems">> => #{}})),
     ?_assertEqual(schema_error({not_implemented, <<"$dynamicRef">>},
                                <<"/$dynamicRef">>),
                   compile(#{<<"$dynamicRef">> => <<"#node">>})),
     ?_assertEqual(schema_error({not_implemented, <<"$recursiveRef">>},
                                <<"/$recursiveRef">>),
                   legacy(#{<<"$recursiveRef">> => <<"#">>})),
     %% Keyword другого dialect — действительно unknown.
     ?_assertEqual({ok, artifact(schema_node(
                                   [{annotation, <<"additionalItems">>, false}]))},
                   compile(#{<<"additionalItems">> => false}))].

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

compiled(Root, Resources) ->
    #{root => Root, sources => [], resources => Resources}.

resource(Rid, Nodes) ->
    resource(Rid, #{}, Nodes).

resource(Rid, Anchors, Nodes) ->
    Id = case Rid of anonymous -> undefined; _ -> Rid end,
    #resource{id               = Id,
              dialect          = ?DIALECT,
              anchors          = Anchors,
              dynamic_anchors  = #{},
              recursive_anchor = false,
              nodes            = Nodes}.
