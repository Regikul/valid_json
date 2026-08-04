%% Загрузчик без `base_uri/1`: колбэк необязателен, и назвать локацию есть чем
%% не всякому. База такого хранилища берётся дальше по общей цепочке.
-module(valid_json_test_loader_bare).

-behaviour(valid_json_loader).

-export([load/1, base_uri/1]).

load(Entries) ->
    {ok, Entries}.

base_uri(_) ->
    undefined.
