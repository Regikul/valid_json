%% Annotation-dependent applicators: спуск в подсхему по тем свойствам и
%% элементам, которых не коснулся ни один сосед. Отличие от остальных
%% обработчиков — четвёртый аргумент: объединённое покрытие schema object, ради
%% которого эти constraints и выполняются последними
%% (okf/architecture/validator-core.md, «Обход node»).
-module(valid_json_unevaluated).

-include("valid_json_core.hrl").

-export([check/4]).

%% Применение: сегмент локации инстанса и само значение. Сегмент keyword
%% location у обоих keywords один и тот же — они стоят на себе, как
%% `additionalProperties`.
-type application() :: {binary(), json()}.

-spec check(constraint(), json(), evaluated(), #eval_context{}) -> #eval_result{}.
check({unevaluated_properties, Addr}, Instance, Evaluated, Context)
  when is_map(Instance) ->
    Names = valid_json_evaluated:unevaluated_properties(
              Evaluated, maps:keys(Instance)),
    properties([{Name, maps:get(Name, Instance)} || Name <- Names], Addr, Context);
%% Keyword применяется только к своему типу инстанса: другое значение даёт
%% успешный unit без error и annotation, а не отказ.
check({unevaluated_properties, _Addr}, _Instance, _Evaluated, Context) ->
    inapplicable(<<"unevaluatedProperties">>, Context);
check({unevaluated_items, Addr}, Instance, Evaluated, Context)
  when is_list(Instance) ->
    Indexes = valid_json_evaluated:unevaluated_indexes(Evaluated, length(Instance)),
    items(pick(Indexes, Instance, 0), Addr, Context);
check({unevaluated_items, _Addr}, _Instance, _Evaluated, Context) ->
    inapplicable(<<"unevaluatedItems">>, Context).

%% Непокрытые индексы приходят по возрастанию, поэтому массив обходится один
%% раз, а не выбирается поэлементно.
-spec pick([non_neg_integer()], [json()], non_neg_integer()) -> [application()].
pick([], _Elements, _Index) ->
    [];
pick(_Indexes, [], _Index) ->
    [];
pick([Index | Rest], [Element | Elements], Index) ->
    [{integer_to_binary(Index), Element} | pick(Rest, Elements, Index + 1)];
pick(Indexes, [_Element | Elements], Index) ->
    pick(Indexes, Elements, Index + 1).

%% Аннотация называет имена, к которым keyword применился, и остаётся пустым
%% списком, если непокрытых свойств не нашлось: сам keyword всё равно написан.
-spec properties([application()], addr(), #eval_context{}) -> #eval_result{}.
properties(Applications, Addr, Context) ->
    Keyword = <<"unevaluatedProperties">>,
    {AppliedResult, Applied} = apply_all(
                                 Applications, Addr, Keyword, Context,
                                 valid_json_eval:empty_result(true), []),
    keyword_result(Keyword, AppliedResult,
                   valid_json_evaluated:properties(Applied),
                   {annotation, Applied}, Context).

%% Аннотация `unevaluatedItems` — всегда `true`: применившись хоть куда-то, он
%% покрыл весь остаток массива (core.txt:2601). Не применявшийся keyword
%% аннотации не производит, но покрытие вносит: непокрытых индексов не было.
-spec items([application()], addr(), #eval_context{}) -> #eval_result{}.
items(Applications, Addr, Context) ->
    Keyword = <<"unevaluatedItems">>,
    {AppliedResult, Applied} = apply_all(
                                 Applications, Addr, Keyword, Context,
                                 valid_json_eval:empty_result(true), []),
    SuccessDetail = case Applied of
                        [] -> none;
                        _  -> {annotation, true}
                    end,
    keyword_result(Keyword, AppliedResult, valid_json_evaluated:items(all),
                   SuccessDetail, Context).

keyword_result(_Keyword, #eval_result{valid = undefined} = Error,
               _Evaluated, _SuccessDetail, _Context) ->
    Error#eval_result{evaluated = valid_json_evaluated:neutral(), units = []};
keyword_result(Keyword, #eval_result{valid = Valid, units = Units},
               Evaluated, SuccessDetail, Context) ->
    Detail = case Valid of
                 true  -> SuccessDetail;
                 false -> {error, message(Keyword)}
             end,
    #eval_result{valid     = Valid,
                 evaluated = coverage(Valid, Evaluated, Context),
                 units     = valid_json_unit:keyword_units(Keyword, Valid, Detail,
                                                           Units, Context)}.

%% Провалившийся keyword аннотации не производит и потому покрытия не вносит.
-spec coverage(boolean(), evaluated(), #eval_context{}) -> evaluated().
coverage(_Valid, _Evaluated, #eval_context{need_coverage = false}) ->
    valid_json_evaluated:neutral();
coverage(true, Evaluated, #eval_context{}) ->
    Evaluated;
coverage(false, _Evaluated, #eval_context{}) ->
    valid_json_evaluated:neutral().

%% Родитель покрывает само свойство или индекс, а не то, что нашлось внутри
%% значения: наверх идут применённые сегменты, а не покрытие их подсхем.
-spec apply_all([application()], addr(), binary(), #eval_context{}, #eval_result{},
                [binary()]) -> {#eval_result{}, [binary()]}.
apply_all([], _Addr, _Keyword, _Context, Result, Applied) ->
    {valid_json_eval:finish_acc(Result), Applied};
apply_all([{Segment, Value} | Rest], Addr, Keyword, Context, Result, Applied) ->
    Merged = valid_json_eval:conjoin_acc_discard_coverage(
               Result, branch(Addr, Keyword, Segment, Value, Context)),
    case Merged#eval_result.valid =:= false andalso
        Context#eval_context.format =:= flag of
        true  -> {valid_json_eval:finish_acc(Merged),
                  [Segment | Applied]};
        false -> apply_all(Rest, Addr, Keyword, Context, Merged,
                           [Segment | Applied])
    end.

%% Локация keyword следует схеме, локация инстанса — значению. Своего сегмента у
%% ветви нет: она стоит на самом keyword. Флаг `need_coverage` при спуске гаснет:
%% покрытие дочерней schema принадлежит ей самой (validator-core.md, «Контекст
%% и cycle guard»). В формате flag consuming-переход задаётся отдельным входом,
%% а ненаблюдаемые стеки локаций не строятся.
-spec branch(addr(), binary(), binary(), json(), #eval_context{}) -> #eval_result{}.
branch(Addr, _Keyword, _Segment, Value,
       #eval_context{format = flag,
                     instance_location = {Depth, _Instance}} = Context) ->
    valid_json_eval:eval_child_at(
      Addr, Value, [], {Depth + 1, []}, false, Context);
branch(Addr, Keyword, Segment, Value, Context) ->
    #eval_context{keyword_location = Keywords,
                  instance_location = {Depth, Instance}} = Context,
    valid_json_eval:eval_child_at(
      Addr, Value, [Keyword | Keywords],
      {Depth + 1, [Segment | Instance]}, false, Context).

-spec message(binary()) -> binary().
message(<<"unevaluatedProperties">>) ->
    <<"unevaluated object properties do not match the schema">>;
message(<<"unevaluatedItems">>) ->
    <<"unevaluated array items do not match the schema">>.

-spec inapplicable(binary(), #eval_context{}) -> #eval_result{}.
inapplicable(_Keyword, #eval_context{format = flag}) ->
    valid_json_eval:empty_result(true);
inapplicable(Keyword, Context) ->
    #eval_result{valid     = true,
                 evaluated = valid_json_evaluated:neutral(),
                 units     = valid_json_unit:keyword_units(
                               Keyword, true, none, [], Context)}.
