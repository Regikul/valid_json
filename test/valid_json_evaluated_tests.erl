%% Алгебра маски массива. Ключевое свойство — независимость представления
%% от порядка слияния: иначе fixtures начнут зависеть от порядка обхода ветвей.
-module(valid_json_evaluated_tests).

-include_lib("eunit/include/eunit.hrl").

%% Тесты модуля независимы, поэтому eunit прогоняет их параллельно.
eunit_wrapper_(Tests) -> {inparallel, Tests}.

neutral_test() ->
    ?assertEqual(neutral, valid_json_evaluated:neutral()).

neutral_identity_test_() ->
    Properties = valid_json_evaluated:properties([<<"foo">>]),
    Items = valid_json_evaluated:items({2, []}),
    [?_assertEqual(Properties,
                   valid_json_evaluated:merge(valid_json_evaluated:neutral(),
                                              Properties)),
     ?_assertEqual(Items,
                   valid_json_evaluated:merge(Items,
                                              valid_json_evaluated:neutral())),
     ?_assertEqual(neutral, valid_json_evaluated:properties([])),
     ?_assertEqual(neutral, valid_json_evaluated:items({0, []}))].

neutral_read_test_() ->
    Properties = valid_json_evaluated:properties([<<"foo">>]),
    Names = [<<"bar">>, <<"foo">>],
    [?_assertEqual(Names,
                   valid_json_evaluated:unevaluated_properties(neutral, Names)),
     ?_assertEqual([<<"bar">>],
                   valid_json_evaluated:unevaluated_properties(Properties, Names)),
     ?_assertEqual([], valid_json_evaluated:unevaluated_indexes(neutral, 0)),
     ?_assertEqual([0, 1, 2],
                   valid_json_evaluated:unevaluated_indexes(neutral, 3))].

all_absorbs_test_() ->
    [?_assertEqual(all, valid_json_evaluated:merge_items(all, mask(0, []))),
     ?_assertEqual(all, valid_json_evaluated:merge_items(mask(3, [7]), all)),
     ?_assertEqual(all, valid_json_evaluated:merge_items(all, all))].

prefix_test_() ->
    [?_assertEqual({5, []}, merged([mask(3, []), mask(5, [])])),
     ?_assertEqual({5, []}, merged([mask(5, []), mask(3, [])]))].

%% Разреженные индексы, примыкающие к префиксу, поглощаются им.
absorption_test_() ->
    [?_assertEqual({1, []},  merged([mask(0, [0])])),
     ?_assertEqual({3, []},  merged([mask(0, [0, 1, 2])])),
     ?_assertEqual({2, [4]}, merged([mask(1, [1, 4])])),
     ?_assertEqual({3, [5]}, merged([mask(0, [1, 2]), mask(1, [5])]))].

%% Индексы меньше префикса и сам префикс в разреженной части не хранятся.
canonical_test_() ->
    [?_assertEqual({4, []},  merged([mask(4, [0, 1, 2, 3])])),
     ?_assertEqual({4, [9]}, merged([mask(4, [1, 9])]))].

%% Пример из validator-core: contains отмечает 0, 1, 2 и 4, индекс 3 остаётся
%% непокрытым, поэтому маска не схлопывается в один префикс.
sparse_from_contains_test() ->
    ?assertEqual({3, [4]}, merged([mask(0, [0, 2]), mask(0, [1, 4])])).

order_independent_test_() ->
    Masks = [mask(0, [0, 3]), mask(1, [5]), mask(2, []), mask(0, [2, 4])],
    Expected = merged(Masks),
    [{lists:flatten(io_lib:format("~p", [Permutation])),
      ?_assertEqual(Expected, merged(Permutation))}
     || Permutation <- permutations(Masks)].

%% Чтение маски: индексы, до которых `unevaluatedItems` обязан дойти. Длину
%% массива маска не знает, поэтому исчерпанный префикс и покрытие сверх длины
%% дают один и тот же пустой ответ.
unevaluated_indexes_test_() ->
    [?_assertEqual([], indexes(all, 3)),
     ?_assertEqual([], indexes(mask(3, []), 3)),
     ?_assertEqual([], indexes(mask(5, []), 3)),
     ?_assertEqual([], indexes(mask(0, []), 0)),
     ?_assertEqual([0, 1, 2], indexes(mask(0, []), 3)),
     ?_assertEqual([2, 3], indexes(mask(2, []), 4)),
     %% Разреженная часть выкалывает отдельные индексы за префиксом.
     ?_assertEqual([1, 3], indexes(mask(1, [2]), 4)),
     ?_assertEqual([3], indexes(mask(3, [4]), 5))].

indexes(Mask, Length) ->
    valid_json_evaluated:unevaluated_indexes(Mask, Length).

merged(Masks) ->
    expand(lists:foldl(fun valid_json_evaluated:merge_items/2,
                       {0, sets:new()}, Masks)).

mask(Prefix, Indexes) ->
    {Prefix, sets:from_list(Indexes)}.

expand({Prefix, Sparse}) -> {Prefix, lists:sort(sets:to_list(Sparse))}.

permutations([]) -> [[]];
permutations(L)  -> [[H | T] || H <- L, T <- permutations(L -- [H])].
