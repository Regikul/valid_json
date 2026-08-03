%% Пользовательский прогон готового артефакта: разобрать опции вызова, вычислить
%% и спроецировать результат в стандартный output format. Ядро не знает, откуда
%% взялись документы и где хранится артефакт.
%%
%% Общим входом в вычисление этот модуль не является: внутренние потребители,
%% которым нужен сам `#eval_result{}`, зовут `valid_json_eval:run/3` напрямую —
%% так устроена проверка схем метасхемой в слое resources.
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
    ok = check_options(Options),
    proplists:get_value(output, Options, flag).

%% Негодное значение и незнакомый ключ — ошибка вызова API, а не
%% пользовательского ввода, поэтому они завершаются badarg, как в store и
%% compile. Промолчать здесь дороже, чем в опциях хранилища: `flag` разрешает
%% short-circuit, и опечатка в имени опции тихо оставила бы вызывающего без всей
%% запрошенной диагностики.
-spec check_options([term()]) -> ok.
check_options([]) ->
    ok;
check_options([{output, Format} | Rest])
  when Format =:= flag; Format =:= basic;
       Format =:= detailed; Format =:= verbose ->
    check_options(Rest);
check_options(Options) ->
    erlang:error(badarg, [Options]).
