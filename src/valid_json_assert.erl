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
    number(fun(Number) -> Number > Bound end, Instance).

%% Keyword ограничивает только свой тип instance: значение другого типа проходит
%% успешно, а не отвергается. Сравнение чисел в Erlang точно и через границу
%% integer/float, поэтому 300 и 300.0 остаются одной точкой.
-spec number(fun((number()) -> boolean()), json()) -> #eval_result{}.
number(Check, Instance) when is_number(Instance) ->
    result(Check(Instance));
number(_Check, _Instance) ->
    result(true).

%% Чистые assertions не вносят покрытия. Units не собираются, пока не появилась
%% проекция basic; тогда каждый handler начнёт строить свой unit сам.
-spec result(boolean()) -> #eval_result{}.
result(Valid) ->
    #eval_result{valid = Valid, evaluated = valid_json_evaluated:neutral(), units = []}.
