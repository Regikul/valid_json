%% Обход node. Порядок шагов и разделение двух результатов описаны
%% в okf/architecture/validator-core.md, раздел «Вычисление».
-module(valid_json_eval).

-include("valid_json_core.hrl").

-export([run/3, resolve/2]).

%% Единственный вход в вычисление. Cycle guard — единственная причина отказа.
-spec run(compiled(), json(), format()) -> {ok, #eval_result{}} | {error, eval_error()}.
run(#{root := Root} = Compiled, Instance, Format) ->
    Context = #eval_context{schema            = Compiled,
                            resource          = Root,
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
-spec eval(addr(), json(), #eval_context{}) -> #eval_result{}.
eval(Addr, Instance, #eval_context{guard = Guard} = Context) ->
    Frame = {Addr, Context#eval_context.instance_location},
    case sets:is_element(Frame, Guard) of
        true  -> throw({no_progress, Addr});
        false -> ok
    end,
    Entered = enter_resource(Addr, Context#eval_context{guard = sets:add_element(Frame, Guard)}),
    eval_node(resolve(Addr, Context#eval_context.schema), Instance, Entered).

%% Граница ресурса определяется целевым rid, а не видом перехода.
-spec enter_resource(addr(), #eval_context{}) -> #eval_context{}.
enter_resource({Rid, _}, #eval_context{resource = Rid} = Context) ->
    Context;
enter_resource({Rid, _}, #eval_context{dynamic_scope = Scope} = Context) ->
    Context#eval_context{resource = Rid, dynamic_scope = [Rid | Scope]}.

%% Boolean true даёт успех с пустым покрытием, false — отказ. Units в режиме flag
%% не собираются, поэтому их сборка появится вместе с проекцией basic.
-spec eval_node(schema_node(), json(), #eval_context{}) -> #eval_result{}.
eval_node(true, _Instance, _Context) ->
    #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(), units = []};
eval_node(false, _Instance, _Context) ->
    #eval_result{valid = false, evaluated = valid_json_evaluated:neutral(), units = []};
eval_node(#node{constraints = Constraints, unevaluated = []}, Instance, Context) ->
    discard_coverage(eval_constraints(Constraints, Instance, Context));
eval_node(#node{} = Node, _Instance, _Context) ->
    erlang:error({not_implemented, Node}).

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
        valid_json_assert:check(Constraint, Instance, Context),
    Merged   = valid_json_evaluated:merge(Evaluated, EvaluatedOne),
    Collected = lists:reverse(UnitsOne, Units),
    case Valid andalso ValidOne of
        false when Context#eval_context.mode =:= flag ->
            #eval_result{valid = false, evaluated = Merged,
                         units = lists:reverse(Collected)};
        Accumulated ->
            eval_constraints(Rest, Instance, Context, Accumulated, Merged, Collected)
    end.

%% Провалившийся schema object не отдаёт эффективных аннотаций, но свои
%% диагностические units сохраняет.
-spec discard_coverage(#eval_result{}) -> #eval_result{}.
discard_coverage(#eval_result{valid = false} = Result) ->
    Result#eval_result{evaluated = valid_json_evaluated:neutral()};
discard_coverage(#eval_result{} = Result) ->
    Result.
