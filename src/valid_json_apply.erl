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
           valid_json_evaluated:neutral(), Units, Context);
check({if_then_else, If, Then, Else}, Instance, Context) ->
    conditional(If, Then, Else, Instance, Context);
%% Подсхему выбирает присутствие свойства, а применяется она ко всему instance,
%% поэтому keyword остаётся in-place applicator. Порядок обхода задан сортировкой
%% имён: наблюдаемое дерево units не должно зависеть от порядка обхода map.
check({dependent_schemas, Schemas}, Instance, Context) when is_map(Instance) ->
    Present = [{Name, maps:get(Name, Schemas)}
               || Name <- lists:sort(maps:keys(Schemas)), is_map_key(Name, Instance)],
    dependent(Present, Instance, Context);
%% Keyword применяется только к объекту: другое значение даёт успешный unit без
%% error и annotation, а не отказ.
check({dependent_schemas, _Schemas}, _Instance, Context) ->
    result(<<"dependentSchemas">>, true, none, valid_json_evaluated:neutral(), [], Context).

%% Зависимости конъюнктивны, как ветви `allOf`, и покрытие каждой идёт наверх:
%% подсхема применяется к тому же instance. Провалившаяся своё покрытие очистила
%% сама, поэтому отдельного условия здесь нет.
-spec dependent([{binary(), addr()}], json(), #eval_context{}) -> #eval_result{}.
dependent(Present, Instance, Context) ->
    {Valid, Evaluated, Units} =
        dependent(Present, Instance, Context, true, valid_json_evaluated:neutral(), []),
    result(<<"dependentSchemas">>, Valid,
           <<"value does not match the subschema of a present property">>,
           Evaluated, Units, Context).

dependent([], _Instance, _Context, Valid, Evaluated, Units) ->
    {Valid, Evaluated, lists:reverse(Units)};
dependent([{Name, Addr} | Rest], Instance, Context, Valid, Evaluated, Units) ->
    #eval_result{valid = ValidOne, evaluated = EvaluatedOne, units = UnitsOne} =
        branch(Addr, <<"dependentSchemas">>, [Name], Instance, Context),
    Accumulated = Valid andalso ValidOne,
    Merged = valid_json_evaluated:merge(Evaluated, EvaluatedOne),
    Collected = lists:reverse(UnitsOne, Units),
    case Accumulated =:= false andalso Context#eval_context.mode =:= flag of
        true  -> {false, Merged, lists:reverse(Collected)};
        false -> dependent(Rest, Instance, Context, Accumulated, Merged, Collected)
    end.

%% Вердикта `if` не меняет: он выбирает ветвь (core.txt:2388). Собственный unit
%% он выпускает всегда и всегда успешный — ошибки у этого keyword не бывает, а
%% units опровергнувшей его подсхемы остаются рядом диагностикой. Аннотации он
%% отдаёт и без ветвей (core.txt:2400); при провале своё покрытие подсхема уже
%% очистила сама, поэтому отдельного условия здесь нет.
-spec conditional(addr(), addr() | undefined, addr() | undefined, json(),
                  #eval_context{}) -> #eval_result{}.
conditional(If, Then, Else, Instance, Context) ->
    #eval_result{evaluated = Evaluated, units = Units, valid = Matched} =
        branch(If, <<"if">>, [], Instance, Context),
    Condition = result(<<"if">>, true, none, Evaluated, Units, Context),
    case taken(Matched, Then, Else) of
        undefined       -> Condition;
        {Keyword, Addr} -> both(Condition, selected(Keyword, Addr, Instance, Context))
    end.

%% Ветвь выбирает вердикт `if`, и невыбранная не вычисляется вовсе — ни ради
%% валидации, ни ради аннотаций (core.txt:2422). Ненаписанная ветвь оставляет
%% успех и не выпускает units: применяться было нечему.
-spec taken(boolean(), addr() | undefined, addr() | undefined) ->
          {binary(), addr()} | undefined.
taken(true, Then, _Else) when Then =/= undefined  -> {<<"then">>, Then};
taken(false, _Then, Else) when Else =/= undefined -> {<<"else">>, Else};
taken(_Matched, _Then, _Else)                     -> undefined.

-spec selected(binary(), addr(), json(), #eval_context{}) -> #eval_result{}.
selected(Keyword, Addr, Instance, Context) ->
    #eval_result{valid = Valid, evaluated = Evaluated, units = Units} =
        branch(Addr, Keyword, [], Instance, Context),
    result(Keyword, Valid, message(Keyword), Evaluated, Units, Context).

-spec message(binary()) -> binary().
message(<<"then">>) -> <<"value matches the condition but not the \"then\" subschema">>;
message(<<"else">>) -> <<"value fails the condition and the \"else\" subschema">>.

%% Покрытие дают обе части — сам `if` и выбранная ветвь
%% (validator-core.md, «Покрытие при успехе»), — а вердикт только ветвь.
-spec both(#eval_result{}, #eval_result{}) -> #eval_result{}.
both(#eval_result{evaluated = Condition, units = Before},
     #eval_result{valid = Valid, evaluated = Branch, units = After}) ->
    #eval_result{valid     = Valid,
                 evaluated = valid_json_evaluated:merge(Condition, Branch),
                 units     = Before ++ After}.

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
%% лежат внутри него. В режиме flag units не собираются вовсе. Сообщение `none`
%% принадлежит keyword, который провалиться не может.
-spec result(binary(), boolean(), binary() | none, evaluated(), [#output_unit{}],
             #eval_context{}) -> #eval_result{}.
result(_Keyword, Valid, _Message, Evaluated, _Units, #eval_context{mode = flag}) ->
    #eval_result{valid = Valid, evaluated = Evaluated, units = []};
result(Keyword, Valid, Message, Evaluated, Units, Context) ->
    Unit = valid_json_unit:keyword(Keyword, Valid, detail(Valid, Message), Units, Context),
    #eval_result{valid = Valid, evaluated = Evaluated, units = [Unit]}.

-spec detail(boolean(), binary() | none) -> detail().
detail(true, _Message)  -> none;
detail(false, Message) -> {error, Message}.
