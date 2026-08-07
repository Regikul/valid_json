%% Построение транзитивного замыкания schema documents. Модуль читает store,
%% объединяет эфемерные resource indexes и возвращает только Index + Sources;
%% constraint IR здесь не создаётся.
-module(valid_json_compile_closure).

-include("valid_json_core.hrl").
-include("valid_json_resources.hrl").

-export([inline/3, document/3, supported_dialect/1, dialect_resolver/2]).

-type result() :: {ok, valid_json_resource_index:index(), [uri()]}
                | {error, #schema_error{}}.

-spec inline(store(), json(), dialect()) -> result().
inline(#store{} = Store, Schema, DefaultDialect) ->
    close_documents(Store, [{inline, Schema}],
                    valid_json_vocabulary:canonical(DefaultDialect),
                    undefined, #{}, []).

-spec document(store(), #document{}, dialect()) -> result().
document(#store{} = Store, #document{} = Document, DefaultDialect) ->
    close_documents(Store, [{document, Document}],
                    valid_json_vocabulary:canonical(DefaultDialect),
                    undefined, #{}, []).

%% Опция `default_dialect` называет именно dialect, а не пользовательскую
%% метасхему: она действует там, где `$schema` не написан вовсе, и потому
%% ограничена каноническими URI.
-spec supported_dialect(uri()) ->
          {ok, dialect()} | {error, #schema_error{}}.
supported_dialect(Dialect) ->
    case valid_json_uri:resolve(Dialect, anonymous) of
        {ok, ?DRAFT_2020_12 = Normalized, root} ->
            {ok, Normalized};
        {ok, ?DRAFT_2019_09 = Normalized, root} ->
            {ok, Normalized};
        {ok, ?DRAFT_07 = Normalized, root} ->
            {ok, Normalized};
        {ok, ?DRAFT_06 = Normalized, root} ->
            {ok, Normalized};
        _ ->
            {error, #schema_error{reason = {unknown_dialect, Dialect},
                                  location = undefined}}
    end.

%% Встроенные resources решают свой dialect уже во время обхода, а реестр
%% метасхем принадлежит этому модулю. Индекс получает вместо store функцию:
%% локацию ошибки он знает точнее, а про документы по-прежнему не знает ничего.
-spec dialect_resolver(store(), profile()) ->
          valid_json_resource_index:resolver().
dialect_resolver(#store{} = Store, #profile{draft = Default}) ->
    fun(Dialect) -> dialect_profile(Dialect, Store, Default, []) end.

%% Queue содержит только полные JSON documents. Каждый новый document сначала
%% проходит discovery, затем его index присоединяется к общему. Ссылки сканируем
%% по признанным schema positions; неизвестные keyword values сюда не попадают.
-spec close_documents(store(), [{inline, json()} | {document, #document{}}],
                      profile(), valid_json_resource_index:index() | undefined,
                      #{term() => true}, [uri()]) ->
          {ok, valid_json_resource_index:index(), [uri()]}
        | {error, #schema_error{}}.
close_documents(_Store, [], _Default, Index, _Loaded, Sources) ->
    {ok, Index, lists:sort(Sources)};
close_documents(Store, [Entry | Rest], Default, Index0, Loaded, Sources0) ->
    {Key, Retrieval, Schema, Owner, Source} = document_parts(Entry, Store),
    case maps:is_key(Key, Loaded) of
        true ->
            close_documents(Store, Rest, Default, Index0, Loaded, Sources0);
        false ->
            DialectBase = document_root(Schema, Retrieval),
            case document_profile(Schema, Default, DialectBase, Store) of
                {ok, Profile, Metaschema} ->
                    Resolve = dialect_resolver(Store, Default),
                    case valid_json_resource_index:discover(Schema, Retrieval,
                                                            Profile, Resolve) of
                        {ok, DocumentIndex} ->
                            case owned_resources(DocumentIndex, Owner, Store) of
                                ok ->
                                    case merge_index(Index0, DocumentIndex) of
                                        {ok, Index} ->
                                            Pending = referenced_documents(DocumentIndex,
                                                                           Index, Store),
                                            Sources = add_sources(
                                                        valid_json_resource_index:metaschemas(
                                                          DocumentIndex),
                                                        add_source(
                                                          Metaschema,
                                                          add_source(Source, Sources0))),
                                            close_documents(
                                              Store, Rest ++ Pending, Default,
                                              Index, Loaded#{Key => true}, Sources);
                                        {error, _} = Error ->
                                            Error
                                    end;
                                {error, _} = Error ->
                                    Error
                            end;
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end
    end.

-spec document_parts({inline, json()} | {document, #document{}}, store()) ->
          {term(), rid(), json(), uri() | undefined, uri() | undefined}.
document_parts({inline, Schema}, _Store) ->
    {inline, anonymous, Schema, undefined, undefined};
document_parts({document, #document{registered = Retrieval,
                                    canonical = Canonical,
                                    json = Schema} = Document}, Store) ->
    {{document, Canonical}, Retrieval, Schema, Canonical,
     source_name(Document, Store)}.

-spec registered_document(#document{}, store()) -> boolean().
registered_document(#document{registered = Retrieval, canonical = Canonical} = Document,
                    #store{documents = Documents}) ->
    maps:get(Retrieval, Documents, undefined) =:= Document orelse
    maps:get(Canonical, Documents, undefined) =:= Document.

-spec add_source(uri() | undefined, [uri()]) -> [uri()].
add_source(undefined, Sources) ->
    Sources;
add_source(Source, Sources) ->
    ordsets:add_element(Source, Sources).

-spec add_sources([uri()], [uri()]) -> [uri()].
add_sources(New, Sources) ->
    ordsets:union(New, Sources).

%% Профиль документа выбирается его собственным `$schema`, а без него — профилем
%% компиляции. Наружу уходит и канонический URI прочитанной пользовательской
%% метасхемы: её `$vocabulary` влияет на артефакт, поэтому она обязана попасть в
%% `sources` (validator-resources-runtime.md, «Транзитивное замыкание»).
-spec document_profile(json(), profile(), rid(), store()) ->
          {ok, profile(), uri() | undefined} | {error, #schema_error{}}.
document_profile(#{<<"$schema">> := Dialect}, #profile{draft = Default},
                 Resource, Store)
  when is_binary(Dialect) ->
    case dialect_profile(Dialect, Store, Default, []) of
        {ok, _Profile, _Metaschema} = Ok ->
            Ok;
        {error, Reason} ->
            {error, #schema_error{reason = Reason,
                                  location = keyword_location(Resource,
                                                              <<"$schema">>)}}
    end;
document_profile(#{<<"$schema">> := Other}, _Default, Resource, _Store) ->
    {error, #schema_error{reason = {bad_keyword_value, Other},
                          location = keyword_location(Resource, <<"$schema">>)}};
document_profile(_Schema, Default, _Resource, _Store) ->
    {ok, Default, undefined}.

%% Канонический dialect несёт встроенный набор keywords. Всякий другой URI
%% обязан называть зарегистрированный document: это пользовательская метасхема,
%% и активные vocabularies объявляет её `$vocabulary`. Draft самой метасхемы
%% берётся из её `$schema` тем же правилом, поэтому цепочка идёт под guard:
%% метасхема, зацикленная на себе, dialect не определяет.
-spec dialect_profile(uri(), store(), dialect(), [uri()]) ->
          {ok, profile(), uri() | undefined} | {error, reason()}.
dialect_profile(Dialect, Store, Default, Seen) ->
    case valid_json_uri:resolve(Dialect, anonymous) of
        {ok, ?DRAFT_2020_12 = Canonical, root} ->
            {ok, valid_json_vocabulary:canonical(Canonical), undefined};
        {ok, ?DRAFT_2019_09 = Canonical, root} ->
            {ok, valid_json_vocabulary:canonical(Canonical), undefined};
        {ok, ?DRAFT_07 = Canonical, root} ->
            {ok, valid_json_vocabulary:canonical(Canonical), undefined};
        {ok, ?DRAFT_06 = Canonical, root} ->
            {ok, valid_json_vocabulary:canonical(Canonical), undefined};
        {ok, Uri, root} when Uri =/= anonymous ->
            metaschema_profile(Uri, Store, Default, Seen);
        _ ->
            {error, {unknown_dialect, Dialect}}
    end.

%% На этой фазе сама метасхема не компилируется: из неё читается один
%% `$vocabulary`. Поэтому в основное замыкание она не попадает и её собственные
%% `$ref` здесь не разрешаются — отдельный schema-check pass скомпилирует её с
%% локальным cache и добавит транзитивные документы в `sources`.
-spec metaschema_profile(uri(), store(), dialect(), [uri()]) ->
          {ok, profile(), uri() | undefined} | {error, reason()}.
metaschema_profile(Uri, Store, Default, Seen) ->
    case lists:member(Uri, Seen) of
        true ->
            {error, {unknown_dialect, Uri}};
        false ->
            case valid_json_store:fetch(Uri, Store) of
                undefined ->
                    {error, {unknown_dialect, Uri}};
                #document{} = Metaschema ->
                    metaschema_vocabularies(Uri, Metaschema, Store, Default,
                                            [Uri | Seen])
            end
    end.

-spec metaschema_vocabularies(uri(), #document{}, store(), dialect(), [uri()]) ->
          {ok, profile(), uri() | undefined} | {error, reason()}.
metaschema_vocabularies(Uri, #document{json = Json} = Metaschema, Store, Default,
                        Seen) ->
    case metaschema_draft(Json, Store, Default, Seen) of
        {ok, Draft} ->
            case valid_json_vocabulary:declared(Uri, Json, Draft) of
                {ok, Profile} -> {ok, Profile, source_name(Metaschema, Store)};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

%% Draft метасхемы решает, какие URI vocabularies существуют. Метасхема без
%% `$schema` подчиняется тому же правилу, что и обычный document: её draft
%% берётся из dialect компиляции по умолчанию.
-spec metaschema_draft(json(), store(), dialect(), [uri()]) ->
          {ok, dialect()} | {error, reason()}.
metaschema_draft(#{<<"$schema">> := Dialect}, Store, Default, Seen)
  when is_binary(Dialect) ->
    case dialect_profile(Dialect, Store, Default, Seen) of
        {ok, #profile{draft = Draft}, _Metaschema} -> {ok, Draft};
        {error, _} = Error                         -> Error
    end;
metaschema_draft(#{<<"$schema">> := Other}, _Store, _Default, _Seen) ->
    {error, {bad_keyword_value, Other}};
metaschema_draft(_Json, _Store, Default, _Seen) ->
    {ok, Default}.

%% Встроенные метасхемы в `sources` не входят: они не меняются никогда.
-spec source_name(#document{}, store()) -> uri() | undefined.
source_name(#document{canonical = Canonical} = Document, Store) ->
    case registered_document(Document, Store) of
        true  -> Canonical;
        false -> undefined
    end.

-spec document_root(json(), rid()) -> rid().
document_root(#{<<"$id">> := Id}, Retrieval) when is_binary(Id) ->
    case valid_json_uri:resolve(Id, Retrieval) of
        {ok, Root, root} when Root =/= anonymous -> Root;
        _ -> Retrieval
    end;
document_root(_Schema, Retrieval) ->
    Retrieval.

-spec keyword_location(rid(), binary()) -> addr().
keyword_location(Rid, Keyword) ->
    {Rid, valid_json_location:pointer([Keyword])}.

%% Resource URI не может одновременно принадлежать inline/embedded resource и
%% другому document store. Корень текущего registered document — единственное
%% допустимое совпадение.
-spec owned_resources(valid_json_resource_index:index(), uri() | undefined,
                      store()) -> ok | {error, #schema_error{}}.
owned_resources(Index, Owner, Store) ->
    owned_resource_names(lists:sort(maps:keys(
                                      valid_json_resource_index:resources(Index))),
                         Index, Owner, Store).

-spec owned_resource_names([rid()], valid_json_resource_index:index(),
                           uri() | undefined, store()) ->
          ok | {error, #schema_error{}}.
owned_resource_names([], _Index, _Owner, _Store) ->
    ok;
owned_resource_names([anonymous | Rest], Index, Owner, Store) ->
    owned_resource_names(Rest, Index, Owner, Store);
owned_resource_names([Rid | Rest], Index, Owner, Store) ->
    case valid_json_store:fetch(Rid, Store) of
        undefined ->
            owned_resource_names(Rest, Index, Owner, Store);
        #document{canonical = Owner} when Owner =/= undefined ->
            owned_resource_names(Rest, Index, Owner, Store);
        #document{} ->
            {error, #schema_error{reason = {name_taken, Rid},
                                  location =
                                      valid_json_resource_index:declaration(Rid,
                                                                            Index)}}
    end.

-spec merge_index(valid_json_resource_index:index() | undefined,
                  valid_json_resource_index:index()) ->
          {ok, valid_json_resource_index:index()} | {error, #schema_error{}}.
merge_index(undefined, Index) ->
    {ok, Index};
merge_index(Index, DocumentIndex) ->
    valid_json_resource_index:merge(Index, DocumentIndex).

%% Неизвестная base URI сначала пробуется как document name. Промах не является
%% немедленной ошибкой: более поздний достижимый document может объявить эту URI
%% embedded `$id`; окончательную классификацию делает emission общего индекса.
-spec referenced_documents(valid_json_resource_index:index(),
                           valid_json_resource_index:index(), store()) ->
          [{document, #document{}}].
referenced_documents(DocumentIndex, Index, Store) ->
    Found = lists:foldl(
              fun({Rid, Reference}, Acc) ->
                      referenced_document(Rid, Reference, Index, Store, Acc)
              end,
              #{}, references(DocumentIndex)),
    [{document, maps:get(Canonical, Found)} ||
        Canonical <- lists:sort(maps:keys(Found))].

-spec referenced_document(rid(), json(), valid_json_resource_index:index(),
                          store(), #{uri() => #document{}}) ->
          #{uri() => #document{}}.
referenced_document(_Rid, Reference, _Index, _Store, Found)
  when not is_binary(Reference) ->
    Found;
referenced_document(Rid, Reference, Index, Store, Found) ->
    case valid_json_uri:resolve(Reference, Rid) of
        {ok, Base, _Target} ->
            case valid_json_resource_index:known(Base, Index) of
                true ->
                    Found;
                false ->
                    case valid_json_store:fetch(Base, Store) of
                        #document{canonical = Canonical} = Document ->
                            Found#{Canonical => Document};
                        undefined ->
                            Found
                    end
            end;
        {error, _Reason} ->
            Found
    end.

-spec references(valid_json_resource_index:index()) -> [{rid(), json()}].
references(Index) ->
    Resources = valid_json_resource_index:resources(Index),
    lists:append(
      [resource_references(Rid, maps:get(Rid, Resources)) ||
          Rid <- lists:sort(maps:keys(Resources))]).

-spec resource_references(rid(), #{pointer() => json()}) -> [{rid(), json()}].
resource_references(Rid, Schemas) ->
    [{Rid, maps:get(<<"$ref">>, Schema)} ||
        Pointer <- lists:sort(maps:keys(Schemas)),
        Schema <- [maps:get(Pointer, Schemas)],
        is_map(Schema), maps:is_key(<<"$ref">>, Schema)].
