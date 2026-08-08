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
    {Matched, Seen, Error, Evaluated, Units} =
        scan(Addrs, <<"allOf">>, Instance, Context, fun(M, S) -> M < S end),
    logical(<<"allOf">>, all_of_outcome(Matched, Seen, Error),
            <<"value does not match every subschema">>, Evaluated, Units, Context);
check({any_of, Addrs}, Instance, Context) ->
    {Matched, _Seen, Error, Evaluated, Units} =
        scan(Addrs, <<"anyOf">>, Instance, Context, fun(M, _S) -> M > 0 end),
    logical(<<"anyOf">>, any_of_outcome(Matched, Error, Context),
            <<"value does not match any subschema">>, Evaluated, Units, Context);
check({one_of, Addrs}, Instance, Context) ->
    {Matched, _Seen, Error, Evaluated, Units} =
        scan(Addrs, <<"oneOf">>, Instance, Context, fun(M, _S) -> M > 1 end),
    logical(<<"oneOf">>, one_of_outcome(Matched, Error),
            matches(Matched), Evaluated, Units, Context);
%% Успешная внутренняя схема покрытия не переносит: она инстансу не подошла, а
%% была им опровергнута. Units её остаются диагностическими.
check({'not', Addr}, Instance, Context) ->
    case branch(Addr, <<"not">>, [], Instance, Context) of
        #eval_result{valid = undefined} = Error ->
            Error;
        #eval_result{valid = Valid, units = Units} ->
            result(<<"not">>, not Valid, <<"value matches the subschema">>,
                   valid_json_evaluated:neutral(), Units, Context)
    end;
check({if_then_else, If, Then, Else}, Instance, Context) ->
    conditional(If, Then, Else, Instance, Context);
%% Подсхему выбирает присутствие свойства, а применяется она ко всему instance,
%% поэтому keyword остаётся in-place applicator. Порядок обхода задан сортировкой
%% имён: наблюдаемое дерево units не должно зависеть от порядка обхода map.
check({dependent_schemas, Schemas}, Instance, Context) when is_map(Instance) ->
    Present = [{Name, maps:get(Name, Schemas)}
               || Name <- lists:sort(maps:keys(Schemas)), maps:is_key(Name, Instance)],
    dependent(Present, Instance, Context);
%% Keyword применяется только к объекту: другое значение даёт успешный unit без
%% error и annotation, а не отказ.
check({dependent_schemas, _Schemas}, _Instance, Context) ->
    result(<<"dependentSchemas">>, true, none, valid_json_evaluated:neutral(), [], Context);
check({dependencies, Dependencies}, Instance, Context) when is_map(Instance) ->
    Present = [{Name, maps:get(Name, Dependencies)}
               || Name <- lists:sort(maps:keys(Dependencies)), maps:is_key(Name, Instance)],
    legacy_dependencies(Present, Instance, Context);
check({dependencies, _Dependencies}, _Instance, Context) ->
    result(<<"dependencies">>, true, none, valid_json_evaluated:neutral(), [], Context).

%% Зависимости конъюнктивны, как ветви `allOf`, и покрытие каждой идёт наверх:
%% подсхема применяется к тому же instance. Провалившаяся своё покрытие очистила
%% сама, поэтому отдельного условия здесь нет.
-spec dependent([{binary(), addr()}], json(), #eval_context{}) -> #eval_result{}.
dependent(Present, Instance, Context) ->
    case dependent(Present, Instance, Context,
                   valid_json_eval:empty_result(true)) of
        #eval_result{valid = undefined} = Error ->
            Error;
        #eval_result{valid = Valid, evaluated = Evaluated, units = Units} ->
            result(<<"dependentSchemas">>, Valid,
                   <<"value does not match the subschema of a present property">>,
                   Evaluated, Units, Context)
    end.

dependent([], _Instance, _Context, Result) ->
    valid_json_eval:finish_acc(Result);
dependent([{Name, Addr} | Rest], Instance, Context, Result) ->
    Merged = valid_json_eval:conjoin_acc(
               Result,
               branch(Addr, <<"dependentSchemas">>, [Name], Instance, Context)),
    case Merged#eval_result.valid =:= false andalso
         Context#eval_context.format =:= flag of
        true  -> valid_json_eval:finish_acc(Merged);
        false -> dependent(Rest, Instance, Context, Merged)
    end.

%% Legacy `dependencies` is one keyword with two value forms. The property
%% form has no child schema and therefore no nested unit; schema dependencies
%% retain their branch tree and can contribute annotations to the caller.
-spec legacy_dependencies([{binary(), [binary()] | addr()}], #{binary() => json()},
                         #eval_context{}) -> #eval_result{}.
legacy_dependencies(Present, Instance, Context) ->
    case legacy_dependencies(Present, Instance, Context,
                             valid_json_eval:empty_result(true)) of
        #eval_result{valid = undefined} = Error ->
            Error;
        #eval_result{valid = Valid, evaluated = Evaluated, units = Units} ->
            result(<<"dependencies">>, Valid,
                   <<"object does not satisfy dependencies of a present property">>,
                   Evaluated, Units, Context)
    end.

-spec legacy_dependencies([{binary(), [binary()] | addr()}], #{binary() => json()},
                         #eval_context{}, #eval_result{}) -> #eval_result{}.
legacy_dependencies([], _Instance, _Context, Result) ->
    valid_json_eval:finish_acc(Result);
legacy_dependencies([{_Name, Names} | Rest], Instance, Context, Result)
  when is_list(Names) ->
    Valid = lists:all(fun(Name) -> maps:is_key(Name, Instance) end, Names),
    Property = valid_json_eval:empty_result(Valid),
    next_legacy_dependencies(Rest, Instance, Context,
                             valid_json_eval:conjoin_acc(Result, Property));
legacy_dependencies([{Name, Addr} | Rest], Instance, Context, Result) ->
    Branch = branch(Addr, <<"dependencies">>, [Name], Instance, Context),
    next_legacy_dependencies(Rest, Instance, Context,
                             valid_json_eval:conjoin_acc(Result, Branch)).

-spec next_legacy_dependencies([{binary(), [binary()] | addr()}], #{binary() => json()},
                               #eval_context{}, #eval_result{}) -> #eval_result{}.
next_legacy_dependencies(_Rest, _Instance,
                         #eval_context{format = flag},
                         #eval_result{valid = false} = Result) ->
    valid_json_eval:finish_acc(Result);
next_legacy_dependencies(Rest, Instance, Context, Result) ->
    legacy_dependencies(Rest, Instance, Context, Result).

%% Вердикта `if` не меняет: он выбирает ветвь (core.txt:2388). Собственный unit
%% он выпускает всегда и всегда успешный — ошибки у этого keyword не бывает, а
%% units опровергнувшей его подсхемы остаются рядом диагностикой. Аннотации он
%% отдаёт и без ветвей (core.txt:2400); при провале своё покрытие подсхема уже
%% очистила сама, поэтому отдельного условия здесь нет.
-spec conditional(addr(), addr() | undefined, addr() | undefined, json(),
                  #eval_context{}) -> #eval_result{}.
conditional(If, Then, Else, Instance, Context) ->
    case branch(If, <<"if">>, [], Instance, Context) of
        #eval_result{valid = undefined} = Error ->
            Error;
        #eval_result{evaluated = Evaluated, units = Units, valid = Matched} ->
            Condition = result(<<"if">>, true, none, Evaluated, Units, Context),
            case taken(Matched, Then, Else) of
                undefined ->
                    Condition;
                {Keyword, Addr} ->
                    both(Condition,
                         selected(Keyword, Addr, Instance, Context))
            end
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
    case branch(Addr, Keyword, [], Instance, Context) of
        #eval_result{valid = undefined} = Error ->
            Error;
        #eval_result{valid = Valid, evaluated = Evaluated, units = Units} ->
            result(Keyword, Valid, message(Keyword), Evaluated, Units, Context)
    end.

-spec message(binary()) -> binary().
message(<<"then">>) -> <<"value matches the condition but not the \"then\" subschema">>;
message(<<"else">>) -> <<"value fails the condition and the \"else\" subschema">>.

%% Покрытие дают обе части — сам `if` и выбранная ветвь
%% (validator-core.md, «Покрытие при успехе»), — а вердикт только ветвь.
-spec both(#eval_result{}, #eval_result{}) -> #eval_result{}.
both(#eval_result{}, #eval_result{valid = undefined} = Error) ->
    Error;
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
          {non_neg_integer(), non_neg_integer(), eval_error() | undefined,
           evaluated(), [#output_unit{}]}.
scan(Addrs, Keyword, Instance, Context, Stop) ->
    scan(Addrs, 0, Keyword, Instance, Context, Stop,
         {0, 0, undefined, valid_json_evaluated:neutral(), []}).

scan([], _Index, _Keyword, _Instance, _Context, _Stop, Acc) ->
    finish(Acc);
scan([Addr | Rest], Index, Keyword, Instance, Context, Stop,
     {Matched, Seen, Error, Evaluated, Units}) ->
    Acc = case branch(Addr, Keyword, [integer_to_binary(Index)], Instance, Context) of
              #eval_result{valid = undefined, error = ErrorOne} ->
                  {Matched, Seen, first_error(Error, ErrorOne), Evaluated, Units};
              #eval_result{valid = Valid, evaluated = EvaluatedOne,
                           units = UnitsOne} ->
                  {Matched + matched(Valid), Seen + 1, Error,
                   valid_json_evaluated:merge(Evaluated, EvaluatedOne),
                   lists:reverse(UnitsOne, Units)}
          end,
    case stopped(Stop, Acc, Context) of
        true  -> finish(Acc);
        false -> scan(Rest, Index + 1, Keyword, Instance, Context, Stop, Acc)
    end.

finish({Matched, Seen, Error, Evaluated, Units}) ->
    {Matched, Seen, Error, Evaluated, lists:reverse(Units)}.

%% Обрыв разрешён только там, где покрытия уже никто не ждёт: `anyOf`
%% останавливается на первом успехе, а аннотации остальных ветвей могут
%% понадобиться `unevaluated*` выше по обходу.
-spec stopped(stop(), tuple(), #eval_context{}) -> boolean().
stopped(Stop, {Matched, Seen, _Error, _Evaluated, _Units},
        #eval_context{format = flag, coverage = false}) ->
    Stop(Matched, Seen);
stopped(_Stop, _Acc, #eval_context{}) ->
    false.

matched(true)  -> 1;
matched(false) -> 0.

first_error(undefined, Error) -> Error;
first_error(Error, _Later) -> Error.

all_of_outcome(Matched, Seen, _Error) when Matched < Seen ->
    {ok, false};
all_of_outcome(_Matched, _Seen, undefined) ->
    {ok, true};
all_of_outcome(_Matched, _Seen, Error) ->
    {error, Error}.

any_of_outcome(Matched, _Error, #eval_context{coverage = false})
  when Matched > 0 ->
    {ok, true};
any_of_outcome(Matched, undefined, _Context) ->
    {ok, Matched > 0};
any_of_outcome(_Matched, Error, _Context) ->
    {error, Error}.

one_of_outcome(Matched, _Error) when Matched > 1 ->
    {ok, false};
one_of_outcome(Matched, undefined) ->
    {ok, Matched =:= 1};
one_of_outcome(_Matched, Error) ->
    {error, Error}.

logical(Keyword, {ok, Valid}, Message, Evaluated, Units, Context) ->
    result(Keyword, Valid, Message, Evaluated, Units, Context);
logical(_Keyword, {error, Error}, _Message, _Evaluated, _Units, _Context) ->
    valid_json_eval:error_result(Error).

%% Локация ветви — сегмент keyword и, у списочных applicators, её индекс. Стек
%% инстанса не меняется: логические applicators применяют дочернюю schema к тому
%% же значению.
-spec branch(addr(), binary(), [binary()], json(), #eval_context{}) -> #eval_result{}.
branch(Addr, _Keyword, _Tail, Instance,
       #eval_context{format = flag, instance_location = InstanceLocation,
                     coverage = Coverage} = Context) ->
    valid_json_eval:eval_at(Addr, Instance, [], InstanceLocation,
                            Coverage, Context);
branch(Addr, Keyword, Tail, Instance, #eval_context{keyword_location = Location} = Context) ->
    #eval_context{instance_location = InstanceLocation,
                  coverage = Coverage} = Context,
    valid_json_eval:eval_at(Addr, Instance, Tail ++ [Keyword | Location],
                            InstanceLocation, Coverage, Context).

%% Applicator выпускает собственный unit написанного keyword, а units ветвей
%% лежат внутри него. В режиме flag units не собираются вовсе. Сообщение `none`
%% принадлежит keyword, который провалиться не может.
-spec result(binary(), boolean(), binary() | none, evaluated(), [#output_unit{}],
             #eval_context{}) -> #eval_result{}.
result(_Keyword, Valid, _Message, neutral, _Units, #eval_context{format = flag}) ->
    valid_json_eval:empty_result(Valid);
result(_Keyword, Valid, _Message, Evaluated, _Units, #eval_context{format = flag}) ->
    #eval_result{valid = Valid, evaluated = Evaluated, units = []};
result(Keyword, Valid, Message, Evaluated, Units, Context) ->
    Unit = valid_json_unit:keyword(Keyword, Valid, detail(Valid, Message), Units, Context),
    #eval_result{valid = Valid, evaluated = Evaluated, units = [Unit]}.

-spec detail(boolean(), binary() | none) -> detail().
detail(true, _Message)  -> none;
detail(false, Message) -> {error, Message}.
