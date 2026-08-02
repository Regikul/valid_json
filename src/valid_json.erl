%% Фасад библиотеки. Переводит публичный вызов во внутренний и делегирует;
%% собственной логики не имеет. Области описаны в okf/architecture/validator-design.md.
-module(valid_json).

-include("valid_json_core.hrl").

-export([validate/3]).

%% valid = false — нормальный результат; единственная причина отказа —
%% сработавший cycle guard.
-spec validate(compiled(), json(), [option()]) -> {ok, output()} | {error, eval_error()}.
validate(Compiled, Instance, Options) ->
    valid_json_core:validate(Compiled, Instance, Options).
