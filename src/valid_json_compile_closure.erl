%% Построение транзитивного замыкания schema documents. Модуль читает store,
%% объединяет эфемерные resource indexes и возвращает только Index + Sources;
%% constraint IR здесь не создаётся.
-module(valid_json_compile_closure).

-include("valid_json_core.hrl").
-include("valid_json_resources.hrl").

-export([inline/3, document/3, supported_dialect/1]).

-type result() :: {ok, valid_json_resource_index:index(), [uri()]}
                | {error, #schema_error{}}.

-spec inline(store(), json(), dialect()) -> result().
inline(#store{} = Store, Schema, DefaultDialect) ->
    close_documents(Store, [{inline, Schema}], DefaultDialect,
                    undefined, #{}, []).

-spec document(store(), #document{}, dialect()) -> result().
document(#store{} = Store, #document{} = Document, DefaultDialect) ->
    close_documents(Store, [{document, Document}], DefaultDialect,
                    undefined, #{}, []).

-spec supported_dialect(uri()) ->
          {ok, dialect()} | {error, #schema_error{}}.
supported_dialect(Dialect) ->
    case valid_json_uri:resolve(Dialect, anonymous) of
        {ok, ?DRAFT_2020_12 = Normalized, root} ->
            {ok, Normalized};
        {ok, ?DRAFT_2019_09 = Normalized, root} ->
            {ok, Normalized};
        _ ->
            {error, #schema_error{reason = {unknown_dialect, Dialect},
                                  location = undefined}}
    end.

%% Queue содержит только полные JSON documents. Каждый новый document сначала
%% проходит discovery, затем его index присоединяется к общему. Ссылки сканируем
%% по признанным schema positions; неизвестные keyword values сюда не попадают.
-spec close_documents(store(), [{inline, json()} | {document, #document{}}],
                      dialect(), valid_json_resource_index:index() | undefined,
                      #{term() => true}, [uri()]) ->
          {ok, valid_json_resource_index:index(), [uri()]}
        | {error, #schema_error{}}.
close_documents(_Store, [], _DefaultDialect, Index, _Loaded, Sources) ->
    {ok, Index, lists:sort(Sources)};
close_documents(Store, [Entry | Rest], DefaultDialect, Index0, Loaded, Sources0) ->
    {Key, Retrieval, Schema, Owner, Source} = document_parts(Entry, Store),
    case maps:is_key(Key, Loaded) of
        true ->
            close_documents(Store, Rest, DefaultDialect, Index0, Loaded, Sources0);
        false ->
            DialectBase = document_root(Schema, Retrieval),
            case document_dialect(Schema, DefaultDialect, DialectBase) of
                {ok, Dialect} ->
                    case valid_json_resource_index:discover(Schema, Retrieval, Dialect) of
                        {ok, DocumentIndex} ->
                            case owned_resources(DocumentIndex, Owner, Store) of
                                ok ->
                                    case merge_index(Index0, DocumentIndex) of
                                        {ok, Index} ->
                                            Pending = referenced_documents(DocumentIndex,
                                                                           Index, Store),
                                            Sources = add_source(Source, Sources0),
                                            close_documents(
                                              Store, Rest ++ Pending, DefaultDialect,
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
document_parts({document, #document{retrieval = Retrieval,
                                    canonical = Canonical,
                                    json = Schema} = Document}, Store) ->
    Source = case registered_document(Document, Store) of
                 true  -> Canonical;
                 false -> undefined
             end,
    {{document, Canonical}, Retrieval, Schema, Canonical, Source}.

-spec registered_document(#document{}, store()) -> boolean().
registered_document(#document{retrieval = Retrieval, canonical = Canonical} = Document,
                    #store{documents = Documents}) ->
    maps:get(Retrieval, Documents, undefined) =:= Document orelse
    maps:get(Canonical, Documents, undefined) =:= Document.

-spec add_source(uri() | undefined, [uri()]) -> [uri()].
add_source(undefined, Sources) ->
    Sources;
add_source(Source, Sources) ->
    ordsets:add_element(Source, Sources).

-spec document_dialect(json(), dialect(), rid()) ->
          {ok, dialect()} | {error, #schema_error{}}.
document_dialect(#{<<"$schema">> := Dialect}, _DefaultDialect, Resource)
  when is_binary(Dialect) ->
    case supported_dialect(Dialect) of
        {ok, _} = Supported -> Supported;
        {error, #schema_error{reason = Reason}} ->
            {error, #schema_error{reason = Reason,
                                  location = keyword_location(Resource,
                                                              <<"$schema">>)}}
    end;
document_dialect(#{<<"$schema">> := Other}, _DefaultDialect, Resource) ->
    {error, #schema_error{reason = {bad_keyword_value, Other},
                          location = keyword_location(Resource, <<"$schema">>)}};
document_dialect(_Schema, DefaultDialect, _Resource) ->
    {ok, DefaultDialect}.

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
