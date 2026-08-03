%% Обход node. Порядок шагов и разделение двух результатов описаны
%% в okf/architecture/validator-core.md, раздел «Вычисление».
-module(valid_json_eval).

-include("valid_json_core.hrl").

-export([run/3, eval/3, resolve/2]).

%% Единственный вход в вычисление. Cycle guard — единственная причина отказа.
-spec run(compiled(), json(), format()) -> {ok, #eval_result{}} | {error, eval_error()}.
run(#{root := Root} = Compiled, Instance, Format) ->
    Context = #eval_context{schema            = Compiled,
                            node              = {Root, <<>>},
                            keyword_location  = [],
                            instance_location = [],
                            dynamic_scope     = [Root],
                            guard             = sets:new([{version, 2}]),
                            mode              = Format,
                            coverage          = false},
    try eval({Root, <<>>}, Instance, Context) of
        Result -> {ok, Result}
    catch
        throw:{no_progress, _} = Error -> {error, Error}
    end.

%% Разрешение адреса в готовом артефакте тотально.
-spec resolve(addr(), compiled()) -> schema_node().
resolve({Rid, Pointer}, #{resources := Resources}) ->
    #resource{nodes = Nodes} = maps:get(Rid, Resources),
    maps:get(Pointer, Nodes).

%% Общий вход: guard, resource scope, затем сам node. Кадр живёт только в
%% контексте потомков, поэтому снимается на выходе без отдельного шага.
%% Applicators входят сюда же: своей точки входа у них нет.
-spec eval(addr(), json(), #eval_context{}) -> #eval_result{}.
eval(Addr, Instance, #eval_context{guard = Guard} = Context) ->
    Frame = {Addr, Context#eval_context.instance_location},
    case sets:is_element(Frame, Guard) of
        true  -> throw({no_progress, Addr});
        false -> ok
    end,
    Entered = enter_node(Addr, Context#eval_context{guard = sets:add_element(Frame, Guard)}),
    eval_node(resolve(Addr, Context#eval_context.schema), Instance, Entered).

%% Граница ресурса определяется целевым rid, а не видом перехода: это первая
%% половина адреса, и сравнивается именно она.
-spec enter_node(addr(), #eval_context{}) -> #eval_context{}.
enter_node({Rid, _} = Addr, #eval_context{node = {Rid, _}} = Context) ->
    Context#eval_context{node = Addr};
enter_node({Rid, _} = Addr, #eval_context{dynamic_scope = Scope} = Context) ->
    Context#eval_context{node = Addr, dynamic_scope = [Rid | Scope]}.

%% Boolean true даёт успех с пустым покрытием, false — отказ. Аннотаций boolean
%% не производит, но остаётся обычным адресуемым node и потому выпускает
%% собственный unit. Детей у него нет, поэтому сообщение о провале он несёт сам.
-spec eval_node(schema_node(), json(), #eval_context{}) -> #eval_result{}.
eval_node(true, _Instance, Context) ->
    #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(),
                 units = node_units(true, none, [], Context)};
eval_node(false, _Instance, Context) ->
    #eval_result{valid = false, evaluated = valid_json_evaluated:neutral(),
                 units = node_units(false, {error, <<"schema is false">>}, [], Context)};
eval_node(#node{constraints = Constraints, unevaluated = Unevaluated}, Instance, Context) ->
    #eval_result{valid = Valid, units = Units} = Result =
        discard_coverage(eval_all(Constraints, Unevaluated, Instance, Context)),
    Result#eval_result{units = node_units(Valid, none, Units, Context)}.

%% Обычные constraints выполняются первыми, и `unevaluated*` читают их общее
%% покрытие: своего порядка между собой у них нет, потому что каждый применяется
%% к своему типу инстанса. Пока это покрытие не посчитано, обрывать обход нельзя
%% даже в режиме flag (validator-core.md, «Output unit и локации»), причём не
%% только в самом node: покрытие поднимается сюда по цепочке in-place
%% applicators, и оборванный внутри неё `anyOf` потерял бы часть аннотаций.
-spec eval_all([constraint()], [constraint()], json(), #eval_context{}) -> #eval_result{}.
eval_all(Constraints, [], Instance, #eval_context{coverage = Coverage} = Context) ->
    eval_constraints(Constraints, Instance, Context, not Coverage);
eval_all(Constraints, Unevaluated, Instance, Context) ->
    Awaited = Context#eval_context{coverage = true},
    #eval_result{evaluated = Evaluated} = Result =
        eval_constraints(Constraints, Instance, Awaited, false),
    Step = fun(Constraint, Acc) ->
                   both(Acc, valid_json_unevaluated:check(Constraint, Instance,
                                                          Evaluated, Context))
           end,
    lists:foldl(Step, Result, Unevaluated).

-spec both(#eval_result{}, #eval_result{}) -> #eval_result{}.
both(#eval_result{valid = Valid, evaluated = Evaluated, units = Units},
     #eval_result{valid = ValidOne, evaluated = EvaluatedOne, units = UnitsOne}) ->
    #eval_result{valid     = Valid andalso ValidOne,
                 evaluated = valid_json_evaluated:merge(Evaluated, EvaluatedOne),
                 units     = Units ++ UnitsOne}.

%% Собственный unit node стоит над units своих constraints и ни сообщения, ни
%% аннотации не несёт: причину провала называют его дети
%% (validator-core.md, «Output unit и локации»). В режиме flag units не
%% собираются вовсе: ответ исчерпывается вердиктом.
-spec node_units(boolean(), detail(), [#output_unit{}], #eval_context{}) -> [#output_unit{}].
node_units(_Valid, _Detail, _Nested, #eval_context{mode = flag}) ->
    [];
node_units(Valid, Detail, Nested, Context) ->
    [valid_json_unit:schema(Valid, Detail, Nested, Context)].

%% Schema object есть конъюнкция независимых ограничений. Обрыв разрешён только
%% в режиме flag и только там, где покрытие уже никому не нужно: аргумент `Short`
%% его и разрешает.
-spec eval_constraints([constraint()], json(), #eval_context{}, boolean()) ->
          #eval_result{}.
eval_constraints(Constraints, Instance, Context, Short) ->
    eval_constraints(Constraints, Instance, Context, Short,
                     true, valid_json_evaluated:neutral(), []).

eval_constraints([], _Instance, _Context, _Short, Valid, Evaluated, Units) ->
    #eval_result{valid = Valid, evaluated = Evaluated, units = lists:reverse(Units)};
eval_constraints([Constraint | Rest], Instance, Context, Short, Valid, Evaluated, Units) ->
    #eval_result{valid = ValidOne, evaluated = EvaluatedOne, units = UnitsOne} =
        dispatch(Constraint, Instance, Context),
    Merged   = valid_json_evaluated:merge(Evaluated, EvaluatedOne),
    Collected = lists:reverse(UnitsOne, Units),
    case Valid andalso ValidOne of
        false when Short, Context#eval_context.mode =:= flag ->
            #eval_result{valid = false, evaluated = Merged,
                         units = lists:reverse(Collected)};
        Accumulated ->
            eval_constraints(Rest, Instance, Context, Short, Accumulated, Merged,
                             Collected)
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
dispatch({ref, Addr}, Instance, Context) ->
    reference(<<"$ref">>, Addr, Instance, Context);
dispatch({dynamic_ref, Name, Lexical}, Instance, Context) ->
    reference(<<"$dynamicRef">>, dynamic_target(Name, Lexical, Context),
              Instance, Context);
dispatch({recursive_ref, Lexical}, Instance, Context) ->
    reference(<<"$recursiveRef">>, recursive_target(Lexical, Context),
              Instance, Context);
dispatch({items, _} = Constraint, Instance, Context) ->
    valid_json_array:check(Constraint, Instance, Context);
dispatch({prefix_items, _, _} = Constraint, Instance, Context) ->
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
    valid_json_annotate:check(Constraint, Instance, Context);
dispatch(Constraint, Instance, Context) ->
    valid_json_assert:check(Constraint, Instance, Context).

%% Reference применяет target к тому же instance через общий вход evaluator'а:
%% только так сохраняются resource scope и cycle guard. Keyword location
%% продолжает путь через сегмент самого keyword, а его absolute location
%% указывает на каноническую target schema, как требует output contract.
-spec reference(binary(), addr(), json(), #eval_context{}) -> #eval_result{}.
reference(Keyword, Addr, Instance,
          #eval_context{keyword_location = Location, mode = Mode} = Context) ->
    Target = Context#eval_context{keyword_location = [Keyword | Location]},
    #eval_result{valid = Valid, units = Units} = Result = eval(Addr, Instance, Target),
    case Mode of
        flag ->
            Result;
        _ ->
            Unit = valid_json_unit:reference(Keyword, Addr, Valid, Units, Context),
            Result#eval_result{units = [Unit]}
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

%% Провалившийся schema object не отдаёт эффективных аннотаций, но свои
%% диагностические units сохраняет.
-spec discard_coverage(#eval_result{}) -> #eval_result{}.
discard_coverage(#eval_result{valid = false} = Result) ->
    Result#eval_result{evaluated = valid_json_evaluated:neutral()};
discard_coverage(#eval_result{} = Result) ->
    Result.
