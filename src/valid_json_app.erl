%% OTP entry: встроенные метасхемы поднимает первая ветка дерева, поэтому к
%% моменту старта хранилищ compile path видит полную таблицу.
-module(valid_json_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    valid_json_sup:start_link().

stop(_State) ->
    %% Таблица встроенных метасхем уходит вместе с деревом: держит её хранитель
    %% ветки. Следующий старт собирает bundle заново, и это стоит около девяти
    %% миллисекунд.
    ok.
