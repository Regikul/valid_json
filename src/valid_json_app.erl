%% OTP entry: встроенные метасхемы публикуются до объявления приложения
%% готовым, поэтому compile path никогда не видит пустой persistent_term.
-module(valid_json_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    ok = valid_json_metaschema:publish(),
    valid_json_sup:start_link().

stop(_State) ->
    %% Записи immutable и намеренно переживают restart приложения. При загрузке
    %% новой версии publish/0 заменит их целиком до готовности приложения.
    ok.
