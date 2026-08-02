%% Проекции дерева units в standard output formats.
%% Все структурные форматы строятся из одного дерева; см. validator-core.md.
-module(valid_json_output).

-include("valid_json_core.hrl").

-export([project/2]).

-spec project(format(), #eval_result{}) -> output().
project(flag, #eval_result{valid = Valid}) ->
    #{<<"valid">> => Valid};
project(basic, #eval_result{valid = Valid, units = Units}) ->
    basic(Valid, Units).

%% basic — плоский список units применённых keywords: при провале сообщения об
%% ошибках, при успехе аннотации. Успешный unit без аннотации в плоский список
%% не попадает, но из дерева не исчезает: его показывает verbose.
-spec basic(boolean(), [#output_unit{}]) -> output().
basic(false, Units) ->
    root(false, <<"errors">>, [unit(Unit) || Unit <- Units, failed(Unit)]);
basic(true, Units) ->
    root(true, <<"annotations">>, [unit(Unit) || Unit <- Units, annotated(Unit)]).

%% Корневой unit стоит на пустых локациях: вычисление начинается от корня схемы
%% и корня инстанса.
-spec root(boolean(), binary(), [output()]) -> output().
root(Valid, Key, Nested) ->
    #{<<"valid">>             => Valid,
      <<"keywordLocation">>   => <<>>,
      <<"instanceLocation">>  => <<>>,
      Key                     => Nested}.

failed(#output_unit{valid = Valid}) -> not Valid.

annotated(#output_unit{detail = {annotation, _}}) -> true;
annotated(#output_unit{})                         -> false.

-spec unit(#output_unit{}) -> output().
unit(#output_unit{valid = Valid, keyword_location = Keywords,
                  absolute_location = Absolute, instance_location = Instance,
                  detail = Detail}) ->
    Unit = #{<<"valid">>            => Valid,
             <<"keywordLocation">>  => valid_json_location:pointer(Keywords),
             <<"instanceLocation">> => valid_json_location:pointer(Instance)},
    detail(Detail, absolute(Absolute, Unit)).

%% Анонимный resource URI не синтезирует, поэтому ключ просто отсутствует.
-spec absolute({uri(), [binary()]} | undefined, output()) -> output().
absolute(undefined, Unit) ->
    Unit;
absolute(Location, Unit) ->
    Unit#{<<"absoluteKeywordLocation">> => valid_json_location:fragment(Location)}.

-spec detail(detail(), output()) -> output().
detail({error, Message}, Unit)    -> Unit#{<<"error">> => Message};
detail({annotation, Value}, Unit) -> Unit#{<<"annotation">> => Value};
detail(none, Unit)                -> Unit.
