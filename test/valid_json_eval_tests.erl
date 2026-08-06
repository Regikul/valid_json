%% Evaluator fixtures поверх вручную собранного compiled(): результат проверяется
%% до проекции в JSON, чтобы слои не сливались в один end-to-end вердикт.
-module(valid_json_eval_tests).

-include_lib("eunit/include/eunit.hrl").
-include("valid_json_core.hrl").

%% Тесты модуля независимы, поэтому eunit прогоняет их параллельно.
eunit_wrapper_(Tests) -> {inparallel, Tests}.

-define(DIALECT, <<"https://json-schema.org/draft/2020-12/schema">>).
-define(LEGACY, <<"https://json-schema.org/draft/2019-09/schema">>).
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

%% Annotation-only keyword выпускает успешный unit со своим значением и не
%% трогает ни вердикт, ни покрытие. Instance ему безразличен: он описывает
%% позицию, а не значение, и значение отдаётся целиком, каким бы ни было.
annotation_test_() ->
    Deprecated = {annotation, <<"deprecated">>, true},
    [?_assertEqual([{<<"/deprecated">>, true, {annotation, true}}],
                   located([Deprecated], 1)),
     ?_assertEqual([{<<"/title">>, true, {annotation, <<"t">>}}],
                   located([{annotation, <<"title">>, <<"t">>}], #{<<"a">> => 1})),
     ?_assertEqual([{<<"/examples">>, true, {annotation, [1, null]}}],
                   located([{annotation, <<"examples">>, [1, null]}], <<"a">>)),
     ?_assertEqual({ok, #{<<"valid">> => true}}, validate(schema_node([Deprecated]), 1)),
     ?_assertEqual(neutral(), coverage([Deprecated], 1)),
     ?_assertEqual([], units([Deprecated], 1, flag))].

%% Аннотирующий `format` ведёт себя как annotation-only keyword: аннотацией
%% становится само имя формата, вердикт всегда успешен, покрытия нет. Незнакомое
%% имя собирается наравне со стандартным — валидатор из-за него не отказывает.
format_test_() ->
    Email = {format, <<"email">>, false},
    [?_assertEqual([{<<"/format">>, true, {annotation, <<"email">>}}],
                   located([Email], <<"not an email">>)),
     ?_assertEqual([{<<"/format">>, true, {annotation, <<"custom-name">>}}],
                   located([{format, <<"custom-name">>, false}], 1)),
     ?_assertEqual({ok, #{<<"valid">> => true}},
                   validate(schema_node([Email]), <<"not an email">>)),
     ?_assertEqual(neutral(), coverage([Email], <<"a">>)),
     ?_assertEqual([], units([Email], <<"a">>, flag))].

%% Assertion добавляется к annotation, а не заменяет её: успешная проверка
%% оставляет тот же unit с именем формата. Проверяются только строки, а имя вне
%% таблицы algorithms проверять нечем, поэтому и другой тип, и незнакомое имя
%% остаются успешной аннотацией. Покрытия assertion не вносит, как и annotation.
format_assertion_test_() ->
    Ipv4 = {format, <<"ipv4">>, true},
    [?_assertEqual([{<<"/format">>, true, {annotation, <<"ipv4">>}}],
                   located([Ipv4], <<"127.0.0.1">>)),
     ?_assertMatch([{<<"/format">>, false, {error, _}}],
                   located([Ipv4], <<"not-an-ipv4">>)),
     ?_assertEqual([{<<"/format">>, true, {annotation, <<"ipv4">>}}],
                   located([Ipv4], 1)),
     ?_assertEqual([{<<"/format">>, true, {annotation, <<"custom-name">>}}],
                   located([{format, <<"custom-name">>, true}], <<"anything">>)),
     ?_assertEqual({ok, #{<<"valid">> => true}},
                   validate(schema_node([Ipv4]), <<"127.0.0.1">>)),
     ?_assertEqual({ok, #{<<"valid">> => false}},
                   validate(schema_node([Ipv4]), <<"not-an-ipv4">>)),
     ?_assertEqual(neutral(), coverage([Ipv4], <<"127.0.0.1">>)),
     %% В flag вердикт есть, а units нет: assertion меняет ответ, а не
     %% диагностику.
     ?_assertEqual([], units([Ipv4], <<"not-an-ipv4">>, flag))].

%% Content keywords аннотируют только строку и никогда не отказывают: испорченное
%% содержимое остаётся валидным, потому что декодировать и разбирать его по
%% умолчанию нельзя. Значение `contentSchema` отдаётся аннотацией целиком, а к
%% instance подсхема не применяется вовсе.
content_test_() ->
    Encoding = {content, <<"contentEncoding">>, <<"base64">>},
    Media = {content, <<"contentMediaType">>, <<"application/json">>},
    Inner = #{<<"type">> => <<"object">>},
    [?_assertEqual([{<<"/contentEncoding">>, true, {annotation, <<"base64">>}}],
                   located([Encoding], <<"eyJmb28iOi%iYmFyIn0K">>)),
     ?_assertEqual([{<<"/contentMediaType">>, true,
                     {annotation, <<"application/json">>}}],
                   located([Media], <<"{:}">>)),
     ?_assertEqual([{<<"/contentSchema">>, true, {annotation, Inner}}],
                   located([{content, <<"contentSchema">>, Inner}], <<"[]">>)),
     ?_assertEqual({ok, #{<<"valid">> => true}},
                   validate(schema_node([Encoding, Media]), <<"{:}">>)),
     ?_assertEqual(neutral(), coverage([Encoding], <<"a">>)),
     ?_assertEqual([], units([Encoding], <<"a">>, flag))].

%% Значение другого типа content keyword не описывает: unit остаётся успешным,
%% но annotation не выпускает — то же правило применимости, что и у assertions
%% над своим типом.
content_applicability_test_() ->
    Media = {content, <<"contentMediaType">>, <<"application/json">>},
    [?_assertEqual([{<<"/contentMediaType">>, true, none}], located([Media], 100)),
     ?_assertEqual([{<<"/contentMediaType">>, true, none}],
                   located([Media], #{<<"a">> => <<"{}">>})),
     ?_assertEqual({ok, #{<<"valid">> => true}}, validate(schema_node([Media]), 100)),
     ?_assertEqual(neutral(), coverage([Media], 100))].

%% В basic аннотация доходит до плоского списка, а провал соседнего keyword
%% уносит её оттуда: тот же schema object перестаёт производить аннотации.
%% Из дерева она не исчезает — её показывает verbose.
annotation_projection_test_() ->
    Node = schema_node([{type, [string]}, {annotation, <<"title">>, <<"t">>}]),
    [?_assertEqual({ok, #{<<"valid">>            => true,
                          <<"keywordLocation">>  => <<>>,
                          <<"instanceLocation">> => <<>>,
                          <<"annotations">>      =>
                              [#{<<"valid">>            => true,
                                 <<"keywordLocation">>  => <<"/title">>,
                                 <<"instanceLocation">> => <<>>,
                                 <<"annotation">>       => <<"t">>}]}},
                   basic(Node, <<"a">>)),
     ?_assertMatch([#{<<"keywordLocation">> := <<"/type">>}], errors(artifact(Node), 1)),
     ?_assertMatch([{<<"/type">>, false, _}, {<<"/title">>, true, {annotation, <<"t">>}}],
                   located([{type, [string]}, {annotation, <<"title">>, <<"t">>}], 1))].

%% Разрешение адреса в готовом артефакте тотально: каждый указатель выбирает
%% ровно свой node, а корень resource стоит под пустым указателем.
resolve_test_() ->
    Root = schema_node([{all_of, [addr(<<"/allOf/0">>)]}]),
    Child = schema_node([{type, [string]}]),
    Artifact = tree(#{<<>> => Root, <<"/allOf/0">> => Child, <<"/allOf/1">> => false}),
    [?_assertEqual(Root, valid_json_eval:resolve(addr(<<>>), Artifact)),
     ?_assertEqual(Child, valid_json_eval:resolve(addr(<<"/allOf/0">>), Artifact)),
     ?_assertEqual(false, valid_json_eval:resolve(addr(<<"/allOf/1">>), Artifact))].

%% `$ref` применяет canonical target к тому же instance и переносит его
%% verdict/coverage без повторного URI resolution в evaluator.
ref_test_() ->
    Target = addr(<<"/$defs/value">>),
    Integer = ref_tree([{type, [integer]}]),
    Covering = tree(
                 #{<<>> => schema_node([{ref, Target}]),
                   <<"/$defs/value">> =>
                       schema_node([{properties,
                                     #{<<"a">> => addr(
                                                    <<"/$defs/value/properties/a">>)},
                                     undefined, undefined}]),
                   <<"/$defs/value/properties/a">> => true}),
    [?_assert(verdict(Integer, 1)),
     ?_assertNot(verdict(Integer, <<"1">>)),
     ?_assertEqual({[<<"a">>], 0, []},
                   coverage_of(Covering, #{<<"a">> => 1}))].

%% Guard хранит active frame, а не множество когда-либо посещённых адресов:
%% self-reference останавливается, два последовательных перехода к одной цели
%% разрешены.
ref_cycle_guard_test_() ->
    Self = artifact(schema_node([{ref, addr(<<>>)}])),
    Target = addr(<<"/$defs/value">>),
    Repeated = tree(
                 #{<<>> => schema_node([{ref, Target}, {ref, Target}]),
                   <<"/$defs/value">> => true}),
    [?_assertEqual({error, {no_progress, addr(<<>>)}},
                   valid_json_eval:run(Self, 1, flag)),
     ?_assertMatch({ok, #eval_result{valid = true}},
                   valid_json_eval:run(Repeated, 1, flag))].

%% keywordLocation продолжает syntactic path через `/$ref`, а absolute location
%% ref unit и target keywords строится от target resource.
ref_location_test() ->
    Source = <<"https://example.com/source">>,
    Target = <<"https://example.com/target">>,
    TargetAddr = {Target, <<"/$defs/value">>},
    Artifact =
        #{root => Source,
          sources => [],
          resources =>
              #{Source => #resource{id = Source, dialect = ?DIALECT,
                                     anchors = #{}, dynamic_anchors = #{},
                                     recursive_anchor = false,
                                     nodes = #{<<>> => schema_node([{ref, TargetAddr}])}},
                Target => #resource{id = Target, dialect = ?DIALECT,
                                     anchors = #{}, dynamic_anchors = #{},
                                     recursive_anchor = false,
                                     nodes =
                                         #{<<"/$defs/value">> =>
                                               schema_node([{type, [string]}])}}}},
    [RootUnit] = collect(Artifact, 1, basic),
    [RefUnit] = RootUnit#output_unit.nested,
    [TargetUnit] = RefUnit#output_unit.nested,
    [TypeUnit] = TargetUnit#output_unit.nested,
    ?assertEqual([<<"$ref">>], RefUnit#output_unit.keyword_location),
    ?assertEqual({Source, [<<"$ref">>]},
                 RefUnit#output_unit.absolute_location),
    ?assertEqual([<<"type">>, <<"$ref">>],
                 TypeUnit#output_unit.keyword_location),
    ?assertEqual({Target, [<<"type">>, <<"value">>, <<"$defs">>]},
                 TypeUnit#output_unit.absolute_location).

%% Имя ищется по dynamic scope, и побеждает самый внешний resource, который его
%% объявил: внутренняя цель переопределяется внешней (core.txt, 8.2.3.2).
dynamic_ref_override_test_() ->
    Artifact = dynamic_tree(#{<<"item">> => <<"/$defs/item">>}),
    [?_assert(verdict(Artifact, 1)),
     ?_assertNot(verdict(Artifact, <<"x">>))].

%% Ни один resource dynamic scope имени не объявил — остаётся лексическая цель,
%% проверенная компилятором.
dynamic_ref_fallback_test_() ->
    Artifact = dynamic_tree(#{<<"other">> => <<"/$defs/item">>}),
    [?_assertNot(verdict(Artifact, 1)),
     ?_assert(verdict(Artifact, <<"x">>))].

%% Уровней в scope может быть больше двух, и средний не заслоняет внешний.
dynamic_ref_outermost_test_() ->
    Middle = <<"https://example.com/middle">>,
    Inner = <<"https://example.com/inner">>,
    Artifact =
        #{root => ?RESOURCE,
          sources => [],
          resources =>
              #{?RESOURCE =>
                    dynamic_resource(?RESOURCE, #{<<"item">> => <<"/$defs/item">>},
                                     #{<<>> => schema_node([{ref, {Middle, <<>>}}]),
                                       <<"/$defs/item">> =>
                                           schema_node([{type, [integer]}])}),
                Middle =>
                    dynamic_resource(Middle, #{<<"item">> => <<"/$defs/item">>},
                                     #{<<>> => schema_node([{ref, {Inner, <<>>}}]),
                                       <<"/$defs/item">> =>
                                           schema_node([{type, [boolean]}])}),
                Inner =>
                    dynamic_resource(Inner, #{<<"item">> => <<"/$defs/item">>},
                                     #{<<>> => schema_node(
                                                 [{dynamic_ref, <<"item">>,
                                                   {Inner, <<"/$defs/item">>}}]),
                                       <<"/$defs/item">> =>
                                           schema_node([{type, [string]}])})}},
    [?_assert(verdict(Artifact, 1)),
     ?_assertNot(verdict(Artifact, true)),
     ?_assertNot(verdict(Artifact, <<"x">>))].

%% Цель после разрешения ничем не отличается от цели `$ref`: она входит в тот же
%% cycle guard, а keyword location продолжает путь через собственный сегмент.
dynamic_ref_cycle_test() ->
    Self = #{root => ?RESOURCE,
             sources => [],
             resources =>
                 #{?RESOURCE =>
                       dynamic_resource(?RESOURCE, #{<<"loop">> => <<>>},
                                        #{<<>> => schema_node(
                                                    [{dynamic_ref, <<"loop">>,
                                                      {?RESOURCE, <<>>}}])})}},
    ?assertEqual({error, {no_progress, {?RESOURCE, <<>>}}},
                 valid_json_eval:run(Self, 1, flag)).

%% Reference unit называет physical location написанного keyword; вложенный
%% target schema unit отдельно несёт каноническую разрешённую цель.
dynamic_ref_location_test() ->
    Artifact = dynamic_tree(#{<<"item">> => <<"/$defs/item">>}),
    [RootUnit] = collect(Artifact, <<"x">>, basic),
    [RefUnit] = RootUnit#output_unit.nested,
    [InnerUnit] = RefUnit#output_unit.nested,
    [DynamicUnit] = InnerUnit#output_unit.nested,
    ?assertEqual([<<"$dynamicRef">>, <<"$ref">>],
                 DynamicUnit#output_unit.keyword_location),
    ?assertEqual({<<"https://example.com/inner">>, [<<"$dynamicRef">>]},
                 DynamicUnit#output_unit.absolute_location).

%% Лексическая цель помечена, поэтому recursive reference выбирает самый
%% внешний помеченный resource. Внешнее `required` применяется и к `next`.
recursive_ref_override_test_() ->
    Artifact = recursive_tree(true, true),
    [?_assertNot(verdict(Artifact,
                         #{<<"outer">> => true, <<"next">> => #{}})),
     ?_assert(verdict(Artifact,
                      #{<<"outer">> => true,
                        <<"next">> => #{<<"outer">> => true}}))].

%% Непомеченная лексическая цель запрещает переигрывать ссылку, даже если во
%% внешнем scope есть recursive anchor.
recursive_ref_fallback_test() ->
    Artifact = recursive_tree(true, false),
    ?assert(verdict(Artifact,
                    #{<<"outer">> => true, <<"next">> => #{}})).

%% Три resource в scope: внутренний и средний помечены, но победить обязан
%% внешний. `next` только с middle прошёл бы при ошибочном выборе средней цели.
recursive_ref_outermost_test_() ->
    Artifact = recursive_outermost_tree(),
    Root = #{<<"outer">> => true, <<"middle">> => true},
    [?_assertNot(verdict(Artifact,
                         Root#{<<"next">> => #{<<"middle">> => true}})),
     ?_assert(verdict(
                Artifact,
                Root#{<<"next">> => #{<<"outer">> => true,
                                         <<"middle">> => true}}))].

recursive_ref_cycle_test() ->
    Artifact = #{root => ?RESOURCE,
                 sources => [],
                 resources =>
                     #{?RESOURCE =>
                           recursive_resource(
                             ?RESOURCE, true,
                             #{<<>> => schema_node(
                                         [{recursive_ref, {?RESOURCE, <<>>}}])})}},
    ?assertEqual({error, {no_progress, {?RESOURCE, <<>>}}},
                 valid_json_eval:run(Artifact, 1, flag)).

%% Keyword location остаётся синтаксическим путём, а absolute location unit'а
%% называет physical recursive keyword; выбранный target лежит уровнем ниже.
recursive_ref_location_test() ->
    Artifact = recursive_tree(true, true),
    Instance = #{<<"outer">> => true,
                 <<"next">> => #{<<"outer">> => true}},
    RecursiveLocation = [<<"$recursiveRef">>, <<"next">>,
                         <<"properties">>, <<"$ref">>],
    [RecursiveUnit] =
        [Unit || Unit <- keywords(collect(Artifact, Instance, basic)),
                 Unit#output_unit.keyword_location =:= RecursiveLocation],
    ?assertEqual({<<"https://example.com/inner-recursive">>,
                  [<<"$recursiveRef">>, <<"next">>, <<"properties">>]},
                 RecursiveUnit#output_unit.absolute_location),
    ?assertEqual([<<"next">>], RecursiveUnit#output_unit.instance_location).

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
    Pair = prefix_items([true, true], undefined),
    [?_assertEqual([{<<"/prefixItems">>, {annotation, 1}}], own_details(Pair, [1, 2, 3])),
     ?_assertEqual([{<<"/prefixItems">>, {annotation, true}}], own_details(Pair, [1, 2])),
     ?_assertEqual([{<<"/prefixItems">>, {annotation, true}}], own_details(Pair, [1])),
     ?_assertEqual([{<<"/prefixItems">>, none}], own_details(Pair, [])),
     ?_assertEqual([{<<"/items">>, {annotation, true}}], own_details(items([]), [1])),
     ?_assertEqual([{<<"/items">>, none}], own_details(items([]), [])),
     %% Хвостовому `items` применяться не к чему, а сам префикс аннотацию даёт.
     ?_assertEqual([{<<"/prefixItems">>, {annotation, true}}, {<<"/items">>, none}],
                   own_details(prefix_items([true], false), [1]))].

%% `items` покрывает весь массив, `prefixItems` — свой префикс. Провалившийся
%% keyword аннотации не даёт, поэтому и покрытия не вносит.
array_coverage_test_() ->
    [?_assertEqual({[], all, []}, coverage_of(items(true), [1, 2])),
     ?_assertEqual(neutral(), coverage_of(items(false), [1])),
     ?_assertEqual({[], 2, []}, coverage_of(prefix_items([true, true], undefined), [1, 2, 3])),
     %% Схем хватило на весь массив — покрыт весь массив.
     ?_assertEqual({[], all, []}, coverage_of(prefix_items([true, true], undefined), [1, 2])),
     ?_assertEqual({[], all, []}, coverage_of(prefix_items([true], true), [1, 2, 3]))].

%% Раскладка Draft 2019-09 устроена так же, как `prefixItems` с хвостовым
%% `items`: array-form `items` раздаёт по схеме на индекс, `additionalItems`
%% достаётся остатку.
items_array_test_() ->
    Pair = items_array([[{type, [integer]}], [{type, [string]}]], undefined),
    Closed = items_array([true], false),
    [?_assert(verdict(Pair, [1, <<"a">>])),
     ?_assertNot(verdict(Pair, [1, 2])),
     %% Длину массива keyword не ограничивает: лишние схемы остаются без пары,
     %% лишние элементы — без схемы.
     ?_assert(verdict(Pair, [1])),
     ?_assert(verdict(Pair, [])),
     ?_assert(verdict(Pair, [1, <<"a">>, true])),
     %% Остаток за префиксом достаётся `additionalItems`.
     ?_assert(verdict(Closed, [1])),
     ?_assertNot(verdict(Closed, [1, 2])),
     ?_assert(verdict(items_array([], undefined), [1])),
     %% Не-массив constraint не ограничивает.
     ?_assert(verdict(Closed, <<"ab">>))].

items_array_units_test_() ->
    Tail = items_array([[{type, [integer]}]], [{type, [string]}]),
    [?_assertEqual([{<<"/items">>, <<>>},
                    {<<"/items/0/type">>, <<"/0">>},
                    {<<"/additionalItems">>, <<>>},
                    {<<"/additionalItems/type">>, <<"/1">>},
                    {<<"/additionalItems/type">>, <<"/2">>}],
                   paired(collect(Tail, [1, <<"a">>, <<"b">>], basic))),
     %% Не-массив: units написанных keywords остаются, но без деталей.
     ?_assertEqual([{<<"/items">>, true, none}, {<<"/additionalItems">>, true, none}],
                   printed(collect(Tail, 1, basic)))].

%% Аннотация array-form `items` — наибольший индекс, к которому он применился,
%% либо `true`, если он применился ко всему массиву. Аннотация `additionalItems`
%% — всегда `true`. Не применявшийся keyword аннотации не производит.
items_array_annotation_test_() ->
    Pair = items_array([true, true], undefined),
    [?_assertEqual([{<<"/items">>, {annotation, 1}}], own_details(Pair, [1, 2, 3])),
     ?_assertEqual([{<<"/items">>, {annotation, true}}], own_details(Pair, [1, 2])),
     ?_assertEqual([{<<"/items">>, {annotation, true}}], own_details(Pair, [1])),
     ?_assertEqual([{<<"/items">>, none}], own_details(Pair, [])),
     ?_assertEqual([{<<"/items">>, {annotation, 0}},
                    {<<"/additionalItems">>, {annotation, true}}],
                   own_details(items_array([true], true), [1, 2])),
     %% `additionalItems` применяться не к чему, а сам префикс аннотацию даёт.
     ?_assertEqual([{<<"/items">>, {annotation, true}},
                    {<<"/additionalItems">>, none}],
                   own_details(items_array([true], false), [1]))].

%% Output format управляет только объёмом диагностики. Даже если полный обход
%% доходит до рекурсивной ветви, уже определённый boolean-результат обязан быть
%% тем же, что и у short-circuit режима flag. Если результата для поглощения
%% ошибки нет, все четыре формата возвращают один и тот же no_progress.
no_progress_logical_outcome_test() ->
    AnyTrueFirst = cyclic_branches(any_of, <<"anyOf">>, [true, cycle]),
    AnyTrueLast = cyclic_branches(any_of, <<"anyOf">>, [cycle, true]),
    AnyUnknown = cyclic_branches(any_of, <<"anyOf">>, [false, cycle]),
    AllFalseFirst = cyclic_branches(all_of, <<"allOf">>, [false, cycle]),
    AllFalseLast = cyclic_branches(all_of, <<"allOf">>, [cycle, false]),
    AllUnknown = cyclic_branches(all_of, <<"allOf">>, [true, cycle]),
    OneDecided = cyclic_branches(one_of, <<"oneOf">>, [true, true, cycle]),
    OneUnknown = cyclic_branches(one_of, <<"oneOf">>, [true, false, cycle]),
    assert_formats({ok, true}, AnyTrueFirst, 1),
    assert_formats({ok, true}, AnyTrueLast, 1),
    assert_formats({error, {no_progress, addr(<<"/anyOf/1">>)}}, AnyUnknown, 1),
    assert_formats({ok, false}, AllFalseFirst, 1),
    assert_formats({ok, false}, AllFalseLast, 1),
    assert_formats({error, {no_progress, addr(<<"/allOf/1">>)}}, AllUnknown, 1),
    assert_formats({ok, false}, OneDecided, 1),
    assert_formats({error, {no_progress, addr(<<"/oneOf/2">>)}}, OneUnknown, 1).

%% У `not` и выбранной conditional-ветви нет второго boolean-операнда, поэтому
%% no_progress существенен. Невыбранная ветвь по-прежнему не вычисляется.
no_progress_unary_outcome_test() ->
    Negated = branching([{'not', addr(<<"/not">>)}],
                        [{<<"/not">>, self_cycle(<<"/not">>)}]),
    Condition = conditional(self_cycle(<<"/if">>), true, false),
    Selected = conditional(true, self_cycle(<<"/then">>), false),
    Unselected = conditional(false, self_cycle(<<"/then">>), true),
    assert_formats({error, {no_progress, addr(<<"/not">>)}}, Negated, 1),
    assert_formats({error, {no_progress, addr(<<"/if">>)}}, Condition, 1),
    assert_formats({error, {no_progress, addr(<<"/then">>)}}, Selected, 1),
    assert_formats({ok, true}, Unselected, 1).

%% Schema object и применяющие подсхему контейнеры являются конъюнкциями:
%% известный false поглощает ошибку независимо от порядка обхода. Это отдельно
%% защищает продолжение структурного обхода после no_progress ради позднего
%% решающего провала.
no_progress_conjunction_outcome_test() ->
    Loop = addr(<<"/$defs/loop">>),
    Conjunction = tree(#{<<>> => schema_node([{ref, Loop}, {const, 2}]),
                         <<"/$defs/loop">> => self_cycle(<<"/$defs/loop">>)}),
    Properties = branching(
                   [{properties,
                     #{<<"a">> => addr(<<"/properties/a">>),
                       <<"b">> => addr(<<"/properties/b">>)},
                     undefined, undefined}],
                   [{<<"/properties/a">>, self_cycle(<<"/properties/a">>)},
                    {<<"/properties/b">>, false}]),
    PropertyNames = property_names(self_cycle(<<"/propertyNames">>)),
    Dependent = branching(
                  [{dependent_schemas,
                    #{<<"a">> => addr(<<"/dependentSchemas/a">>),
                      <<"b">> => addr(<<"/dependentSchemas/b">>)}}],
                  [{<<"/dependentSchemas/a">>,
                    self_cycle(<<"/dependentSchemas/a">>)},
                   {<<"/dependentSchemas/b">>, false}]),
    Prefix = branching(
               [{prefix_items, [addr(<<"/prefixItems/0">>),
                                addr(<<"/prefixItems/1">>)], undefined}],
               [{<<"/prefixItems/0">>, self_cycle(<<"/prefixItems/0">>)},
                {<<"/prefixItems/1">>, false}]),
    Unevaluated = unevaluated_tree(
                    [],
                    [{unevaluated_properties,
                      addr(<<"/unevaluatedProperties">>)}],
                    conditional_child(<<"/unevaluatedProperties">>)),
    assert_formats({ok, false}, Conjunction, 1),
    assert_formats({ok, false}, Properties, #{<<"a">> => 1, <<"b">> => 2}),
    assert_formats({error, {no_progress, addr(<<"/propertyNames">>)}},
                   PropertyNames, #{<<"a">> => 1}),
    assert_formats({ok, false}, Dependent, #{<<"a">> => 1, <<"b">> => 2}),
    assert_formats({ok, false}, Prefix, [1, 2]),
    assert_formats({ok, false}, Unevaluated, #{<<"a">> => 1, <<"b">> => 2}).

%% Для contains неизвестны отдельные результаты и, следовательно, диапазон
%% числа совпадений. Границы могут уже определить boolean; но если наверху есть
%% unevaluatedItems, неизвестный набор совпавших индексов не позволяет строить
%% маску покрытия и ошибка остаётся существенной.
no_progress_contains_outcome_test() ->
    DecidedTrue = cyclic_contains(undefined, undefined, false),
    Unknown = cyclic_contains(2, undefined, false),
    DecidedFalse = cyclic_contains(undefined, 0, false),
    CoverageUnknown = cyclic_contains(undefined, undefined, true),
    assert_formats({ok, true}, DecidedTrue, [1, 2]),
    assert_formats({error, {no_progress, addr(<<"/contains/else">>)}},
                   Unknown, [1, 2]),
    assert_formats({ok, false}, DecidedFalse, [1, 2]),
    assert_formats({error, {no_progress, addr(<<"/contains/else">>)}},
                   CoverageUnknown, [1, 2]).

items_array_coverage_test_() ->
    [?_assertEqual({[], 2, []},
                   coverage_of(items_array([true, true], undefined), [1, 2, 3])),
     %% Схем хватило на весь массив — покрыт весь массив.
     ?_assertEqual({[], all, []},
                   coverage_of(items_array([true, true], undefined), [1, 2])),
     ?_assertEqual({[], all, []}, coverage_of(items_array([true], true), [1, 2, 3])),
     %% Провалившийся keyword аннотации не даёт, поэтому и покрытия не вносит.
     ?_assertEqual(neutral(), coverage_of(items_array([false], undefined), [1]))].

%% Обрыв разрешён только в режиме flag; в остальных режимах обходятся все
%% элементы, потому что дерево units должно быть полным.
array_short_circuit_test_() ->
    Artifact = prefix_items([false, tripwire()], undefined),
    [?_assertMatch({ok, #eval_result{valid = false}},
                   valid_json_eval:run(Artifact, [1, 2], flag)),
     ?_assertError({badkey, _}, valid_json_eval:run(Artifact, [1, 2], basic))].

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

%% `unevaluated*` применяются к тому, чего не коснулся ни один сосед. Покрытие
%% берётся от constraints того же node, включая достигнутые по ссылке.
unevaluated_test_() ->
    Properties = unevaluated_properties([{type, [integer]}]),
    Items = unevaluated_items([{type, [integer]}]),
    [?_assert(verdict(Properties, #{<<"foo">> => <<"x">>, <<"bar">> => 1})),
     ?_assertNot(verdict(Properties, #{<<"bar">> => <<"x">>})),
     %% Непокрытых свойств нет — подсхеме применяться не к чему.
     ?_assert(verdict(Properties, #{<<"foo">> => <<"x">>})),
     ?_assert(verdict(Properties, 1)),
     ?_assert(verdict(Items, [<<"x">>, 1])),
     ?_assertNot(verdict(Items, [<<"x">>, <<"y">>])),
     ?_assert(verdict(Items, [<<"x">>])),
     ?_assert(verdict(Items, 1)),
     %% Покрытие цели `$ref` считается покрытием самого node.
     ?_assert(verdict(referenced_coverage(), #{<<"foo">> => 1})),
     ?_assertNot(verdict(referenced_coverage(), #{<<"bar">> => 1}))].

%% Ветви in-place applicators обходятся целиком, пока покрытия ждут: успех
%% первой ветви `anyOf` не отменяет аннотаций остальных, и обрыв в режиме flag
%% дал бы другой вердикт. Ловушка стоит в невлияющей ветви и показывает, что
%% обход дошёл и до неё.
unevaluated_branches_test_() ->
    [?_assert(verdict(nested_coverage(), #{<<"foo">> => 1})),
     ?_assertNot(verdict(nested_coverage(), #{<<"bar">> => 1})),
     ?_assertError({badkey, _},
                   valid_json_eval:run(nested_coverage(tripwire()), #{<<"foo">> => 1}, flag))].

%% Аннотации собираются и внутри `not`: у внутренней схемы свой
%% `unevaluatedProperties`, и его вердикт зависит от покрытия соседей, хотя
%% наружу это покрытие не выйдет (suite, `not.json`).
unevaluated_inside_not_test_() ->
    [?_assertNot(verdict(unevaluated_inside_not(), #{<<"foo">> => 1})),
     ?_assert(verdict(unevaluated_inside_not(), #{<<"bar">> => 1}))].

%% Разреженное покрытие от `contains`: пример из validator-core. Совпадения
%% отмечают индексы 0, 1, 2 и 4, а индекс 3 обязан дойти до `unevaluatedItems`.
unevaluated_sparse_test_() ->
    [?_assert(verdict(sparse_coverage(), [2, 3, 4, 5, 8])),
     ?_assertNot(verdict(sparse_coverage(), [2, 3, 4, 7, 8]))].

%% Граница resource: node с unevaluated лежит в другом документе, и покрытие
%% считается там же, где написаны его constraints.
unevaluated_boundary_test_() ->
    [?_assert(verdict(boundary_coverage(), #{<<"foo">> => 1})),
     ?_assertNot(verdict(boundary_coverage(), #{<<"bar">> => 1}))].

%% Аннотация `unevaluatedProperties` называет имена, к которым keyword
%% применился, а `unevaluatedItems` — всегда `true`: применившись хоть куда-то,
%% он покрыл весь остаток массива.
unevaluated_annotation_test_() ->
    Details = fun(Artifact, Instance) ->
                      [{valid_json_location:pointer(Keywords), Detail}
                       || #output_unit{keyword_location = Keywords, detail = Detail}
                              <- own(collect(Artifact, Instance, basic))]
              end,
    Properties = unevaluated_properties(true),
    Items = unevaluated_items(true),
    [?_assertEqual([{<<"/properties">>, {annotation, [<<"foo">>]}},
                    {<<"/unevaluatedProperties">>, {annotation, [<<"bar">>]}}],
                   Details(Properties, #{<<"foo">> => 1, <<"bar">> => 2})),
     %% Непокрытых свойств не нашлось — аннотация остаётся пустой.
     ?_assertEqual([{<<"/properties">>, {annotation, [<<"foo">>]}},
                    {<<"/unevaluatedProperties">>, {annotation, []}}],
                   Details(Properties, #{<<"foo">> => 1})),
     %% Не-объект: unit успешный, но аннотации нет.
     ?_assertEqual([{<<"/properties">>, none}, {<<"/unevaluatedProperties">>, none}],
                   Details(Properties, 1)),
     ?_assertEqual([{<<"/prefixItems">>, {annotation, 0}},
                    {<<"/unevaluatedItems">>, {annotation, true}}],
                   Details(Items, [1, 2])),
     %% Непокрытых элементов не нашлось — применяться было нечему.
     ?_assertEqual([{<<"/prefixItems">>, {annotation, true}},
                    {<<"/unevaluatedItems">>, none}],
                   Details(Items, [1]))].

%% Покрытие вносит и сам `unevaluated*`: свойства, к которым он применился, и
%% весь остаток массива.
unevaluated_coverage_test_() ->
    [?_assertEqual({[<<"bar">>, <<"foo">>], 0, []},
                   coverage_of(unevaluated_properties(true), #{<<"foo">> => 1, <<"bar">> => 2})),
     ?_assertEqual({[], all, []}, coverage_of(unevaluated_items(true), [1, 2])),
     %% Провалившийся node покрытия не отдаёт вовсе.
     ?_assertEqual(neutral(),
                   coverage_of(unevaluated_properties(false), #{<<"bar">> => 1}))].

%% `{"properties": {"foo": true}, "unevaluatedProperties": Child}`.
unevaluated_properties(Child) ->
    unevaluated_tree([{properties, #{<<"foo">> => addr(<<"/properties/foo">>)},
                       undefined, undefined}],
                     [{unevaluated_properties, addr(<<"/unevaluatedProperties">>)}],
                     #{<<"/properties/foo">> => true,
                       <<"/unevaluatedProperties">> => child(Child)}).

%% `{"prefixItems": [true], "unevaluatedItems": Child}`.
unevaluated_items(Child) ->
    unevaluated_tree([{prefix_items, [addr(<<"/prefixItems/0">>)], undefined}],
                     [{unevaluated_items, addr(<<"/unevaluatedItems">>)}],
                     #{<<"/prefixItems/0">> => true,
                       <<"/unevaluatedItems">> => child(Child)}).

%% Покрытие приходит из цели ссылки, а не от соседнего keyword.
referenced_coverage() ->
    unevaluated_tree([{ref, addr(<<"/$defs/base">>)}],
                     [{unevaluated_properties, addr(<<"/unevaluatedProperties">>)}],
                     #{<<"/$defs/base">> =>
                           schema_node([{properties, #{<<"foo">> => addr(<<"/$defs/base/properties/foo">>)},
                                        undefined, undefined}]),
                       <<"/$defs/base/properties/foo">> => true,
                       <<"/unevaluatedProperties">> => false}).

nested_coverage() ->
    nested_coverage(true).

%% Покрытие поднимается через цепочку in-place applicators: `foo` покрывает
%% вторая ветвь `anyOf`, лежащая под `allOf`.
nested_coverage(First) ->
    unevaluated_tree([{all_of, [addr(<<"/allOf/0">>)]}],
                     [{unevaluated_properties, addr(<<"/unevaluatedProperties">>)}],
                     #{<<"/allOf/0">> =>
                           schema_node([{any_of, [addr(<<"/allOf/0/anyOf/0">>),
                                                  addr(<<"/allOf/0/anyOf/1">>)]}]),
                       <<"/allOf/0/anyOf/0">> => child(First),
                       <<"/allOf/0/anyOf/1">> =>
                           schema_node([{properties, #{<<"foo">> => addr(<<"/allOf/0/anyOf/1/properties/foo">>)},
                                        undefined, undefined}]),
                       <<"/allOf/0/anyOf/1/properties/foo">> => true,
                       <<"/unevaluatedProperties">> => false}).

unevaluated_inside_not() ->
    tree(#{<<>> => schema_node([{'not', addr(<<"/not">>)}]),
           <<"/not">> =>
               #node{constraints = [{any_of, [addr(<<"/not/anyOf/0">>),
                                              addr(<<"/not/anyOf/1">>)]}],
                     unevaluated = [{unevaluated_properties,
                                     addr(<<"/not/unevaluatedProperties">>)}]},
           <<"/not/anyOf/0">> => true,
           <<"/not/anyOf/1">> =>
               schema_node([{properties, #{<<"foo">> => addr(<<"/not/anyOf/1/properties/foo">>)},
                            undefined, undefined}]),
           <<"/not/anyOf/1/properties/foo">> => true,
           <<"/not/unevaluatedProperties">> => false}).

%% Две ветви `allOf` с `contains`, каждая отмечает свои индексы; непокрытым
%% остаётся тот, что не совпал ни с одной.
sparse_coverage() ->
    Branch = fun(Index, Divisor) ->
                     Pointer = <<"/allOf/", (integer_to_binary(Index))/binary>>,
                     {Pointer,
                      schema_node([{contains, addr(<<Pointer/binary, "/contains">>),
                                    undefined, undefined, true}]),
                      <<Pointer/binary, "/contains">>,
                      schema_node([{multiple_of, Divisor}])}
             end,
    {First, FirstNode, FirstChild, FirstChildNode} = Branch(0, 2),
    {Second, SecondNode, SecondChild, SecondChildNode} = Branch(1, 3),
    unevaluated_tree([{all_of, [addr(First), addr(Second)]}],
                     [{unevaluated_items, addr(<<"/unevaluatedItems">>)}],
                     #{First => FirstNode, FirstChild => FirstChildNode,
                       Second => SecondNode, SecondChild => SecondChildNode,
                       <<"/unevaluatedItems">> => schema_node([{multiple_of, 5}])}).

unevaluated_tree(Constraints, Unevaluated, Children) ->
    tree(Children#{<<>> => #node{constraints = Constraints, unevaluated = Unevaluated}}).

%% Ссылка ведёт в другой resource, и node с unevaluated целиком принадлежит ему.
boundary_coverage() ->
    Target = <<"https://example.com/target">>,
    Nodes = #{<<>> => #node{constraints = [{properties, #{<<"foo">> => {Target, <<"/properties/foo">>}},
                                            undefined, undefined}],
                            unevaluated = [{unevaluated_properties,
                                            {Target, <<"/unevaluatedProperties">>}}]},
              <<"/properties/foo">> => true,
              <<"/unevaluatedProperties">> => false},
    #{root      => ?RESOURCE,
      sources   => [],
      resources => #{?RESOURCE => resource(?RESOURCE, #{<<>> => schema_node([{ref, {Target, <<>>}}])}),
                     Target    => resource(Target, Nodes)}}.

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
     ?_assertError({badkey, _}, valid_json_eval:run(Failing, 1, basic))].

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
                   valid_json_core:validate(Artifact, Instance, [{output, basic}])),
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

%% Опция вызова разбирается так же, как опции store и compile: негодное значение
%% и незнакомый ключ — ошибка вызова API. Промолчать нельзя, потому что тихим
%% умолчанием стал бы flag, а он не собирает units и лишил бы вызывающего всей
%% запрошенной диагностики.
output_option_error_test_() ->
    Artifact = artifact(schema_node([{type, [integer]}])),
    [?_assertError(badarg, valid_json_core:validate(Artifact, 1, [{output, bogus}])),
     ?_assertError(badarg, valid_json_core:validate(Artifact, 1, [{outpt, basic}])),
     ?_assertError(badarg, valid_json_core:validate(Artifact, 1, [output])),
     ?_assertError(badarg, valid_json_core:validate(Artifact, 1, not_a_list)),
     ?_assertEqual({ok, #{<<"valid">> => true}},
                   valid_json_core:validate(Artifact, 1, []))].

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

%% Детали собственных units написанных keywords рядом с их локациями: так
%% читаются аннотации, которые keyword произвёл на этом инстансе.
own_details(Artifact, Instance) ->
    [{valid_json_location:pointer(Keywords), Detail}
     || #output_unit{keyword_location = Keywords, detail = Detail}
            <- own(collect(Artifact, Instance, basic))].

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

%% Логический applicator с обычными boolean-ветвями и специальной ветвью
%% `cycle`, которая ссылается на собственный node при той же instance location.
cyclic_branches(Tag, Keyword, Children) ->
    Pointers = [<<"/", Keyword/binary, "/", (integer_to_binary(Index))/binary>>
                || Index <- lists:seq(0, length(Children) - 1)],
    Nodes = [{Pointer, cyclic_child(Child, Pointer)}
             || {Pointer, Child} <- lists:zip(Pointers, Children)],
    branching([{Tag, [addr(Pointer) || Pointer <- Pointers]}], Nodes).

cyclic_child(cycle, Pointer) -> self_cycle(Pointer);
cyclic_child(Child, _Pointer) -> Child.

self_cycle(Pointer) ->
    schema_node([{ref, addr(Pointer)}]).

%% На значении 1 условие выбирает Then, на остальных — Else. Возвращается map,
%% который можно встроить в дерево фикстуры вместе с её корнем.
conditional_children(Base, Then, Else) ->
    If = <<Base/binary, "/if">>,
    ThenPointer = <<Base/binary, "/then">>,
    ElsePointer = <<Base/binary, "/else">>,
    #{Base => schema_node([{if_then_else, addr(If), addr(ThenPointer),
                            addr(ElsePointer)}]),
      If => schema_node([{const, 1}]),
      ThenPointer => child(Then),
      ElsePointer => child(Else)}.

conditional_child(Base) ->
    conditional_children(Base, self_cycle(<<Base/binary, "/then">>), false).

cyclic_contains(Min, Max, WithUnevaluated) ->
    Children = conditional_children(
                 <<"/contains">>, true,
                 self_cycle(<<"/contains/else">>)),
    Unevaluated = case WithUnevaluated of
                      true  -> [{unevaluated_items,
                                 addr(<<"/unevaluatedItems">>)}];
                      false -> []
                  end,
    Root = #node{constraints = [{contains, addr(<<"/contains">>),
                                 Min, Max, true}],
                 unevaluated = Unevaluated},
    Extra = case WithUnevaluated of
                true  -> Children#{<<"/unevaluatedItems">> => false};
                false -> Children
            end,
    tree(Extra#{<<>> => Root}).

assert_formats(Expected, Artifact, Instance) ->
    lists:foreach(
      fun(Format) ->
              ?assertEqual({Format, Expected},
                           {Format, validation_outcome(Artifact, Instance, Format)})
      end,
      [flag, basic, detailed, verbose]).

validation_outcome(Artifact, Instance, Format) ->
    case valid_json_core:validate(Artifact, Instance, [{output, Format}]) of
        {ok, #{<<"valid">> := Valid}} -> {ok, Valid};
        {error, Error}                 -> {error, Error}
    end.

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
    Prefix = lists:zip(lists:seq(0, length(Children) - 1), Children),
    branching([{prefix_items, [addr(Pointer(Index)) || {Index, _Child} <- Prefix],
                slot(<<"/items">>, Tail)}],
              [{Pointer(Index), Child} || {Index, Child} <- Prefix]
              ++ [{<<"/items">>, Tail} || Tail =/= undefined]).

%% Раскладка Draft 2019-09: схемы array-form `items` адресуются по индексу, а
%% `additionalItems` стоит на собственном keyword и задаётся `undefined`, если не
%% написан.
items_array(Children, Tail) ->
    Pointer = fun(Index) -> <<"/items/", (integer_to_binary(Index))/binary>> end,
    Prefix = lists:zip(lists:seq(0, length(Children) - 1), Children),
    branching([{items_array, [addr(Pointer(Index)) || {Index, _Child} <- Prefix],
                slot(<<"/additionalItems">>, Tail)}],
              [{Pointer(Index), Child} || {Index, Child} <- Prefix]
              ++ [{<<"/additionalItems">>, Tail} || Tail =/= undefined]).

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

ref_tree(Target) ->
    Pointer = <<"/$defs/value">>,
    tree(#{<<>> => schema_node([{ref, addr(Pointer)}]),
           Pointer => child(Target)}).

%% Дочерняя schema задаётся списком constraints, boolean или готовым node.
child(Node) when is_boolean(Node) -> Node;
child(#node{} = Node)             -> Node;
child(Constraints)                -> schema_node(Constraints).

addr(Pointer) ->
    {anonymous, Pointer}.

%% Node, вычисление которого падает: он показывает, дошёл ли обход до ветви.
%% Падение даёт ссылка в никуда: разрешение адреса в готовом артефакте тотально,
%% и до вычисления такой node не доживает.
tripwire() ->
    schema_node([{ref, addr(<<"/missing">>)}]).

absolute(Artifact, Instance) ->
    {ok, #eval_result{units = Units}} = valid_json_eval:run(Artifact, Instance, basic),
    [Location || #output_unit{absolute_location = Location} <- keywords(Units)].

%% Проекция печатает ту же локацию отдельным ключом.
printed_absolute(Artifact, Instance) ->
    {ok, #{<<"errors">> := [Unit]}} =
        valid_json_core:validate(Artifact, Instance, [{output, basic}]),
    maps:get(<<"absoluteKeywordLocation">>, Unit).

%% Сообщение существует только у провалившегося constraint, поэтому берётся из
%% его же unit.
message(Constraint, Instance) ->
    [{_Location, false, {error, Message}}] = located([Constraint], Instance),
    Message.

basic(Node, Instance) ->
    valid_json_core:validate(artifact(Node), Instance, [{output, basic}]).

%% Плоский список провалов уже готовой проекции: он показывает, что до неё
%% дошло, а что осталось только в дереве.
errors(Artifact, Instance) ->
    {ok, #{<<"errors">> := Errors}} =
        valid_json_core:validate(Artifact, Instance, [{output, basic}]),
    Errors.

coverage(Constraints, Instance) ->
    {ok, #eval_result{evaluated = Evaluated}} = run(schema_node(Constraints), Instance),
    expand(Evaluated).

run(Node, Instance) ->
    valid_json_eval:run(artifact(Node), Instance, flag).

validate(Node, Instance) ->
    valid_json_core:validate(artifact(Node), Instance, [{output, flag}]).

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
      resources => #{Rid => resource(Id, Nodes)}}.

%% Внешний resource применяет внутренний, а внутренний ссылается на своё
%% `/$defs/item` через `$dynamicRef`. Что именно объявил внешний, и решает, чья
%% цель победит: его собственная или лексическая.
dynamic_tree(OuterAnchors) ->
    Inner = <<"https://example.com/inner">>,
    #{root => ?RESOURCE,
      sources => [],
      resources =>
          #{?RESOURCE =>
                dynamic_resource(?RESOURCE, OuterAnchors,
                                 #{<<>> => schema_node([{ref, {Inner, <<>>}}]),
                                   <<"/$defs/item">> =>
                                       schema_node([{type, [integer]}])}),
            Inner =>
                dynamic_resource(Inner, #{<<"item">> => <<"/$defs/item">>},
                                 #{<<>> => schema_node(
                                             [{dynamic_ref, <<"item">>,
                                               {Inner, <<"/$defs/item">>}}]),
                                   <<"/$defs/item">> =>
                                       schema_node([{type, [string]}])})}}.

%% Resource с dynamic anchors: их читает только `$dynamicRef`.
dynamic_resource(Id, Anchors, Nodes) ->
    (resource(Id, Nodes))#resource{dynamic_anchors = Anchors}.

%% Внешний resource применяет внутренний к тому же объекту. Внутренний спускает
%% `$recursiveRef` в свойство `next`, поэтому повтор внешнего корня происходит
%% уже на новой instance location и не является cycle.
recursive_tree(OuterRecursive, InnerRecursive) ->
    Inner = <<"https://example.com/inner-recursive">>,
    #{root => ?RESOURCE,
      sources => [],
      resources =>
          #{?RESOURCE =>
                recursive_resource(
                  ?RESOURCE, OuterRecursive,
                  #{<<>> => schema_node(
                              [{required, [<<"outer">>]},
                               {ref, {Inner, <<>>}}])}),
            Inner =>
                recursive_resource(
                  Inner, InnerRecursive,
                  #{<<>> => schema_node(
                              [{properties,
                                #{<<"next">> => {Inner, <<"/properties/next">>}},
                                undefined, undefined}]),
                    <<"/properties/next">> =>
                        schema_node([{recursive_ref, {Inner, <<>>}}])})}}.

recursive_outermost_tree() ->
    Middle = <<"https://example.com/middle-recursive">>,
    Inner = <<"https://example.com/inner-recursive">>,
    #{root => ?RESOURCE,
      sources => [],
      resources =>
          #{?RESOURCE =>
                recursive_resource(
                  ?RESOURCE, true,
                  #{<<>> => schema_node(
                              [{required, [<<"outer">>]},
                               {ref, {Middle, <<>>}}])}),
            Middle =>
                recursive_resource(
                  Middle, true,
                  #{<<>> => schema_node(
                              [{required, [<<"middle">>]},
                               {ref, {Inner, <<>>}}])}),
            Inner =>
                recursive_resource(
                  Inner, true,
                  #{<<>> => schema_node(
                              [{properties,
                                #{<<"next">> => {Inner, <<"/properties/next">>}},
                                undefined, undefined}]),
                    <<"/properties/next">> =>
                        schema_node([{recursive_ref, {Inner, <<>>}}])})}}.

recursive_resource(Id, Recursive, Nodes) ->
    #resource{id               = Id,
              dialect          = ?LEGACY,
              anchors          = #{},
              dynamic_anchors  = #{},
              recursive_anchor = Recursive,
              nodes            = Nodes}.

%% Отдельный resource: артефакту из нескольких документов их нужно несколько.
resource(Id, Nodes) ->
    #resource{id               = Id,
              dialect          = ?DIALECT,
              anchors          = #{},
              dynamic_anchors  = #{},
              recursive_anchor = false,
              nodes            = Nodes}.
