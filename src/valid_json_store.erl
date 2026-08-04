%% Чистый реестр JSON Schema documents. Он регистрирует два имени документа —
%% retrieval и canonical URI, — но ничего не компилирует и не знает о ссылках.
%% Нормативный контракт — okf/architecture/validator-resources-runtime.md,
%% разделы «Registry без сети» и «API и фазы компиляции».
-module(valid_json_store).

-include("valid_json_resources.hrl").

-export([new/1, add/2, add/3, remove/2, fetch/2, canonical_names/1,
         base/1, resolve_name/2, from_documents/2]).
-export_type([store/0, registry_option/0]).

%% `new/1` не имеет error-ветви по публичному контракту. Ошибочная опция —
%% ошибка вызова API, поэтому она завершается badarg, а не schema_error.
-spec new([registry_option()]) -> store().
new(Options) when is_list(Options) ->
    case base_option(Options) of
        {ok, Base} -> #store{base = Base};
        error      -> erlang:error(badarg, [Options])
    end;
new(Options) ->
    erlang:error(badarg, [Options]).

%% Запись здесь одна, поэтому имя ошибки вызывающий знает и без нас.
-spec add(store(), uri(), json()) ->
          {ok, uri(), store()} | {error, #schema_error{}}.
add(Store, Uri, Json) ->
    case add(Store, [{Uri, Json}]) of
        {ok, [Canonical], Added} -> {ok, Canonical, Added};
        {error, [{Uri, Error}]}  -> {error, Error}
    end.

%% Списочная регистрация атомарна относительно значения: сначала строятся все
%% documents и снимаются заменяемые записи, затем проверяются конфликты. Ошибка
%% не возвращает промежуточный store вызывающему.
%%
%% Ошибки собираются все: записи разбираются независимо, и показать разом весь
%% испорченный вызов полезнее, чем первую попавшуюся запись. Имя ошибки — то
%% написание, с каким пришёл вызывающий: канонического имени у отвергнутой
%% записи может не быть вовсе, а `name_taken` называет чужое.
%%
%% Фазы не смешиваются: пока хоть одно имя не разрешилось, конфликты не
%% считаются — считать их не из чего, документов нет.
-spec add(store(), [{uri(), json()}]) ->
          {ok, [uri()], store()} | {error, [{uri(), #schema_error{}}]}.
add(#store{} = Store, Entries) when is_list(Entries) ->
    case documents(Entries, Store#store.base) of
        {ok, Added} -> insert_all(Added, Store);
        {error, _} = Error -> Error
    end;
add(Store, Entries) ->
    erlang:error(badarg, [Store, Entries]).

%% Снятый документ называется парой: написанием вызывающего и своим каноническим
%% именем. Первое нужно тому, кто станет называть им ошибку, второе — тому, кто
%% держит артефакты. Запись, не нашедшая документа, пары не даёт и ошибкой не
%% считается: удалять нечего. Ошибки разрешения имён собираются все, как в
%% `add/2`, и по той же причине.
-spec remove(store(), [uri()]) ->
          {ok, [{uri(), uri()}], store()} | {error, [{uri(), #schema_error{}}]}.
remove(#store{} = Store, Uris) when is_list(Uris) ->
    case names(Uris, Store#store.base) of
        {ok, Names} ->
            {Removed, Documents} = remove_names(Names, Store#store.documents),
            {ok, Removed, Store#store{documents = Documents}};
        {error, _} = Error ->
            Error
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

%% Оба ключа документа дают одно каноническое имя, поэтому список без повторов.
%% Встроенная область сюда не попадает: её документы в реестре не лежат.
-spec canonical_names(store()) -> [uri()].
canonical_names(#store{documents = Documents}) ->
    ordsets:from_list([Canonical
                       || #document{canonical = Canonical}
                              <- maps:values(Documents)]).

%% База нужна снаружи одному читателю артефактов: он разрешает от неё короткое
%% имя тем же правилом, каким разрешается регистрируемое. Отдаётся она уже
%% нормализованной, то есть ровно такой, какой пользуется сам реестр.
-spec base(store()) -> uri() | anonymous.
base(#store{base = Base}) ->
    Base.

%% Правило разрешения имени публично затем, чтобы регистрация и валидация не
%% разошлись: обе зовут одно и то же.
-spec resolve_name(uri(), rid()) -> {ok, uri()} | {error, #schema_error{}}.
resolve_name(Uri, Base) ->
    registration_name(Uri, Base).

%% Обратная сборка реестра из документов: двухключевое устройство остаётся
%% внутри модуля, а снаружи документ переносится как одно целое. Оба ключа
%% восстанавливаются из полей самого документа, поэтому список повторов не
%% содержит.
-spec from_documents([#document{}], [registry_option()]) -> store().
from_documents(Documents, Options) when is_list(Documents) ->
    Store = new(Options),
    Store#store{documents = index(Documents)}.

-spec index([#document{}]) -> #{uri() => #document{}}.
index(Documents) ->
    lists:foldl(fun(#document{retrieval = Retrieval,
                              canonical = Canonical} = Document, Acc) ->
                        Acc#{Retrieval => Document, Canonical => Document}
                end, #{}, Documents).

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

%% Записи разбираются независимо друг от друга, поэтому ошибки одной не мешают
%% увидеть ошибки остальных. Документ сохраняется вместе с именем записи: под
%% ним же называется ошибка следующей фазы.
-spec documents([term()], rid()) ->
          {ok, [{uri(), #document{}}]} | {error, [{uri(), #schema_error{}}]}.
documents(Entries, Base) ->
    case lists:foldl(fun(Entry, Acc) -> build(Entry, Base, Acc) end,
                     {[], []}, Entries) of
        {Documents, []} -> {ok, lists:reverse(Documents)};
        {_Documents, Errors} -> {error, lists:reverse(Errors)}
    end.

-spec build(term(), rid(), {[{uri(), #document{}}], [{uri(), #schema_error{}}]}) ->
          {[{uri(), #document{}}], [{uri(), #schema_error{}}]}.
build({Uri, Json}, Base, {Documents, Errors}) when is_binary(Uri) ->
    case document(Uri, Json, Base) of
        {ok, Document}     -> {[{Uri, Document} | Documents], Errors};
        {error, Error}     -> {Documents, [{Uri, Error} | Errors]}
    end;
build(_Entry, _Base, _Acc) ->
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

-spec names([term()], rid()) ->
          {ok, [{uri(), uri()}]} | {error, [{uri(), #schema_error{}}]}.
names(Uris, Base) ->
    case lists:foldl(fun(Uri, Acc) -> name(Uri, Base, Acc) end, {[], []}, Uris) of
        {Names, []} -> {ok, lists:reverse(Names)};
        {_Names, Errors} -> {error, lists:reverse(Errors)}
    end.

-spec name(term(), rid(), {[{uri(), uri()}], [{uri(), #schema_error{}}]}) ->
          {[{uri(), uri()}], [{uri(), #schema_error{}}]}.
name(Uri, Base, {Names, Errors}) when is_binary(Uri) ->
    case registration_name(Uri, Base) of
        {ok, Name}     -> {[{Uri, Name} | Names], Errors};
        {error, Error} -> {Names, [{Uri, Error} | Errors]}
    end;
name(_Uri, _Base, _Acc) ->
    erlang:error(badarg).

-spec insert_all([{uri(), #document{}}], store()) ->
          {ok, [uri()], store()} | {error, [{uri(), #schema_error{}}]}.
insert_all(Added, #store{documents = Existing} = Store) ->
    Retrievals = [Uri || {_Entry, #document{retrieval = Uri}} <- Added],
    Stripped = strip_replacements(Retrievals, Existing),
    case lists:foldl(fun insert/2, {[], [], Stripped}, Added) of
        {Canonicals, [], Documents} ->
            {ok, lists:reverse(Canonicals), Store#store{documents = Documents}};
        {_Canonicals, Errors, _Documents} ->
            {error, lists:reverse(Errors)}
    end.

%% Отвергнутая запись не вставляется, а обход продолжается: так за один вызов
%% видно все конфликты. Невидимым остаётся один — конфликт с записью, которая и
%% сама отвергнута, потому что в реестр она не попала.
-spec insert({uri(), #document{}},
             {[uri()], [{uri(), #schema_error{}}], #{uri() => #document{}}}) ->
          {[uri()], [{uri(), #schema_error{}}], #{uri() => #document{}}}.
insert({Entry, #document{retrieval = Retrieval, canonical = Canonical} = Document},
       {Canonicals, Errors, Documents0}) ->
    %% Повтор одного retrieval внутри batch — тот же upsert, что между вызовами.
    Documents = strip_replacement(Retrieval, Documents0),
    case free_names([Retrieval, Canonical], Documents) of
        ok ->
            Stored = Documents#{Retrieval => Document, Canonical => Document},
            {[Canonical | Canonicals], Errors, Stored};
        {error, Error} ->
            {Canonicals, [{Entry, Error} | Errors], Documents0}
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

%% Встроенные документы отсюда не видны: они лежат мимо реестра, и `maps:get`
%% их не находит. Тем самым снять встроенное имя нельзя, и отдельного запрета
%% на это не нужно.
-spec remove_names([{uri(), uri()}], #{uri() => #document{}}) ->
          {[{uri(), uri()}], #{uri() => #document{}}}.
remove_names(Names, Documents) ->
    {Removed, Rest} = lists:foldl(fun remove_name/2, {[], Documents}, Names),
    {lists:reverse(Removed), Rest}.

-spec remove_name({uri(), uri()},
                  {[{uri(), uri()}], #{uri() => #document{}}}) ->
          {[{uri(), uri()}], #{uri() => #document{}}}.
remove_name({Entry, Name}, {Removed, Documents}) ->
    case maps:get(Name, Documents, undefined) of
        #document{canonical = Canonical} = Document ->
            {[{Entry, Canonical} | Removed], remove_document(Document, Documents)};
        undefined ->
            {Removed, Documents}
    end.

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
