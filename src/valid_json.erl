%% Фасад библиотеки. Переводит публичный вызов во внутренний и делегирует;
%% собственной логики не имеет. Области описаны в okf/architecture/validator-design.md.
-module(valid_json).

-include("valid_json_core.hrl").

-export([new/1, add/2, add/3, remove/2, validate/3]).

-spec new([valid_json_store:store_option()]) -> valid_json_store:store().
new(Options) ->
    valid_json_store:new(Options).

-spec add(valid_json_store:store(), uri(), json()) ->
          {ok, uri(), valid_json_store:store()} | {error, #schema_error{}}.
add(Store, Uri, Json) ->
    valid_json_store:add(Store, Uri, Json).

-spec add(valid_json_store:store(), [{uri(), json()}]) ->
          {ok, [uri()], valid_json_store:store()} | {error, #schema_error{}}.
add(Store, Documents) ->
    valid_json_store:add(Store, Documents).

-spec remove(valid_json_store:store(), [uri()]) ->
          {ok, valid_json_store:store()} | {error, #schema_error{}}.
remove(Store, Uris) ->
    valid_json_store:remove(Store, Uris).

%% valid = false — нормальный результат; единственная причина отказа —
%% сработавший cycle guard.
-spec validate(compiled(), json(), [option()]) -> {ok, output()} | {error, eval_error()}.
validate(Compiled, Instance, Options) ->
    valid_json_core:validate(Compiled, Instance, Options).
