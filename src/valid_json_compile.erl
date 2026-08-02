%% Компиляция schema JSON в nodes одного анонимного resource. $id, anchors и
%% ссылок здесь ещё нет, поэтому rid всегда anonymous, и дочерний адрес
%% отличается от родительского только указателем.
%% Инварианты компиляции — okf/architecture/validator-core.md.
-module(valid_json_compile).

-include("valid_json_core.hrl").

-export([compile/2]).

%% Порядок constraints в node задан статически. Наблюдаемое дерево units не
%% должно зависеть от порядка обхода map, поэтому обход идёт по этому списку,
%% а не по maps:keys/1. Элемент — один constraint: обычно это сам keyword, а
%% составной перечисляет свои keywords списком и компилируется за один шаг.
-define(ORDER, [<<"type">>, <<"enum">>, <<"const">>,
                <<"multipleOf">>,
                <<"maximum">>, <<"exclusiveMaximum">>,
                <<"minimum">>, <<"exclusiveMinimum">>,
                <<"maxLength">>, <<"minLength">>, <<"pattern">>,
                <<"maxItems">>, <<"minItems">>, <<"uniqueItems">>,
                <<"maxProperties">>, <<"minProperties">>,
                <<"required">>, <<"dependentRequired">>,
                [<<"properties">>, <<"patternProperties">>, <<"additionalProperties">>],
                <<"allOf">>, <<"anyOf">>, <<"oneOf">>, <<"not">>,
                [<<"if">>, <<"then">>, <<"else">>]]).

%% Полностью потребляются компилятором и собственного constraint не дают.
-define(CONSUMED, [<<"$schema">>, <<"$comment">>]).

-type nodes() :: #{pointer() => schema_node()}.

-spec compile(json(), dialect()) -> {ok, compiled()} | {error, #schema_error{}}.
compile(Schema, Dialect) ->
    case compile_node(Schema, [], #{}) of
        {ok, Nodes}        -> {ok, artifact(Nodes, Dialect)};
        {error, _} = Error -> Error
    end.

%% Все nodes строятся до вычисления, поэтому обход спускается в каждую дочернюю
%% schema position и накапливает общую map. Локация — тот же обратный стек
%% сегментов, что и в вычислении, и печатается в указатель при укладке node.
-spec compile_node(json(), [binary()], nodes()) -> {ok, nodes()} | {error, #schema_error{}}.
compile_node(Schema, Location, Nodes) when is_boolean(Schema) ->
    {ok, place(Location, Schema, Nodes)};
compile_node(Schema, Location, Nodes) when is_map(Schema) ->
    case maps:keys(Schema) -- (lists:flatten(?ORDER) ++ ?CONSUMED) of
        [] ->
            case constraints(Schema, Location, Nodes) of
                {ok, Constraints, Built} ->
                    Node = #node{constraints = Constraints, unevaluated = []},
                    {ok, place(Location, Node, Built)};
                {error, _} = Error ->
                    Error
            end;
        [Keyword | _] ->
            {error, schema_error({not_implemented, Keyword}, [Keyword | Location])}
    end;
%% На позиции schema стоит значение, которое schema не является. Для slot IR оно
%% невозможно, а называет его собственная локация.
compile_node(Other, Location, _Nodes) ->
    {error, schema_error({bad_keyword_value, Other}, Location)}.

-spec place([binary()], schema_node(), nodes()) -> nodes().
place(Location, Node, Nodes) ->
    Nodes#{valid_json_location:pointer(Location) => Node}.

%% Дочерний переход хранит полный адрес, а не голый указатель: подсхема с $id
%% получит собственный rid уже в P3.
-spec addr([binary()]) -> addr().
addr(Location) ->
    {anonymous, valid_json_location:pointer(Location)}.

-spec schema_error(reason(), [binary()]) -> #schema_error{}.
schema_error(Reason, Location) ->
    #schema_error{reason = Reason, location = addr(Location)}.

%% Обход групп несёт накопленные nodes: applicator дописывает в них свои
%% дочерние schemas, assertion передаёт дальше без изменений. Группа, ни один
%% keyword которой не написан, constraint не даёт. Ответ `none` означает
%% обратное: keywords написаны и их nodes построены, но вычислять по ним нечего.
-spec constraints(#{binary() => json()}, [binary()], nodes()) ->
          {ok, [constraint()], nodes()} | {error, #schema_error{}}.
constraints(Schema, Location, Nodes) ->
    Step = fun(_Group, {error, _} = Error) ->
                   Error;
              (Group, {ok, Acc, Built}) ->
                   case lists:any(fun(Keyword) -> is_map_key(Keyword, Schema) end,
                                  keywords(Group)) of
                       false ->
                           {ok, Acc, Built};
                       true ->
                           case constraint(Group, Schema, Location, Built) of
                               {ok, none, Grown}       -> {ok, Acc, Grown};
                               {ok, Constraint, Grown} -> {ok, [Constraint | Acc], Grown};
                               {error, _} = Error      -> Error
                           end
                   end
           end,
    case lists:foldl(Step, {ok, [], Nodes}, ?ORDER) of
        {ok, Acc, Built}   -> {ok, lists:reverse(Acc), Built};
        {error, _} = Error -> Error
    end.

%% Одиночный keyword записан в ?ORDER сам собой, группа — списком.
-spec keywords(binary() | [binary()]) -> [binary()].
keywords(Keyword) when is_binary(Keyword) -> [Keyword];
keywords(Group)                           -> Group.

%% Разбор идёт по элементу ?ORDER целиком, а не по написанному подмножеству:
%% элемент — статический литерал, и по нему видно, какой constraint собирается.
-spec constraint(binary() | [binary()], #{binary() => json()}, [binary()], nodes()) ->
          {ok, constraint() | none, nodes()} | {error, #schema_error{}}.
constraint([<<"properties">>, <<"patternProperties">>, <<"additionalProperties">>],
           Schema, Location, Nodes) ->
    object(Schema, Location, Nodes);
constraint([<<"if">>, <<"then">>, <<"else">>], Schema, Location, Nodes) ->
    conditional(Schema, Location, Nodes);
constraint(<<"allOf">> = Keyword, Schema, Location, Nodes) ->
    branches(all_of, Keyword, maps:get(Keyword, Schema), Location, Nodes);
constraint(<<"anyOf">> = Keyword, Schema, Location, Nodes) ->
    branches(any_of, Keyword, maps:get(Keyword, Schema), Location, Nodes);
constraint(<<"oneOf">> = Keyword, Schema, Location, Nodes) ->
    branches(one_of, Keyword, maps:get(Keyword, Schema), Location, Nodes);
constraint(<<"not">> = Keyword, Schema, Location, Nodes) ->
    Child = [Keyword | Location],
    case compile_node(maps:get(Keyword, Schema), Child, Nodes) of
        {ok, Built}        -> {ok, {'not', addr(Child)}, Built};
        {error, _} = Error -> Error
    end;
constraint(Keyword, Schema, Location, Nodes) ->
    case assertion(Keyword, maps:get(Keyword, Schema)) of
        {ok, Constraint} -> {ok, Constraint, Nodes};
        {error, Reason}  -> {error, schema_error(Reason, [Keyword | Location])}
    end.

%% Три object applicators сворачиваются в один constraint: `additionalProperties`
%% смотрит только на соседние `properties` и `patternProperties`, и статически
%% сохранённые имена с паттернами не дают воспользоваться общим накопителем
%% аннотаций (validator-core.md, «Составные constraints»). Ненаписанный keyword
%% оставляет свой слот `undefined`.
-spec object(#{binary() => json()}, [binary()], nodes()) ->
          {ok, constraint(), nodes()} | {error, #schema_error{}}.
object(Schema, Location, Nodes) ->
    Slots = [{<<"properties">>, fun named/3},
             {<<"patternProperties">>, fun patterned/3},
             {<<"additionalProperties">>, fun subschema/3}],
    case slots(Slots, Schema, Location, Nodes) of
        {ok, [Additional, Patterns, Props], Built} ->
            {ok, {properties, Props, Patterns, Additional}, Built};
        {error, _} = Error ->
            Error
    end.

%% `then` и `else` без `if` спецификация велит игнорировать целиком и запрещает
%% вычислять — и ради вердикта, и ради аннотаций (core.txt:2379 и 2422),
%% поэтому constraint без `if` не собирается. Nodes всё равно строятся: это
%% schema positions известных keywords, на них можно сослаться, и ошибка внутри
%% них обязана останавливать компиляцию.
-spec conditional(#{binary() => json()}, [binary()], nodes()) ->
          {ok, constraint() | none, nodes()} | {error, #schema_error{}}.
conditional(Schema, Location, Nodes) ->
    Slots = [{Keyword, fun subschema/3} || Keyword <- [<<"if">>, <<"then">>, <<"else">>]],
    case slots(Slots, Schema, Location, Nodes) of
        {ok, [_Else, _Then, undefined], Built} ->
            {ok, none, Built};
        {ok, [Else, Then, If], Built} ->
            {ok, {if_then_else, If, Then, Else}, Built};
        {error, _} = Error ->
            Error
    end.

%% Слоты составного constraint: написанный keyword строит свой кусок IR, а
%% ненаписанный оставляет `undefined`. Обход накапливает nodes, а результат
%% приходит в обратном порядке — так его и разбирают вызывающие.
-spec slots([{binary(), function()}], #{binary() => json()}, [binary()], nodes()) ->
          {ok, [term()], nodes()} | {error, #schema_error{}}.
slots(Slots, Schema, Location, Nodes) ->
    Step = fun(_Slot, {error, _} = Error) ->
                   Error;
              ({Keyword, Build}, {ok, Acc, Built}) ->
                   case maps:find(Keyword, Schema) of
                       error ->
                           {ok, [undefined | Acc], Built};
                       {ok, Value} ->
                           case Build(Value, [Keyword | Location], Built) of
                               {ok, Slot, Grown}  -> {ok, [Slot | Acc], Grown};
                               {error, _} = Error -> Error
                           end
                   end
           end,
    lists:foldl(Step, {ok, [], Nodes}, Slots).

%% Имя свойства становится сегментом локации. Обход идёт по отсортированным
%% именам, чтобы первая ошибка не зависела от порядка обхода map.
-spec named(json(), [binary()], nodes()) ->
          {ok, #{binary() => addr()}, nodes()} | {error, #schema_error{}}.
named(Value, Location, Nodes) when is_map(Value) ->
    Step = fun(_Name, {error, _} = Error) ->
                   Error;
              (Name, {ok, Acc, Built}) ->
                   Child = [Name | Location],
                   case compile_node(maps:get(Name, Value), Child, Built) of
                       {ok, Grown}        -> {ok, Acc#{Name => addr(Child)}, Grown};
                       {error, _} = Error -> Error
                   end
           end,
    lists:foldl(Step, {ok, #{}, Nodes}, lists:sort(maps:keys(Value)));
named(Value, Location, _Nodes) ->
    {error, schema_error({bad_keyword_value, Value}, Location)}.

%% Сегмент локации — исходный текст паттерна. Порядок списка задан сортировкой
%% по нему же: от порядка обхода map наблюдаемое дерево units зависеть не должно.
-spec patterned(json(), [binary()], nodes()) ->
          {ok, [{regex(), addr()}], nodes()} | {error, #schema_error{}}.
patterned(Value, Location, Nodes) when is_map(Value) ->
    Step = fun(_Source, {error, _} = Error) ->
                   Error;
              (Source, {ok, Acc, Built}) ->
                   Child = [Source | Location],
                   case re:compile(Source, [unicode, dollar_endonly]) of
                       {error, Reason} ->
                           {error, schema_error({bad_pattern, Reason}, Child)};
                       {ok, Compiled} ->
                           case compile_node(maps:get(Source, Value), Child, Built) of
                               {ok, Grown} ->
                                   {ok, [{{Source, Compiled}, addr(Child)} | Acc], Grown};
                               {error, _} = Error ->
                                   Error
                           end
                   end
           end,
    case lists:foldl(Step, {ok, [], Nodes}, lists:sort(maps:keys(Value))) of
        {ok, Acc, Built}   -> {ok, lists:reverse(Acc), Built};
        {error, _} = Error -> Error
    end;
patterned(Value, Location, _Nodes) ->
    {error, schema_error({bad_keyword_value, Value}, Location)}.

%% Своего сегмента у такой ветви нет: она стоит на самом keyword.
-spec subschema(json(), [binary()], nodes()) ->
          {ok, addr(), nodes()} | {error, #schema_error{}}.
subschema(Value, Location, Nodes) ->
    case compile_node(Value, Location, Nodes) of
        {ok, Built}        -> {ok, addr(Location), Built};
        {error, _} = Error -> Error
    end.

%% Пустой список ветвей метасхема запрещает, но в slot IR он ложится, поэтому
%% компилятор доводит его до вычисления — как `type: []` и `enum: []`.
-spec branches(atom(), binary(), json(), [binary()], nodes()) ->
          {ok, constraint(), nodes()} | {error, #schema_error{}}.
branches(Tag, Keyword, Value, Location, Nodes) when is_list(Value) ->
    case indexed(Value, [Keyword | Location], Nodes, 0, []) of
        {ok, Addrs, Built} -> {ok, {Tag, Addrs}, Built};
        {error, _} = Error -> Error
    end;
branches(_Tag, Keyword, Value, Location, _Nodes) ->
    {error, schema_error({bad_keyword_value, Value}, [Keyword | Location])}.

%% Сегмент ветви — её десятичный индекс: он же стоит в локации units.
-spec indexed([json()], [binary()], nodes(), non_neg_integer(), [addr()]) ->
          {ok, [addr()], nodes()} | {error, #schema_error{}}.
indexed([], _Location, Nodes, _Index, Acc) ->
    {ok, lists:reverse(Acc), Nodes};
indexed([Schema | Rest], Location, Nodes, Index, Acc) ->
    Child = [integer_to_binary(Index) | Location],
    case compile_node(Schema, Child, Nodes) of
        {ok, Built}        -> indexed(Rest, Location, Built, Index + 1, [addr(Child) | Acc]);
        {error, _} = Error -> Error
    end.

%% Assertions в дочерние schemas не спускаются, поэтому причина ошибки не несёт
%% ни имени keyword, ни локации: их дописывает вызывающий.
-spec assertion(binary(), json()) -> {ok, constraint()} | {error, reason()}.
assertion(<<"type">>, Value) ->
    Names = case Value of
                _ when is_binary(Value) -> [Value];
                _ when is_list(Value)   -> Value;
                _                       -> invalid
            end,
    case type_names(Names) of
        {ok, Types} -> {ok, {type, Types}};
        error       -> {error, {bad_keyword_value, Value}}
    end;
assertion(<<"enum">>, Values) when is_list(Values) ->
    {ok, {enum, Values}};
assertion(<<"const">>, Value) ->
    {ok, {const, Value}};
%% Неположительный multipleOf запрещён метасхемой и отвергается компилятором:
%% иначе делитель 0 дошёл бы до вычисления.
assertion(<<"multipleOf">>, Value) when is_number(Value), Value > 0 ->
    {ok, {multiple_of, Value}};
assertion(<<"maximum">>, Value) when is_number(Value) ->
    {ok, {maximum, Value}};
assertion(<<"exclusiveMaximum">>, Value) when is_number(Value) ->
    {ok, {exclusive_maximum, Value}};
assertion(<<"minimum">>, Value) when is_number(Value) ->
    {ok, {minimum, Value}};
assertion(<<"exclusiveMinimum">>, Value) when is_number(Value) ->
    {ok, {exclusive_minimum, Value}};
%% Опции и запрет на неявное якорение заданы в validator-core.md, раздел
%% «Регулярные выражения». Исходный текст остаётся рядом с re:mp() ради
%% диагностики, а некомпилируемое выражение останавливает компиляцию: это одна
%% из проверок, которые остаются за компилятором и после включения метасхемы.
assertion(<<"pattern">>, Value) when is_binary(Value) ->
    case re:compile(Value, [unicode, dollar_endonly]) of
        {ok, Compiled}  -> {ok, {pattern, {Value, Compiled}}};
        {error, Reason} -> {error, {bad_pattern, Reason}}
    end;
assertion(<<"maxLength">>, Value) ->
    counted(max_length, Value);
assertion(<<"minLength">>, Value) ->
    counted(min_length, Value);
assertion(<<"maxItems">>, Value) ->
    counted(max_items, Value);
assertion(<<"minItems">>, Value) ->
    counted(min_items, Value);
assertion(<<"maxProperties">>, Value) ->
    counted(max_properties, Value);
assertion(<<"minProperties">>, Value) ->
    counted(min_properties, Value);
%% uniqueItems: false — написанный no-op: он остаётся в IR и выпускает
%% собственный unit, поэтому компилятор его не выбрасывает.
assertion(<<"uniqueItems">>, Value) when is_boolean(Value) ->
    {ok, {unique_items, Value}};
assertion(<<"required">>, Value) ->
    case is_list(Value) andalso lists:all(fun is_binary/1, Value) of
        true  -> {ok, {required, Value}};
        false -> {error, {bad_keyword_value, Value}}
    end;
assertion(<<"dependentRequired">>, Value) ->
    Names = fun(List) -> is_list(List) andalso lists:all(fun is_binary/1, List) end,
    case is_map(Value) andalso lists:all(Names, maps:values(Value)) of
        true  -> {ok, {dependent_required, Value}};
        false -> {error, {bad_keyword_value, Value}}
    end;
assertion(_Keyword, Value) ->
    {error, {bad_keyword_value, Value}}.

%% Метасхема требует здесь nonNegativeInteger, а `type: "integer"` принимает и
%% десятичную форму: `2.0` — то же целое. Слот IR целочисленный, поэтому форма
%% нормализуется на входе, а не размазывается по обработчикам.
-spec counted(atom(), json()) -> {ok, constraint()} | {error, reason()}.
counted(Tag, Value) ->
    case Value of
        _ when is_integer(Value), Value >= 0 ->
            {ok, {Tag, Value}};
        _ when is_float(Value), Value >= 0.0, Value == trunc(Value) ->
            {ok, {Tag, trunc(Value)}};
        _ ->
            {error, {bad_keyword_value, Value}}
    end.

-spec type_names([json()] | invalid) -> {ok, [json_type()]} | error.
type_names(invalid) ->
    error;
type_names(Names) ->
    Step = fun(_Name, error)      -> error;
              (Name, {ok, Acc})   ->
                   case type_name(Name) of
                       {ok, Type} -> {ok, [Type | Acc]};
                       error      -> error
                   end
           end,
    case lists:foldl(Step, {ok, []}, Names) of
        {ok, Acc} -> {ok, lists:reverse(Acc)};
        error     -> error
    end.

-spec type_name(json()) -> {ok, json_type()} | error.
type_name(<<"null">>)    -> {ok, null};
type_name(<<"boolean">>) -> {ok, boolean};
type_name(<<"object">>)  -> {ok, object};
type_name(<<"array">>)   -> {ok, array};
type_name(<<"number">>)  -> {ok, number};
type_name(<<"integer">>) -> {ok, integer};
type_name(<<"string">>)  -> {ok, string};
type_name(_)             -> error.

-spec artifact(nodes(), dialect()) -> compiled().
artifact(Nodes, Dialect) ->
    #{root      => anonymous,
      sources   => [],
      resources => #{anonymous =>
          #resource{id               = undefined,
                    dialect          = Dialect,
                    anchors          = #{},
                    dynamic_anchors  = #{},
                    recursive_anchor = false,
                    nodes            = Nodes}}}.
