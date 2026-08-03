%% Чистый реестр JSON Schema documents. Он регистрирует два имени документа —
%% retrieval и canonical URI, — но ничего не компилирует и не знает о ссылках.
%% Нормативный контракт — okf/architecture/validator-resources-runtime.md,
%% разделы «Registry без сети» и «API и фазы компиляции».
-module(valid_json_store).

-include("valid_json_resources.hrl").

-export([new/1, add/2, add/3, remove/2, fetch/2]).
-export_type([store/0, store_option/0]).

%% `new/1` не имеет error-ветви по публичному контракту. Ошибочная опция —
%% ошибка вызова API, поэтому она завершается badarg, а не schema_error.
-spec new([store_option()]) -> store().
new(Options) when is_list(Options) ->
    case base_option(Options) of
        {ok, Base} -> #store{base = Base};
        error      -> erlang:error(badarg, [Options])
    end;
new(Options) ->
    erlang:error(badarg, [Options]).

-spec add(store(), uri(), json()) ->
          {ok, uri(), store()} | {error, #schema_error{}}.
add(Store, Uri, Json) ->
    case add(Store, [{Uri, Json}]) of
        {ok, [Canonical], Added} -> {ok, Canonical, Added};
        {error, _} = Error       -> Error
    end.

%% Списочная регистрация атомарна относительно значения: сначала строятся все
%% documents и снимаются заменяемые записи, затем проверяются конфликты. Ошибка
%% не возвращает промежуточный store вызывающему.
-spec add(store(), [{uri(), json()}]) ->
          {ok, [uri()], store()} | {error, #schema_error{}}.
add(#store{} = Store, Entries) when is_list(Entries) ->
    case documents(Entries, Store#store.base, []) of
        {ok, Added} -> insert_all(Added, Store);
        {error, _} = Error -> Error
    end;
add(Store, Entries) ->
    erlang:error(badarg, [Store, Entries]).

-spec remove(store(), [uri()]) -> {ok, store()} | {error, #schema_error{}}.
remove(#store{} = Store, Uris) when is_list(Uris) ->
    case names(Uris, Store#store.base, []) of
        {ok, Names} -> {ok, Store#store{documents = remove_names(Names,
                                                                  Store#store.documents)}};
        {error, _} = Error -> Error
    end;
remove(Store, Uris) ->
    erlang:error(badarg, [Store, Uris]).

%% Compiler передаёт сюда уже разрешённое каноническое имя. Пользовательский
%% registry имеет приоритет; промах читается из отдельной immutable области.
-spec fetch(uri(), store()) -> #document{} | undefined.
fetch(Uri, #store{documents = Documents}) ->
    case maps:get(Uri, Documents, undefined) of
        undefined -> fetch_builtin(Uri);
        Document  -> Document
    end.

-spec base_option([term()]) -> {ok, rid()} | error.
base_option([]) ->
    {ok, anonymous};
base_option([{base_uri, Uri}]) when is_binary(Uri) ->
    hierarchical_base(Uri);
base_option(_Options) ->
    error.

%% Относительные имена безопасно разрешаются только от hierarchical URI.
%% Authority делает URI hierarchical независимо от path; без authority path
%% обязан быть абсолютным. Так `file:/schemas/root` разрешён, а URN отвергнут.
-spec hierarchical_base(uri()) -> {ok, uri()} | error.
hierarchical_base(Uri) ->
    case {uri_string:parse(Uri), valid_json_uri:resolve(Uri, anonymous)} of
        {#{scheme := _, host := _}, {ok, Normalized, root}} ->
            {ok, Normalized};
        {#{scheme := _, path := <<"/", _/binary>>}, {ok, Normalized, root}} ->
            {ok, Normalized};
        _ ->
            error
    end.

-spec documents([term()], rid(), [#document{}]) ->
          {ok, [#document{}]} | {error, #schema_error{}}.
documents([], _Base, Acc) ->
    {ok, lists:reverse(Acc)};
documents([{Uri, Json} | Rest], Base, Acc) when is_binary(Uri) ->
    case document(Uri, Json, Base) of
        {ok, Document} -> documents(Rest, Base, [Document | Acc]);
        {error, _} = Error -> Error
    end;
documents(_Entries, _Base, _Acc) ->
    erlang:error(badarg).

-spec document(uri(), json(), rid()) -> {ok, #document{}} | {error, #schema_error{}}.
document(Uri, Json, Base) ->
    case registration_name(Uri, Base) of
        {ok, Retrieval} ->
            case canonical(Json, Retrieval) of
                {ok, Canonical} ->
                    {ok, #document{retrieval = Retrieval,
                                   canonical = Canonical,
                                   json = Json}};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

-spec registration_name(uri(), rid()) -> {ok, uri()} | {error, #schema_error{}}.
registration_name(Uri, Base) ->
    case valid_json_uri:resolve(Uri, Base) of
        {ok, Name, root} when Name =/= anonymous -> {ok, Name};
        {ok, _Name, _Fragment}                  -> schema_error(invalid_uri);
        {error, Reason}                         -> schema_error(Reason)
    end.

-spec canonical(json(), uri()) -> {ok, uri()} | {error, #schema_error{}}.
canonical(#{<<"$id">> := Id}, Retrieval) when is_binary(Id) ->
    case valid_json_uri:resolve(Id, Retrieval) of
        {ok, Canonical, root} when Canonical =/= anonymous -> {ok, Canonical};
        {ok, _Canonical, _Fragment} -> schema_error({bad_keyword_value, Id});
        {error, Reason}             -> schema_error(Reason)
    end;
canonical(#{<<"$id">> := Id}, _Retrieval) ->
    schema_error({bad_keyword_value, Id});
canonical(_Json, Retrieval) ->
    {ok, Retrieval}.

-spec names([term()], rid(), [uri()]) ->
          {ok, [uri()]} | {error, #schema_error{}}.
names([], _Base, Acc) ->
    {ok, lists:reverse(Acc)};
names([Uri | Rest], Base, Acc) when is_binary(Uri) ->
    case registration_name(Uri, Base) of
        {ok, Name}       -> names(Rest, Base, [Name | Acc]);
        {error, _} = Error -> Error
    end;
names(_Uris, _Base, _Acc) ->
    erlang:error(badarg).

-spec insert_all([#document{}], store()) ->
          {ok, [uri()], store()} | {error, #schema_error{}}.
insert_all(Added, #store{documents = Existing} = Store) ->
    Retrievals = [Uri || #document{retrieval = Uri} <- Added],
    Stripped = strip_replacements(Retrievals, Existing),
    case lists:foldl(fun insert/2, {ok, [], Stripped}, Added) of
        {ok, Canonicals, Documents} ->
            {ok, lists:reverse(Canonicals), Store#store{documents = Documents}};
        {error, _} = Error ->
            Error
    end.

-spec insert(#document{}, {ok, [uri()], #{uri() => #document{}}} |
                            {error, #schema_error{}}) ->
          {ok, [uri()], #{uri() => #document{}}} | {error, #schema_error{}}.
insert(_Document, {error, _} = Error) ->
    Error;
insert(#document{retrieval = Retrieval, canonical = Canonical} = Document,
       {ok, Canonicals, Documents0}) ->
    %% Повтор одного retrieval внутри batch — тот же upsert, что между вызовами.
    Documents = strip_replacement(Retrieval, Documents0),
    case free_names([Retrieval, Canonical], Documents) of
        ok ->
            Stored = Documents#{Retrieval => Document, Canonical => Document},
            {ok, [Canonical | Canonicals], Stored};
        {error, _} = Error ->
            Error
    end.

-spec strip_replacements([uri()], #{uri() => #document{}}) ->
          #{uri() => #document{}}.
strip_replacements(Retrievals, Documents) ->
    lists:foldl(fun strip_replacement/2, Documents, Retrievals).

-spec strip_replacement(uri(), #{uri() => #document{}}) ->
          #{uri() => #document{}}.
strip_replacement(Retrieval, Documents) ->
    case maps:get(Retrieval, Documents, undefined) of
        #document{retrieval = Retrieval} = Old -> remove_document(Old, Documents);
        _Other                                -> Documents
    end.

-spec free_names([uri()], #{uri() => #document{}}) ->
          ok | {error, #schema_error{}}.
free_names([], _Documents) ->
    ok;
free_names([Name | Rest], Documents) ->
    case valid_json_metaschema:is_builtin(Name) orelse maps:is_key(Name, Documents) of
        true  -> schema_error({name_taken, Name});
        false -> free_names(Rest, Documents)
    end.

-spec remove_names([uri()], #{uri() => #document{}}) ->
          #{uri() => #document{}}.
remove_names(Names, Documents) ->
    lists:foldl(
      fun(Name, Acc) ->
              case maps:get(Name, Acc, undefined) of
                  #document{} = Document -> remove_document(Document, Acc);
                  undefined              -> Acc
              end
      end,
      Documents,
      Names).

-spec remove_document(#document{}, #{uri() => #document{}}) ->
          #{uri() => #document{}}.
remove_document(#document{retrieval = Retrieval, canonical = Canonical}, Documents) ->
    maps:remove(Canonical, maps:remove(Retrieval, Documents)).

-spec schema_error(reason()) -> {error, #schema_error{}}.
schema_error(Reason) ->
    {error, #schema_error{reason = Reason, location = undefined}}.

-spec fetch_builtin(uri()) -> #document{} | undefined.
fetch_builtin(Uri) ->
    valid_json_metaschema:fetch(Uri).
