%% Фасад библиотеки. Переводит публичный вызов во внутренний и делегирует;
%% собственной логики не имеет. Области описаны в okf/architecture/validator-design.md.
-module(valid_json).

-include("valid_json_core.hrl").
-include("valid_json_resources.hrl").

-export([add/1, add/2, remove/1, validate_uri/3,
         store_add/2, store_add/3, store_remove/2, store_validate_uri/4]).

-spec add(uri(), json()) ->
          {ok, [uri()]} | {error, valid_json_store_manager:add_error()}.
add(Uri, Json) ->
    add([{Uri, Json}]).

-spec add([{uri(), json()}]) ->
          {ok, [uri()]} | {error, valid_json_store_manager:add_error()}.
add(Entries) ->
    store_add(?STANDARD_STORE, Entries).

-spec remove([uri()]) -> ok | {error, [{uri(), #schema_error{}}]}.
remove(Uris) ->
    store_remove(?STANDARD_STORE, Uris).

-spec validate_uri(uri(), json(), [option()]) ->
          {ok, output()} | {error, not_found} | {error, eval_error()}.
validate_uri(Uri, Instance, Options) ->
    store_validate_uri(?STANDARD_STORE, Uri, Instance, Options).

-spec store_add(atom(), uri(), json()) ->
          {ok, [uri()]} | {error, valid_json_store_manager:add_error()}.
store_add(Store, Uri, Json) ->
    store_add(Store, [{Uri, Json}]).

-spec store_add(atom(), [{uri(), json()}]) ->
          {ok, [uri()]} | {error, valid_json_store_manager:add_error()}.
store_add(Store, Entries) ->
    valid_json_store_manager:add(Store, Entries).

-spec store_remove(atom(), [uri()]) ->
          ok | {error, [{uri(), #schema_error{}}]}.
store_remove(Store, Uris) ->
    valid_json_store_manager:remove(Store, Uris).

-spec store_validate_uri(atom(), uri(), json(), [option()]) ->
          {ok, output()} | {error, not_found} | {error, eval_error()}.
store_validate_uri(Store, Uri, Instance, Options) ->
    case valid_json_store_manager:lookup(Store, Uri) of
        {ok, Compiled} -> valid_json_core:validate(Compiled, Instance, Options);
        {error, not_found} -> {error, not_found}
    end.
