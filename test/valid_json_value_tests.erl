%% Модель значения. Проверяются все семь json types, особая семантика integer
%% и три ветви кратности.
-module(valid_json_value_tests).

-include_lib("eunit/include/eunit.hrl").

%% Тесты модуля независимы, поэтому eunit прогоняет их параллельно.
eunit_wrapper_(Tests) -> {inparallel, Tests}.

-define(TYPES, [null, boolean, object, array, string, number, integer]).

%% Для каждого значения перечислены все типы, которым оно принадлежит.
%% Проверка идёт по всем семи сразу, поэтому лишнее совпадение тоже красное.
seven_types_test_() ->
    Values = [{null,    [null]},
              {true,    [boolean]},
              {false,   [boolean]},
              {#{},     [object]},
              {[],      [array]},
              {<<"a">>, [string]},
              {<<>>,    [string]},
              {1,       [number, integer]},
              {-1,      [number, integer]},
              {1.5,     [number]},
              {1.0,     [number, integer]}],
    [{lists:flatten(io_lib:format("~p", [Value])),
      ?_assertEqual(Expected, matching_types(Value))}
     || {Value, Expected} <- Values].

%% Обратная сторона той же таблицы: у значения двух типов выбирается узкий,
%% потому что сообщение об ошибке должно называть его так же, как схема.
type_of_test_() ->
    Values = [{null, null}, {true, boolean}, {false, boolean},
              {#{}, object}, {[], array}, {<<"a">>, string}, {<<>>, string},
              {1, integer}, {-1, integer}, {1.0, integer}, {1 bsl 200, integer},
              {1.5, number}, {1.0e-8, number}],
    [{lists:flatten(io_lib:format("~p", [Value])),
      ?_assertEqual(Expected, valid_json_value:type_of(Value))}
     || {Value, Expected} <- Values].

%% Целое остаётся целым при любой величине, ненулевая дробная часть выводит
%% значение из integer.
integer_test_() ->
    [?_assert(valid_json_value:is_type(integer, 1 bsl 200)),
     ?_assert(valid_json_value:is_type(integer, 1.0e17)),
     ?_assert(valid_json_value:is_type(integer, -0.0)),
     ?_assertNot(valid_json_value:is_type(integer, 0.5)),
     ?_assertNot(valid_json_value:is_type(integer, 1.0e-8))].

%% Первая ветвь гибрида: оба целых, точный rem без участия float.
multiple_of_integer_test_() ->
    [?_assert(valid_json_value:is_multiple_of(10, 2)),
     ?_assertNot(valid_json_value:is_multiple_of(7, 2)),
     ?_assert(valid_json_value:is_multiple_of(0, 7)),
     ?_assert(valid_json_value:is_multiple_of(-10, 2)),
     %% Точность не теряется на величинах, не представимых double.
     ?_assert(valid_json_value:is_multiple_of(1 bsl 2000, 1 bsl 1000)),
     ?_assertNot(valid_json_value:is_multiple_of((1 bsl 2000) + 1, 1 bsl 1000))].

%% Вторая ветвь: частное представимо, ответ даёт сравнение с round/1.
multiple_of_quotient_test_() ->
    [?_assert(valid_json_value:is_multiple_of(4.5, 1.5)),
     ?_assert(valid_json_value:is_multiple_of(-4.5, 1.5)),
     ?_assert(valid_json_value:is_multiple_of(0, 1.5)),
     ?_assertNot(valid_json_value:is_multiple_of(35, 1.5)),
     ?_assert(valid_json_value:is_multiple_of(0.0075, 0.0001)),
     ?_assertNot(valid_json_value:is_multiple_of(0.00751, 0.0001)),
     %% Частное больше 2^53 остаётся целым и не теряет ответа.
     ?_assert(valid_json_value:is_multiple_of(12391239123, 1.0e-8))].

%% Третья ветвь: частное не представимо double, поэтому деление уходит в
%% badarith и ответ считается на точных дробях.
multiple_of_exact_test_() ->
    [?_assertNot(valid_json_value:is_multiple_of(1.0e308, 0.123456789)),
     %% Субнормальный делитель: дробь строится по другой ветви представления.
     ?_assert(valid_json_value:is_multiple_of(1.0e308, 5.0e-324)),
     ?_assert(valid_json_value:is_multiple_of(1 bsl 2000, 0.5)),
     ?_assertNot(valid_json_value:is_multiple_of(1 bsl 2000, 1.5))].

%% Объявленное расхождение профиля: декодер уже округлил оба литерала, поэтому
%% десятично верный ответ здесь недостижим. Тест фиксирует границу, а не идеал;
%% см. validator-core.md, раздел «Точность чисел».
multiple_of_declared_gap_test() ->
    ?assertNot(valid_json_value:is_multiple_of(0.3, 0.1)).

%% Границы byte_size сокращают часть случаев, поэтому ответ сверяется с прямым
%% подсчётом code points на строках всех четырёх длин представления.
length_shortcut_test_() ->
    Strings = [<<>>, <<"a">>, <<"abc">>, <<"é"/utf8>>, <<"привет"/utf8>>,
               <<"💩"/utf8>>, <<"💩💩"/utf8>>, <<"a💩é"/utf8>>],
    [{lists:flatten(io_lib:format("~ts =~p= ~p", [String, Length, Bound])),
      [?_assertEqual(Length =< Bound, valid_json_value:is_length_at_most(String, Bound)),
       ?_assertEqual(Length >= Bound, valid_json_value:is_length_at_least(String, Bound))]}
     || String <- Strings,
        Length <- [length(unicode:characters_to_list(String))],
        Bound  <- lists:seq(0, 9)].

%% Уникальность — та же JSON equality, что у const и enum.
unique_test_() ->
    [?_assert(valid_json_value:is_unique([])),
     ?_assert(valid_json_value:is_unique([1, 2, 3])),
     ?_assertNot(valid_json_value:is_unique([1, 2, 1])),
     ?_assert(valid_json_value:is_unique([true, 1, <<"1">>, null, [], #{}])),
     ?_assertNot(valid_json_value:is_unique([1, 1.0])),
     ?_assertNot(valid_json_value:is_unique([#{<<"a">> => [1]}, #{<<"a">> => [1.0]}])),
     ?_assertNot(valid_json_value:is_unique([[0], [0.0]])),
     ?_assert(valid_json_value:is_unique([0, false])),
     ?_assert(valid_json_value:is_unique([null, <<"null">>])),
     ?_assert(valid_json_value:is_unique([42])),
     %% Совпадение в начале: обрыва обхода больше нет, ответ прежний.
     ?_assertNot(valid_json_value:is_unique([1, 1, 2, 3])),
     %% Порядок элементов массива значим, порядок ключей объекта — нет.
     ?_assert(valid_json_value:is_unique([[1, 2], [2, 1]])),
     ?_assertNot(valid_json_value:is_unique([#{<<"a">> => 1, <<"b">> => 2},
                                             #{<<"b">> => 2, <<"a">> => 1}]))].

matching_types(Value) ->
    [Type || Type <- ?TYPES, valid_json_value:is_type(Type, Value)].
