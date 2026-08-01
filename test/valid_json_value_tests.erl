%% Модель значения. Проверяются все семь json types и особая семантика integer.
-module(valid_json_value_tests).

-include_lib("eunit/include/eunit.hrl").

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

%% Целое остаётся целым при любой величине, ненулевая дробная часть выводит
%% значение из integer.
integer_test_() ->
    [?_assert(valid_json_value:is_type(integer, 1 bsl 200)),
     ?_assert(valid_json_value:is_type(integer, 1.0e17)),
     ?_assert(valid_json_value:is_type(integer, -0.0)),
     ?_assertNot(valid_json_value:is_type(integer, 0.5)),
     ?_assertNot(valid_json_value:is_type(integer, 1.0e-8))].

matching_types(Value) ->
    [Type || Type <- ?TYPES, valid_json_value:is_type(Type, Value)].
