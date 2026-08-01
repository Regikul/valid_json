%% Компиляция schema object в #node{}. Пока без resources: подсхем, $id и
%% ссылок здесь нет, поэтому артефакт всегда состоит из одного анонимного
%% resource с единственным node по указателю <<>>.
%% Инварианты компиляции — okf/architecture/validator-core.md.
-module(valid_json_compile).

-include("valid_json_core.hrl").

-export([compile/2]).

-export_type([compile_error/0]).

%% Каталог причин дизайна называет keyword через location, а её пока нет:
%% единственный anonymous node адресовать нечем. Поэтому обе записи временно
%% несут опознавательный элемент сами и схлопнутся до формы дизайна вместе с
%% появлением addr().
-type compile_error() :: {not_implemented, {keyword, binary()}}
                       | {bad_keyword_value, binary(), json()}
                       | {bad_pattern, binary(), term()}
                       | {not_a_schema, json()}.

%% Порядок constraints в node задан статически. Наблюдаемое дерево units не
%% должно зависеть от порядка обхода map, поэтому обход идёт по этому списку,
%% а не по maps:keys/1.
-define(ORDER, [<<"type">>, <<"enum">>, <<"const">>,
                <<"multipleOf">>,
                <<"maximum">>, <<"exclusiveMaximum">>,
                <<"minimum">>, <<"exclusiveMinimum">>,
                <<"pattern">>]).

%% Полностью потребляются компилятором и собственного constraint не дают.
-define(CONSUMED, [<<"$schema">>, <<"$comment">>]).

-spec compile(json(), dialect()) -> {ok, compiled()} | {error, compile_error()}.
compile(Schema, Dialect) ->
    case compile_node(Schema) of
        {ok, Node}         -> {ok, artifact(Node, Dialect)};
        {error, _} = Error -> Error
    end.

-spec compile_node(json()) -> {ok, schema_node()} | {error, compile_error()}.
compile_node(Schema) when is_boolean(Schema) ->
    {ok, Schema};
compile_node(Schema) when is_map(Schema) ->
    case maps:keys(Schema) -- (?ORDER ++ ?CONSUMED) of
        []              -> constraints(Schema);
        [Keyword | _]   -> {error, {not_implemented, {keyword, Keyword}}}
    end;
compile_node(Other) ->
    {error, {not_a_schema, Other}}.

-spec constraints(#{binary() => json()}) -> {ok, #node{}} | {error, compile_error()}.
constraints(Schema) ->
    Step = fun(_Keyword, {error, _} = Error) ->
                   Error;
              (Keyword, {ok, Acc}) ->
                   case maps:find(Keyword, Schema) of
                       error ->
                           {ok, Acc};
                       {ok, Value} ->
                           case constraint(Keyword, Value) of
                               {ok, Constraint}   -> {ok, [Constraint | Acc]};
                               {error, _} = Error -> Error
                           end
                   end
           end,
    case lists:foldl(Step, {ok, []}, ?ORDER) of
        {ok, Acc}          -> {ok, #node{constraints = lists:reverse(Acc), unevaluated = []}};
        {error, _} = Error -> Error
    end.

-spec constraint(binary(), json()) -> {ok, constraint()} | {error, compile_error()}.
constraint(<<"type">> = Keyword, Value) ->
    Names = case Value of
                _ when is_binary(Value) -> [Value];
                _ when is_list(Value)   -> Value;
                _                       -> invalid
            end,
    case type_names(Names) of
        {ok, Types} -> {ok, {type, Types}};
        error       -> {error, {bad_keyword_value, Keyword, Value}}
    end;
constraint(<<"enum">>, Values) when is_list(Values) ->
    {ok, {enum, Values}};
constraint(<<"const">>, Value) ->
    {ok, {const, Value}};
%% Неположительный multipleOf запрещён метасхемой и отвергается компилятором:
%% иначе делитель 0 дошёл бы до вычисления.
constraint(<<"multipleOf">>, Value) when is_number(Value), Value > 0 ->
    {ok, {multiple_of, Value}};
constraint(<<"maximum">>, Value) when is_number(Value) ->
    {ok, {maximum, Value}};
constraint(<<"exclusiveMaximum">>, Value) when is_number(Value) ->
    {ok, {exclusive_maximum, Value}};
constraint(<<"minimum">>, Value) when is_number(Value) ->
    {ok, {minimum, Value}};
constraint(<<"exclusiveMinimum">>, Value) when is_number(Value) ->
    {ok, {exclusive_minimum, Value}};
%% Опции и запрет на неявное якорение заданы в validator-core.md, раздел
%% «Регулярные выражения». Исходный текст остаётся рядом с re:mp() ради
%% диагностики, а некомпилируемое выражение останавливает компиляцию: это одна
%% из проверок, которые остаются за компилятором и после включения метасхемы.
constraint(<<"pattern">>, Value) when is_binary(Value) ->
    case re:compile(Value, [unicode, dollar_endonly]) of
        {ok, Compiled}  -> {ok, {pattern, {Value, Compiled}}};
        {error, Reason} -> {error, {bad_pattern, Value, Reason}}
    end;
constraint(Keyword, Value) ->
    {error, {bad_keyword_value, Keyword, Value}}.

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

-spec artifact(schema_node(), dialect()) -> compiled().
artifact(Node, Dialect) ->
    #{root      => anonymous,
      sources   => [],
      resources => #{anonymous =>
          #resource{id               = undefined,
                    dialect          = Dialect,
                    anchors          = #{},
                    dynamic_anchors  = #{},
                    recursive_anchor = false,
                    nodes            = #{<<>> => Node}}}}.
