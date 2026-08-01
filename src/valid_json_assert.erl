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
    result(Value == Instance).

%% Чистые assertions не вносят покрытия. Units не собираются, пока не появилась
%% проекция basic; тогда каждый handler начнёт строить свой unit сам.
-spec result(boolean()) -> #eval_result{}.
result(Valid) ->
    #eval_result{valid = Valid, evaluated = valid_json_evaluated:neutral(), units = []}.
