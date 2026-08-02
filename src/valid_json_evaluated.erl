%% Алгебра эффективного покрытия для unevaluated*: множество имён свойств и
%% маска массива. Форма маски и правило слияния описаны в
%% okf/architecture/validator-core.md, раздел «Два результата».
-module(valid_json_evaluated).

-include("valid_json_core.hrl").

-export([neutral/0, properties/1, items/1, merge/2, merge_items/2]).
-export([unevaluated_indexes/2]).

-spec neutral() -> evaluated().
neutral() ->
    #{properties => sets:new([{version, 2}]),
      items      => {0, sets:new([{version, 2}])}}.

%% Покрытие, внесённое одним object applicator: имена свойств, к которым он
%% применился. Маску массива он не трогает.
-spec properties([binary()]) -> evaluated().
properties(Names) ->
    (neutral())#{properties := sets:from_list(Names, [{version, 2}])}.

%% Покрытие, внесённое одним array applicator: непрерывный префикс и совпавшие
%% индексы `contains`. Список индексов нормализуется здесь, чтобы обработчики не
%% собирали каноническую маску руками. Имён свойств такой applicator не трогает.
-spec items(all | {non_neg_integer(), [non_neg_integer()]}) -> evaluated().
items(all) ->
    (neutral())#{items := all};
items({Prefix, Indexes}) ->
    (neutral())#{items := normalize(Prefix, sets:from_list(Indexes, [{version, 2}]))}.

-spec merge(evaluated(), evaluated()) -> evaluated().
merge(#{properties := P1, items := I1}, #{properties := P2, items := I2}) ->
    #{properties => sets:union(P1, P2),
      items      => merge_items(I1, I2)}.

%% Union по разреженным множествам и max по префиксу. Нормализация обязательна:
%% без неё представление покрытия зависело бы от порядка обхода ветвей.
-spec merge_items(items_mask(), items_mask()) -> items_mask().
merge_items(all, _) -> all;
merge_items(_, all) -> all;
merge_items({P1, S1}, {P2, S2}) ->
    normalize(max(P1, P2), sets:union(S1, S2)).

%% Индексы массива длины Length, которых покрытие не касается: их и получает
%% `unevaluatedItems`. Маска канонична, поэтому исчерпанный префикс сразу
%% отвечает пустым списком, а разреженная часть только выкалывает отдельные
%% индексы за ним.
-spec unevaluated_indexes(items_mask(), non_neg_integer()) -> [non_neg_integer()].
unevaluated_indexes(all, _Length) ->
    [];
unevaluated_indexes({Prefix, _Sparse}, Length) when Prefix >= Length ->
    [];
unevaluated_indexes({Prefix, Sparse}, Length) ->
    [Index || Index <- lists:seq(Prefix, Length - 1),
              not sets:is_element(Index, Sparse)].

-spec normalize(non_neg_integer(), sets:set(non_neg_integer())) -> items_mask().
normalize(P, S) ->
    case sets:is_element(P, S) of
        true  -> normalize(P + 1, sets:del_element(P, S));
        false -> {P, sets:filter(fun(I) -> I > P end, S)}
    end.
