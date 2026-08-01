#!/usr/bin/env escript
%%! -noshell
%%
%% Замер соответствия `re` диалекту ECMA-262 на закреплённом снапшоте сьюта.
%%
%% Прогоняет строковые сценарии keyword'а `pattern` из обязательного набора и
%% из `optional/ecmascript-regex` через четыре набора опций компиляции и
%% печатает, сколько сценариев каждый из них проходит. Числа этого замера
%% приведены в okf/architecture/ecma-to-pcre-adaptation.md, раздел «Замер»;
%% скрипт существует затем, чтобы их можно было перепроверить
%% после смены версии OTP.
%%
%% Движок от диалекта JSON Schema не зависит, поэтому берётся один — 2020-12.
%%
%%     escript test/regex_survey.escript          сводная таблица
%%     escript test/regex_survey.escript -v       плюс перечень провалов
%%
-module(regex_survey).
-export([main/1]).

-define(SUITE, "test/fixtures/json-schema-test-suite/tests/draft2020-12/").

option_sets() ->
    [[unicode],
     [unicode, ucp],
     [unicode, dollar_endonly],
     [unicode, ucp, dollar_endonly]].

files() ->
    [?SUITE "pattern.json", ?SUITE "optional/ecmascript-regex.json"].

main(Args) ->
    Cases = cases(),
    io:format("сценариев: ~p~n~n", [length(Cases)]),
    lists:foreach(fun(Opts) ->
        io:format("  ~-32w ~p/~p~n", [Opts, passed(Cases, Opts), length(Cases)])
    end, option_sets()),
    case Args of
        ["-v"] -> lists:foreach(fun(Opts) -> report(Cases, Opts) end, option_sets());
        _      -> ok
    end.

%% Сценарий — пара «паттерн, строка» с ожидаемым вердиктом. Нестроковые данные
%% пропускаются: `pattern` их не проверяет, и в замере они были бы шумом.
cases() ->
    [{Pattern, Data, Valid, Description}
     || File  <- files(),
        Group <- decode(File),
        Schema <- [maps:get(<<"schema">>, Group)],
        is_map(Schema),
        maps:is_key(<<"pattern">>, Schema),
        Pattern <- [maps:get(<<"pattern">>, Schema)],
        Description <- [maps:get(<<"description">>, Group)],
        Test  <- maps:get(<<"tests">>, Group),
        Data  <- [maps:get(<<"data">>, Test)],
        is_binary(Data),
        Valid <- [maps:get(<<"valid">>, Test)]].

decode(File) ->
    case file:read_file(File) of
        {ok, Bin}       -> json:decode(Bin);
        {error, enoent} -> abort("нет файла ~ts — запускать из корня репозитория", [File])
    end.

%% Ошибка компиляции паттерна — это провал сценария, а не отдельный исход:
%% схему с таким паттерном мы всё равно не примем.
verdict(Pattern, Data, Opts) ->
    case re:compile(Pattern, Opts) of
        {ok, MP}    -> re:run(Data, MP, [{capture, none}]) =:= match;
        {error, _}  -> compile_error
    end.

passed(Cases, Opts) ->
    length([ok || {P, D, V, _} <- Cases, verdict(P, D, Opts) =:= V]).

report(Cases, Opts) ->
    Failed = [C || C = {P, D, V, _} <- Cases, verdict(P, D, Opts) =/= V],
    io:format("~nпровалы под ~w:~n", [Opts]),
    lists:foreach(fun({P, D, V, Desc}) ->
        io:format("  ~ts~n    pattern=~ts  data=~tp  ждали=~w  получили=~w~n",
                  [Desc, P, D, V, verdict(P, D, Opts)])
    end, Failed).

abort(Format, Args) ->
    io:format(standard_error, Format ++ "~n", Args),
    halt(1).
