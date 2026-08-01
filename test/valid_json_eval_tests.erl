%% Evaluator fixtures поверх вручную собранного compiled(): результат проверяется
%% до проекции в JSON, чтобы слои не сливались в один end-to-end вердикт.
-module(valid_json_eval_tests).

-include_lib("eunit/include/eunit.hrl").
-include("valid_json_core.hrl").

-define(DIALECT, <<"https://json-schema.org/draft/2020-12/schema">>).

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

%% Публичный результат — JSON выбранного формата; valid = false остаётся ok.
flag_output_test_() ->
    [?_assertEqual({ok, #{<<"valid">> => true}},
                   validate(schema_node([{type, [string]}]), <<"a">>)),
     ?_assertEqual({ok, #{<<"valid">> => false}},
                   validate(schema_node([{type, [string]}]), 1))].

valid(Constraints, Instance) ->
    {ok, #eval_result{valid = Valid}} = run(schema_node(Constraints), Instance),
    Valid.

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
    #{root      => anonymous,
      sources   => [],
      resources => #{anonymous =>
          #resource{id               = undefined,
                    dialect          = ?DIALECT,
                    anchors          = #{},
                    dynamic_anchors  = #{},
                    recursive_anchor = false,
                    nodes            = #{<<>> => Node}}}}.
