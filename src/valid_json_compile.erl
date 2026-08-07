%% Публичная координация компиляции: выбирает entry и dialect, строит
%% транзитивное замыкание документов и передаёт готовый resource index emitter'у.
%% Фасад приложения этот внутренний разрез не меняет.
-module(valid_json_compile).

-include("valid_json_core.hrl").
-include("valid_json_resources.hrl").

-export([compile/2, compile/3, compile_uri/3]).
-export_type([compile_option/0, schema_validation/0]).

-ifdef(TEST).
-export([compile_emitter_fixture/2]).
-endif.

%% `schema_validation` называет формат, в котором проверка метасхемой доложит о
%% провале. `trust_schema` — отдельная политика вызывающего, которая может
%% отключить саму проверку, но не compiler safety checks.
-type compile_option() :: {default_dialect, dialect()}
                        | {assert_format, boolean()}
                        | {schema_validation, schema_validation()}
                        | {trust_schema, boolean()}.

-spec compile(json(), dialect()) -> {ok, compiled()} | {error, #schema_error{}}.
compile(Schema, Dialect) ->
    Profile = valid_json_vocabulary:canonical(Dialect),
    %% Store у этого входа нет, поэтому пользовательская метасхема встроенного
    %% resource неотличима от неизвестного dialect — как и на любом другом имени,
    %% которого нет в реестре.
    Resolve = valid_json_compile_closure:dialect_resolver(
                valid_json_store:temporary(), Profile),
    case valid_json_resource_index:discover(Schema, anonymous, Profile, Resolve) of
        {ok, Index} ->
            finish(valid_json_store:temporary(), {ok, Index, []}, basic, false,
                   false);
        {error, _} = Error ->
            Error
    end.

-ifdef(TEST).
%% Точные emitter fixtures проверяют защитную обработку некорректных входов и
%% форму IR отдельно от публичной проверки метасхемой. Функция существует только
%% в test build; пользовательские compile-входы всегда проходят schema-check.
-spec compile_emitter_fixture(json(), dialect()) ->
          {ok, compiled()} | {error, #schema_error{}}.
compile_emitter_fixture(Schema, Dialect) ->
    Profile = valid_json_vocabulary:canonical(Dialect),
    Resolve = valid_json_compile_closure:dialect_resolver(
                valid_json_store:temporary(), Profile),
    case valid_json_resource_index:discover(Schema, anonymous, Profile, Resolve) of
        {ok, Index} -> valid_json_compile_emit:emit(Index, [], false);
        {error, _} = Error -> Error
    end.
-endif.

%% Публичный entry для inline schema. Store остаётся read-only: closure
%% втягивает только документы, достижимые по `$ref`, а evaluator получает
%% готовый толстый artifact без registry lookup.
-spec compile(store(), json(), [compile_option()]) ->
          {ok, compiled()} | {error, #schema_error{}}.
compile(#store{} = Store, Schema, Options) when is_list(Options) ->
    case compile_options(Options) of
        {ok, DefaultDialect, SchemaValidation, TrustSchema, AssertFormat} ->
            finish(Store, valid_json_compile_closure:inline(Store, Schema,
                                                            DefaultDialect),
                   SchemaValidation, TrustSchema, AssertFormat);
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
        {ok, DefaultDialect, SchemaValidation, TrustSchema, AssertFormat} ->
            case entry_name(Uri, Store#store.base) of
                {ok, Name} ->
                    case valid_json_store:fetch(Name, Store) of
                        undefined ->
                            {error, #schema_error{reason = {unknown_document, Name},
                                                  location = undefined}};
                        #document{} = Document ->
                            finish(Store, valid_json_compile_closure:document(
                                            Store, Document, DefaultDialect),
                                   SchemaValidation, TrustSchema, AssertFormat)
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end;
compile_uri(Store, Uri, Options) ->
    erlang:error(badarg, [Store, Uri, Options]).

-spec finish(store(),
             {ok, valid_json_resource_index:index(), [uri()]}
           | {error, #schema_error{}}, schema_validation(), boolean(), boolean()) ->
          {ok, compiled()} | {error, #schema_error{}}.
finish(Store, {ok, Index, Sources0}, SchemaValidation, TrustSchema, AssertFormat) ->
    case valid_json_resource_index:check_references(Index) of
        ok ->
            case valid_json_schema_check:check(Index, Store, SchemaValidation,
                                               TrustSchema) of
                {ok, MetaSources} ->
                    Sources = ordsets:union(Sources0, MetaSources),
                    valid_json_compile_emit:emit(Index, Sources, AssertFormat);
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end;
finish(_Store, {error, _} = Error, _SchemaValidation, _TrustSchema,
       _AssertFormat) ->
    Error.

-spec compile_options([term()]) ->
          {ok, dialect(), schema_validation(), boolean(), boolean()}
        | {error, #schema_error{}}.
compile_options(Options) ->
    compile_options(Options, ?DRAFT_2020_12, basic, false, false).

-define(SCHEMA_VALIDATION(Mode),
        Mode =:= flag; Mode =:= basic;
        Mode =:= detailed; Mode =:= verbose).

%% `assert_format` меняет IR и потому является compile option, а не option
%% вычисления (validator-resources-runtime.md, «Опции»). По умолчанию `format`
%% только аннотирует: включать проверку без явной настройки спецификация
%% запрещает (validation.txt:617).
-spec compile_options([term()], dialect(), schema_validation(), boolean(), boolean()) ->
          {ok, dialect(), schema_validation(), boolean(), boolean()}
        | {error, #schema_error{}}.
compile_options([], DefaultDialect, SchemaValidation, TrustSchema, AssertFormat) ->
    {ok, DefaultDialect, SchemaValidation, TrustSchema, AssertFormat};
compile_options([{default_dialect, Dialect} | Rest], _DefaultDialect,
                SchemaValidation, TrustSchema, AssertFormat)
  when is_binary(Dialect) ->
    case valid_json_compile_closure:supported_dialect(Dialect) of
        {ok, Normalized} ->
            compile_options(Rest, Normalized, SchemaValidation, TrustSchema,
                            AssertFormat);
        {error, _} = Error ->
            Error
    end;
compile_options([{assert_format, Assert} | Rest], DefaultDialect,
                SchemaValidation, TrustSchema, _AssertFormat)
  when is_boolean(Assert) ->
    compile_options(Rest, DefaultDialect, SchemaValidation, TrustSchema, Assert);
compile_options([{schema_validation, Mode} | Rest], DefaultDialect,
                _SchemaValidation, TrustSchema, AssertFormat)
  when ?SCHEMA_VALIDATION(Mode) ->
    compile_options(Rest, DefaultDialect, Mode, TrustSchema, AssertFormat);
compile_options([{trust_schema, Trust} | Rest], DefaultDialect,
                SchemaValidation, _TrustSchema, AssertFormat)
  when is_boolean(Trust) ->
    compile_options(Rest, DefaultDialect, SchemaValidation, Trust, AssertFormat);
compile_options(_Options, _DefaultDialect, _SchemaValidation, _TrustSchema,
                _AssertFormat) ->
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
