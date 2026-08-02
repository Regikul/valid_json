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
                            mode              = Format},
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
%% собственный unit.
-spec eval_node(schema_node(), json(), #eval_context{}) -> #eval_result{}.
eval_node(true, _Instance, Context) ->
    #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(),
                 units = node_units(true, none, Context)};
eval_node(false, _Instance, Context) ->
    #eval_result{valid = false, evaluated = valid_json_evaluated:neutral(),
                 units = node_units(false, {error, <<"schema is false">>}, Context)};
eval_node(#node{constraints = Constraints, unevaluated = []}, Instance, Context) ->
    discard_coverage(eval_constraints(Constraints, Instance, Context));
eval_node(#node{} = Node, _Instance, _Context) ->
    erlang:error({not_implemented, Node}).

%% В режиме flag units не собираются вовсе: ответ исчерпывается вердиктом.
-spec node_units(boolean(), detail(), #eval_context{}) -> [#output_unit{}].
node_units(_Valid, _Detail, #eval_context{mode = flag}) ->
    [];
node_units(Valid, Detail, Context) ->
    [valid_json_unit:schema(Valid, Detail, Context)].

%% Schema object есть конъюнкция независимых ограничений. Обрыв разрешён только
%% в режиме flag: в остальных режимах дерево units должно быть полным.
-spec eval_constraints([constraint()], json(), #eval_context{}) -> #eval_result{}.
eval_constraints(Constraints, Instance, Context) ->
    eval_constraints(Constraints, Instance, Context,
                     true, valid_json_evaluated:neutral(), []).

eval_constraints([], _Instance, _Context, Valid, Evaluated, Units) ->
    #eval_result{valid = Valid, evaluated = Evaluated, units = lists:reverse(Units)};
eval_constraints([Constraint | Rest], Instance, Context, Valid, Evaluated, Units) ->
    #eval_result{valid = ValidOne, evaluated = EvaluatedOne, units = UnitsOne} =
        dispatch(Constraint, Instance, Context),
    Merged   = valid_json_evaluated:merge(Evaluated, EvaluatedOne),
    Collected = lists:reverse(UnitsOne, Units),
    case Valid andalso ValidOne of
        false when Context#eval_context.mode =:= flag ->
            #eval_result{valid = false, evaluated = Merged,
                         units = lists:reverse(Collected)};
        Accumulated ->
            eval_constraints(Rest, Instance, Context, Accumulated, Merged, Collected)
    end.

%% Диспетчер разводит constraints по обработчикам: assertion отвечает на вопрос
%% о самом значении, applicator спускается в дочерние schemas. Список тегов
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
dispatch({properties, _, _, _} = Constraint, Instance, Context) ->
    valid_json_object:check(Constraint, Instance, Context);
dispatch({property_names, _} = Constraint, Instance, Context) ->
    valid_json_object:check(Constraint, Instance, Context);
dispatch(Constraint, Instance, Context) ->
    valid_json_assert:check(Constraint, Instance, Context).

%% Провалившийся schema object не отдаёт эффективных аннотаций, но свои
%% диагностические units сохраняет.
-spec discard_coverage(#eval_result{}) -> #eval_result{}.
discard_coverage(#eval_result{valid = false} = Result) ->
    Result#eval_result{evaluated = valid_json_evaluated:neutral()};
discard_coverage(#eval_result{} = Result) ->
    Result.
