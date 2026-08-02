%% Evaluator fixtures поверх вручную собранного compiled(): результат проверяется
%% до проекции в JSON, чтобы слои не сливались в один end-to-end вердикт.
-module(valid_json_eval_tests).

-include_lib("eunit/include/eunit.hrl").
-include("valid_json_core.hrl").

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

%% Boolean-схема сегмента не добавляет: она стоит там же, где схема.
boolean_units_test_() ->
    [?_assertEqual([{<<>>, true, none}], located(true, 1)),
     ?_assertMatch([{<<>>, false, {error, _}}], located(false, 1))].

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
    Own = [<<"/properties">>, <<"/patternProperties">>, <<"/additionalProperties">>],
    Details = fun(Instance) ->
                      [{Pointer, Detail}
                       || #output_unit{keyword_location = Keywords, detail = Detail}
                              <- collect(object(), Instance, basic),
                          Pointer <- [valid_json_location:pointer(Keywords)],
                          lists:member(Pointer, Own)]
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
                    {<<"/anyOf/0">>, false, {error, _}},
                    {<<"/anyOf/1/type">>, false, {error, _}}],
                   printed(collect(Listed, 1, basic))),
     %% Units опровергнутой внутренней схемы остаются диагностическими.
     ?_assertMatch([{<<"/not">>, false, {error, _}},
                    {<<"/not/const">>, true, none}],
                   printed(collect(Negated, 1, basic)))].

%% Абсолютная локация выводится из адреса node, а не накапливается обходом,
%% поэтому у названного resource она появляется сама и печатается вместе с unit.
absolute_test_() ->
    Assertion = schema_node([{type, [string]}]),
    [?_assertEqual([undefined], absolute(artifact(Assertion), 1)),
     ?_assertEqual([{?RESOURCE, [<<"type">>]}], absolute(named(Assertion), 1)),
     %% У boolean-схемы собственного сегмента нет: она стоит в корне resource.
     ?_assertEqual([{?RESOURCE, []}], absolute(named(false), 1)),
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
     %% Провалившаяся boolean-схема тоже обязана дать непустой errors.
     ?_assertMatch({ok, #{<<"valid">> := false, <<"errors">> := [_]}},
                   basic(false, 1))].

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
    [{valid_json_location:pointer(Keywords), Valid, Detail}
     || #output_unit{valid = Valid, keyword_location = Keywords,
                     detail = Detail} <- Units].

units(Node, Instance, Format) when is_boolean(Node) ->
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
     || #output_unit{keyword_location = Keywords, instance_location = Instance} <- Units].

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
    [Location || #output_unit{absolute_location = Location} <- Units].

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

coverage(Constraints, Instance) ->
    {ok, #eval_result{evaluated = Evaluated}} = run(schema_node(Constraints), Instance),
    expand(Evaluated).

run(Node, Instance) ->
    valid_json_eval:run(artifact(Node), Instance, flag).

validate(Node, Instance) ->
    valid_json:validate(artifact(Node), Instance, [{output, flag}]).

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
