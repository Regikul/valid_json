%% Вход вычислительного ядра: вычислить артефакт и спроецировать результат.
%% Ядро не знает, откуда взялись документы и где хранится артефакт.
-module(valid_json_core).

-include("valid_json_core.hrl").

-export([validate/3]).

-spec validate(compiled(), json(), [option()]) -> {ok, output()} | {error, eval_error()}.
validate(Compiled, Instance, Options) ->
    Format = output_format(Options),
    case valid_json_eval:run(Compiled, Instance, Format) of
        {ok, Result}   -> {ok, valid_json_output:project(Format, Result)};
        {error, _} = Error -> Error
    end.

%% Формат входит в вызов evaluator'а: он определяет сбор units и возможность
%% short-circuit. По умолчанию запрашивается flag.
-spec output_format([option()]) -> format().
output_format(Options) ->
    case proplists:get_value(output, Options, flag) of
        Format when Format =:= flag; Format =:= basic ->
            Format;
        Other when Other =:= detailed; Other =:= verbose ->
            erlang:error({not_implemented, {output, Other}})
    end.
