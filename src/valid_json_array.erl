%% Array applicators: спуск в подсхемы по элементам массива. `prefixItems` с
%% хвостовым `items` свёрнуты компилятором в один constraint, array-form `items`
%% с `additionalItems` — во второй, `contains` со своими границами — в третий, но
%% каждый написанный keyword выпускает собственный unit и собственную аннотацию
%% (okf/architecture/validator-core.md, «Контракт handler'а»).
-module(valid_json_array).

-include("valid_json_core.hrl").

-export([check/3]).

%% Применение: сегменты keyword location, индекс элемента, сам элемент и адрес
%% дочерней schema. Элемент несётся рядом с индексом, чтобы обход не доставал его
%% из списка заново.
-type application() :: {[binary()], non_neg_integer(), json(), addr()}.

%% Роль keyword в раскладке: список схем по индексам либо одна схема на остаток
%% массива. Именем keyword роль не определяется — array-form `items` Draft
%% 2019-09 стоит в префиксе, а одноимённый хвостовой `items` Draft 2020-12 в
%% остатке.
-type role() :: prefix | rest.

%% Ненаписанная граница `contains`.
-type bound() :: non_neg_integer() | undefined.

-spec check(constraint(), json(), #eval_context{}) -> #eval_result{}.
check({items, Addr}, Instance, Context) when is_list(Instance) ->
    evaluate([{<<"items">>, rest, elements(<<"items">>, Addr, Instance, 0)}],
             length(Instance), Context);
%% Keywords применяются только к массиву: другое значение даёт успешный unit без
%% error и annotation, а не отказ.
check({items, Addr}, _Instance, Context) ->
    inapplicable([{<<"items">>, Addr}], Context);
check({prefix_items, Addrs, Tail}, Instance, Context) when is_list(Instance) ->
    ordered(<<"prefixItems">>, Addrs, <<"items">>, Tail, Instance, Context);
check({prefix_items, Addrs, Tail}, _Instance, Context) ->
    inapplicable([{<<"prefixItems">>, Addrs}, {<<"items">>, Tail}], Context);
check({items_array, Addrs, Tail}, Instance, Context) when is_list(Instance) ->
    ordered(<<"items">>, Addrs, <<"additionalItems">>, Tail, Instance, Context);
check({items_array, Addrs, Tail}, _Instance, Context) ->
    inapplicable([{<<"items">>, Addrs}, {<<"additionalItems">>, Tail}], Context);
check({contains, Addr, Min, Max, Marks}, Instance, Context) when is_list(Instance) ->
    contains(Addr, Min, Max, Marks, Instance, Context);
check({contains, Addr, Min, Max, _Marks}, _Instance, Context) ->
    inapplicable([{<<"contains">>, Addr},
                  {<<"minContains">>, Min},
                  {<<"maxContains">>, Max}], Context).

%% Раскладки обоих dialects устроены одинаково: список схем разбирает префикс
%% массива, одна схема достаётся остатку. Отличаются они только именами
%% keywords, поэтому дальше несётся роль, а имя нужно локации и тексту ошибки.
-spec ordered(binary(), [addr()], binary(), addr() | undefined, [json()],
              #eval_context{}) -> #eval_result{}.
ordered(Head, Addrs, Tail, TailAddr, Instance, Context) ->
    Prefix  = prefix(Head, Addrs, Instance, 0, []),
    Applied = length(Prefix),
    Rest    = lists:nthtail(Applied, Instance),
    evaluate([{Head, prefix, Prefix},
              {Tail, rest, elements(Tail, TailAddr, Rest, Applied)}],
             length(Instance), Context).

%% Схема из префикса применяется к элементу с тем же индексом; лишние схемы
%% и лишние элементы остаются без пары.
-spec prefix(binary(), [addr()], [json()], non_neg_integer(), [application()]) ->
          [application()].
prefix(_Keyword, [], _Elements, _Index, Acc) ->
    lists:reverse(Acc);
prefix(_Keyword, _Addrs, [], _Index, Acc) ->
    lists:reverse(Acc);
prefix(Keyword, [Addr | Addrs], [Element | Elements], Index, Acc) ->
    Application = {[integer_to_binary(Index), Keyword], Index, Element, Addr},
    prefix(Keyword, Addrs, Elements, Index + 1, [Application | Acc]).

%% Одиночный `items` применяется ко всему массиву, хвостовой keyword — к остатку
%% за префиксом: формы отличаются только первым индексом. Своего сегмента у ветви
%% нет, она стоит на самом keyword.
-spec elements(binary(), addr() | undefined, [json()], non_neg_integer()) ->
          [application()] | undefined.
elements(_Keyword, undefined, _Elements, _Index) ->
    undefined;
elements(Keyword, Addr, Elements, Index) ->
    [{[Keyword], I, Element, Addr} ||
        {I, Element} <- lists:zip(lists:seq(Index, Index + length(Elements) - 1),
                                  Elements)].

%% Обрыв разрешён только в режиме flag; в остальных режимах выполняются оба
%% keyword'а, потому что дерево units должно быть полным.
-spec evaluate([{binary(), role(), [application()] | undefined}], non_neg_integer(),
               #eval_context{}) -> #eval_result{}.
evaluate(Written, Length, Context) ->
    evaluate(Written, Length, Context,
             #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(), units = []}).

evaluate([], _Length, _Context, Result) ->
    Result;
evaluate([{_Keyword, _Role, undefined} | Rest], Length, Context, Result) ->
    evaluate(Rest, Length, Context, Result);
evaluate([{Keyword, Role, Applications} | Rest], Length, Context, Result) ->
    Merged = valid_json_eval:conjoin(
               Result, keyword(Keyword, Role, Applications, Length, Context)),
    case Merged#eval_result.valid =:= false andalso Context#eval_context.format =:= flag of
        true  -> Merged;
        false -> evaluate(Rest, Length, Context, Merged)
    end.

-spec keyword(binary(), role(), [application()], non_neg_integer(), #eval_context{}) ->
          #eval_result{}.
keyword(Keyword, Role, Applications, Length, Context) ->
    {AppliedResult, Applied} =
        apply_all(Applications, Context,
                  #eval_result{valid = true,
                               evaluated = valid_json_evaluated:neutral(),
                               units = []}, 0),
    case AppliedResult of
        #eval_result{valid = undefined} = Error ->
            Error#eval_result{evaluated = valid_json_evaluated:neutral(), units = []};
        #eval_result{valid = Valid, units = Units} ->
            #eval_result{valid     = Valid,
                         evaluated = coverage(Role, Valid, Applied, Length),
                         units     = valid_json_unit:keyword_units(
                                       Keyword, Valid,
                                       detail(Role, Keyword, Valid, Applied, Length),
                                       Units, Context)}
    end.

%% Родитель покрывает индекс элемента, а не то, что нашлось внутри значения:
%% наверх идёт число применённых элементов, а не покрытие их подсхем.
-spec apply_all([application()], #eval_context{}, #eval_result{}, non_neg_integer()) ->
          {#eval_result{}, non_neg_integer()}.
apply_all([], _Context, Result, Applied) ->
    {Result, Applied};
apply_all([{Tail, Index, Element, Addr} | Rest], Context, Result, Applied) ->
    Merged = valid_json_eval:conjoin(
               Result, branch(Addr, Tail, Index, Element, Context)),
    case Merged#eval_result.valid =:= false andalso
         Context#eval_context.format =:= flag of
        true  -> {Merged, Applied + 1};
        false -> apply_all(Rest, Context, Merged, Applied + 1)
    end.

%% Keyword остатка покрывает весь остаток массива, keyword префикса — префикс
%% длиной в число применённых схем, а если их хватило на весь массив, то и его
%% целиком (validator-core.md, «Покрытие при успехе»). Провалившийся keyword
%% аннотации не производит и потому покрытия не вносит.
-spec coverage(role(), boolean(), non_neg_integer(), non_neg_integer()) -> evaluated().
coverage(_Role, false, _Applied, _Length) ->
    valid_json_evaluated:neutral();
coverage(rest, true, _Applied, _Length) ->
    valid_json_evaluated:items(all);
coverage(prefix, true, Applied, Length) when Applied >= Length ->
    valid_json_evaluated:items(all);
coverage(prefix, true, Applied, _Length) ->
    valid_json_evaluated:items({Applied, []}).

%% Аннотация keyword префикса — наибольший индекс, к которому он применился,
%% либо `true`, если он применился ко всем (2020-12 core.txt:2481 про
%% `prefixItems`, 2019-09 core.txt:2274 про array-form `items`). Аннотация
%% keyword остатка — всегда `true`: применившись хоть куда-то, он покрыл весь
%% остаток (2020-12 core.txt:2504, 2019-09 core.txt:2300). Не применявшийся
%% keyword аннотации не производит.
-spec detail(role(), binary(), boolean(), non_neg_integer(), non_neg_integer()) ->
          detail().
detail(Role, Keyword, false, _Applied, _Length) ->
    {error, message(Role, Keyword)};
detail(_Role, _Keyword, true, 0, _Length) ->
    none;
detail(rest, _Keyword, true, _Applied, _Length) ->
    {annotation, true};
detail(prefix, _Keyword, true, Applied, Length) when Applied >= Length ->
    {annotation, true};
detail(prefix, _Keyword, true, Applied, _Length) ->
    {annotation, Applied - 1}.

%% Подсхема применяется к каждому элементу и после первого совпадения: обрыв
%% потерял бы и счёт для `maxContains`, и аннотацию (core.txt:2554). Вердикт
%% самого `contains` — хотя бы одно совпадение, и только `minContains: 0` снимает
%% это требование (core.txt:2533); границы отвечают за свои вердикты сами.
-spec contains(addr(), bound(), bound(), boolean(), [json()], #eval_context{}) ->
          #eval_result{}.
contains(Addr, Min, Max, Marks, Instance, Context) ->
    {Matched, ErrorCount, Error, Units} =
        scan(Addr, Instance, 0, Context, [], 0, undefined, []),
    case Error of
        undefined ->
            contains_complete(Min, Max, Marks, Instance, Matched, Units, Context);
        _ ->
            contains_incomplete(Min, Max, Marks, length(Matched), ErrorCount,
                                Error, Context)
    end.

contains_complete(Min, Max, Marks, Instance, Matched, Units, Context) ->
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
                 units     = lists:append(
                               [valid_json_unit:keyword_units(Keyword, Valid, Detail,
                                                              Nested, Context)
                                || {Keyword, Valid, Detail, Nested} <- Written])}.

%% При no-progress часть элементов имеет неизвестный результат. Если весь
%% диапазон возможного числа совпадений лежит по одну сторону границ, boolean
%% уже определён; иначе ошибка существенна. Неизвестная contains-аннотация
%% остаётся существенной и при известном boolean, когда её ждёт unevaluated*.
contains_incomplete(Min, Max, Marks, Known, Unknown, Error, Context) ->
    Lower = effective_min(Min),
    Least = Known,
    Most = Known + Unknown,
    if
        Most < Lower ->
            incomplete_decided(false);
        Max =/= undefined, Least > Max ->
            incomplete_decided(false);
        Least >= Lower,
        (Max =:= undefined orelse Most =< Max),
        not (Marks andalso Context#eval_context.coverage) ->
            incomplete_decided(true);
        true ->
            valid_json_eval:error_result(Error)
    end.

effective_min(undefined) -> 1;
effective_min(Min) -> Min.

incomplete_decided(Valid) ->
    #eval_result{valid = Valid,
                 evaluated = valid_json_evaluated:neutral(),
                 units = []}.

-spec scan(addr(), [json()], non_neg_integer(), #eval_context{},
           [non_neg_integer()], non_neg_integer(), eval_error() | undefined,
           [#output_unit{}]) ->
          {[non_neg_integer()], non_neg_integer(), eval_error() | undefined,
           [#output_unit{}]}.
scan(_Addr, [], _Index, _Context, Matched, ErrorCount, Error, Units) ->
    {lists:reverse(Matched), ErrorCount, Error, lists:reverse(Units)};
scan(Addr, [Element | Rest], Index, Context, Matched, ErrorCount, Error, Units) ->
    case branch(Addr, [<<"contains">>], Index, Element, Context) of
        #eval_result{valid = undefined, error = ErrorOne} ->
            scan(Addr, Rest, Index + 1, Context, Matched, ErrorCount + 1,
                 first_error(Error, ErrorOne), Units);
        #eval_result{valid = Valid, units = UnitsOne} ->
            scan(Addr, Rest, Index + 1, Context,
                 matched(Valid, Index, Matched), ErrorCount, Error,
                 lists:reverse(UnitsOne, Units))
    end.

first_error(undefined, Error) -> Error;
first_error(Error, _Later) -> Error.

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
%% Флаг `coverage` при спуске гаснет: покрытие дочерней schema принадлежит ей
%% самой (validator-core.md, «Контекст и cycle guard»).
-spec branch(addr(), [binary()], non_neg_integer(), json(), #eval_context{}) ->
          #eval_result{}.
branch(Addr, Tail, Index, Element, Context) ->
    #eval_context{keyword_location = Keywords,
                  instance_location = {Depth, Instance}} = Context,
    Nested = Context#eval_context{keyword_location  = Tail ++ Keywords,
                                  instance_location = {Depth + 1,
                                                       [integer_to_binary(Index) | Instance]},
                                  coverage          = false},
    valid_json_eval:eval(Addr, Element, Nested).

%% Keyword префикса раздаёт по схеме на индекс, keyword остатка — одну схему на
%% всё, что осталось; отсюда и разное число в тексте.
-spec message(role(), binary()) -> binary().
message(prefix, <<"prefixItems">>) ->
    <<"array prefix items do not match their schemas">>;
message(prefix, <<"items">>) ->
    <<"array items do not match their schemas">>;
message(rest, <<"items">>) ->
    <<"array items do not match the schema">>;
message(rest, <<"additionalItems">>) ->
    <<"additional array items do not match the schema">>.

-spec message(binary()) -> binary().
message(<<"contains">>) ->
    <<"array does not contain a matching element">>;
message(<<"minContains">>) ->
    <<"array contains too few matching elements">>;
message(<<"maxContains">>) ->
    <<"array contains too many matching elements">>.

-spec inapplicable([{binary(), term()}], #eval_context{}) -> #eval_result{}.
inapplicable(_Slots, #eval_context{format = flag}) ->
    #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(), units = []};
inapplicable(Slots, Context) ->
    Units = [valid_json_unit:keyword(Keyword, true, none, Context)
             || {Keyword, Slot} <- Slots, Slot =/= undefined],
    #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(), units = Units}.
