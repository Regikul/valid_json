%% Корневой supervisor пока не имеет runtime-детей. Он создаёт корректную OTP
%% точку жизни приложения; хранитель ETS и manager будут добавлены сюда позже.
-module(valid_json_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {{rest_for_one, 1, 5}, []}}.
