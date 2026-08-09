%% Обход node. Порядок шагов и разделение двух результатов описаны
%% в okf/architecture/validator-core.md, раздел «Вычисление».
-module(valid_json_eval).

-include("valid_json_core.hrl").

-export([run/3, eval/3, eval_child_at/6, eval_in_place_at/6,
         resolve/2, conjoin/2, conjoin_acc/2,
         conjoin_acc_discard_coverage/2, finish_acc/1, empty_result/1,
         error_result/1]).

%% Единственный вход в вычисление. Cycle guard — единственная причина отказа.
-spec run(compiled(), json(), format()) -> {ok, #eval_result{}} | {error, eval_error()}.
run(#{root := Root} = Compiled, Instance, Format) ->
    Context = #eval_context{schema            = Compiled,
                            node              = {Root, <<>>},
                            keyword_location  = [],
                            instance_location = [],
                            dynamic_scope     = [Root],
                            guard             = #{},
                            format            = Format,
                            need_coverage     = false},
    case eval({Root, <<>>}, Instance, Context) of
        #eval_result{valid = undefined, error = Error} -> {error, Error};
        #eval_result{} = Result ->
            {ok, finish_root(resolve({Root, <<>>}, Compiled), Result, Context)}
    end.

%% Basic собирается сразу плоским, но публичный формат всё равно имеет один
%% корневой output unit. Оборачиваем его только здесь: дочерним nodes такой
%% контейнер не нужен. У boolean false собственная ошибка принадлежит корню, а
%% не дублируется в его `errors`.
-spec finish_root(schema_node(), #eval_result{}, #eval_context{}) -> #eval_result{}.
finish_root(_Root, Result, #eval_context{format = flag}) ->
    Result;
finish_root(false, #eval_result{valid = false} = Result,
            #eval_context{format = basic} = Context) ->
    Root = valid_json_unit:schema(false, {error, <<"schema is false">>}, [], Context),
    Result#eval_result{units = [Root]};
finish_root(_Root, #eval_result{valid = Valid, units = Units} = Result,
            #eval_context{format = basic} = Context) ->
    Root = valid_json_unit:schema(Valid, none, Units, Context),
    Result#eval_result{units = [Root]};
finish_root(_Root, Result, #eval_context{}) ->
    Result.

%% Разрешение адреса в готовом артефакте тотально.
-spec resolve(addr(), compiled()) -> schema_node().
resolve({Rid, Pointer}, #{resources := Resources}) ->
    #resource{nodes = Nodes} = maps:get(Rid, Resources),
    maps:get(Pointer, Nodes).

%% Корневой вход начинает независимую ветвь. Текущий node не лежит в guard:
%% in-place вход сравнивает цель с ним отдельно, а guard хранит только более
%% ранних предков на той же позиции instance.
-spec eval(addr(), json(), #eval_context{}) -> #eval_result{}.
eval(Addr, Instance,
     #eval_context{keyword_location = Keywords,
                   instance_location = InstanceLocation,
                   need_coverage = NeedCoverage} = Context) ->
    eval_entered(Addr, Instance, Keywords, InstanceLocation, NeedCoverage,
                 #{}, Context).

%% Consuming applicator переходит к другому JSON value. Ни один активный node
%% прежней позиции не может образовать с ним no-progress cycle, поэтому новый
%% guard начинается пустым и не требует ни lookup, ни allocation.
-spec eval_child_at(addr(), json(), [binary()], instance_location(), boolean(),
                    #eval_context{}) -> #eval_result{}.
eval_child_at(Addr, Instance, Keywords, InstanceLocation, NeedCoverage, Context) ->
    eval_entered(Addr, Instance, Keywords, InstanceLocation, NeedCoverage,
                 #{}, Context).

%% In-place applicator сохраняет JSON value. Возврат к текущему node или любому
%% его предку на этой позиции дословно повторил бы тот же обход. Перед переходом
%% текущий node становится предком цели; sibling branches получают исходный
%% immutable context и потому друг друга не блокируют.
-spec eval_in_place_at(addr(), json(), [binary()], instance_location(), boolean(),
                       #eval_context{}) -> #eval_result{}.
eval_in_place_at(Addr, Instance, Keywords, InstanceLocation, NeedCoverage,
                 #eval_context{node = Current, guard = Guard} = Context) ->
    case Addr =:= Current orelse maps:is_key(Addr, Guard) of
        true ->
            error_result({no_progress, Addr});
        false ->
            eval_entered(Addr, Instance, Keywords, InstanceLocation,
                         NeedCoverage, Guard#{Current => true}, Context)
    end.

%% После выбора guard координаты ветви и resource scope фиксируются одним
%% record update. Dynamic scope не связан с позицией instance и при consuming
%% переходе продолжает расти по прежним правилам.
-spec eval_entered(addr(), json(), [binary()], instance_location(), boolean(),
                   eval_guard(), #eval_context{}) -> #eval_result{}.
eval_entered({Rid, _} = Addr, Instance, Keywords, InstanceLocation,
             NeedCoverage, Guard,
             #eval_context{schema = Schema, node = {CurrentRid, _},
                           dynamic_scope = Scope} = Context) ->
    DynamicScope = case Rid =:= CurrentRid of
                       true  -> Scope;
                       false -> [Rid | Scope]
                   end,
    Entered = Context#eval_context{
                node = Addr,
                keyword_location = Keywords,
                instance_location = InstanceLocation,
                dynamic_scope = DynamicScope,
                guard = Guard,
                need_coverage = NeedCoverage},
    eval_node(resolve(Addr, Schema), Instance, Entered).

%% Ошибка ветви остаётся обычным значением до ближайшей boolean-операции.
-spec error_result(eval_error()) -> #eval_result{}.
error_result(Error) ->
    #eval_result{valid = undefined,
                 evaluated = valid_json_evaluated:neutral(),
                 units = [],
                 error = Error}.

%% Частый результат без покрытия, diagnostics и ошибки разделяется между
%% вызовами как literal term. Значение неизменяемо, поэтому это не создаёт
%% общей mutable state и снимает heap allocation с flag handlers и fold seeds.
-spec empty_result(boolean()) -> #eval_result{}.
empty_result(true) ->
    #eval_result{valid = true, evaluated = neutral, units = []};
empty_result(false) ->
    #eval_result{valid = false, evaluated = neutral, units = []}.

%% Конъюнкция используется schema object и container applicators. `false`
%% окончательно определяет результат и потому поглощает no-progress другой
%% ветви; без провала сохраняется первая встретившаяся ошибка. Порядок sibling
%% diagnostics не является частью публичного контракта.
-spec conjoin(#eval_result{}, #eval_result{}) -> #eval_result{}.
conjoin(#eval_result{valid = true, evaluated = neutral, units = [],
                     error = undefined}, Right) ->
    Right;
conjoin(Left, #eval_result{valid = true, evaluated = neutral, units = [],
                           error = undefined}) ->
    Left;
conjoin(Left, Right) ->
    conjoined(Left, Right,
              Left#eval_result.units ++ Right#eval_result.units).

%% Длинный левый fold кладёт очередные units в голову аккумулятора: уже
%% собранный префикс больше не копируется. Порядок siblings не нормализуется,
%% поэтому finish_acc/1 не требует отдельного прохода.
-spec conjoin_acc(#eval_result{}, #eval_result{}) -> #eval_result{}.
conjoin_acc(Left, Right) ->
    Units = reverse_prepend(Right#eval_result.units, Left#eval_result.units),
    conjoined(Left, Right, Units).

%% Container applicators возвращают собственное покрытие свойства или индекса;
%% покрытие применённой дочерней schema наружу не выходит. Такой fold сохраняет
%% её verdict, ошибку и units, не объединяя заведомо невостребованную аннотацию.
-spec conjoin_acc_discard_coverage(#eval_result{}, #eval_result{}) -> #eval_result{}.
conjoin_acc_discard_coverage(
  #eval_result{valid = LeftValid, units = [], error = undefined},
  #eval_result{valid = RightValid, units = [], error = undefined})
  when is_boolean(LeftValid), is_boolean(RightValid) ->
    empty_result(LeftValid andalso RightValid);
conjoin_acc_discard_coverage(Left, Right) ->
    Units = reverse_prepend(Right#eval_result.units, Left#eval_result.units),
    conjoined(Left, Right, valid_json_evaluated:neutral(), Units).

-spec finish_acc(#eval_result{}) -> #eval_result{}.
finish_acc(#eval_result{units = []} = Result) ->
    Result;
finish_acc(#eval_result{} = Result) ->
    Result.

-spec reverse_prepend([#output_unit{}], [#output_unit{}]) -> [#output_unit{}].
reverse_prepend([], Acc) ->
    Acc;
reverse_prepend([Unit], Acc) ->
    [Unit | Acc];
reverse_prepend(Units, Acc) ->
    lists:reverse(Units, Acc).

-spec conjoined(#eval_result{}, #eval_result{}, [#output_unit{}]) -> #eval_result{}.
conjoined(Left, Right, Units) ->
    conjoined(Left, Right,
              valid_json_evaluated:merge(Left#eval_result.evaluated,
                                         Right#eval_result.evaluated),
              Units).

-spec conjoined(#eval_result{}, #eval_result{}, evaluated(), [#output_unit{}]) ->
          #eval_result{}.
conjoined(Left, Right, Evaluated, Units) ->
    Valid = conjunction(Left#eval_result.valid, Right#eval_result.valid),
    Error = case Valid of
                undefined -> first_error(Left#eval_result.error,
                                         Right#eval_result.error);
                _ -> undefined
            end,
    #eval_result{valid = Valid,
                 evaluated = Evaluated,
                 units = Units,
                 error = Error}.

conjunction(false, _Right) -> false;
conjunction(_Left, false) -> false;
conjunction(undefined, _Right) -> undefined;
conjunction(_Left, undefined) -> undefined;
conjunction(true, true) -> true.

first_error(undefined, Error) -> Error;
first_error(Error, _Later) -> Error.

%% Boolean true даёт успех с пустым покрытием, false — отказ. Аннотаций boolean
%% не производит, но остаётся обычным адресуемым node и потому выпускает
%% собственный unit. Детей у него нет, поэтому сообщение о провале он несёт сам.
-spec eval_node(schema_node(), json(), #eval_context{}) -> #eval_result{}.
eval_node(true, _Instance, #eval_context{format = flag}) ->
    empty_result(true);
eval_node(false, _Instance, #eval_context{format = flag}) ->
    empty_result(false);
eval_node(true, _Instance, Context) ->
    #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(),
                 units = node_units(true, none, [], Context)};
eval_node(false, _Instance, Context) ->
    #eval_result{valid = false, evaluated = valid_json_evaluated:neutral(),
                 units = node_units(false, {error, <<"schema is false">>}, [], Context)};
eval_node(#node{constraints = Constraints, unevaluated = Unevaluated}, Instance, Context) ->
    case finish_coverage(eval_all(Constraints, Unevaluated, Instance, Context), Context) of
        #eval_result{valid = undefined} = Error ->
            %% Частично построенный node не является результатом вычисления и
            %% не должен попадать в diagnostic tree поглотившего его родителя.
            Error#eval_result{evaluated = valid_json_evaluated:neutral(), units = []};
        #eval_result{valid = Valid, units = Units} = Result ->
            Result#eval_result{units = node_units(Valid, none, Units, Context)}
    end.

%% Обычные constraints выполняются первыми, и `unevaluated*` читают их общее
%% покрытие: своего порядка между собой у них нет, потому что каждый применяется
%% к своему типу инстанса. Пока это покрытие не посчитано, обрывать обход нельзя
%% даже в режиме flag (validator-core.md, «Output unit и локации»), причём не
%% только в самом node: покрытие поднимается сюда по цепочке in-place
%% applicators, и оборванный внутри неё `anyOf` потерял бы часть аннотаций.
-spec eval_all([constraint()], [constraint()], json(), #eval_context{}) -> #eval_result{}.
eval_all(Constraints, [], Instance,
         #eval_context{need_coverage = NeedCoverage} = Context) ->
    eval_constraints(Constraints, Instance, Context, not NeedCoverage);
eval_all(Constraints, Unevaluated, Instance, Context) ->
    Awaited = Context#eval_context{need_coverage = true},
    case eval_constraints(Constraints, Instance, Awaited, false) of
        #eval_result{valid = undefined} = Error ->
            %% Без полной маски нельзя определить, к чему применять
            %% unevaluated*. В отличие от обычной конъюнкции здесь нет ветви,
            %% которую можно безопасно выполнить после ошибки покрытия.
            Error;
        #eval_result{evaluated = Evaluated} = Result ->
            Step = fun(Constraint, Acc) ->
                           conjoin(Acc,
                                   valid_json_unevaluated:check(
                                     Constraint, Instance, Evaluated, Context))
                   end,
            lists:foldl(Step, Result, Unevaluated)
    end.

%% Собственный unit node стоит над units своих constraints и ни сообщения, ни
%% аннотации не несёт: причину провала называют его дети
%% (validator-core.md, «Output unit и локации»). В режиме flag units не
%% собираются вовсе: ответ исчерпывается вердиктом.
-spec node_units(boolean(), detail(), [#output_unit{}], #eval_context{}) -> [#output_unit{}].
node_units(_Valid, _Detail, _Nested, #eval_context{format = flag}) ->
    [];
node_units(Valid, Detail, Nested, #eval_context{format = basic} = Context) ->
    Kept = case Valid of
               true  -> Nested;
               false -> drop_annotations(Nested)
           end,
    case Detail of
        none -> Kept;
        _    -> [valid_json_unit:schema(Valid, Detail, [], Context) | Kept]
    end;
node_units(Valid, Detail, Nested, Context) ->
    [valid_json_unit:schema(Valid, Detail, Nested, Context)].

%% Аннотации провалившегося schema object не являются effective. В tree-режиме
%% их сохраняет hierarchy ради verbose и позднее фильтрует Basic; плоский Basic
%% обязан отбросить их прямо на границе node.
-spec drop_annotations([#output_unit{}]) -> [#output_unit{}].
drop_annotations(Units) ->
    [Unit || #output_unit{detail = Detail} = Unit <- Units,
             not is_annotation(Detail)].

is_annotation({annotation, _}) -> true;
is_annotation(_Detail)         -> false.

%% Schema object есть конъюнкция независимых ограничений. Обрыв разрешён только
%% в режиме flag и только там, где покрытие уже никому не нужно: аргумент `Short`
%% его и разрешает.
-spec eval_constraints([constraint()], json(), #eval_context{}, boolean()) ->
          #eval_result{}.
eval_constraints(Constraints, Instance, Context, Short) ->
    eval_constraints(Constraints, Instance, Context, Short,
                     empty_result(true)).

eval_constraints([], _Instance, _Context, _Short, Result) ->
    Result;
eval_constraints([Constraint | Rest], Instance, Context, Short, Result) ->
    Merged = conjoin(Result, dispatch(Constraint, Instance, Context)),
    case Merged#eval_result.valid of
        false when Short, Context#eval_context.format =:= flag ->
            Merged;
        _ ->
            %% После no_progress обход продолжается: более поздний false
            %% constraint окончательно определит конъюнкцию как invalid.
            eval_constraints(Rest, Instance, Context, Short, Merged)
    end.

%% Диспетчер разводит constraints по обработчикам: assertion отвечает на вопрос
%% о самом значении, applicator спускается в дочерние schemas, а annotation-only
%% keyword не делает ни того, ни другого и только отдаёт значение. Список тегов
%% перечислен явно: принадлежность обработчику — часть контракта IR, а не
%% свойство формы тега.
-spec dispatch(constraint(), json(), #eval_context{}) -> #eval_result{}.
dispatch({all_of, _} = Constraint, Instance, Context) ->
    valid_json_apply:check(Constraint, Instance, Context);
dispatch({any_of, _} = Constraint, Instance, Context) ->
    valid_json_apply:check(Constraint, Instance, Context);
dispatch({one_of, _} = Constraint, Instance, Context) ->
    valid_json_apply:check(Constraint, Instance, Context);
dispatch({'not', _} = Constraint, Instance, Context) ->
    valid_json_apply:check(Constraint, Instance, Context);
dispatch({if_then_else, _, _, _} = Constraint, Instance, Context) ->
    valid_json_apply:check(Constraint, Instance, Context);
dispatch({dependent_schemas, _} = Constraint, Instance, Context) ->
    valid_json_apply:check(Constraint, Instance, Context);
dispatch({dependencies, _} = Constraint, Instance, Context) ->
    valid_json_apply:check(Constraint, Instance, Context);
dispatch({ref, Addr}, Instance, Context) ->
    reference(<<"$ref">>, Addr, Instance, Context);
dispatch({dynamic_ref, Name, Lexical}, Instance, Context) ->
    reference(<<"$dynamicRef">>, dynamic_target(Name, Lexical, Context),
              Instance, Context);
dispatch({recursive_ref, Lexical}, Instance, Context) ->
    reference(<<"$recursiveRef">>, recursive_target(Lexical, Context),
              Instance, Context);
dispatch({marker, Keyword}, _Instance, Context) ->
    marker(Keyword, Context);
dispatch({items, _} = Constraint, Instance, Context) ->
    valid_json_array:check(Constraint, Instance, Context);
dispatch({prefix_items, _, _} = Constraint, Instance, Context) ->
    valid_json_array:check(Constraint, Instance, Context);
dispatch({items_array, _, _} = Constraint, Instance, Context) ->
    valid_json_array:check(Constraint, Instance, Context);
dispatch({contains, _, _, _, _} = Constraint, Instance, Context) ->
    valid_json_array:check(Constraint, Instance, Context);
dispatch({properties, _, _, _} = Constraint, Instance, Context) ->
    valid_json_object:check(Constraint, Instance, Context);
dispatch({property_names, _} = Constraint, Instance, Context) ->
    valid_json_object:check(Constraint, Instance, Context);
dispatch({annotation, _, _} = Constraint, Instance, Context) ->
    valid_json_annotate:check(Constraint, Instance, Context);
dispatch({format, _, _} = Constraint, Instance, Context) ->
    valid_json_format:check(Constraint, Instance, Context);
dispatch({content, _, _} = Constraint, Instance, Context) ->
    valid_json_annotate:check(Constraint, Instance, Context);
dispatch(Constraint, Instance, Context) ->
    valid_json_assert:check(Constraint, Instance, Context).

%% Compile-time container вроде `$defs` участвует только в verbose hierarchy.
%% В остальных структурных режимах его silent unit сохранён в diagnostic tree,
%% но basic отфильтрует его как unit без detail.
-spec marker(binary(), #eval_context{}) -> #eval_result{}.
marker(_Keyword, #eval_context{format = flag}) ->
    empty_result(true);
marker(Keyword, Context) ->
    #eval_result{valid = true,
                 evaluated = valid_json_evaluated:neutral(),
                 units = valid_json_unit:keyword_units(
                           Keyword, true, none, [], Context)}.

%% Reference применяет target к тому же instance через общий вход evaluator'а:
%% только так сохраняются resource scope и cycle guard. Keyword location
%% продолжает путь через сегмент самого keyword, а его absolute location
%% указывает на каноническую target schema, как требует output contract. В
%% режиме flag location не наблюдаема и её стек не материализуется.
-spec reference(binary(), addr(), json(), #eval_context{}) -> #eval_result{}.
reference(Keyword, Addr, Instance,
          #eval_context{keyword_location = Location,
                        instance_location = InstanceLocation,
                        format = Format,
                        need_coverage = NeedCoverage} = Context) ->
    Keywords = case Format of
                   flag -> [];
                   _    -> [Keyword | Location]
               end,
    case eval_in_place_at(Addr, Instance, Keywords, InstanceLocation,
                          NeedCoverage, Context) of
        #eval_result{valid = undefined} = Error ->
            Error;
        #eval_result{valid = Valid, units = Units} = Result ->
            case Format of
                flag ->
                    Result;
                basic ->
                    Result;
                _ ->
                    Unit = valid_json_unit:reference(
                             Keyword, Addr, Valid, Units, Context),
                    Result#eval_result{units = [Unit]}
            end
    end.

%% Цель `$dynamicRef` — самый внешний resource dynamic scope, объявивший это имя
%% через `$dynamicAnchor` (core.txt, 8.2.3.2). Стек лежит внутренним концом
%% вперёд, поэтому левый fold и оставляет последним самое внешнее совпадение.
%% Не нашлось ни одного — остаётся лексическая цель, проверенная компилятором.
-spec dynamic_target(binary(), addr(), #eval_context{}) -> addr().
dynamic_target(Name, Lexical,
               #eval_context{schema = #{resources := Resources},
                             dynamic_scope = Scope}) ->
    dynamic_target(Scope, Name, Resources, Lexical).

dynamic_target([], _Name, _Resources, Found) ->
    Found;
dynamic_target([Rid | Outer], Name, Resources, Found) ->
    #resource{dynamic_anchors = Anchors} = maps:get(Rid, Resources),
    Declared = case Anchors of
                   #{Name := Pointer} -> {Rid, Pointer};
                   #{}                -> Found
               end,
    dynamic_target(Outer, Name, Resources, Declared).

%% Draft 2019-09 переигрывает цель только тогда, когда лексический resource сам
%% разрешает recursion. Затем выбирается корень самого внешнего помеченного
%% resource в dynamic scope. Стек лежит внутренним концом вперёд, поэтому тот же
%% левый fold, что у dynamic anchors, оставляет последним внешнюю цель.
-spec recursive_target(addr(), #eval_context{}) -> addr().
recursive_target({LexicalRid, _} = Lexical,
                 #eval_context{schema = #{resources := Resources},
                               dynamic_scope = Scope}) ->
    #resource{recursive_anchor = Recursive} = maps:get(LexicalRid, Resources),
    case Recursive of
        false -> Lexical;
        true  -> recursive_target(Scope, Resources, Lexical)
    end.

-spec recursive_target([rid()], #{rid() => #resource{}}, addr()) -> addr().
recursive_target([], _Resources, Found) ->
    Found;
recursive_target([Rid | Outer], Resources, Found) ->
    #resource{recursive_anchor = Recursive} = maps:get(Rid, Resources),
    Declared = case Recursive of
                   true  -> {Rid, <<>>};
                   false -> Found
               end,
    recursive_target(Outer, Resources, Declared).

%% Покрытие покидает node только по явному запросу предка. Провалившийся или
%% незавершённый schema object в любом случае не отдаёт effective annotations,
%% но свои законченные diagnostic units сохраняет.
-spec finish_coverage(#eval_result{}, #eval_context{}) -> #eval_result{}.
finish_coverage(#eval_result{valid = false} = Result, _Context) ->
    Result#eval_result{evaluated = valid_json_evaluated:neutral()};
finish_coverage(#eval_result{valid = undefined} = Result, _Context) ->
    Result#eval_result{evaluated = valid_json_evaluated:neutral()};
finish_coverage(#eval_result{} = Result,
                #eval_context{need_coverage = false}) ->
    Result#eval_result{evaluated = valid_json_evaluated:neutral()};
finish_coverage(#eval_result{} = Result, #eval_context{need_coverage = true}) ->
    Result.
