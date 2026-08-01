%% Проекции дерева units в standard output formats.
%% Все структурные форматы строятся из одного дерева; см. validator-core.md.
-module(valid_json_output).

-include("valid_json_core.hrl").

-export([project/2]).

-spec project(format(), #eval_result{}) -> output().
project(flag, #eval_result{valid = Valid}) ->
    #{<<"valid">> => Valid}.
