%% Корень библиотеки. Здесь стоят хранилища, и падение одного не касается
%% остальных, поэтому стратегия one_for_one. Порядок внутри хранилища — забота
%% valid_json_store_sup.
%%
%% Стандартное хранилище поднимается всегда: приложению, которому хватает одного
%% набора схем, ничего заводить не нужно.
-module(valid_json_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

-define(STANDARD_STORE, valid_json).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Standard = valid_json_store_sup:child_spec(?STANDARD_STORE),
    {ok, {#{strategy => one_for_one, intensity => 1, period => 5}, [Standard]}}.
