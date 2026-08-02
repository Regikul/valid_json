%% Array applicators: спуск в подсхемы по элементам массива. `prefixItems` с
%% хвостовым `items` свёрнуты компилятором в один constraint, `contains` со
%% своими границами — в другой, но каждый написанный keyword выпускает
%% собственный unit и собственную аннотацию (okf/architecture/validator-core.md,
%% «Контракт handler'а»).
-module(valid_json_array).

-include("valid_json_core.hrl").

-export([check/3]).

%% Применение: сегменты keyword location, индекс элемента, сам элемент и адрес
%% дочерней schema. Элемент несётся рядом с индексом, чтобы обход не доставал его
%% из списка заново.
-type application() :: {[binary()], non_neg_integer(), json(), addr()}.

%% Ненаписанная граница `contains`.
-type bound() :: non_neg_integer() | undefined.

-spec check(constraint(), json(), #eval_context{}) -> #eval_result{}.
check({items, Addr}, Instance, Context) when is_list(Instance) ->
    evaluate([{<<"items">>, elements(Addr, Instance, 0)}], length(Instance), Context);
%% Keywords применяются только к массиву: другое значение даёт успешный unit без
%% error и annotation, а не отказ.
check({items, Addr}, _Instance, Context) ->
    inapplicable([{<<"items">>, Addr}], Context);
check({prefix_items, Addrs, Tail}, Instance, Context) when is_list(Instance) ->
    Prefix  = prefix(Addrs, Instance, 0, []),
    Applied = length(Prefix),
    Rest    = lists:nthtail(Applied, Instance),
    evaluate([{<<"prefixItems">>, Prefix},
              {<<"items">>, elements(Tail, Rest, Applied)}],
             length(Instance), Context);
check({prefix_items, Addrs, Tail}, _Instance, Context) ->
    inapplicable([{<<"prefixItems">>, Addrs}, {<<"items">>, Tail}], Context);
check({contains, Addr, Min, Max, Marks}, Instance, Context) when is_list(Instance) ->
    contains(Addr, Min, Max, Marks, Instance, Context);
check({contains, Addr, Min, Max, _Marks}, _Instance, Context) ->
    inapplicable([{<<"contains">>, Addr},
                  {<<"minContains">>, Min},
                  {<<"maxContains">>, Max}], Context).

%% Схема из `prefixItems` применяется к элементу с тем же индексом; лишние схемы
%% и лишние элементы остаются без пары.
-spec prefix([addr()], [json()], non_neg_integer(), [application()]) -> [application()].
prefix([], _Elements, _Index, Acc) ->
    lists:reverse(Acc);
prefix(_Addrs, [], _Index, Acc) ->
    lists:reverse(Acc);
prefix([Addr | Addrs], [Element | Elements], Index, Acc) ->
    Application = {[integer_to_binary(Index), <<"prefixItems">>], Index, Element, Addr},
    prefix(Addrs, Elements, Index + 1, [Application | Acc]).

%% `items` без `prefixItems` применяется ко всему массиву, хвостовой — к остатку
%% за префиксом: формы отличаются только первым индексом. Своего сегмента у ветви
%% нет, она стоит на самом keyword.
-spec elements(addr() | undefined, [json()], non_neg_integer()) ->
          [application()] | undefined.
elements(undefined, _Elements, _Index) ->
    undefined;
elements(Addr, Elements, Index) ->
    [{[<<"items">>], I, Element, Addr} || {I, Element} <- lists:enumerate(Index, Elements)].

%% Обрыв разрешён только в режиме flag; в остальных режимах выполняются оба
%% keyword'а, потому что дерево units должно быть полным.
-spec evaluate([{binary(), [application()] | undefined}], non_neg_integer(),
               #eval_context{}) -> #eval_result{}.
evaluate(Written, Length, Context) ->
    evaluate(Written, Length, Context,
             #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(), units = []}).

evaluate([], _Length, _Context, #eval_result{units = Units} = Result) ->
    Result#eval_result{units = lists:reverse(Units)};
evaluate([{_Keyword, undefined} | Rest], Length, Context, Result) ->
    evaluate(Rest, Length, Context, Result);
evaluate([{Keyword, Applications} | Rest], Length, Context,
         #eval_result{valid = Valid, evaluated = Evaluated, units = Units}) ->
    #eval_result{valid = ValidOne, evaluated = EvaluatedOne, units = UnitsOne} =
        keyword(Keyword, Applications, Length, Context),
    Merged = #eval_result{valid     = Valid andalso ValidOne,
                          evaluated = valid_json_evaluated:merge(Evaluated, EvaluatedOne),
                          units     = lists:reverse(UnitsOne, Units)},
    case Merged#eval_result.valid =:= false andalso Context#eval_context.mode =:= flag of
        true  -> Merged#eval_result{units = lists:reverse(Merged#eval_result.units)};
        false -> evaluate(Rest, Length, Context, Merged)
    end.

-spec keyword(binary(), [application()], non_neg_integer(), #eval_context{}) ->
          #eval_result{}.
keyword(Keyword, Applications, Length, Context) ->
    {Valid, Applied, Units} = apply_all(Applications, Context, true, 0, []),
    #eval_result{valid     = Valid,
                 evaluated = coverage(Keyword, Valid, Applied, Length),
                 units     = own(Keyword, Valid, detail(Keyword, Valid, Applied, Length),
                                 Units, Context)}.

%% Покрытие дочерней schema принадлежит ей самой и наверх не идёт: родитель
%% покрывает индекс элемента, а не то, что нашлось внутри значения.
-spec apply_all([application()], #eval_context{}, boolean(), non_neg_integer(),
                [#output_unit{}]) -> {boolean(), non_neg_integer(), [#output_unit{}]}.
apply_all([], _Context, Valid, Applied, Units) ->
    {Valid, Applied, lists:reverse(Units)};
apply_all([{Tail, Index, Element, Addr} | Rest], Context, Valid, Applied, Units) ->
    #eval_result{valid = ValidOne, units = UnitsOne} =
        branch(Addr, Tail, Index, Element, Context),
    Accumulated = Valid andalso ValidOne,
    Collected = lists:reverse(UnitsOne, Units),
    case Accumulated =:= false andalso Context#eval_context.mode =:= flag of
        true  -> {false, Applied + 1, lists:reverse(Collected)};
        false -> apply_all(Rest, Context, Accumulated, Applied + 1, Collected)
    end.

%% `items` покрывает весь остаток массива, `prefixItems` — префикс длиной в число
%% применённых схем, а если их хватило на весь массив, то и его целиком
%% (validator-core.md, «Покрытие при успехе»). Провалившийся keyword аннотации не
%% производит и потому покрытия не вносит.
-spec coverage(binary(), boolean(), non_neg_integer(), non_neg_integer()) -> evaluated().
coverage(_Keyword, false, _Applied, _Length) ->
    valid_json_evaluated:neutral();
coverage(<<"items">>, true, _Applied, _Length) ->
    valid_json_evaluated:items(all);
coverage(<<"prefixItems">>, true, Applied, Length) when Applied >= Length ->
    valid_json_evaluated:items(all);
coverage(<<"prefixItems">>, true, Applied, _Length) ->
    valid_json_evaluated:items({Applied, []}).

%% Аннотация `prefixItems` — наибольший индекс, к которому keyword применился,
%% либо `true`, если он применился ко всем (core.txt:2481). Аннотация `items` —
%% всегда `true`: применившись хоть куда-то, он покрыл весь остаток
%% (core.txt:2504). Не применявшийся keyword аннотации не производит.
-spec detail(binary(), boolean(), non_neg_integer(), non_neg_integer()) -> detail().
detail(Keyword, false, _Applied, _Length) ->
    {error, message(Keyword)};
detail(_Keyword, true, 0, _Length) ->
    none;
detail(<<"items">>, true, _Applied, _Length) ->
    {annotation, true};
detail(<<"prefixItems">>, true, Applied, Length) when Applied >= Length ->
    {annotation, true};
detail(<<"prefixItems">>, true, Applied, _Length) ->
    {annotation, Applied - 1}.

%% Подсхема применяется к каждому элементу и после первого совпадения: обрыв
%% потерял бы и счёт для `maxContains`, и аннотацию (core.txt:2554). Вердикт
%% самого `contains` — хотя бы одно совпадение, и только `minContains: 0` снимает
%% это требование (core.txt:2533); границы отвечают за свои вердикты сами.
-spec contains(addr(), bound(), bound(), boolean(), [json()], #eval_context{}) ->
          #eval_result{}.
contains(Addr, Min, Max, Marks, Instance, Context) ->
    {Matched, Units} = scan(Addr, Instance, 0, Context, [], []),
    Length = length(Instance),
    Count  = length(Matched),
    Found  = Count > 0 orelse Min =:= 0,
    %% Обход общий, но подсхему применял только `contains`, поэтому units ветвей
    %% лежат внутри его unit'а, а границы остаются листьями.
    Written = [{<<"contains">>, Found, found(Found, Matched, Count, Length), Units}]
              ++ bounded(<<"minContains">>, Min, at_least(Count, Min))
              ++ bounded(<<"maxContains">>, Max, at_most(Count, Max)),
    #eval_result{valid     = lists:all(fun({_K, Valid, _D, _N}) -> Valid end, Written),
                 evaluated = marks(Marks, Found, Matched, Count, Length),
                 units     = lists:append([own(Keyword, Valid, Detail, Nested, Context)
                                           || {Keyword, Valid, Detail, Nested} <- Written])}.

-spec scan(addr(), [json()], non_neg_integer(), #eval_context{},
           [non_neg_integer()], [#output_unit{}]) ->
          {[non_neg_integer()], [#output_unit{}]}.
scan(_Addr, [], _Index, _Context, Matched, Units) ->
    {lists:reverse(Matched), lists:reverse(Units)};
scan(Addr, [Element | Rest], Index, Context, Matched, Units) ->
    #eval_result{valid = Valid, units = UnitsOne} =
        branch(Addr, [<<"contains">>], Index, Element, Context),
    scan(Addr, Rest, Index + 1, Context, matched(Valid, Index, Matched),
         lists:reverse(UnitsOne, Units)).

matched(true, Index, Matched)   -> [Index | Matched];
matched(false, _Index, Matched) -> Matched.

%% Аннотация — индексы совпавших элементов по возрастанию либо `true`, если
%% совпали все; на пустом массиве она обязана присутствовать (core.txt:2540).
-spec found(boolean(), [non_neg_integer()], non_neg_integer(), non_neg_integer()) ->
          detail().
found(false, _Matched, _Count, _Length) ->
    {error, message(<<"contains">>)};
found(true, _Matched, Count, Length) when Length > 0, Count =:= Length ->
    {annotation, true};
found(true, Matched, _Count, _Length) ->
    {annotation, Matched}.

%% Ненаписанная граница ни unit, ни вердикта не даёт: спецификация оставляет её
%% без эффекта. Аннотаций границы не производят, поэтому у успеха деталей нет.
-spec bounded(binary(), bound(), boolean()) ->
          [{binary(), boolean(), detail(), [#output_unit{}]}].
bounded(_Keyword, undefined, _Valid) -> [];
bounded(Keyword, _Value, true)       -> [{Keyword, true, none, []}];
bounded(Keyword, _Value, false)      -> [{Keyword, false, {error, message(Keyword)}, []}].

-spec at_least(non_neg_integer(), bound()) -> boolean().
at_least(_Count, undefined) -> true;
at_least(Count, Min)        -> Count >= Min.

-spec at_most(non_neg_integer(), bound()) -> boolean().
at_most(_Count, undefined) -> true;
at_most(Count, Max)        -> Count =< Max.

%% Разреженную часть маски порождает только `contains` и только в Draft 2020-12:
%% в Draft 2019-09 его аннотация на `unevaluatedItems` не влияет
%% (validator-core.md, «Составные constraints»).
-spec marks(boolean(), boolean(), [non_neg_integer()], non_neg_integer(),
            non_neg_integer()) -> evaluated().
marks(false, _Found, _Matched, _Count, _Length) ->
    valid_json_evaluated:neutral();
marks(true, false, _Matched, _Count, _Length) ->
    valid_json_evaluated:neutral();
marks(true, true, _Matched, Count, Length) when Length > 0, Count =:= Length ->
    valid_json_evaluated:items(all);
marks(true, true, Matched, _Count, _Length) ->
    valid_json_evaluated:items({0, Matched}).

%% Локация keyword следует схеме, локация инстанса — значению: индекс элемента
%% двигает второй стек, а сегменты первого зависят от применившегося keyword.
%% Ожидание покрытия сюда не наследуется: покрытие дочерней schema принадлежит
%% ей самой, и обрывать её обход ради чужих аннотаций незачем.
-spec branch(addr(), [binary()], non_neg_integer(), json(), #eval_context{}) ->
          #eval_result{}.
branch(Addr, Tail, Index, Element, Context) ->
    #eval_context{keyword_location = Keywords, instance_location = Instance} = Context,
    Nested = Context#eval_context{keyword_location  = Tail ++ Keywords,
                                  instance_location = [integer_to_binary(Index) | Instance],
                                  coverage          = false},
    valid_json_eval:eval(Addr, Element, Nested).

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
message(<<"items">>) ->
    <<"array items do not match the schema">>;
message(<<"prefixItems">>) ->
    <<"array prefix items do not match their schemas">>;
message(<<"contains">>) ->
    <<"array does not contain a matching element">>;
message(<<"minContains">>) ->
    <<"array contains too few matching elements">>;
message(<<"maxContains">>) ->
    <<"array contains too many matching elements">>.

-spec inapplicable([{binary(), term()}], #eval_context{}) -> #eval_result{}.
inapplicable(_Slots, #eval_context{mode = flag}) ->
    #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(), units = []};
inapplicable(Slots, Context) ->
    Units = [valid_json_unit:keyword(Keyword, true, none, Context)
             || {Keyword, Slot} <- Slots, Slot =/= undefined],
    #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(), units = Units}.
