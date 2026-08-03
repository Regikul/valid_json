%% Публичная координация компиляции: выбирает entry и dialect, строит
%% транзитивное замыкание документов и передаёт готовый resource index emitter'у.
%% Фасад приложения этот внутренний разрез не меняет.
-module(valid_json_compile).

-include("valid_json_core.hrl").
-include("valid_json_resources.hrl").

-export([compile/2, compile/3, compile_uri/3]).
-export_type([compile_option/0]).

-type compile_option() :: {default_dialect, dialect()}
                        | {assert_format, boolean()}.

-spec compile(json(), dialect()) -> {ok, compiled()} | {error, #schema_error{}}.
compile(Schema, Dialect) ->
    case valid_json_resource_index:discover(Schema, anonymous, Dialect) of
        {ok, Index} ->
            valid_json_compile_emit:emit(Index, []);
        {error, _} = Error ->
            Error
    end.

%% Production entry для inline schema. Store остаётся read-only: closure
%% втягивает только документы, достижимые по `$ref`, а evaluator получает
%% готовый толстый artifact без registry lookup.
-spec compile(store(), json(), [compile_option()]) ->
          {ok, compiled()} | {error, #schema_error{}}.
compile(#store{} = Store, Schema, Options) when is_list(Options) ->
    case compile_options(Options) of
        {ok, DefaultDialect} ->
            finish(valid_json_compile_closure:inline(Store, Schema,
                                                     DefaultDialect));
        {error, _} = Error ->
            Error
    end;
compile(Store, Schema, Options) ->
    erlang:error(badarg, [Store, Schema, Options]).

%% Entry document можно назвать retrieval либо canonical URI. Относительное
%% написание разрешается от base самого store, но в artifact нигде не хранится.
-spec compile_uri(store(), uri(), [compile_option()]) ->
          {ok, compiled()} | {error, #schema_error{}}.
compile_uri(#store{} = Store, Uri, Options)
  when is_binary(Uri), is_list(Options) ->
    case compile_options(Options) of
        {ok, DefaultDialect} ->
            case entry_name(Uri, Store#store.base) of
                {ok, Name} ->
                    case valid_json_store:fetch(Name, Store) of
                        undefined ->
                            {error, #schema_error{reason = {unknown_document, Name},
                                                  location = undefined}};
                        #document{} = Document ->
                            finish(valid_json_compile_closure:document(
                                     Store, Document, DefaultDialect))
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end;
compile_uri(Store, Uri, Options) ->
    erlang:error(badarg, [Store, Uri, Options]).

-spec finish({ok, valid_json_resource_index:index(), [uri()]}
           | {error, #schema_error{}}) ->
          {ok, compiled()} | {error, #schema_error{}}.
finish({ok, Index, Sources}) ->
    valid_json_compile_emit:emit(Index, Sources);
finish({error, _} = Error) ->
    Error.

-spec compile_options([term()]) ->
          {ok, dialect()} | {error, #schema_error{}}.
compile_options(Options) ->
    compile_options(Options, ?DRAFT_2020_12).

-spec compile_options([term()], dialect()) ->
          {ok, dialect()} | {error, #schema_error{}}.
compile_options([], DefaultDialect) ->
    {ok, DefaultDialect};
compile_options([{default_dialect, Dialect} | Rest], _DefaultDialect)
  when is_binary(Dialect) ->
    case valid_json_compile_closure:supported_dialect(Dialect) of
        {ok, Normalized}   -> compile_options(Rest, Normalized);
        {error, _} = Error -> Error
    end;
compile_options([{assert_format, Assert} | Rest], DefaultDialect)
  when is_boolean(Assert) ->
    %% Аннотация `format` уже собирается, а выбор между annotation и assertion
    %% остаётся в P8: до таблицы format algorithms включать проверку нечем.
    %% Опция валидируется production API, но IR пока не меняет.
    compile_options(Rest, DefaultDialect);
compile_options(_Options, _DefaultDialect) ->
    erlang:error(badarg).

-spec entry_name(uri(), rid()) ->
          {ok, uri()} | {error, #schema_error{}}.
entry_name(Uri, Base) ->
    case valid_json_uri:resolve(Uri, Base) of
        {ok, Name, root} when Name =/= anonymous ->
            {ok, Name};
        {ok, _Name, _Target} ->
            {error, #schema_error{reason = invalid_uri, location = undefined}};
        {error, Reason} ->
            {error, #schema_error{reason = Reason, location = undefined}}
    end.
