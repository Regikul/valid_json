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
     %% Страховочный IR slot допускает пустой список; публичный compile-отказ
     %% метасхемы проверяется в valid_json_metaschema_tests.
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

%% Скомпилированный re:mp() попадает прямо в IR, но сравнивается не он, а
%% лежащий рядом исходный текст: с OTP 28 равных термов из одного текста больше
%% не получить, и сам re:mp() стирает `scrub/1`. Опции компиляции проверяются
%% отдельно, по поведению, в pattern_options_test_/0.
pattern_test_() ->
    [?_assertEqual({ok, artifact(schema_node([{pattern, regex(<<"^a+$">>)}]))},
                   compile(#{<<"pattern">> => <<"^a+$">>})),
     ?_assertEqual({ok, artifact(schema_node([{pattern, regex(<<"[0-9]">>)}]))},
                   compile(#{<<"pattern">> => <<"[0-9]">>}))].

%% Пока re:mp() входил в сравниваемый терм, точное равенство заодно закрепляло
%% и опции его компиляции. Стёртый scrub'ом терм их больше не показывает,
%% поэтому опции проверяются по наблюдаемому поведению паттерна из IR:
%% `dollar_endonly` не пускает `$` перед завершающим переводом строки, а
%% `unicode` читает и паттерн, и субъект как UTF-8, а не как байты.
pattern_options_test_() ->
    [?_assertNot(compiled_matches(<<"^a$">>, <<"a\n">>)),
     ?_assert(compiled_matches(<<"^a$">>, <<"a">>)),
     ?_assert(compiled_matches(<<"^.$">>, <<"ф"/utf8>>))].

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
     %% То же разделение: emitter тотален, а публичная проверка метасхемой
     %% отвергает пустой schemaArray отдельным тестом.
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
%% принадлежит только 2019-09, а неизвестный там `prefixItems` игнорируется и не
%% мешает соседнему `items`.
array_dialect_test_() ->
    [?_assertEqual({ok, legacy_artifact(#{<<>>        => schema_node([{items,
                                                                       addr(<<"/items">>)}]),
                                          <<"/items">> => true})},
                   legacy(#{<<"items">> => true})),
     ?_assertEqual({ok, legacy_artifact(schema_node([]))},
                   legacy(#{<<"prefixItems">> => [true]})),
     ?_assertEqual({ok, legacy_artifact(#{<<>> => schema_node([{items,
                                                                 addr(<<"/items">>)}]),
                                          <<"/items">> => true})},
                   legacy(#{<<"prefixItems">> => [false], <<"items">> => true}))].

%% Array-form `items` раздаёт по схеме на индекс, `additionalItems` стоит на
%% самом keyword и достаётся остатку — раскладка та же, что у `prefixItems` с
%% хвостовым `items`, только имена другие.
array_legacy_test_() ->
    [?_assertEqual({ok, legacy_artifact(#{<<>> => schema_node([{items_array,
                                                                [addr(<<"/items/0">>),
                                                                 addr(<<"/items/1">>)],
                                                                undefined}]),
                                          <<"/items/0">> => true,
                                          <<"/items/1">> => schema_node([{const, 1}])})},
                   legacy(#{<<"items">> => [true, #{<<"const">> => 1}]})),
     ?_assertEqual({ok, legacy_artifact(#{<<>> => schema_node([{items_array,
                                                                [addr(<<"/items/0">>)],
                                                                addr(<<"/additionalItems">>)}]),
                                          <<"/items/0">>         => true,
                                          <<"/additionalItems">> => false})},
                   legacy(#{<<"items">> => [true], <<"additionalItems">> => false})),
     %% Пустой префикс метасхема запрещает, но в IR он ложится, как `allOf: []`.
     ?_assertEqual({ok, legacy_artifact(schema_node([{items_array, [], undefined}]))},
                   legacy(#{<<"items">> => []}))].

%% `additionalItems` без array-form `items` спецификация велит игнорировать:
%% constraint не собирается ни рядом со schema-form `items`, ни в одиночку. Сама
%% подсхема остаётся node — discovery признал эту schema position.
array_legacy_ignored_test_() ->
    [?_assertEqual({ok, legacy_artifact(#{<<>> => schema_node([{items,
                                                                addr(<<"/items">>)}]),
                                          <<"/items">>           => true,
                                          <<"/additionalItems">> => false})},
                   legacy(#{<<"items">> => true, <<"additionalItems">> => false})),
     ?_assertEqual({ok, legacy_artifact(#{<<>>                   => schema_node([]),
                                          <<"/additionalItems">> => false})},
                   legacy(#{<<"additionalItems">> => false}))].

array_legacy_error_test_() ->
    [?_assertEqual(schema_error({bad_keyword_value, null}, <<"/items/1/maximum">>),
                   legacy(#{<<"items">> => [true, #{<<"maximum">> => null}]})),
     ?_assertEqual(schema_error({bad_keyword_value, 42}, <<"/additionalItems">>),
                   legacy(#{<<"items">> => [true], <<"additionalItems">> => 42})),
     %% Игнорируемый `additionalItems` всё равно обязан быть schema: его node
     %% выпускается общим проходом.
     ?_assertEqual(schema_error({bad_keyword_value, 42}, <<"/additionalItems">>),
                   legacy(#{<<"additionalItems">> => 42}))].

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

%% `unevaluated*` лежат в собственном поле node: они читают общее покрытие
%% соседей и потому обязаны выполняться после всех обычных constraints. Свои
%% подсхемы они называют так же, как `additionalProperties`, — без сегмента
%% сверх имени keyword.
unevaluated_test() ->
    Schema = #{<<"unevaluatedProperties">> => #{<<"type">> => <<"integer">>},
               <<"unevaluatedItems">>      => false,
               <<"properties">>            => #{<<"a">> => true}},
    Root = #node{constraints =
                     [{properties, #{<<"a">> => addr(<<"/properties/a">>)},
                       undefined, undefined}],
                 unevaluated =
                     [{unevaluated_items, addr(<<"/unevaluatedItems">>)},
                      {unevaluated_properties, addr(<<"/unevaluatedProperties">>)}]},
    ?assertEqual({ok, artifact(#{<<>>                          => Root,
                                 <<"/properties/a">>           => true,
                                 <<"/unevaluatedItems">>       => false,
                                 <<"/unevaluatedProperties">>  =>
                                     schema_node([{type, [integer]}])})},
                 compile(Schema)),
    %% Keyword известен обоим dialects: в 2019-09 он не должен становиться
    %% неизвестным расширением.
    ?assertEqual({ok, legacy_artifact(#{<<>> =>
                                            #node{constraints = [],
                                                  unevaluated =
                                                      [{unevaluated_items,
                                                        addr(<<"/unevaluatedItems">>)}]},
                                        <<"/unevaluatedItems">> => true})},
                 legacy(#{<<"unevaluatedItems">> => true})).

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

%% `$defs` даёт silent output marker для verbose, а каждая entry становится
%% node. Имя definition экранируется как обычный JSON Pointer segment.
definitions_resource_test() ->
    Name = <<"a/b~c">>,
    Schema = #{<<"$defs">> => #{Name => #{<<"type">> => <<"string">>}}},
    Expected =
        artifact(#{<<>> => schema_node([{marker, <<"$defs">>}]),
                   <<"/$defs/a~1b~0c">> => schema_node([{type, [string]}])}),
    ?assertEqual({ok, Expected}, compile(Schema)).

%% `definitions` сохраняет собственную pointer location, но во всём остальном
%% ведёт как `$defs`: контейнер выпускает marker, entries становятся nodes.
compat_definitions_resource_test_() ->
    Schema = #{<<"definitions">> =>
                   #{<<"value">> => #{<<"type">> => <<"integer">>}}},
    Nodes = #{<<>> => schema_node([{marker, <<"definitions">>}]),
              <<"/definitions/value">> => schema_node([{type, [integer]}])},
    [?_assertEqual({ok, artifact(Nodes)}, compile(Schema)),
     ?_assertEqual({ok, legacy_artifact(Nodes)}, legacy(Schema))].

%% Anchor index строится до emission, поэтому корневой `$ref` разрешает цель,
%% объявленную позже в `$defs`, и хранит в IR только canonical addr().
anchor_ref_resource_test() ->
    Schema = #{<<"$ref">> => <<"#number">>,
               <<"$defs">> =>
                   #{<<"value">> => #{<<"$anchor">> => <<"number">>,
                                      <<"type">> => <<"integer">>}}},
    Nodes = #{<<>> => schema_node([{marker, <<"$defs">>},
                                   {ref, {anonymous, <<"/$defs/value">>}}]),
              <<"/$defs/value">> => schema_node([{type, [integer]}])},
    Expected = compiled(
                 anonymous,
                 #{anonymous => resource(
                                  anonymous,
                                  #{<<"number">> => <<"/$defs/value">>},
                                  Nodes)}),
    ?assertEqual({ok, Expected}, compile(Schema)).

%% `$dynamicAnchor` доходит до артефакта отдельной картой и одновременно
%% работает как обычный plain-name fragment: `$ref` на него разрешается наравне
%% с `$anchor`. Собственного constraint keyword не даёт.
dynamic_anchor_resource_test() ->
    Schema = #{<<"$ref">> => <<"#node">>,
               <<"$defs">> =>
                   #{<<"value">> => #{<<"$dynamicAnchor">> => <<"node">>,
                                      <<"type">> => <<"integer">>}}},
    Nodes = #{<<>> => schema_node([{marker, <<"$defs">>},
                                   {ref, {anonymous, <<"/$defs/value">>}}]),
              <<"/$defs/value">> => schema_node([{type, [integer]}])},
    Expected = compiled(
                 anonymous,
                 #{anonymous => resource(
                                  anonymous,
                                  #{<<"node">> => <<"/$defs/value">>},
                                  #{<<"node">> => <<"/$defs/value">>},
                                  Nodes)}),
    ?assertEqual({ok, Expected}, compile(Schema)).

%% Динамическая форма: fragment — plain name, и лексическая цель несёт
%% одноимённый `$dynamicAnchor`. В IR попадают оба: имя для поиска по dynamic
%% scope и лексическая цель как запасной вариант.
dynamic_ref_resource_test() ->
    Schema = #{<<"$dynamicRef">> => <<"#node">>,
               <<"$defs">> =>
                   #{<<"value">> => #{<<"$dynamicAnchor">> => <<"node">>,
                                      <<"type">> => <<"integer">>}}},
    Nodes = #{<<>> => schema_node([{marker, <<"$defs">>},
                                   {dynamic_ref, <<"node">>,
                                    {anonymous, <<"/$defs/value">>}}]),
              <<"/$defs/value">> => schema_node([{type, [integer]}])},
    Expected = compiled(
                 anonymous,
                 #{anonymous => resource(
                                  anonymous,
                                  #{<<"node">> => <<"/$defs/value">>},
                                  #{<<"node">> => <<"/$defs/value">>},
                                  Nodes)}),
    ?assertEqual({ok, Expected}, compile(Schema)).

%% Лексическая цель может лежать в другом resource, и `$dynamicAnchor` там же:
%% имя ищется в resource цели, а не в том, где написан keyword.
dynamic_ref_other_resource_test() ->
    Root = <<"https://example.com/root">>,
    Child = <<"https://example.com/child">>,
    Schema = #{<<"$id">> => Root,
               <<"$dynamicRef">> => <<"child#node">>,
               <<"$defs">> =>
                   #{<<"child">> => #{<<"$id">> => Child,
                                      <<"$dynamicAnchor">> => <<"node">>}}},
    {ok, #{resources := Resources}} = compile(Schema),
    #resource{nodes = #{<<>> := #node{constraints = Constraints}}} =
        maps:get(Root, Resources),
    ?assertEqual([{marker, <<"$defs">>},
                  {dynamic_ref, <<"node">>, {Child, <<>>}}], Constraints).

%% Не выполнено хотя бы одно условие динамичности — и keyword компилируется в
%% обычный `{ref, _}`. Дальше evaluator о его происхождении ничего не знает.
dynamic_ref_static_forms_test_() ->
    Target = {anonymous, <<"/$defs/value">>},
    %% Fragment — JSON Pointer, имени у ссылки нет вовсе.
    Pointer = #{<<"$dynamicRef">> => <<"#/$defs/value">>,
                <<"$defs">> =>
                    #{<<"value">> => #{<<"$dynamicAnchor">> => <<"node">>}}},
    %% Имя есть, но цель объявила его обычным `$anchor`.
    Static = #{<<"$dynamicRef">> => <<"#node">>,
               <<"$defs">> => #{<<"value">> => #{<<"$anchor">> => <<"node">>}}},
    [?_assertEqual([{marker, <<"$defs">>}, {ref, Target}],
                   root_constraints(Pointer)),
     ?_assertEqual([{marker, <<"$defs">>}, {ref, Target}],
                   root_constraints(Static))].

%% Разрешается ссылка так же, как `$ref`, и промахи называются теми же ошибками.
%% В Draft 2019-09 keyword неизвестен, а неизвестные этот dialect игнорирует.
dynamic_ref_value_test_() ->
    [?_assertEqual(schema_error({bad_keyword_value, 42}, <<"/$dynamicRef">>),
                   compile(#{<<"$dynamicRef">> => 42})),
     ?_assertEqual(schema_error(unresolved_anchor, <<"/$dynamicRef">>),
                   compile(#{<<"$dynamicRef">> => <<"#missing">>})),
     ?_assertEqual({ok, legacy_artifact(schema_node([]))},
                   legacy(#{<<"$dynamicRef">> => <<"#missing">>}))].

%% Recursive IR не зависит от наличия anchor у лексической цели: этот флаг
%% решает, будет ли evaluator переигрывать цель в runtime scope.
recursive_ref_resource_test_() ->
    Recursive = #{<<"$recursiveAnchor">> => true,
                  <<"$recursiveRef">> => <<"#">>},
    Plain = #{<<"$recursiveRef">> => <<"#">>},
    Node = schema_node([{recursive_ref, {anonymous, <<>>}}]),
    [?_assertEqual({ok, legacy_artifact(Node, true)}, legacy(Recursive)),
     ?_assertEqual({ok, legacy_artifact(Node, false)}, legacy(Plain))].

recursive_anchor_resources_test() ->
    Root = <<"https://example.com/root">>,
    Child = <<"https://example.com/child">>,
    Schema = #{<<"$id">> => Root,
               <<"$recursiveAnchor">> => false,
               <<"definitions">> =>
                   #{<<"nested">> => #{<<"$recursiveAnchor">> => true},
                     <<"resource">> => #{<<"$id">> => Child,
                                          <<"$recursiveAnchor">> => true}}},
    Expected = compiled(
                 Root,
                 #{Root => legacy_resource(
                             Root, false,
                             #{<<>> => schema_node([{marker, <<"definitions">>}]),
                               <<"/definitions/nested">> => schema_node([])}),
                   Child => legacy_resource(Child, true,
                                            #{<<>> => schema_node([])})}),
    ?assertEqual({ok, Expected}, legacy(Schema)).

recursive_ref_dialect_and_value_test_() ->
    Current = #{<<"$recursiveAnchor">> => true,
                <<"$recursiveRef">> => <<"#">>},
    [?_assertEqual(
         {ok, artifact(schema_node(
                         [{annotation, <<"$recursiveAnchor">>, true},
                          {annotation, <<"$recursiveRef">>, <<"#">>}]))},
         compile(Current)),
     ?_assertEqual(schema_error({bad_keyword_value, <<"other#">>},
                                <<"/$recursiveRef">>),
                   legacy(#{<<"$recursiveRef">> => <<"other#">>})),
     ?_assertEqual(schema_error({bad_keyword_value, 42},
                                <<"/$recursiveRef">>),
                   legacy(#{<<"$recursiveRef">> => 42})),
     ?_assertEqual(schema_error({bad_keyword_value, <<"yes">>},
                                <<"/$recursiveAnchor">>),
                   legacy(#{<<"$recursiveAnchor">> => <<"yes">>}))].

%% Старый `dependencies` не является keyword двух заявленных vocabularies.
%% Разница unknown-policy уже впечатана в IR: 2019-09 игнорирует, 2020-12
%% сохраняет значение как annotation.
dependencies_compatibility_profile_test_() ->
    Value = #{<<"a">> => [<<"b">>]},
    Schema = #{<<"dependencies">> => Value},
    [?_assertEqual({ok, legacy_artifact(schema_node([]))}, legacy(Schema)),
     ?_assertEqual({ok, artifact(schema_node(
                                   [{annotation, <<"dependencies">>, Value}]))},
                   compile(Schema))].

pointer_ref_resource_test() ->
    Schema = #{<<"$ref">> => <<"#/$defs/value">>,
               <<"$defs">> => #{<<"value">> => false}},
    Expected = artifact(
                 #{<<>> => schema_node([{marker, <<"$defs">>},
                                        {ref, {anonymous,
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
                                  #{<<>> => schema_node([{marker, <<"$defs">>},
                                                        {ref, {Child, <<>>}}])}),
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
                            #{<<>> => schema_node([{marker, <<"$defs">>},
                                                  {ref, {Child, <<>>}}])}),
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
    ?assertEqual({ok, Expected}, trusted_compile(Store, Schema, [])).

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
    ?assertEqual({ok, Expected}, trusted_compile_uri(Store, A, [])).

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
    {ok, Compiled} = trusted_compile_uri(Store, A, []),
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
    {ok, Compiled} = trusted_compile(Store, Schema, []),
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
        trusted_compile(Store, #{<<"$ref">> => Ref}, []),
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
    {ok, Compiled} = trusted_compile_uri(Store, <<"root.json">>, []),
    ?assertEqual(Canonical, maps:get(root, Compiled)),
    ?assertEqual([Canonical, Target], maps:get(sources, Compiled)),
    #resource{nodes = #{<<>> := #node{constraints = [{ref, {Target, <<>>}}]}}} =
        maps:get(Canonical, maps:get(resources, Compiled)),
    %% Retrieval alias действительно был входом, хотя root artifact canonical.
    ?assertEqual(Retrieval,
                 (valid_json_store:fetch(Retrieval, Store))#document.retrieval).

public_dialect_test() ->
    Legacy = #{<<"$schema">> => ?LEGACY, <<"type">> => <<"integer">>},
    {ok, Compiled} =
        trusted_compile(valid_json_store:new([]), Legacy, []),
    #resource{dialect = ?LEGACY} =
        maps:get(anonymous, maps:get(resources, Compiled)),
    {ok, Defaulted} =
        trusted_compile(valid_json_store:new([]), #{},
                        [{default_dialect, ?LEGACY}]),
    #resource{dialect = ?LEGACY} =
        maps:get(anonymous, maps:get(resources, Defaulted)).

%% Встроенный resource со своим `$schema` компилируется своим dialect, а
%% объемлющий остаётся при своём. Разница видна в одном артефакте: array-form
%% `items` даёт раскладку только в 2019-09, а `prefixItems` там неизвестен и
%% этим dialect игнорируется.
cross_draft_embedded_test() ->
    Root = <<"https://example.com/root">>,
    Legacy = <<"https://example.com/legacy">>,
    Schema = #{<<"$id">> => Root,
               <<"$schema">> => ?DIALECT,
               <<"$ref">> => Legacy,
               <<"prefixItems">> => [#{<<"type">> => <<"string">>}],
               <<"$defs">> =>
                   #{<<"legacy">> =>
                         #{<<"$id">> => Legacy,
                           <<"$schema">> => ?LEGACY,
                           <<"prefixItems">> => [#{<<"type">> => <<"string">>}],
                           <<"items">> => [#{<<"type">> => <<"string">>}],
                           <<"additionalItems">> => #{<<"type">> => <<"integer">>}}}},
    {ok, #{resources := Resources}} =
        trusted_compile(valid_json_store:new([]), Schema, []),
    #resource{dialect = RootDialect, nodes = RootNodes} = maps:get(Root, Resources),
    #resource{dialect = LegacyDialect, nodes = LegacyNodes} =
        maps:get(Legacy, Resources),
    ?assertEqual(?DIALECT, RootDialect),
    ?assertEqual(?LEGACY, LegacyDialect),
    ?assertEqual([{marker, <<"$defs">>},
                  {ref, {Legacy, <<>>}},
                  {prefix_items, [{Root, <<"/prefixItems/0">>}], undefined}],
                 constraints(<<>>, RootNodes)),
    %% В 2019-09 `prefixItems` — неизвестный keyword, и этот dialect его
    %% игнорирует вовсе; раскладку задают array-form `items` и `additionalItems`.
    ?assertEqual([{items_array, [{Legacy, <<"/items/0">>}],
                   {Legacy, <<"/additionalItems">>}}],
                 constraints(<<>>, LegacyNodes)),
    %% Внутрь `prefixItems` 2019-09-ресурса компилятор не спускался.
    ?assertEqual([<<>>, <<"/additionalItems">>, <<"/items/0">>],
                 lists:sort(maps:keys(LegacyNodes))).

%% Тот же переход между документами: dialect втянутого по `$ref` документа
%% задаёт его собственный `$schema`, а не dialect ссылающегося.
cross_draft_remote_test() ->
    Remote = <<"https://example.com/remote">>,
    {ok, Remote, Store} =
        valid_json_store:add(valid_json_store:new([]), Remote,
                             #{<<"$id">> => Remote,
                               <<"$schema">> => ?LEGACY,
                               <<"prefixItems">> => [#{<<"type">> => <<"string">>}]}),
    {ok, #{resources := Resources, sources := Sources}} =
        trusted_compile(Store, #{<<"$ref">> => Remote}, []),
    ?assertEqual([Remote], Sources),
    #resource{dialect = ?DIALECT, nodes = EntryNodes} =
        maps:get(anonymous, Resources),
    #resource{dialect = ?LEGACY, nodes = RemoteNodes} = maps:get(Remote, Resources),
    ?assertEqual([{ref, {Remote, <<>>}}], constraints(<<>>, EntryNodes)),
    %% В 2019-09 `prefixItems` неизвестен, а неизвестные этот dialect игнорирует:
    %% в 2020-12 тот же keyword дал бы раскладку массива.
    ?assertEqual([], constraints(<<>>, RemoteNodes)).

%% Пользовательская метасхема, названная встроенным resource, действует только
%% внутри него и обязана попасть в `sources`: её `$vocabulary` влияет на артефакт.
cross_draft_embedded_metaschema_test() ->
    Meta = <<"https://example.com/meta/core-only">>,
    Store = metaschema_store(Meta, [<<"core">>]),
    Root = <<"https://example.com/root">>,
    Embedded = <<"https://example.com/embedded">>,
    Schema = #{<<"$id">> => Root,
               <<"minimum">> => 5,
               <<"$defs">> =>
                   #{<<"e">> => #{<<"$id">> => Embedded,
                                  <<"$schema">> => Meta,
                                  <<"minimum">> => 10}}},
    {ok, #{resources := Resources, sources := Sources}} =
        trusted_compile(Store, Schema, []),
    ?assertEqual([Meta], Sources),
    #resource{dialect = ?DIALECT, nodes = RootNodes} = maps:get(Root, Resources),
    #resource{dialect = Meta, nodes = EmbeddedNodes} = maps:get(Embedded, Resources),
    ?assertEqual([{marker, <<"$defs">>}, {minimum, 5}],
                 constraints(<<>>, RootNodes)),
    %% Validation в метасхеме не объявлена, поэтому `minimum` внутри неизвестен.
    ?assertEqual([{annotation, <<"minimum">>, 10}], constraints(<<>>, EmbeddedNodes)).

%% Вне корня schema resource `$schema` запрещён обоими dialects, и ошибка
%% называет его собственную локацию.
misplaced_schema_test_() ->
    Compile = fun(Dialect) ->
                      valid_json_compile:compile(
                        valid_json_store:new([]),
                        #{<<"$defs">> => #{<<"x">> => #{<<"$schema">> => ?DIALECT}}},
                        [{default_dialect, Dialect}])
              end,
    Error = {error, #schema_error{reason = {misplaced_keyword, <<"$schema">>},
                                  location = {anonymous, <<"/$defs/x/$schema">>}}},
    [?_assertEqual(Error, Compile(?DIALECT)),
     ?_assertEqual(Error, Compile(?LEGACY))].

public_reference_error_test_() ->
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
          #{anonymous => resource(
                           anonymous,
                           #{<<>> => schema_node([{marker, <<"$defs">>}])}),
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
          #{Root => resource(
                     Root, #{<<>> => schema_node([{marker, <<"$defs">>}])}),
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
                 compile(#{<<"$defs">> => 42})),
    ?assertEqual(schema_error({bad_keyword_value, 42}, <<"/definitions">>),
                 legacy(#{<<"definitions">> => 42})).

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

%% `format` аннотирует в обоих dialects, и объявленный в корневой метасхеме
%% Draft 2019-09 `false` этого не меняет: он относится к assertion. Имя формата
%% остаётся открытым значением — незнакомое доходит до IR наравне со
%% стандартным, а вот нестроковое значение для слота IR невозможно.
format_test_() ->
    [?_assertEqual({ok, artifact(schema_node([{format, <<"email">>, false}]))},
                   compile(#{<<"format">> => <<"email">>})),
     ?_assertEqual({ok, legacy_artifact(schema_node([{format, <<"email">>, false}]))},
                   legacy(#{<<"format">> => <<"email">>})),
     ?_assertEqual({ok, artifact(schema_node([{format, <<"custom-name">>, false}]))},
                   compile(#{<<"format">> => <<"custom-name">>})),
     ?_assertEqual(schema_error({bad_keyword_value, 1}, <<"/format">>),
                   compile(#{<<"format">> => 1}))].

%% Роль `format` выбирает компиляция, а не вычисление: assertion меняет IR и
%% потому включается опцией `assert_format`. По умолчанию keyword только
%% аннотирует — включать проверку без явной настройки спецификация запрещает.
%% Незнакомое имя при опции compile error не даёт: проверять его нечем, и оно
%% остаётся annotation-only.
assert_format_option_test_() ->
    Ipv4 = #{<<"format">> => <<"ipv4">>},
    [?_assertEqual([{format, <<"ipv4">>, true}],
                   option_constraints(Ipv4, [{assert_format, true}])),
     ?_assertEqual([{format, <<"ipv4">>, false}],
                   option_constraints(Ipv4, [{assert_format, false}])),
     ?_assertEqual([{format, <<"ipv4">>, false}], option_constraints(Ipv4, [])),
     ?_assertEqual([{format, <<"custom-name">>, true}],
                   option_constraints(#{<<"format">> => <<"custom-name">>},
                                      [{assert_format, true}])),
     ?_assertError(badarg,
                   trusted_compile(valid_json_store:new([]), Ipv4,
                                   [{assert_format, yes}]))].

%% Опция принадлежит проходу компиляции целиком, а не отдельному документу:
%% встроенный resource со своим `$id` получает ту же роль keyword, что и корень.
assert_format_reaches_every_resource_test() ->
    Inner = <<"https://example.com/inner">>,
    Schema = #{<<"format">> => <<"ipv4">>,
               <<"$defs">> => #{<<"inner">> => #{<<"$id">> => Inner,
                                                 <<"format">> => <<"ipv4">>}}},
    {ok, #{resources := Resources}} =
        trusted_compile(valid_json_store:new([]), Schema,
                        [{assert_format, true}]),
    #resource{nodes = Nodes} = maps:get(Inner, Resources),
    ?assertEqual([{format, <<"ipv4">>, true}], constraints(<<>>, Nodes)).

%% Аннотации стоят в конце порядка обхода: сначала идёт то, что определяет
%% вердикт, потом то, что только описывает значение. `format` стоит перед ними:
%% под опцией он определяет вердикт, и порядок units из-за неё не поедет.
format_order_test() ->
    Schema = #{<<"title">>  => <<"t">>,
               <<"format">> => <<"email">>,
               <<"type">>   => <<"string">>},
    Constraints = [{type, [string]},
                   {format, <<"email">>, false},
                   {annotation, <<"title">>, <<"t">>}],
    ?assertEqual({ok, artifact(schema_node(Constraints))}, compile(Schema)).

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

%% Пользовательская метасхема задаёт активные vocabularies. Keyword выключенной
%% vocabulary становится неизвестным и в Draft 2020-12 остаётся annotation:
%% `minimum` больше ничего не проверяет, а applicator продолжает работать.
vocabulary_disabled_test() ->
    Meta = <<"https://example.com/meta/no-validation">>,
    Store = metaschema_store(Meta, [<<"core">>, <<"applicator">>]),
    Schema = #{<<"$schema">> => Meta,
               <<"properties">> => #{<<"a">> => #{<<"minimum">> => 10}},
               <<"minimum">> => 5},
    {ok, Compiled} = trusted_compile(Store, Schema, []),
    #{resources := #{anonymous := #resource{dialect = Dialect, nodes = Nodes}},
      sources := Sources} = Compiled,
    %% Dialect артефакта называет то, что написано в `$schema`, а метасхема
    %% входит в sources: её `$vocabulary` влияет на результат компиляции.
    ?assertEqual(Meta, Dialect),
    ?assertEqual([Meta], Sources),
    ?assertEqual([{properties, #{<<"a">> => addr(<<"/properties/a">>)},
                   undefined, undefined},
                  {annotation, <<"minimum">>, 5}],
                 constraints(<<>>, Nodes)),
    ?assertEqual([{annotation, <<"minimum">>, 10}],
                 constraints(<<"/properties/a">>, Nodes)).

%% Выключенный applicator перестаёт быть schema position: внутрь его значения
%% компилятор не спускается, поэтому написанный там `$id` resource не объявляет.
vocabulary_disabled_applicator_test() ->
    Meta = <<"https://example.com/meta/core-only">>,
    Store = metaschema_store(Meta, [<<"core">>]),
    Inner = <<"https://example.com/inner">>,
    Properties = #{<<"a">> => #{<<"$id">> => Inner, <<"type">> => <<"string">>}},
    Schema = #{<<"$schema">> => Meta, <<"properties">> => Properties},
    {ok, #{resources := Resources}} =
        trusted_compile(Store, Schema, []),
    ?assertEqual([anonymous], maps:keys(Resources)),
    #resource{nodes = Nodes} = maps:get(anonymous, Resources),
    ?assertEqual([<<>>], maps:keys(Nodes)),
    ?assertEqual([{annotation, <<"properties">>, Properties}],
                 constraints(<<>>, Nodes)).

%% Неизвестный vocabulary со значением `true` останавливает компиляцию: схема
%% написана на языке, которого реализация не знает. Со значением `false` он
%% необязателен и просто игнорируется.
vocabulary_unrecognized_test_() ->
    Custom = <<"https://example.com/vocab/custom">>,
    Required = <<"https://example.com/meta/required-custom">>,
    Optional = <<"https://example.com/meta/optional-custom">>,
    Declared = fun(Value) ->
                       #{vocab(<<"core">>) => true,
                         vocab(<<"validation">>) => true,
                         Custom => Value}
               end,
    {ok, _, Store} =
        valid_json_store:add(
          valid_json_store:new([]),
          [{Required, metaschema(Required, Declared(true))},
           {Optional, metaschema(Optional, Declared(false))}]),
    Compile = fun(Meta) ->
                      trusted_compile(
                        Store, #{<<"$schema">> => Meta,
                                 <<"type">> => <<"number">>}, [])
              end,
    Assertion = <<"https://example.com/meta/format-assertion">>,
    {ok, Assertion, WithAssertion} =
        valid_json_store:add(
          valid_json_store:new([]), Assertion,
          metaschema(Assertion, #{vocab(<<"core">>) => true,
                                  vocab(<<"format-assertion">>) => true})),
    [?_assertEqual({error, #schema_error{reason = {unrecognized_vocabulary, Custom},
                                         location = {anonymous, <<"/$schema">>}}},
                   Compile(Required)),
     ?_assertMatch({ok, #{resources := #{anonymous := #resource{}}}},
                   Compile(Optional)),
     %% Format-Assertion до P8 не поддержан, и объявившая его метасхема обязана
     %% быть отвергнута: реализация без полной проверки форматов не имеет права
     %% молча аннотировать вместо assertion.
     ?_assertEqual({error, #schema_error{
                              reason = {unrecognized_vocabulary,
                                        vocab(<<"format-assertion">>)},
                              location = {anonymous, <<"/$schema">>}}},
                   trusted_compile(
                     WithAssertion, #{<<"$schema">> => Assertion,
                                      <<"format">> => <<"email">>}, []))].

%% Core обязателен и должен быть объявлен значением `true`: без него нечем
%% обрабатывать даже сам `$schema`.
vocabulary_core_test_() ->
    Missing = <<"https://example.com/meta/no-core">>,
    Disabled = <<"https://example.com/meta/core-false">>,
    Unknown = <<"https://example.com/meta/unregistered">>,
    {ok, _, Store} =
        valid_json_store:add(
          valid_json_store:new([]),
          [{Missing, metaschema(Missing, #{vocab(<<"validation">>) => true})},
           {Disabled, metaschema(Disabled, #{vocab(<<"core">>) => false})}]),
    Compile = fun(Meta) ->
                      trusted_compile(Store, #{<<"$schema">> => Meta}, [])
              end,
    Error = fun(Reason) ->
                    {error, #schema_error{reason = Reason,
                                          location = {anonymous, <<"/$schema">>}}}
            end,
    [?_assertEqual(Error(core_vocabulary_missing), Compile(Missing)),
     ?_assertEqual(Error(core_vocabulary_missing), Compile(Disabled)),
     %% Незарегистрированная метасхема неотличима от неизвестного dialect:
     %% прочитать её объявление неоткуда.
     ?_assertEqual(Error({unknown_dialect, Unknown}), Compile(Unknown))].

%% Вне обработки документа как метасхемы `$vocabulary` не значит ничего: он
%% потребляется компилятором и собственного constraint не даёт.
vocabulary_consumed_test() ->
    Schema = #{<<"$vocabulary">> => #{vocab(<<"core">>) => true},
               <<"type">> => <<"integer">>},
    ?assertEqual({ok, artifact(schema_node([{type, [integer]}]))},
                 compile(Schema)).

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
%% исчезать: иначе преждевременно подключённый файл сьюта пройдёт по
%% недоразумению. Отложенных keywords сейчас не осталось — content keywords были
%% последними, — поэтому проверить остаётся только обратное: keyword другого
%% dialect отложенным не считается и остаётся обычным unknown.
foreign_dialect_keyword_test_() ->
    [?_assertEqual({ok, artifact(schema_node(
                                   [{annotation, <<"additionalItems">>, false}]))},
                   compile(#{<<"additionalItems">> => false}))].

%% Content keywords только аннотируют, поэтому их значения уходят в IR как есть
%% и не нормализуются. Порядок между собой статический, как и у остальных
%% annotation-only keywords.
content_test_() ->
    [?_assertEqual({ok, artifact(schema_node(
                                   [{content, <<"contentEncoding">>, <<"base64">>}]))},
                   compile(#{<<"contentEncoding">> => <<"base64">>})),
     ?_assertEqual({ok, artifact(schema_node(
                                   [{content, <<"contentMediaType">>,
                                     <<"application/json">>}]))},
                   compile(#{<<"contentMediaType">> => <<"application/json">>})),
     %% Тип значения ограничивает метасхема, а компилятор его не проверяет — то
     %% же правило, что и у `default` рядом с несовместимым `type`.
     ?_assertEqual({ok, artifact(schema_node(
                                   [{content, <<"contentEncoding">>, 1}]))},
                   compile(#{<<"contentEncoding">> => 1}))].

%% Порядок content keywords между собой статический и не зависит от устройства
%% map. Значение `contentSchema` остаётся в constraint исходным JSON: подсхема
%% никогда не применяется к instance, и адрес ей не нужен.
content_order_test() ->
    Schema = #{<<"contentSchema">> => #{<<"type">> => <<"object">>},
               <<"contentMediaType">> => <<"application/json">>,
               <<"contentEncoding">> => <<"base64">>},
    {ok, #{resources := Resources}} = compile(Schema),
    #resource{nodes = Nodes} = maps:get(anonymous, Resources),
    ?assertEqual([{content, <<"contentEncoding">>, <<"base64">>},
                  {content, <<"contentMediaType">>, <<"application/json">>},
                  {content, <<"contentSchema">>, #{<<"type">> => <<"object">>}}],
                 constraints(<<>>, Nodes)).

%% Значение `contentSchema` схемой является, но schema position не образует:
%% компилятор внутрь не спускается, node на неё не строит и её `$anchor` в
%% индекс не заносит. Иначе подсхема, которую спецификация не вычисляет вовсе,
%% могла бы отвергнуть всю схему висячим `$ref` или неподдержанным `pattern`.
content_schema_is_not_a_schema_position_test() ->
    Inner = #{<<"$anchor">> => <<"payload">>, <<"type">> => <<"object">>},
    Schema = #{<<"contentMediaType">> => <<"application/json">>,
               <<"contentSchema">> => Inner},
    {ok, #{resources := Resources}} = compile(Schema),
    #resource{anchors = Anchors, nodes = Nodes} = maps:get(anonymous, Resources),
    ?assertEqual(#{}, Anchors),
    ?assertEqual([<<>>], maps:keys(Nodes)),
    ?assertEqual([{content, <<"contentMediaType">>, <<"application/json">>},
                  {content, <<"contentSchema">>, Inner}],
                 constraints(<<>>, Nodes)).

%% Форму значения проверяет метасхема, а не компилятор: не-schema доходит до IR
%% аннотацией так же, как `default` несовместимого с `type` вида.
content_schema_shape_is_left_to_the_metaschema_test() ->
    ?assertEqual({ok, artifact(schema_node(
                                 [{content, <<"contentSchema">>, <<"x">>}]))},
                 compile(#{<<"contentSchema">> => <<"x">>})).

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
    scrub(valid_json_compile:compile_unchecked(Schema, ?DIALECT)).

%% Компилирует одиночный `pattern` и отвечает, совпал ли субъект. Идёт мимо
%% compile/1: нужен как раз тот re:mp(), который scrub/1 стирает.
compiled_matches(Source, Subject) ->
    {ok, #{resources := Resources}} =
        valid_json_compile:compile_unchecked(#{<<"pattern">> => Source},
                                             ?DIALECT),
    #{anonymous := #resource{nodes = #{<<>> := Node}}} = Resources,
    #node{constraints = [{pattern, {Source, Compiled}}]} = Node,
    re:run(Subject, Compiled, [{capture, none}]) =:= match.

%% Эти fixtures проверяют closure, dialect/vocabulary и форму публичного
%% артефакта. Корректность самих статических schemas покрыта meta-schema suite.
trusted_compile(Store, Schema, Options) ->
    valid_json_compile:compile(
      Store, Schema, [{schema_validation, trusted} | Options]).

trusted_compile_uri(Store, Uri, Options) ->
    valid_json_compile:compile_uri(
      Store, Uri, [{schema_validation, trusted} | Options]).

%% Пользовательская метасхема — обычный документ реестра: компилятор читает из
%% неё только `$vocabulary`, а её собственный dialect выбирает набор URI.
metaschema(Uri, Declared) ->
    #{<<"$id">> => Uri, <<"$schema">> => ?DIALECT, <<"$vocabulary">> => Declared}.

metaschema_store(Uri, Names) ->
    Declared = maps:from_list([{vocab(Name), true} || Name <- Names]),
    {ok, Uri, Store} =
        valid_json_store:add(valid_json_store:new([]), Uri,
                             metaschema(Uri, Declared)),
    Store.

vocab(Name) ->
    <<"https://json-schema.org/draft/2020-12/vocab/", Name/binary>>.

constraints(Pointer, Nodes) ->
    #node{constraints = Constraints} = maps:get(Pointer, Nodes),
    Constraints.

%% Compile options видны только через публичный вход: compile_unchecked/2 их не
%% принимает вовсе.
option_constraints(Schema, Options) ->
    {ok, #{resources := Resources}} =
        trusted_compile(valid_json_store:new([]), Schema, Options),
    #resource{nodes = Nodes} = maps:get(anonymous, Resources),
    constraints(<<>>, Nodes).

%% Тот же вход с другим dialect: раскладку array applicators выбирает компилятор,
%% и это единственное место, где она видна.
legacy(Schema) ->
    valid_json_compile:compile_unchecked(Schema, ?LEGACY).

schema_node(Constraints) ->
    #node{constraints = Constraints, unevaluated = []}.

%% Локация называет позицию, значение которой виновато: сам keyword либо schema
%% position. Resource пока всегда один и анонимный.
schema_error(Reason, Pointer) ->
    {error, #schema_error{reason = Reason, location = {anonymous, Pointer}}}.

addr(Pointer) ->
    {anonymous, Pointer}.

%% Там, где важен только constraint корня, остальной артефакт повторяет уже
%% проверенный случай и в ожидание не выписывается.
root_constraints(Schema) ->
    {ok, #{resources := Resources}} = compile(Schema),
    #resource{nodes = #{<<>> := #node{constraints = Constraints}}} =
        maps:get(anonymous, Resources),
    Constraints.

%% Опции повторяют validator-core.md: без них терм не совпал бы с компиляторным.
%% Ожидаемая сторона несёт вместо re:mp() ту же метку, что оставляет scrub/1.
regex(Source) ->
    {Source, mp}.

%% С OTP 28 re:compile/2 возвращает ссылку на ресурс, и два вызова над одним
%% текстом равными термами уже не будут. Точное сравнение артефактов идёт
%% поэтому по исходному тексту паттерна, а сам re:mp() с обеих сторон
%% заменяется меткой: скомпилированный терм — функция текста и опций, и текст
%% лежит в IR рядом с ним.
scrub(Term) when is_tuple(Term), element(1, Term) =:= re_pattern ->
    mp;
scrub(Term) when is_tuple(Term) ->
    list_to_tuple(scrub(tuple_to_list(Term)));
scrub(Term) when is_list(Term) ->
    [scrub(Item) || Item <- Term];
scrub(Term) when is_map(Term) ->
    maps:fold(fun(Key, Value, Acc) -> Acc#{Key => scrub(Value)} end, #{}, Term);
scrub(Term) ->
    Term.

%% Схема без подсхем даёт единственный node в корне resource, поэтому один node
%% принимается вместо готовой map.
artifact(Node) ->
    artifact(Node, ?DIALECT).

legacy_artifact(Node) ->
    artifact(Node, ?LEGACY).

legacy_artifact(Node, Recursive) ->
    artifact(Node, ?LEGACY, Recursive).

artifact(Node, Dialect) when not is_map(Node) ->
    artifact(#{<<>> => Node}, Dialect);
artifact(Nodes, Dialect) ->
    artifact(Nodes, Dialect, false).

artifact(Node, Dialect, Recursive) when not is_map(Node) ->
    artifact(#{<<>> => Node}, Dialect, Recursive);
artifact(Nodes, Dialect, Recursive) ->
    #{root      => anonymous,
      sources   => [],
      resources => #{anonymous =>
          #resource{id               = undefined,
                    dialect          = Dialect,
                    anchors          = #{},
                    dynamic_anchors  = #{},
                    recursive_anchor = Recursive,
                    nodes            = Nodes}}}.

compiled(Root, Resources) ->
    #{root => Root, sources => [], resources => Resources}.

resource(Rid, Nodes) ->
    resource(Rid, #{}, Nodes).

resource(Rid, Anchors, Nodes) ->
    resource(Rid, Anchors, #{}, Nodes).

resource(Rid, Anchors, DynamicAnchors, Nodes) ->
    Id = case Rid of anonymous -> undefined; _ -> Rid end,
    #resource{id               = Id,
              dialect          = ?DIALECT,
              anchors          = Anchors,
              dynamic_anchors  = DynamicAnchors,
              recursive_anchor = false,
              nodes            = Nodes}.

legacy_resource(Rid, Recursive, Nodes) ->
    Id = case Rid of anonymous -> undefined; _ -> Rid end,
    #resource{id               = Id,
              dialect          = ?LEGACY,
              anchors          = #{},
              dynamic_anchors  = #{},
              recursive_anchor = Recursive,
              nodes            = Nodes}.
