%% Evaluator fixtures поверх вручную собранного compiled(): результат проверяется
%% до проекции в JSON, чтобы слои не сливались в один end-to-end вердикт.
-module(valid_json_eval_tests).

-include_lib("eunit/include/eunit.hrl").
-include("valid_json_core.hrl").

%% Тесты модуля независимы, поэтому eunit прогоняет их параллельно.
eunit_wrapper_(Tests) -> {inparallel, Tests}.

-define(DIALECT, <<"https://json-schema.org/draft/2020-12/schema">>).
-define(RESOURCE, <<"https://example.com/s">>).

type_test_() ->
    [?_assert(valid([{type, [integer]}], 1)),
     ?_assert(valid([{type, [integer]}], 1.0)),
     ?_assertNot(valid([{type, [integer]}], 1.5)),
     ?_assert(valid([{type, [string, null]}], null)),
     ?_assertNot(valid([{type, [string, null]}], false)),
     %% Пустой список типов не проходит ни одно значение.
     ?_assertNot(valid([{type, []}], 1))].

%% JSON equality рекурсивно и не смешивает boolean с number.
equality_test_() ->
    [?_assert(valid([{const, 1}], 1.0)),
     ?_assert(valid([{const, 1.0}], 1)),
     ?_assert(valid([{const, #{<<"a">> => [1, #{}]}}], #{<<"a">> => [1.0, #{}]})),
     ?_assertNot(valid([{const, true}], 1)),
     ?_assertNot(valid([{const, 0}], false)),
     ?_assertNot(valid([{const, [true]}], [1])),
     ?_assertNot(valid([{const, null}], <<"null">>)),
     ?_assertNot(valid([{const, []}], <<>>)),
     ?_assertNot(valid([{const, 9007199254740993}], 9007199254740992.0))].

enum_test_() ->
    [?_assert(valid([{enum, [1, <<"a">>, null]}], null)),
     ?_assert(valid([{enum, [1]}], 1.0)),
     ?_assertNot(valid([{enum, [1]}], true)),
     ?_assertNot(valid([{enum, [true]}], 1)),
     %% Пустой enum не проходит ни одно значение.
     ?_assertNot(valid([{enum, []}], null))].

%% Числовые keywords ограничивают только number. Каждый проверяется на границе
%% и на неприменимом типе instance.
bounds_test_() ->
    [?_assert(valid([{maximum, 3.0}], 3.0)),
     ?_assert(valid([{maximum, 300}], 300.0)),
     ?_assertNot(valid([{maximum, 3.0}], 3.5)),
     ?_assertNot(valid([{exclusive_maximum, 3.0}], 3.0)),
     ?_assert(valid([{exclusive_maximum, 3.0}], 2.2)),
     ?_assert(valid([{minimum, -2}], -2.0)),
     ?_assertNot(valid([{minimum, -2}], -2.0001)),
     ?_assertNot(valid([{exclusive_minimum, 1.1}], 1.1)),
     ?_assert(valid([{exclusive_minimum, 1.1}], 1.2)),
     %% Точность не теряется на целых, не представимых double.
     ?_assertNot(valid([{maximum, 9007199254740992.0}], 9007199254740993))].

multiple_of_test_() ->
    [?_assert(valid([{multiple_of, 2}], 10)),
     ?_assertNot(valid([{multiple_of, 2}], 7)),
     ?_assert(valid([{multiple_of, 0.0001}], 0.0075)),
     ?_assertNot(valid([{multiple_of, 0.123456789}], 1.0e308))].

%% Паттерн ищет подстроку: неявное якорение запрещено MUST (core.txt:709).
pattern_test_() ->
    [?_assert(valid([{pattern, regex(<<"a+">>)}], <<"xaay">>)),
     ?_assertNot(valid([{pattern, regex(<<"a+">>)}], <<"xyz">>)),
     ?_assert(valid([{pattern, regex(<<"^a+$">>)}], <<"aaa">>)),
     ?_assertNot(valid([{pattern, regex(<<"^a+$">>)}], <<"baaa">>)),
     ?_assertNot(valid([{pattern, regex(<<"a+">>)}], <<>>)),
     %% dollar_endonly: $ не совпадает перед завершающим переводом строки.
     ?_assertNot(valid([{pattern, regex(<<"^a$">>)}], <<"a\n">>)),
     %% unicode: и паттерн, и субъект читаются как UTF-8, а не как байты.
     ?_assert(valid([{pattern, regex(<<"^.$">>)}], <<"ф"/utf8>>)),
     ?_assert(valid([{pattern, regex(<<"^ф$"/utf8>>)}], <<"ф"/utf8>>)),
     %% Значение неприменимого типа проходит успешно.
     ?_assert(valid([{pattern, regex(<<"^a$">>)}], 1)),
     ?_assert(valid([{pattern, regex(<<"^a$">>)}], null)),
     ?_assert(valid([{pattern, regex(<<"^a$">>)}], [<<"a">>])),
     ?_assert(valid([{pattern, regex(<<"^a$">>)}], #{<<"a">> => 1}))].

%% Строковые границы считают code points, а не байты: суррогатная пара — один
%% символ длиной в четыре байта.
length_test_() ->
    [?_assert(valid([{max_length, 2}], <<"ab">>)),
     ?_assertNot(valid([{max_length, 2}], <<"abc">>)),
     ?_assert(valid([{max_length, 2}], <<"💩💩"/utf8>>)),
     ?_assertNot(valid([{max_length, 2}], <<"💩💩💩"/utf8>>)),
     ?_assert(valid([{min_length, 2}], <<"💩💩"/utf8>>)),
     ?_assertNot(valid([{min_length, 2}], <<"💩"/utf8>>)),
     ?_assert(valid([{min_length, 0}], <<>>)),
     ?_assert(valid([{max_length, 0}], 100)),
     ?_assert(valid([{min_length, 5}], [<<"a">>]))].

array_bounds_test_() ->
    [?_assert(valid([{max_items, 2}], [1, 2])),
     ?_assertNot(valid([{max_items, 2}], [1, 2, 3])),
     ?_assert(valid([{min_items, 1}], [null])),
     ?_assertNot(valid([{min_items, 1}], [])),
     ?_assert(valid([{max_items, 0}], #{<<"a">> => 1, <<"b">> => 2}))].

unique_items_test_() ->
    [?_assert(valid([{unique_items, true}], [1, 2, 3])),
     ?_assertNot(valid([{unique_items, true}], [1, 1])),
     %% JSON equality: 1 и 1.0 — одно значение, а true и 1 — разные.
     ?_assertNot(valid([{unique_items, true}], [1, 1.0])),
     ?_assert(valid([{unique_items, true}], [true, 1])),
     ?_assertNot(valid([{unique_items, true}],
                       [#{<<"a">> => [1]}, #{<<"a">> => [1.0]}])),
     ?_assert(valid([{unique_items, true}], [])),
     %% Написанный no-op пропускает всё, но из IR не исчезает.
     ?_assert(valid([{unique_items, false}], [1, 1])),
     ?_assert(valid([{unique_items, true}], <<"aa">>))].

object_bounds_test_() ->
    [?_assert(valid([{max_properties, 2}], #{<<"a">> => 1, <<"b">> => 2})),
     ?_assertNot(valid([{max_properties, 1}], #{<<"a">> => 1, <<"b">> => 2})),
     ?_assert(valid([{max_properties, 0}], #{})),
     ?_assert(valid([{min_properties, 1}], #{<<"a">> => 1})),
     ?_assertNot(valid([{min_properties, 1}], #{})),
     ?_assert(valid([{min_properties, 5}], [1, 2]))].

required_test_() ->
    [?_assert(valid([{required, [<<"a">>]}], #{<<"a">> => null})),
     ?_assertNot(valid([{required, [<<"a">>]}], #{<<"b">> => 1})),
     ?_assert(valid([{required, []}], #{})),
     ?_assert(valid([{required, [<<"a">>]}], [<<"a">>]))].

%% Зависимость включается только тогда, когда имя-триггер есть в instance.
dependent_required_test_() ->
    Constraint = {dependent_required, #{<<"bar">> => [<<"foo">>]}},
    [?_assert(valid([Constraint], #{})),
     ?_assert(valid([Constraint], #{<<"foo">> => 1})),
     ?_assert(valid([Constraint], #{<<"bar">> => 1, <<"foo">> => 2})),
     ?_assertNot(valid([Constraint], #{<<"bar">> => 1})),
     ?_assert(valid([{dependent_required, #{<<"bar">> => []}}], #{<<"bar">> => 1})),
     ?_assert(valid([Constraint], <<"bar">>))].

%% Значение неприменимого типа проходит успешно, а не отвергается.
inapplicable_test_() ->
    Constraints = [{multiple_of, 2}, {maximum, 3}, {exclusive_maximum, 3},
                   {minimum, 3}, {exclusive_minimum, 3}],
    [?_assert(valid([Constraint], Instance))
     || Constraint <- Constraints,
        Instance <- [<<"x">>, null, true, [], #{}, [1], <<>>]].

%% Schema object — конъюнкция: достаточно одного провалившегося constraint.
conjunction_test_() ->
    Constraints = [{type, [integer]}, {enum, [1, 2, <<"a">>]}],
    [?_assert(valid(Constraints, 2)),
     ?_assertNot(valid(Constraints, <<"a">>)),
     ?_assertNot(valid(Constraints, 3)),
     ?_assert(valid([], <<"anything">>))].

%% Провалившийся schema object не отдаёт эффективных аннотаций. Чистые
%% assertions покрытия не вносят, поэтому маска остаётся нейтральной в обоих
%% исходах — это фиксирует, что провал её не портит.
coverage_test_() ->
    [{"успех", ?_assertEqual(neutral(), coverage([{type, [integer]}], 1))},
     {"провал", ?_assertEqual(neutral(), coverage([{type, [integer]}], 1.5))}].

boolean_schema_test_() ->
    [?_assertEqual({ok, #{<<"valid">> => true}}, validate(true, 1)),
     ?_assertEqual({ok, #{<<"valid">> => false}}, validate(false, 1))].

%% Каждый написанный keyword выпускает ровно один unit, включая no-op и
%% неприменимый к instance тип. Имя в локации — фактический keyword, а не тег IR.
units_test_() ->
    Cases = [{{type, [string]},                        <<"/type">>},
             {{enum, [1]},                             <<"/enum">>},
             {{const, 1},                              <<"/const">>},
             {{multiple_of, 2},                        <<"/multipleOf">>},
             {{maximum, 4},                            <<"/maximum">>},
             {{exclusive_maximum, 4},                  <<"/exclusiveMaximum">>},
             {{minimum, 0},                            <<"/minimum">>},
             {{exclusive_minimum, 0},                  <<"/exclusiveMinimum">>},
             {{max_length, 2},                         <<"/maxLength">>},
             {{min_length, 0},                         <<"/minLength">>},
             {{pattern, regex(<<"a">>)},               <<"/pattern">>},
             {{max_items, 2},                          <<"/maxItems">>},
             {{min_items, 2},                          <<"/minItems">>},
             {{unique_items, false},                   <<"/uniqueItems">>},
             {{max_properties, 2},                     <<"/maxProperties">>},
             {{min_properties, 2},                     <<"/minProperties">>},
             {{required, []},                          <<"/required">>},
             {{dependent_required, #{}},               <<"/dependentRequired">>}],
    [{binary_to_list(Location),
      ?_assertMatch([{Location, _, _}], located([Constraint], 1))}
     || {Constraint, Location} <- Cases].

%% Units собираются во всех режимах, кроме flag, и обрыв разрешён только там же:
%% в basic после провала выполняются и остальные constraints.
mode_test_() ->
    Constraints = [{type, [string]}, {const, 1}],
    [?_assertEqual([], units(Constraints, 1, flag)),
     ?_assertMatch([{<<"/type">>, false, _}, {<<"/const">>, true, none}],
                   located(Constraints, 1))].

%% Boolean-схема сегмента не добавляет: она стоит там же, где схема. Keywords у
%% неё нет, поэтому сообщение о провале несёт её собственный unit.
boolean_units_test_() ->
    [?_assertEqual({<<>>, true, none}, shown(node_unit(true, 1))),
     ?_assertMatch({<<>>, false, {error, _}}, shown(node_unit(false, 1))),
     ?_assertEqual([], located(false, 1))].

%% Schema object тоже выпускает собственный unit и тоже стоит там же, где схема.
%% Ни сообщения, ни аннотации у него нет: причину провала называют units его
%% keywords, которые лежат внутри него.
schema_units_test_() ->
    Failed = node_unit([{type, [string]}], 1),
    [?_assertEqual({<<>>, false, none}, shown(Failed)),
     ?_assertEqual({<<>>, true, none}, shown(node_unit([{type, [string]}], <<"a">>))),
     ?_assertMatch([{<<"/type">>, false, {error, _}}],
                   [shown(Unit) || Unit <- Failed#output_unit.nested])].

%% Разрешение адреса в готовом артефакте тотально: каждый указатель выбирает
%% ровно свой node, а корень resource стоит под пустым указателем.
resolve_test_() ->
    Root = schema_node([{all_of, [addr(<<"/allOf/0">>)]}]),
    Child = schema_node([{type, [string]}]),
    Artifact = tree(#{<<>> => Root, <<"/allOf/0">> => Child, <<"/allOf/1">> => false}),
    [?_assertEqual(Root, valid_json_eval:resolve(addr(<<>>), Artifact)),
     ?_assertEqual(Child, valid_json_eval:resolve(addr(<<"/allOf/0">>), Artifact)),
     ?_assertEqual(false, valid_json_eval:resolve(addr(<<"/allOf/1">>), Artifact))].

%% Логические applicators спускаются в дочерние nodes общим входом evaluator'а и
%% сводят их вердикты. Ветвь применяется к тому же значению, что и родитель.
all_of_test_() ->
    [?_assert(branches(all_of, <<"allOf">>, [true, true], 1)),
     ?_assertNot(branches(all_of, <<"allOf">>, [true, false], 1)),
     ?_assert(branches(all_of, <<"allOf">>, [[{type, [integer]}]], 1)),
     ?_assertNot(branches(all_of, <<"allOf">>, [[{type, [string]}]], 1)),
     %% Пустой список ветвей проходит любое значение.
     ?_assert(branches(all_of, <<"allOf">>, [], 1))].

any_of_test_() ->
    [?_assert(branches(any_of, <<"anyOf">>, [false, true], 1)),
     ?_assertNot(branches(any_of, <<"anyOf">>, [false, false], 1)),
     ?_assert(branches(any_of, <<"anyOf">>, [[{type, [string]}], [{type, [integer]}]], 1)),
     %% Пустой список не проходит ни одно значение: совпасть не с чем.
     ?_assertNot(branches(any_of, <<"anyOf">>, [], 1))].

one_of_test_() ->
    [?_assert(branches(one_of, <<"oneOf">>, [false, true], 1)),
     ?_assertNot(branches(one_of, <<"oneOf">>, [true, true], 1)),
     ?_assertNot(branches(one_of, <<"oneOf">>, [false, false], 1)),
     ?_assert(branches(one_of, <<"oneOf">>, [[{type, [string]}], [{type, [integer]}]], 1)),
     ?_assertNot(branches(one_of, <<"oneOf">>, [], 1))].

not_test_() ->
    [?_assert(negated(false, 1)),
     ?_assertNot(negated(true, 1)),
     ?_assert(negated([{type, [string]}], 1)),
     ?_assertNot(negated([{type, [integer]}], 1))].

%% Вердикта `if` не даёт: он выбирает ветвь. Ненаписанная ветвь оставляет успех,
%% поэтому один `if` не ограничивает ничего.
conditional_test_() ->
    Both = conditional([{type, [integer]}], [{minimum, 0}], [{type, [string]}]),
    Positive = conditional([{type, [integer]}], [{minimum, 0}], undefined),
    Negative = conditional([{type, [integer]}], undefined, [{type, [string]}]),
    [?_assert(verdict(Both, 1)),
     ?_assertNot(verdict(Both, -1)),
     ?_assert(verdict(Both, <<"a">>)),
     ?_assertNot(verdict(Both, 1.5)),
     ?_assertNot(verdict(Positive, -1)),
     %% Условие не выполнено, а ветвиться некуда.
     ?_assert(verdict(Positive, <<"a">>)),
     ?_assertNot(verdict(Negative, 1.5)),
     ?_assert(verdict(Negative, 1)),
     ?_assert(verdict(conditional(true, undefined, undefined), 1)),
     ?_assert(verdict(conditional(false, undefined, undefined), 1))].

%% Невыбранная ветвь не вычисляется вовсе — ни ради вердикта, ни ради аннотаций.
%% Ловушка падает при вычислении, поэтому её обход был бы виден сразу.
conditional_unselected_test_() ->
    Skipped = conditional([{type, [integer]}], tripwire(), [{type, [string]}]),
    Untaken = conditional([{type, [integer]}], [{minimum, 0}], tripwire()),
    [?_assert(verdict(Skipped, <<"a">>)),
     ?_assert(verdict(Untaken, 1)),
     %% В basic дерево units полное, но невыбранной ветви в нём всё равно нет.
     ?_assertMatch({ok, #eval_result{valid = true}},
                   valid_json_eval:run(Skipped, <<"a">>, basic))].

%% Собственный unit `if` выпускает всегда и всегда успешный: ошибки у этого
%% keyword не бывает, а units опровергнувшей его подсхемы остаются
%% диагностическими. Невыбранная ветвь не выпускает ничего.
conditional_units_test_() ->
    Artifact = conditional([{type, [integer]}], [{minimum, 0}], [{type, [string]}]),
    [?_assertMatch([{<<"/if">>, true, none},
                    {<<"/if/type">>, true, none},
                    {<<"/then">>, false, {error, _}},
                    {<<"/then/minimum">>, false, {error, _}}],
                   printed(collect(Artifact, -1, basic))),
     ?_assertMatch([{<<"/if">>, true, none},
                    {<<"/if/type">>, false, {error, _}},
                    {<<"/else">>, true, none},
                    {<<"/else/type">>, true, none}],
                   printed(collect(Artifact, <<"a">>, basic)))].

%% Покрытие складывается из вклада `if` и вклада выбранной ветви. Провалившийся
%% `if` не вносит ничего: его подсхема очистила покрытие сама.
conditional_coverage_test_() ->
    Named = fun(Name, Pointer) ->
                    [{properties, #{Name => addr(Pointer)}, undefined, undefined}]
            end,
    Artifact = branching([{if_then_else, addr(<<"/if">>), addr(<<"/then">>),
                           addr(<<"/else">>)}],
                         [{<<"/if">>, Named(<<"a">>, <<"/if/properties/a">>)},
                          {<<"/if/properties/a">>, [{type, [integer]}]},
                          {<<"/then">>, Named(<<"b">>, <<"/then/properties/b">>)},
                          {<<"/then/properties/b">>, true},
                          {<<"/else">>, Named(<<"c">>, <<"/else/properties/c">>)},
                          {<<"/else/properties/c">>, true}]),
    [?_assertEqual({[<<"a">>, <<"b">>], 0, []},
                   coverage_of(Artifact, #{<<"a">> => 1, <<"b">> => 2})),
     ?_assertEqual({[<<"c">>], 0, []},
                   coverage_of(Artifact, #{<<"a">> => <<"x">>, <<"c">> => 3}))].

%% Object applicators применяются каждый к своим именам: `properties` — к
%% точному, `patternProperties` — ко всем совпавшим паттернам,
%% `additionalProperties` — только к остатку.
object_test_() ->
    Artifact = object(),
    [?_assert(verdict(Artifact, #{<<"a">> => 1})),
     ?_assertNot(verdict(Artifact, #{<<"a">> => <<"x">>})),
     ?_assert(verdict(Artifact, #{<<"bb">> => <<"x">>})),
     ?_assertNot(verdict(Artifact, #{<<"bb">> => 1})),
     %% Имя, которого не взял никто, достаётся additionalProperties.
     ?_assert(verdict(Artifact, #{<<"c">> => 1})),
     ?_assertNot(verdict(Artifact, #{<<"c">> => <<"x">>})),
     ?_assert(verdict(Artifact, #{<<"a">> => 1, <<"bb">> => <<"x">>})),
     ?_assert(verdict(Artifact, #{})),
     %% Не-объект constraint не ограничивает.
     ?_assert(verdict(Artifact, 1)),
     ?_assert(verdict(Artifact, [#{<<"c">> => 1}]))].

%% Одно имя может достаться нескольким keywords сразу, и применяется каждый.
object_overlap_test_() ->
    Props = #{<<"b">> => addr(<<"/properties/b">>)},
    Patterns = [{regex(<<"^b">>), addr(<<"/patternProperties/^b">>)},
                {regex(<<"b$">>), addr(<<"/patternProperties/b$">>)}],
    Artifact = branching([{properties, Props, Patterns, addr(<<"/additionalProperties">>)}],
                         [{<<"/properties/b">>, [{type, [integer]}]},
                          {<<"/patternProperties/^b">>, [{minimum, 0}]},
                          {<<"/patternProperties/b$">>, [{maximum, 10}]},
                          {<<"/additionalProperties">>, false}]),
    [?_assert(verdict(Artifact, #{<<"b">> => 5})),
     %% Совпали оба паттерна, и нарушение любого из них видно.
     ?_assertNot(verdict(Artifact, #{<<"b">> => -1})),
     ?_assertNot(verdict(Artifact, #{<<"b">> => 11})),
     %% Имя взято соседями, поэтому additionalProperties до него не доходит.
     ?_assertNot(verdict(Artifact, #{<<"b">> => 5, <<"z">> => 1}))].

%% Локация keyword следует схеме, локация инстанса — значению. Собственный unit
%% написанного keyword стоит перед units своих ветвей.
object_units_test_() ->
    Units = paired(collect(object(), #{<<"a">> => 1, <<"bb">> => <<"x">>, <<"c">> => 2}, basic)),
    [?_assertEqual([{<<"/properties">>, <<>>},
                    {<<"/properties/a/type">>, <<"/a">>},
                    {<<"/patternProperties">>, <<>>},
                    {<<"/patternProperties/^b/type">>, <<"/bb">>},
                    {<<"/additionalProperties">>, <<>>},
                    {<<"/additionalProperties/type">>, <<"/c">>}],
                   Units)].

%% Аннотация называет имена, к которым keyword применился, и не зависит от
%% порядка обхода объекта.
object_annotation_test_() ->
    %% Берутся только units самих keywords: units ветвей стоят глубже и говорят
    %% о своих значениях, а не о применении.
    Details = fun(Instance) ->
                      [{valid_json_location:pointer(Keywords), Detail}
                       || #output_unit{keyword_location = Keywords, detail = Detail}
                              <- own(collect(object(), Instance, basic))]
              end,
    [?_assertEqual([{<<"/properties">>, {annotation, [<<"a">>]}},
                    {<<"/patternProperties">>, {annotation, [<<"bb">>, <<"bc">>]}},
                    {<<"/additionalProperties">>, {annotation, []}}],
                   Details(#{<<"bc">> => <<"y">>, <<"a">> => 1, <<"bb">> => <<"x">>})),
     %% Написанный keyword без единого применения даёт пустую аннотацию.
     ?_assertEqual([{<<"/properties">>, {annotation, []}},
                    {<<"/patternProperties">>, {annotation, []}},
                    {<<"/additionalProperties">>, {annotation, []}}],
                   Details(#{})),
     %% Не-объект: unit успешный, но аннотации нет.
     ?_assertEqual([{<<"/properties">>, none},
                    {<<"/patternProperties">>, none},
                    {<<"/additionalProperties">>, none}],
                   Details(1))].

%% Покрытие вносят применившиеся keywords. Покрытие дочерней schema принадлежит
%% ей самой и наверх не идёт.
object_coverage_test_() ->
    Nested = branching([{properties, #{<<"a">> => addr(<<"/properties/a">>)}, undefined, undefined}],
                       [{<<"/properties/a">>,
                         [{properties, #{<<"inner">> => addr(<<"/properties/a/properties/inner">>)},
                                       undefined, undefined}]},
                        {<<"/properties/a/properties/inner">>, true}]),
    [?_assertEqual({[<<"a">>, <<"bb">>, <<"c">>], 0, []},
                   coverage_of(object(), #{<<"a">> => 1, <<"bb">> => <<"x">>, <<"c">> => 2})),
     %% Провалившийся keyword аннотации не даёт, поэтому и покрытия не вносит.
     ?_assertEqual(neutral(), coverage_of(object(), #{<<"a">> => <<"x">>})),
     ?_assertEqual({[<<"a">>], 0, []},
                   coverage_of(Nested, #{<<"a">> => #{<<"inner">> => 1}}))].

%% Подсхема применяется к самому имени свойства, а не к его значению, поэтому
%% ограничивает строку и проходит по всем именам объекта.
property_names_test_() ->
    Short = property_names([{max_length, 2}]),
    [?_assert(verdict(Short, #{<<"ab">> => 1})),
     ?_assertNot(verdict(Short, #{<<"ab">> => 1, <<"abc">> => 2})),
     %% Имя всегда строка, поэтому подсхема видит именно её.
     ?_assert(verdict(property_names([{type, [string]}]), #{<<"a">> => 1})),
     ?_assertNot(verdict(property_names([{type, [integer]}]), #{<<"a">> => 1})),
     %% Применять нечего: пустой объект проходит и false-схему.
     ?_assert(verdict(property_names(false), #{})),
     %% Не-объект constraint не ограничивает.
     ?_assert(verdict(property_names(false), 1)),
     ?_assert(verdict(property_names(false), [#{<<"a">> => 1}]))].

%% Локация keyword следует схеме, локация инстанса — свойству, имя которого
%% проверяется. Собственный unit стоит перед units своих ветвей.
property_names_units_test_() ->
    Artifact = property_names([{max_length, 2}]),
    [?_assertEqual([{<<"/propertyNames">>, <<>>},
                    {<<"/propertyNames/maxLength">>, <<"/ab">>},
                    {<<"/propertyNames/maxLength">>, <<"/abc">>}],
                   paired(collect(Artifact, #{<<"abc">> => 1, <<"ab">> => 2}, basic))),
     %% Аннотации keyword не производит, поэтому у успешного unit деталей нет.
     ?_assertMatch([{<<"/propertyNames">>, true, none} | _],
                   printed(collect(Artifact, #{<<"ab">> => 1}, basic))),
     ?_assertMatch([{<<"/propertyNames">>, false, {error, _}} | _],
                   printed(collect(Artifact, #{<<"abc">> => 1}, basic))),
     %% Не-объект: unit успешный и без деталей.
     ?_assertEqual([{<<"/propertyNames">>, true, none}],
                   printed(collect(Artifact, 1, basic)))].

%% Аннотации keyword не производит, поэтому и покрытия не вносит: для
%% `unevaluatedProperties` имя остаётся непокрытым.
property_names_coverage_test() ->
    ?assertEqual(neutral(),
                 coverage_of(property_names([{max_length, 2}]), #{<<"ab">> => 1})).

%% Подсхему выбирает присутствие свойства, а применяется она ко всему instance.
dependent_schemas_test_() ->
    Artifact = dependent_schemas([{<<"a">>, [{required, [<<"b">>]}]},
                                  {<<"c">>, [{max_properties, 1}]}]),
    [?_assert(verdict(Artifact, #{})),
     %% Свойства нет — зависимость не применяется вовсе.
     ?_assert(verdict(Artifact, #{<<"b">> => 1})),
     ?_assertNot(verdict(Artifact, #{<<"a">> => 1})),
     ?_assert(verdict(Artifact, #{<<"a">> => 1, <<"b">> => 2})),
     ?_assert(verdict(Artifact, #{<<"c">> => 1})),
     %% Применились обе зависимости, и нарушение любой из них видно.
     ?_assertNot(verdict(Artifact, #{<<"a">> => 1, <<"b">> => 2, <<"c">> => 3})),
     %% Не-объект constraint не ограничивает.
     ?_assert(verdict(dependent_schemas([{<<"a">>, false}]), 1))].

%% Keyword — in-place applicator: стек инстанса подсхема не двигает, а сегментом
%% локации становится имя свойства.
dependent_schemas_units_test_() ->
    Artifact = dependent_schemas([{<<"a">>, [{required, [<<"b">>]}]}]),
    [?_assertEqual([{<<"/dependentSchemas">>, <<>>},
                    {<<"/dependentSchemas/a/required">>, <<>>}],
                   paired(collect(Artifact, #{<<"a">> => 1}, basic))),
     ?_assertMatch([{<<"/dependentSchemas">>, false, {error, _}} | _],
                   printed(collect(Artifact, #{<<"a">> => 1}, basic))),
     %% Ни одна зависимость не применилась: unit остаётся, деталей у него нет.
     ?_assertEqual([{<<"/dependentSchemas">>, true, none}],
                   printed(collect(Artifact, #{}, basic)))].

%% Покрытие применившейся зависимости идёт наверх: подсхема стоит на том же
%% значении, что и сам schema object.
dependent_schemas_coverage_test_() ->
    Covering = [{properties, #{<<"a">> => addr(<<"/dependentSchemas/a/properties/a">>)},
                 undefined, undefined}],
    Artifact = branching([{dependent_schemas, #{<<"a">> => addr(<<"/dependentSchemas/a">>)}}],
                         [{<<"/dependentSchemas/a">>, Covering},
                          {<<"/dependentSchemas/a/properties/a">>, true}]),
    [?_assertEqual({[<<"a">>], 0, []}, coverage_of(Artifact, #{<<"a">> => 1})),
     %% Свойства нет — применять нечего, покрытия не появляется.
     ?_assertEqual(neutral(), coverage_of(Artifact, #{<<"b">> => 1}))].

%% Одиночный `items` применяется ко всем элементам массива, `prefixItems` — к
%% элементам с теми же индексами, а его хвостовой `items` — к остатку.
items_test_() ->
    Integers = items([{type, [integer]}]),
    [?_assert(verdict(Integers, [1, 2])),
     ?_assertNot(verdict(Integers, [1, <<"a">>])),
     %% Применять нечего: пустой массив проходит и false-схему.
     ?_assert(verdict(items(false), [])),
     ?_assertNot(verdict(items(false), [1])),
     %% Не-массив constraint не ограничивает.
     ?_assert(verdict(items(false), 1)),
     ?_assert(verdict(items(false), #{<<"a">> => 1}))].

prefix_items_test_() ->
    Pair = prefix_items([[{type, [integer]}], [{type, [string]}]], undefined),
    Closed = prefix_items([true], false),
    [?_assert(verdict(Pair, [1, <<"a">>])),
     ?_assertNot(verdict(Pair, [1, 2])),
     %% Длину массива keyword не ограничивает: лишние схемы остаются без пары,
     %% лишние элементы — без схемы.
     ?_assert(verdict(Pair, [1])),
     ?_assert(verdict(Pair, [])),
     ?_assert(verdict(Pair, [1, <<"a">>, true])),
     %% Остаток за префиксом достаётся хвостовому `items`.
     ?_assert(verdict(Closed, [1])),
     ?_assertNot(verdict(Closed, [1, 2])),
     ?_assert(verdict(prefix_items([], undefined), [1])),
     ?_assert(verdict(Closed, <<"ab">>))].

%% Локация keyword следует схеме, локация инстанса — индексу элемента.
%% Собственный unit написанного keyword стоит перед units своих ветвей.
array_units_test_() ->
    Tail = prefix_items([[{type, [integer]}]], [{type, [string]}]),
    [?_assertEqual([{<<"/items">>, <<>>},
                    {<<"/items/type">>, <<"/0">>},
                    {<<"/items/type">>, <<"/1">>}],
                   paired(collect(items([{type, [integer]}]), [1, <<"a">>], basic))),
     ?_assertEqual([{<<"/prefixItems">>, <<>>},
                    {<<"/prefixItems/0/type">>, <<"/0">>},
                    {<<"/items">>, <<>>},
                    {<<"/items/type">>, <<"/1">>},
                    {<<"/items/type">>, <<"/2">>}],
                   paired(collect(Tail, [1, <<"a">>, <<"b">>], basic))),
     %% Не-массив: units написанных keywords остаются, но без деталей.
     ?_assertEqual([{<<"/prefixItems">>, true, none}, {<<"/items">>, true, none}],
                   printed(collect(Tail, 1, basic)))].

%% Аннотация `prefixItems` — наибольший индекс, к которому он применился, либо
%% `true`, если он применился ко всему массиву. Аннотация `items` — всегда
%% `true`. Не применявшийся keyword аннотации не производит.
array_annotation_test_() ->
    Own = fun(Artifact, Instance) ->
                  [{valid_json_location:pointer(Keywords), Detail}
                   || #output_unit{keyword_location = Keywords, detail = Detail}
                          <- own(collect(Artifact, Instance, basic))]
          end,
    Pair = prefix_items([true, true], undefined),
    [?_assertEqual([{<<"/prefixItems">>, {annotation, 1}}], Own(Pair, [1, 2, 3])),
     ?_assertEqual([{<<"/prefixItems">>, {annotation, true}}], Own(Pair, [1, 2])),
     ?_assertEqual([{<<"/prefixItems">>, {annotation, true}}], Own(Pair, [1])),
     ?_assertEqual([{<<"/prefixItems">>, none}], Own(Pair, [])),
     ?_assertEqual([{<<"/items">>, {annotation, true}}], Own(items([]), [1])),
     ?_assertEqual([{<<"/items">>, none}], Own(items([]), [])),
     %% Хвостовому `items` применяться не к чему, а сам префикс аннотацию даёт.
     ?_assertEqual([{<<"/prefixItems">>, {annotation, true}}, {<<"/items">>, none}],
                   Own(prefix_items([true], false), [1]))].

%% `items` покрывает весь массив, `prefixItems` — свой префикс. Провалившийся
%% keyword аннотации не даёт, поэтому и покрытия не вносит.
array_coverage_test_() ->
    [?_assertEqual({[], all, []}, coverage_of(items(true), [1, 2])),
     ?_assertEqual(neutral(), coverage_of(items(false), [1])),
     ?_assertEqual({[], 2, []}, coverage_of(prefix_items([true, true], undefined), [1, 2, 3])),
     %% Схем хватило на весь массив — покрыт весь массив.
     ?_assertEqual({[], all, []}, coverage_of(prefix_items([true, true], undefined), [1, 2])),
     ?_assertEqual({[], all, []}, coverage_of(prefix_items([true], true), [1, 2, 3]))].

%% Обрыв разрешён только в режиме flag; в остальных режимах обходятся все
%% элементы, потому что дерево units должно быть полным.
array_short_circuit_test_() ->
    Artifact = prefix_items([false, tripwire()], undefined),
    [?_assertMatch({ok, #eval_result{valid = false}},
                   valid_json_eval:run(Artifact, [1, 2], flag)),
     ?_assertError({not_implemented, _}, valid_json_eval:run(Artifact, [1, 2], basic))].

%% Вердикт `contains` — хотя бы одно совпадение, и снимает это требование только
%% `minContains: 0`. Границы считают совпадения и отвечают за свои вердикты сами.
contains_test_() ->
    Integer = [{type, [integer]}],
    [?_assert(verdict(contains(Integer, undefined, undefined), [<<"a">>, 1])),
     ?_assertNot(verdict(contains(Integer, undefined, undefined), [<<"a">>])),
     ?_assertNot(verdict(contains(Integer, undefined, undefined), [])),
     ?_assert(verdict(contains(Integer, 0, undefined), [])),
     ?_assert(verdict(contains(Integer, 2, undefined), [1, <<"a">>, 2])),
     ?_assertNot(verdict(contains(Integer, 2, undefined), [1, <<"a">>])),
     ?_assert(verdict(contains(Integer, undefined, 1), [1, <<"a">>])),
     %% Совпадения считаются до конца массива: с обрывом на первом из них
     %% `maxContains` не увидел бы второго.
     ?_assertNot(verdict(contains(Integer, undefined, 1), [1, <<"a">>, 2])),
     %% Не-массив constraint не ограничивает.
     ?_assert(verdict(contains(false, undefined, undefined), 1))].

%% Собственные units выпускают все три написанных keyword'а, а units подсхемы
%% стоят под ними и несут в локации индекс элемента.
contains_units_test_() ->
    Artifact = contains([{type, [integer]}], 2, undefined),
    [?_assertEqual([{<<"/contains">>, <<>>},
                    {<<"/contains/type">>, <<"/0">>},
                    {<<"/contains/type">>, <<"/1">>},
                    {<<"/minContains">>, <<>>}],
                   paired(collect(Artifact, [1, <<"a">>], basic))),
     %% Совпадение нашлось, поэтому сам `contains` успешен, а граница — нет.
     ?_assertMatch([{<<"/contains">>, true, {annotation, [0]}}, _, _,
                    {<<"/minContains">>, false, {error, _}}],
                   printed(collect(Artifact, [1, <<"a">>], basic))),
     %% Совпали все элементы — аннотация вырождается в `true`.
     ?_assertMatch([{<<"/contains">>, true, {annotation, true}} | _],
                   printed(collect(Artifact, [1, 2], basic))),
     %% На пустом массиве аннотация обязана присутствовать. Пройти его сам
     %% `contains` может только с `minContains: 0`.
     ?_assertEqual([{<<"/contains">>, true, {annotation, []}},
                    {<<"/minContains">>, true, none}],
                   messaged(collect(contains([], 0, undefined), [], basic))),
     ?_assertEqual([{<<"/contains">>, false,
                     <<"array does not contain a matching element">>},
                    {<<"/minContains">>, false,
                     <<"array contains too few matching elements">>}],
                   messaged(collect(contains([], 2, undefined), [], basic))),
     %% Units не совпавших элементов остаются рядом диагностическими.
     ?_assertEqual([{<<"/contains">>, false,
                     <<"array does not contain a matching element">>},
                    {<<"/contains/type">>, false, <<"expected integer, got string">>}],
                   messaged(collect(contains([{type, [integer]}], undefined, undefined),
                                    [<<"a">>], basic))),
     ?_assertEqual([{<<"/contains">>, true, none}, {<<"/maxContains">>, true, none}],
                   printed(collect(contains(true, undefined, 1), 1, basic)))].

%% Разреженную часть маски порождает только `contains` и только в Draft 2020-12:
%% в Draft 2019-09 его аннотация на `unevaluatedItems` не влияет.
contains_coverage_test_() ->
    Integer = [{type, [integer]}],
    [?_assertEqual({[], 1, [2]}, coverage_of(contains(Integer, undefined, undefined),
                                             [1, <<"a">>, 2])),
     %% Совпали все элементы — покрыт весь массив.
     ?_assertEqual({[], all, []}, coverage_of(contains(Integer, undefined, undefined), [1, 2])),
     ?_assertEqual(neutral(), coverage_of(contains(Integer, undefined, undefined), [<<"a">>])),
     %% Пустой массив покрывать нечем даже при `minContains: 0`.
     ?_assertEqual(neutral(), coverage_of(contains(Integer, 0, undefined), [])),
     ?_assertEqual(neutral(), coverage_of(contains(Integer, undefined, undefined, false),
                                          [1, <<"a">>, 2]))].

%% Обрыв разрешён только в режиме flag. Ветвь-ловушка при вычислении падает,
%% поэтому её достижение видно прямо в результате.
short_circuit_test_() ->
    Failing = branching([{all_of, [addr(<<"/allOf/0">>), addr(<<"/allOf/1">>)]}],
                        [{<<"/allOf/0">>, false}, {<<"/allOf/1">>, tripwire()}]),
    Matching = branching([{any_of, [addr(<<"/anyOf/0">>), addr(<<"/anyOf/1">>)]}],
                         [{<<"/anyOf/0">>, true}, {<<"/anyOf/1">>, tripwire()}]),
    Second = branching([{one_of, [addr(<<"/oneOf/0">>), addr(<<"/oneOf/1">>),
                                  addr(<<"/oneOf/2">>)]}],
                       [{<<"/oneOf/0">>, true}, {<<"/oneOf/1">>, true},
                        {<<"/oneOf/2">>, tripwire()}]),
    [?_assertMatch({ok, #eval_result{valid = false}},
                   valid_json_eval:run(Failing, 1, flag)),
     ?_assertMatch({ok, #eval_result{valid = true}},
                   valid_json_eval:run(Matching, 1, flag)),
     ?_assertMatch({ok, #eval_result{valid = false}},
                   valid_json_eval:run(Second, 1, flag)),
     %% В basic дерево units должно быть полным, поэтому обходятся все ветви.
     ?_assertError({not_implemented, _}, valid_json_eval:run(Failing, 1, basic))].

%% Applicator выпускает собственный unit написанного keyword, а units ветвей
%% стоят под ним и несут в локации индекс ветви.
applicator_units_test_() ->
    Listed = branching([{any_of, [addr(<<"/anyOf/0">>), addr(<<"/anyOf/1">>)]}],
                       [{<<"/anyOf/0">>, false}, {<<"/anyOf/1">>, [{type, [string]}]}]),
    Negated = branching([{'not', addr(<<"/not">>)}], [{<<"/not">>, [{const, 1}]}]),
    [?_assertMatch([{<<"/anyOf">>, false, {error, _}},
                    {<<"/anyOf/1/type">>, false, {error, _}}],
                   printed(collect(Listed, 1, basic))),
     %% Units опровергнутой внутренней схемы остаются диагностическими.
     ?_assertMatch([{<<"/not">>, false, {error, _}},
                    {<<"/not/const">>, true, none}],
                   printed(collect(Negated, 1, basic))),
     %% Ветвь-boolean своих keywords не имеет, поэтому сообщение несёт её
     %% собственный unit — и в плоскую проекцию он попадает наравне с keywords.
     ?_assertMatch([#{<<"keywordLocation">> := <<"/anyOf">>},
                    #{<<"keywordLocation">> := <<"/anyOf/0">>, <<"error">> := _},
                    #{<<"keywordLocation">> := <<"/anyOf/1/type">>}],
                   errors(Listed, 1))].

%% Абсолютная локация выводится из адреса node, а не накапливается обходом,
%% поэтому у названного resource она появляется сама и печатается вместе с unit.
absolute_test_() ->
    Assertion = schema_node([{type, [string]}]),
    [?_assertEqual([undefined], absolute(artifact(Assertion), 1)),
     ?_assertEqual([{?RESOURCE, [<<"type">>]}], absolute(named(Assertion), 1)),
     %% У boolean-схемы собственного сегмента нет: она стоит в корне resource,
     %% и keywords, к чьим units можно было бы приглядеться, у неё тоже нет.
     ?_assertEqual({?RESOURCE, []},
                   (node_unit(named(false), 1))#output_unit.absolute_location),
     ?_assertEqual(<<"https://example.com/s#/type">>,
                   printed_absolute(named(Assertion), 1)),
     %% У вложенного node указатель непустой, и путь внутри resource берётся
     %% из него, а не из накопленной локации обхода.
     ?_assertEqual([{?RESOURCE, [<<"allOf">>]},
                    {?RESOURCE, [<<"type">>, <<"0">>, <<"allOf">>]}],
                   absolute(nested_named(), 1)),
     ?_assertEqual(<<"https://example.com/s#/allOf/0/type">>,
                   valid_json_location:fragment({?RESOURCE, [<<"type">>, <<"0">>,
                                                             <<"allOf">>]}))].

%% Названный resource с дочерним node: ветвь адресуется тем же rid.
nested_named() ->
    named_tree(#{<<>>           => schema_node([{all_of, [{?RESOURCE, <<"/allOf/0">>}]}]),
                 <<"/allOf/0">> => schema_node([{type, [string]}])}).

%% Сообщение называет нарушенное требование. Оно не влияет на вердикт, поэтому
%% проверяется отдельно от него.
message_test_() ->
    [?_assertEqual(<<"expected string, got integer">>, message({type, [string]}, 1)),
     ?_assertEqual(<<"expected string, got number">>, message({type, [string]}, 1.5)),
     ?_assertEqual(<<"expected integer or null, got array">>,
                   message({type, [integer, null]}, [])),
     ?_assertEqual(<<"expected no type, got boolean">>, message({type, []}, true)),
     ?_assertEqual(<<"value is not a multiple of 0.0001">>,
                   message({multiple_of, 0.0001}, 0.00751)),
     ?_assertEqual(<<"value is greater than the maximum 4">>, message({maximum, 4}, 5)),
     ?_assertEqual(<<"string is longer than 2 characters">>,
                   message({max_length, 2}, <<"abc">>)),
     ?_assertEqual(<<"string does not match pattern ^a+$">>,
                   message({pattern, regex(<<"^a+$">>)}, <<"b">>)),
     ?_assertEqual(<<"array items are not unique">>, message({unique_items, true}, [1, 1])),
     %% Отсутствующие имена называются поимённо, а присутствующие не называются.
     ?_assertEqual(<<"object is missing required property \"b\"">>,
                   message({required, [<<"a">>, <<"b">>]}, #{<<"a">> => 1})),
     ?_assertEqual(<<"object is missing required properties \"a\", \"b\"">>,
                   message({required, [<<"a">>, <<"b">>]}, #{})),
     ?_assertEqual(<<"object is missing required property \"foo\"">>,
                   message({dependent_required, #{<<"bar">> => [<<"foo">>]}},
                           #{<<"bar">> => 1}))].

%% Публичный вызов доводит дерево units до плоской проекции basic.
basic_output_test_() ->
    Schema = schema_node([{type, [string]}, {min_length, 2}]),
    [?_assertEqual({ok, #{<<"valid">>            => true,
                          <<"keywordLocation">>  => <<>>,
                          <<"instanceLocation">> => <<>>,
                          <<"annotations">>      => []}},
                   basic(Schema, <<"ab">>)),
     ?_assertEqual({ok, #{<<"valid">>            => false,
                          <<"keywordLocation">>  => <<>>,
                          <<"instanceLocation">> => <<>>,
                          <<"errors">> =>
                              [#{<<"valid">>            => false,
                                 <<"keywordLocation">>  => <<"/type">>,
                                 <<"instanceLocation">> => <<>>,
                                 <<"error">> => <<"expected string, got integer">>}]}},
                   basic(Schema, 1)),
     %% Корнем проекции служит собственный unit node. У boolean-схемы это
     %% единственный unit вообще, поэтому её сообщение стоит прямо в корне, а
     %% список остаётся пустым.
     ?_assertEqual({ok, #{<<"valid">>            => false,
                          <<"keywordLocation">>  => <<>>,
                          <<"instanceLocation">> => <<>>,
                          <<"error">>            => <<"schema is false">>,
                          <<"errors">>           => []}},
                   basic(false, 1))].

%% Провалившаяся ветвь свои units сохраняет, но аннотации из неё в плоскую
%% проекцию не выходят: провалившийся schema object не производит аннотаций ни
%% своими keywords, ни keywords своих подсхем.
dropped_annotation_test_() ->
    Covering = [{properties, #{<<"a">> => addr(<<"/anyOf/0/properties/a">>)}, undefined,
                 undefined},
                {type, [string]}],
    Artifact = branching([{any_of, [addr(<<"/anyOf/0">>), addr(<<"/anyOf/1">>)]}],
                         [{<<"/anyOf/0">>, Covering},
                          {<<"/anyOf/0/properties/a">>, true},
                          {<<"/anyOf/1">>, true}]),
    Instance = #{<<"a">> => 1},
    [?_assertEqual({ok, #{<<"valid">>            => true,
                          <<"keywordLocation">>  => <<>>,
                          <<"instanceLocation">> => <<>>,
                          <<"annotations">>      => []}},
                   valid_json:validate(Artifact, Instance, [{output, basic}])),
     %% В дереве units аннотация остаётся: её показывает verbose.
     ?_assertEqual([{<<"/anyOf">>, true, none},
                    {<<"/anyOf/0/properties">>, true, {annotation, [<<"a">>]}},
                    {<<"/anyOf/0/type">>, false,
                     {error, <<"expected string, got object">>}}],
                   printed(collect(Artifact, Instance, basic)))].

%% Публичный результат — JSON выбранного формата; valid = false остаётся ok.
flag_output_test_() ->
    [?_assertEqual({ok, #{<<"valid">> => true}},
                   validate(schema_node([{type, [string]}]), <<"a">>)),
     ?_assertEqual({ok, #{<<"valid">> => false}},
                   validate(schema_node([{type, [string]}]), 1))].

valid(Constraints, Instance) ->
    {ok, #eval_result{valid = Valid}} = run(schema_node(Constraints), Instance),
    Valid.

%% Локация печатается прямо в тесте: обратный стек сегментов читается хуже, чем
%% готовый указатель, а его построение проверено отдельно.
located(Node, Instance) when is_boolean(Node) ->
    printed(units(Node, Instance, basic));
located(Constraints, Instance) ->
    printed(units(Constraints, Instance, basic)).

printed(Units) ->
    [shown(Unit) || Unit <- keywords(Units)].

shown(#output_unit{valid = Valid, keyword_location = Keywords, detail = Detail}) ->
    {valid_json_location:pointer(Keywords), Valid, Detail}.

%% Уровни дерева чередуются: под unit'ом node лежат units его keywords, под
%% unit'ом keyword — units применённых им nodes. Проверкам нужны первые, поэтому
%% уровень nodes разворачивается насквозь.
keywords([])      -> [];
keywords([Root])  -> from_node(Root).

from_node(#output_unit{nested = Keywords}) ->
    lists:append([[Unit | from_keyword(Unit)] || Unit <- Keywords]).

from_keyword(#output_unit{nested = Nodes}) ->
    lists:append([from_node(Node) || Node <- Nodes]).

%% Units самих keywords — прямые дети unit'а node: units их ветвей лежат глубже
%% и говорят о своих значениях, а не о применении.
own([#output_unit{nested = Keywords}]) -> Keywords.

%% Собственный unit node: он один, потому что вычисление начинается от корня.
node_unit(Node, Instance) ->
    [Unit] = units(Node, Instance, basic),
    Unit.

units(Node, Instance, Format) when is_boolean(Node); is_map(Node) ->
    collect(Node, Instance, Format);
units(Constraints, Instance, Format) ->
    collect(schema_node(Constraints), Instance, Format).

collect(Node, Instance, Format) when is_map(Node) ->
    {ok, #eval_result{units = Units}} = valid_json_eval:run(Node, Instance, Format),
    Units;
collect(Node, Instance, Format) ->
    collect(artifact(Node), Instance, Format).

%% Ветви списочного applicator адресуются по индексу, как их кладёт компилятор,
%% поэтому фикстуре достаточно перечислить сами дочерние schemas.
branches(Tag, Keyword, Children, Instance) ->
    Pointers = [<<"/", Keyword/binary, "/", (integer_to_binary(Index))/binary>>
                || Index <- lists:seq(0, length(Children) - 1)],
    Artifact = branching([{Tag, [addr(Pointer) || Pointer <- Pointers]}],
                         lists:zip(Pointers, Children)),
    {ok, #eval_result{valid = Valid}} = valid_json_eval:run(Artifact, Instance, flag),
    Valid.

%% Составной object constraint со всеми тремя написанными keywords: "a" берёт
%% properties, имена на "b" — паттерн, остальные — additionalProperties.
object() ->
    branching([{properties,
                #{<<"a">> => addr(<<"/properties/a">>)},
                [{regex(<<"^b">>), addr(<<"/patternProperties/^b">>)}],
                addr(<<"/additionalProperties">>)}],
              [{<<"/properties/a">>, [{type, [integer]}]},
               {<<"/patternProperties/^b">>, [{type, [string]}]},
               {<<"/additionalProperties">>, [{type, [integer]}]}]).

%% Своего сегмента у ветви нет: она стоит на самом keyword, поэтому фикстуре
%% достаточно одной дочерней schema.
property_names(Child) ->
    branching([{property_names, addr(<<"/propertyNames">>)}],
              [{<<"/propertyNames">>, Child}]).

%% Зависимости адресуются по имени свойства, как их кладёт компилятор, поэтому
%% фикстуре достаточно пар «имя — дочерняя schema».
dependent_schemas(Deps) ->
    Pointer = fun(Name) -> <<"/dependentSchemas/", Name/binary>> end,
    Addrs = maps:from_list([{Name, addr(Pointer(Name))} || {Name, _Child} <- Deps]),
    branching([{dependent_schemas, Addrs}],
              [{Pointer(Name), Child} || {Name, Child} <- Deps]).

%% Своего сегмента у ветви нет: она стоит на самом keyword.
items(Child) ->
    branching([{items, addr(<<"/items">>)}], [{<<"/items">>, Child}]).

%% Схемы префикса адресуются по индексу, как их кладёт компилятор, а хвостовой
%% `items` стоит на собственном keyword и задаётся `undefined`, если не написан.
prefix_items(Children, Tail) ->
    Pointer = fun(Index) -> <<"/prefixItems/", (integer_to_binary(Index))/binary>> end,
    Prefix = lists:enumerate(0, Children),
    branching([{prefix_items, [addr(Pointer(Index)) || {Index, _Child} <- Prefix],
                slot(<<"/items">>, Tail)}],
              [{Pointer(Index), Child} || {Index, Child} <- Prefix]
              ++ [{<<"/items">>, Tail} || Tail =/= undefined]).

contains(Child, Min, Max) ->
    contains(Child, Min, Max, true).

%% Последнее поле — покрывает ли keyword индексы: решение принято компилятором по
%% dialect, и evaluator читает его как данные.
contains(Child, Min, Max, Marks) ->
    branching([{contains, addr(<<"/contains">>), Min, Max, Marks}],
              [{<<"/contains">>, Child}]).

%% Составной условный constraint: каждая ветвь стоит на своём keyword, а
%% ненаписанная задаётся `undefined` и в артефакт не попадает.
conditional(If, Then, Else) ->
    Slots = [{<<"/if">>, If}, {<<"/then">>, Then}, {<<"/else">>, Else}],
    branching([{if_then_else, addr(<<"/if">>), slot(<<"/then">>, Then),
                slot(<<"/else">>, Else)}],
              [Slot || {_Pointer, Child} = Slot <- Slots, Child =/= undefined]).

slot(_Pointer, undefined) -> undefined;
slot(Pointer, _Child)     -> addr(Pointer).

verdict(Artifact, Instance) ->
    {ok, #eval_result{valid = Valid}} = valid_json_eval:run(Artifact, Instance, flag),
    Valid.

coverage_of(Artifact, Instance) ->
    {ok, #eval_result{evaluated = Evaluated}} = valid_json_eval:run(Artifact, Instance, flag),
    expand(Evaluated).

%% Обе локации сразу: keyword следует схеме, инстанс — значению.
paired(Units) ->
    [{valid_json_location:pointer(Keywords), valid_json_location:pointer(Instance)}
     || #output_unit{keyword_location = Keywords, instance_location = Instance}
            <- keywords(Units)].

negated(Child, Instance) ->
    Artifact = branching([{'not', addr(<<"/not">>)}], [{<<"/not">>, Child}]),
    {ok, #eval_result{valid = Valid}} = valid_json_eval:run(Artifact, Instance, flag),
    Valid.

branching(Constraints, Children) ->
    Nodes = maps:from_list([{Pointer, child(Child)} || {Pointer, Child} <- Children]),
    tree(Nodes#{<<>> => schema_node(Constraints)}).

%% Дочерняя schema задаётся списком constraints, boolean или готовым node.
child(Node) when is_boolean(Node) -> Node;
child(#node{} = Node)             -> Node;
child(Constraints)                -> schema_node(Constraints).

addr(Pointer) ->
    {anonymous, Pointer}.

%% Node, вычисление которого падает: он показывает, дошёл ли обход до ветви.
tripwire() ->
    #node{constraints = [], unevaluated = [{unevaluated_items, addr(<<>>)}]}.

absolute(Artifact, Instance) ->
    {ok, #eval_result{units = Units}} = valid_json_eval:run(Artifact, Instance, basic),
    [Location || #output_unit{absolute_location = Location} <- keywords(Units)].

%% Проекция печатает ту же локацию отдельным ключом.
printed_absolute(Artifact, Instance) ->
    {ok, #{<<"errors">> := [Unit]}} =
        valid_json:validate(Artifact, Instance, [{output, basic}]),
    maps:get(<<"absoluteKeywordLocation">>, Unit).

%% Сообщение существует только у провалившегося constraint, поэтому берётся из
%% его же unit.
message(Constraint, Instance) ->
    [{_Location, false, {error, Message}}] = located([Constraint], Instance),
    Message.

basic(Node, Instance) ->
    valid_json:validate(artifact(Node), Instance, [{output, basic}]).

%% Плоский список провалов уже готовой проекции: он показывает, что до неё
%% дошло, а что осталось только в дереве.
errors(Artifact, Instance) ->
    {ok, #{<<"errors">> := Errors}} =
        valid_json:validate(Artifact, Instance, [{output, basic}]),
    Errors.

coverage(Constraints, Instance) ->
    {ok, #eval_result{evaluated = Evaluated}} = run(schema_node(Constraints), Instance),
    expand(Evaluated).

run(Node, Instance) ->
    valid_json_eval:run(artifact(Node), Instance, flag).

validate(Node, Instance) ->
    valid_json:validate(artifact(Node), Instance, [{output, flag}]).

%% Сообщение провалившегося keyword рядом с его локацией: у успеха деталей может
%% не быть вовсе, поэтому оно печатается только там, где есть.
messaged(Units) ->
    [{Pointer, Valid, detail(Detail)} || {Pointer, Valid, Detail} <- printed(Units)].

detail({error, Message}) -> Message;
detail(Detail)           -> Detail.

%% `all` — покрыт весь массив; отдельного префикса и разреженной части у такой
%% маски нет.
expand(#{properties := Properties, items := all}) ->
    {lists:sort(sets:to_list(Properties)), all, []};
expand(#{properties := Properties, items := {Prefix, Sparse}}) ->
    {lists:sort(sets:to_list(Properties)), Prefix, lists:sort(sets:to_list(Sparse))}.

neutral() -> {[], 0, []}.

schema_node(Constraints) ->
    #node{constraints = Constraints, unevaluated = []}.

%% Опции повторяют validator-core.md: якорения нет, режим Unicode включён.
regex(Source) ->
    {ok, Compiled} = re:compile(Source, [unicode, dollar_endonly]),
    {Source, Compiled}.

artifact(Node) ->
    artifact(anonymous, undefined, Node).

%% Названный resource нужен ради абсолютной локации: у анонимного её нет.
named(Node) ->
    artifact(?RESOURCE, ?RESOURCE, Node).

artifact(Rid, Id, Node) ->
    tree(Rid, Id, #{<<>> => Node}).

%% Артефакт с дочерними nodes: подсхемы лежат в той же map под своими
%% указателями, как их кладёт компилятор.
tree(Nodes) ->
    tree(anonymous, undefined, Nodes).

named_tree(Nodes) ->
    tree(?RESOURCE, ?RESOURCE, Nodes).

tree(Rid, Id, Nodes) ->
    #{root      => Rid,
      sources   => [],
      resources => #{Rid =>
          #resource{id               = Id,
                    dialect          = ?DIALECT,
                    anchors          = #{},
                    dynamic_anchors  = #{},
                    recursive_anchor = false,
                    nodes            = Nodes}}}.
