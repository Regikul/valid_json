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

%% Абсолютная локация выводится из адреса node, а не накапливается обходом,
%% поэтому у названного resource она появляется сама и печатается вместе с unit.
absolute_test_() ->
    Assertion = schema_node([{type, [string]}]),
    [?_assertEqual([undefined], absolute(artifact(Assertion), 1)),
     ?_assertEqual([{?RESOURCE, [<<"type">>]}], absolute(named(Assertion), 1)),
     %% У boolean-схемы собственного сегмента нет: она стоит в корне resource.
     ?_assertEqual([{?RESOURCE, []}], absolute(named(false), 1)),
     ?_assertEqual(<<"https://example.com/s#/type">>,
                   printed_absolute(named(Assertion), 1))].

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

collect(Node, Instance, Format) ->
    {ok, #eval_result{units = Units}} =
        valid_json_eval:run(artifact(Node), Instance, Format),
    Units.

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
    #{root      => Rid,
      sources   => [],
      resources => #{Rid =>
          #resource{id               = Id,
                    dialect          = ?DIALECT,
                    anchors          = #{},
                    dynamic_anchors  = #{},
                    recursive_anchor = false,
                    nodes            = #{<<>> => Node}}}}.
