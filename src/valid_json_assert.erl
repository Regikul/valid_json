%% Обработчики чистых assertions. Handler видит constraint, значение и контекст;
%% схему, dialect и registry он не читает. Контракт описан в
%% okf/architecture/validator-core.md, раздел «Контракт handler'а».
-module(valid_json_assert).

-include("valid_json_core.hrl").

-export([check/3]).

%% JSON equality есть Erlang ==: оно рекурсивно, считает 1 и 1.0 равными и не
%% смешивает boolean с number. Поэтому lists:member/2 здесь неприменим.
-spec check(constraint(), json(), #eval_context{}) -> #eval_result{}.
check({type, Types}, Instance, _Context) ->
    result(lists:any(fun(Type) -> valid_json_value:is_type(Type, Instance) end, Types));
check({enum, Values}, Instance, _Context) ->
    result(lists:any(fun(Value) -> Value == Instance end, Values));
check({const, Value}, Instance, _Context) ->
    result(Value == Instance);
check({multiple_of, Divisor}, Instance, _Context) ->
    number(fun(Number) -> valid_json_value:is_multiple_of(Number, Divisor) end, Instance);
check({maximum, Bound}, Instance, _Context) ->
    number(fun(Number) -> Number =< Bound end, Instance);
check({exclusive_maximum, Bound}, Instance, _Context) ->
    number(fun(Number) -> Number < Bound end, Instance);
check({minimum, Bound}, Instance, _Context) ->
    number(fun(Number) -> Number >= Bound end, Instance);
check({exclusive_minimum, Bound}, Instance, _Context) ->
    number(fun(Number) -> Number > Bound end, Instance);
check({pattern, {_Source, Compiled}}, Instance, _Context) ->
    string(fun(Text) -> re:run(Text, Compiled, [{capture, none}]) =:= match end, Instance);
check({max_length, Bound}, Instance, _Context) ->
    string(fun(Text) -> valid_json_value:is_length_at_most(Text, Bound) end, Instance);
check({min_length, Bound}, Instance, _Context) ->
    string(fun(Text) -> valid_json_value:is_length_at_least(Text, Bound) end, Instance);
check({max_items, Bound}, Instance, _Context) ->
    array(fun(Items) -> length(Items) =< Bound end, Instance);
check({min_items, Bound}, Instance, _Context) ->
    array(fun(Items) -> length(Items) >= Bound end, Instance);
%% uniqueItems: false остаётся в IR и выпускает собственный unit, поэтому
%% no-op вычисляется, а не выбрасывается компилятором.
check({unique_items, false}, _Instance, _Context) ->
    result(true);
check({unique_items, true}, Instance, _Context) ->
    array(fun valid_json_value:is_unique/1, Instance);
check({max_properties, Bound}, Instance, _Context) ->
    object(fun(Object) -> map_size(Object) =< Bound end, Instance);
check({min_properties, Bound}, Instance, _Context) ->
    object(fun(Object) -> map_size(Object) >= Bound end, Instance);
check({required, Names}, Instance, _Context) ->
    object(fun(Object) -> present(Names, Object) end, Instance);
check({dependent_required, Dependencies}, Instance, _Context) ->
    object(fun(Object) -> dependencies_met(Dependencies, Object) end, Instance).

%% Требование включается только для имён, которые в instance действительно есть.
-spec dependencies_met(#{binary() => [binary()]}, #{binary() => json()}) -> boolean().
dependencies_met(Dependencies, Object) ->
    Met = fun(Name, Names) ->
              not is_map_key(Name, Object) orelse present(Names, Object)
          end,
    lists:all(fun({Name, Names}) -> Met(Name, Names) end, maps:to_list(Dependencies)).

-spec present([binary()], #{binary() => json()}) -> boolean().
present(Names, Object) ->
    lists:all(fun(Name) -> is_map_key(Name, Object) end, Names).

%% Keyword ограничивает только свой тип instance: значение другого типа проходит
%% успешно, а не отвергается. Сравнение чисел в Erlang точно и через границу
%% integer/float, поэтому 300 и 300.0 остаются одной точкой.
-spec number(fun((number()) -> boolean()), json()) -> #eval_result{}.
number(Check, Instance) when is_number(Instance) ->
    result(Check(Instance));
number(_Check, _Instance) ->
    result(true).

%% То же правило применимости для строк. Instance приходит из json:decode/1 и
%% потому является корректным UTF-8, что и требует unicode-режим движка.
-spec string(fun((binary()) -> boolean()), json()) -> #eval_result{}.
string(Check, Instance) when is_binary(Instance) ->
    result(Check(Instance));
string(_Check, _Instance) ->
    result(true).

-spec array(fun(([json()]) -> boolean()), json()) -> #eval_result{}.
array(Check, Instance) when is_list(Instance) ->
    result(Check(Instance));
array(_Check, _Instance) ->
    result(true).

-spec object(fun((#{binary() => json()}) -> boolean()), json()) -> #eval_result{}.
object(Check, Instance) when is_map(Instance) ->
    result(Check(Instance));
object(_Check, _Instance) ->
    result(true).

%% Чистые assertions не вносят покрытия. Units не собираются, пока не появилась
%% проекция basic; тогда каждый handler начнёт строить свой unit сам.
-spec result(boolean()) -> #eval_result{}.
result(Valid) ->
    #eval_result{valid = Valid, evaluated = valid_json_evaluated:neutral(), units = []}.
