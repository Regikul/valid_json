%% Логические applicators: спуск в дочерние schemas без движения по инстансу.
%% Ветвь вычисляется общим входом evaluator'а по адресу; прямой вызов чужого
%% handler потерял бы локации, dynamic scope и cycle guard
%% (okf/architecture/validator-core.md, «Контракт handler'а»).
-module(valid_json_apply).

-include("valid_json_core.hrl").

-export([check/3]).

-type stop() :: fun((non_neg_integer(), non_neg_integer()) -> boolean()).

%% Условие обрыва каждый applicator задаёт сам: allOf останавливается на первом
%% провале, anyOf — на первом успехе, oneOf — на втором. Действует оно только в
%% режиме flag; в остальных режимах дерево units должно быть полным.
-spec check(constraint(), json(), #eval_context{}) -> #eval_result{}.
check({all_of, Addrs}, Instance, Context) ->
    {Matched, Seen, Evaluated, Units} =
        scan(Addrs, <<"allOf">>, Instance, Context, fun(M, S) -> M < S end),
    result(<<"allOf">>, Matched =:= Seen, <<"value does not match every subschema">>,
           Evaluated, Units, Context);
check({any_of, Addrs}, Instance, Context) ->
    {Matched, _Seen, Evaluated, Units} =
        scan(Addrs, <<"anyOf">>, Instance, Context, fun(M, _S) -> M > 0 end),
    result(<<"anyOf">>, Matched > 0, <<"value does not match any subschema">>,
           Evaluated, Units, Context);
check({one_of, Addrs}, Instance, Context) ->
    {Matched, _Seen, Evaluated, Units} =
        scan(Addrs, <<"oneOf">>, Instance, Context, fun(M, _S) -> M > 1 end),
    result(<<"oneOf">>, Matched =:= 1, matches(Matched), Evaluated, Units, Context);
%% Успешная внутренняя схема покрытия не переносит: она инстансу не подошла, а
%% была им опровергнута. Units её остаются диагностическими.
check({'not', Addr}, Instance, Context) ->
    #eval_result{valid = Valid, units = Units} =
        branch(Addr, <<"not">>, [], Instance, Context),
    result(<<"not">>, not Valid, <<"value matches the subschema">>,
           valid_json_evaluated:neutral(), Units, Context).

-spec matches(non_neg_integer()) -> binary().
matches(0) -> <<"value does not match any subschema">>;
matches(_) -> <<"value matches more than one subschema">>.

%% Общий обход ветвей: считает совпадения и просмотренные ветви, копит покрытие
%% и units. Совпавших хватает всем трём вердиктам, а просмотренных — чтобы
%% отличить полный обход от оборванного.
-spec scan([addr()], binary(), json(), #eval_context{}, stop()) ->
          {non_neg_integer(), non_neg_integer(), evaluated(), [#output_unit{}]}.
scan(Addrs, Keyword, Instance, Context, Stop) ->
    scan(Addrs, 0, Keyword, Instance, Context, Stop,
         {0, 0, valid_json_evaluated:neutral(), []}).

scan([], _Index, _Keyword, _Instance, _Context, _Stop, Acc) ->
    finish(Acc);
scan([Addr | Rest], Index, Keyword, Instance, Context, Stop,
     {Matched, Seen, Evaluated, Units}) ->
    #eval_result{valid = Valid, evaluated = EvaluatedOne, units = UnitsOne} =
        branch(Addr, Keyword, [integer_to_binary(Index)], Instance, Context),
    Acc = {Matched + matched(Valid), Seen + 1,
           valid_json_evaluated:merge(Evaluated, EvaluatedOne),
           lists:reverse(UnitsOne, Units)},
    case stopped(Stop, Acc, Context) of
        true  -> finish(Acc);
        false -> scan(Rest, Index + 1, Keyword, Instance, Context, Stop, Acc)
    end.

finish({Matched, Seen, Evaluated, Units}) ->
    {Matched, Seen, Evaluated, lists:reverse(Units)}.

-spec stopped(stop(), tuple(), #eval_context{}) -> boolean().
stopped(Stop, {Matched, Seen, _Evaluated, _Units}, #eval_context{mode = flag}) ->
    Stop(Matched, Seen);
stopped(_Stop, _Acc, #eval_context{}) ->
    false.

matched(true)  -> 1;
matched(false) -> 0.

%% Локация ветви — сегмент keyword и, у списочных applicators, её индекс. Стек
%% инстанса не меняется: логические applicators применяют дочернюю schema к тому
%% же значению.
-spec branch(addr(), binary(), [binary()], json(), #eval_context{}) -> #eval_result{}.
branch(Addr, Keyword, Tail, Instance, #eval_context{keyword_location = Location} = Context) ->
    Nested = Context#eval_context{keyword_location = Tail ++ [Keyword | Location]},
    valid_json_eval:eval(Addr, Instance, Nested).

%% Applicator выпускает собственный unit написанного keyword, а units ветвей
%% остаются рядом с ним. В режиме flag units не собираются вовсе.
-spec result(binary(), boolean(), binary(), evaluated(), [#output_unit{}],
             #eval_context{}) -> #eval_result{}.
result(_Keyword, Valid, _Message, Evaluated, _Units, #eval_context{mode = flag}) ->
    #eval_result{valid = Valid, evaluated = Evaluated, units = []};
result(Keyword, Valid, Message, Evaluated, Units, Context) ->
    Unit = valid_json_unit:keyword(Keyword, Valid, detail(Valid, Message), Context),
    #eval_result{valid = Valid, evaluated = Evaluated, units = [Unit | Units]}.

-spec detail(boolean(), binary()) -> detail().
detail(true, _Message)  -> none;
detail(false, Message) -> {error, Message}.
