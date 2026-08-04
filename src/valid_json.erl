%% Фасад библиотеки. Переводит публичный вызов во внутренний и делегирует;
%% собственной логики не имеет. Области описаны в okf/architecture/validator-design.md.
-module(valid_json).

-include("valid_json_core.hrl").
-include("valid_json_resources.hrl").

-export([add/1, add/2, remove/1, wait/1, validate/3,
         store_add/2, store_add/3, store_remove/2, store_wait/2,
         store_validate/4, format_error/1]).

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

%% Первая операция того, кто собирается читать: дожидается конца загрузки и
%% отдаёт монитор, по которому вызывающий узнает, что состав мог измениться.
-spec wait(timeout()) -> {ok, reference()} | {error, timeout}.
wait(Timeout) ->
    store_wait(?STANDARD_STORE, Timeout).

%% Названа парно к `compile_uri/3` и отличается от `validate/3` встроенного
%% режима именем, а не формой первого аргумента: одна арность не должна значить
%% двух разных вещей.
-spec validate(uri(), json(), [option()]) ->
          {ok, output()} | {error, not_found} | {error, unavailable}
        | {error, eval_error()}.
validate(Uri, Instance, Options) ->
    store_validate(?STANDARD_STORE, Uri, Instance, Options).

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

-spec store_wait(atom(), timeout()) -> {ok, reference()} | {error, timeout}.
store_wait(Store, Timeout) ->
    valid_json_store_manager:wait(Store, Timeout).

%% Имя принимается и коротким: `lookup` разрешает его от базы хранилища тем же
%% правилом, каким разрешается регистрируемое. `unavailable` означает, что до
%% чтения дело не дошло: хранилище ещё не готово или перезапускается.
-spec store_validate(atom(), uri(), json(), [option()]) ->
          {ok, output()} | {error, not_found} | {error, unavailable}
        | {error, eval_error()}.
store_validate(Store, Uri, Instance, Options) ->
    case valid_json_store_manager:lookup(Store, Uri) of
        {ok, Compiled}       -> valid_json_core:validate(Compiled, Instance, Options);
        {error, _Reason} = E -> E
    end.

-spec format_error(#schema_error{}) -> unicode:chardata().
format_error(Error) ->
    valid_json_error:format_error(Error).
