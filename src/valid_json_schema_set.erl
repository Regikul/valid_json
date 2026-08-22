%% Одноразовая проверка связанного набора JSON Schema documents. Документы
%% регистрируются в чистом store одним атомарным вызовом, поэтому межфайловые
%% ссылки видят весь набор. Встроенные метасхемы живут локальным immutable
%% значением; application tree, ETS и пользовательские compiled artifacts этому
%% входу не нужны.
-module(valid_json_schema_set).

-include("valid_json_resources.hrl").

-export([check/2]).
-export_type([check_option/0, error/0]).

-type check_option() :: {base_uri, uri()}
                      | {default_dialect, dialect()}
                      | {schema_validation, schema_validation()}.
-type error() :: {registration, [{uri(), #schema_error{}}]}
               | {validation, [{uri(), #schema_error{}}]}.

-spec check([{uri(), json()}], [check_option()]) ->
          {ok, [uri()]} | {error, error()}.
check(Entries, Options) when is_list(Entries), is_list(Options) ->
    {RegistryOptions, CompileOptions} = options(Options),
    Store0 = valid_json_store:new(RegistryOptions),
    case valid_json_store:add(Store0, Entries) of
        {ok, Names, Store1} ->
            check_names(Names, Store1, CompileOptions);
        {error, Errors} ->
            {error, {registration, Errors}}
    end;
check(Entries, Options) ->
    erlang:error(badarg, [Entries, Options]).

-spec options([term()]) ->
          {[valid_json_store:registry_option()],
           [valid_json_compile:compile_option()]}.
options(Options) ->
    ok = known_options(Options),
    case lists:keyfind(base_uri, 1, Options) of
        {base_uri, Base} ->
            {[{base_uri, Base}],
             selected_options([default_dialect, schema_validation], Options)};
        false ->
            erlang:error(badarg, [Options])
    end.

-spec known_options([term()]) -> ok.
known_options([]) ->
    ok;
known_options([{base_uri, Uri} | Rest]) when is_binary(Uri) ->
    known_options(Rest);
known_options([{default_dialect, Dialect} | Rest]) when is_binary(Dialect) ->
    known_options(Rest);
known_options([{schema_validation, Mode} | Rest])
  when Mode =:= flag; Mode =:= basic; Mode =:= detailed; Mode =:= verbose ->
    known_options(Rest);
known_options(Options) ->
    erlang:error(badarg, [Options]).

-spec selected_options([atom()], [term()]) -> [term()].
selected_options([], _Options) ->
    [];
selected_options([Key | Rest], Options) ->
    case lists:keyfind(Key, 1, Options) of
        false  -> selected_options(Rest, Options);
        Option -> [Option | selected_options(Rest, Options)]
    end.

-spec check_names([uri()], store(), [valid_json_compile:compile_option()]) ->
          {ok, [uri()]} | {error, error()}.
check_names([], _Store, _Options) ->
    {ok, []};
check_names(Names, Store0, Options) ->
    Store = valid_json_metaschema:with_local_bundles(Store0),
    Check = fun(Name, Errors) ->
                    case valid_json_compile:check_uri(Store, Name, Options) of
                        ok             -> Errors;
                        {error, Error} -> [{Name, Error} | Errors]
                    end
            end,
    case lists:foldl(Check, [], Names) of
        [] ->
            {ok, Names};
        Errors ->
            {error, {validation, lists:reverse(Errors)}}
    end.
