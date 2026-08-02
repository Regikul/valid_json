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
check({unevaluated_properties, Addr}, Instance, #{properties := Covered}, Context)
  when is_map(Instance) ->
    Names = [Name || Name <- lists:sort(maps:keys(Instance)),
                     not sets:is_element(Name, Covered)],
    properties([{Name, maps:get(Name, Instance)} || Name <- Names], Addr, Context);
%% Keyword применяется только к своему типу инстанса: другое значение даёт
%% успешный unit без error и annotation, а не отказ.
check({unevaluated_properties, _Addr}, _Instance, _Evaluated, Context) ->
    inapplicable(<<"unevaluatedProperties">>, Context);
check({unevaluated_items, Addr}, Instance, #{items := Mask}, Context)
  when is_list(Instance) ->
    Indexes = valid_json_evaluated:unevaluated_indexes(Mask, length(Instance)),
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
    {Valid, Applied, Units} = apply_all(Applications, Addr, Keyword, Context, true, [], []),
    Detail = case Valid of
                 true  -> {annotation, Applied};
                 false -> {error, message(Keyword)}
             end,
    #eval_result{valid     = Valid,
                 evaluated = coverage(Valid, valid_json_evaluated:properties(Applied)),
                 units     = own(Keyword, Valid, Detail, Units, Context)}.

%% Аннотация `unevaluatedItems` — всегда `true`: применившись хоть куда-то, он
%% покрыл весь остаток массива (core.txt:2601). Не применявшийся keyword
%% аннотации не производит, но покрытие вносит: непокрытых индексов не было.
-spec items([application()], addr(), #eval_context{}) -> #eval_result{}.
items(Applications, Addr, Context) ->
    Keyword = <<"unevaluatedItems">>,
    {Valid, Applied, Units} = apply_all(Applications, Addr, Keyword, Context, true, [], []),
    Detail = case {Valid, Applied} of
                 {false, _}  -> {error, message(Keyword)};
                 {true, []}  -> none;
                 {true, _}   -> {annotation, true}
             end,
    #eval_result{valid     = Valid,
                 evaluated = coverage(Valid, valid_json_evaluated:items(all)),
                 units     = own(Keyword, Valid, Detail, Units, Context)}.

%% Провалившийся keyword аннотации не производит и потому покрытия не вносит.
-spec coverage(boolean(), evaluated()) -> evaluated().
coverage(true, Evaluated)   -> Evaluated;
coverage(false, _Evaluated) -> valid_json_evaluated:neutral().

%% Покрытие дочерней schema принадлежит ей самой и наверх не идёт: родитель
%% покрывает само свойство или индекс, а не то, что нашлось внутри значения.
-spec apply_all([application()], addr(), binary(), #eval_context{}, boolean(),
                [binary()], [#output_unit{}]) ->
          {boolean(), [binary()], [#output_unit{}]}.
apply_all([], _Addr, _Keyword, _Context, Valid, Applied, Units) ->
    {Valid, lists:reverse(Applied), lists:reverse(Units)};
apply_all([{Segment, Value} | Rest], Addr, Keyword, Context, Valid, Applied, Units) ->
    #eval_result{valid = ValidOne, units = UnitsOne} =
        branch(Addr, Keyword, Segment, Value, Context),
    Accumulated = Valid andalso ValidOne,
    Collected = lists:reverse(UnitsOne, Units),
    case Accumulated =:= false andalso Context#eval_context.mode =:= flag of
        true  -> {false, lists:reverse([Segment | Applied]), lists:reverse(Collected)};
        false -> apply_all(Rest, Addr, Keyword, Context, Accumulated,
                           [Segment | Applied], Collected)
    end.

%% Локация keyword следует схеме, локация инстанса — значению. Своего сегмента у
%% ветви нет: она стоит на самом keyword.
-spec branch(addr(), binary(), binary(), json(), #eval_context{}) -> #eval_result{}.
branch(Addr, Keyword, Segment, Value, Context) ->
    #eval_context{keyword_location = Keywords, instance_location = Instance} = Context,
    Nested = Context#eval_context{keyword_location  = [Keyword | Keywords],
                                  instance_location = [Segment | Instance],
                                  coverage          = false},
    valid_json_eval:eval(Addr, Value, Nested).

%% Units применённых подсхем лежат внутри unit'а того keyword, который их
%% применил. В режиме flag units не собираются вовсе: ответ исчерпывается
%% вердиктом.
-spec own(binary(), boolean(), detail(), [#output_unit{}], #eval_context{}) ->
          [#output_unit{}].
own(_Keyword, _Valid, _Detail, _Nested, #eval_context{mode = flag}) ->
    [];
own(Keyword, Valid, Detail, Nested, Context) ->
    [valid_json_unit:keyword(Keyword, Valid, Detail, Nested, Context)].

-spec message(binary()) -> binary().
message(<<"unevaluatedProperties">>) ->
    <<"unevaluated object properties do not match the schema">>;
message(<<"unevaluatedItems">>) ->
    <<"unevaluated array items do not match the schema">>.

-spec inapplicable(binary(), #eval_context{}) -> #eval_result{}.
inapplicable(_Keyword, #eval_context{mode = flag}) ->
    #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(), units = []};
inapplicable(Keyword, Context) ->
    #eval_result{valid     = true,
                 evaluated = valid_json_evaluated:neutral(),
                 units     = [valid_json_unit:keyword(Keyword, true, none, Context)]}.
