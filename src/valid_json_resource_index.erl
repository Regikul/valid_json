%% Первая фаза resource compiler: выделение schema resources и построение
%% эфемерного индекса физических locations. Constraint IR здесь не строится;
%% каждый найденный schema node сохраняется исходным JSON под каноническим
%% addr(), чтобы следующая фаза могла скомпилировать его без повторного решения
%% границ `$id`.
-module(valid_json_resource_index).

-include("valid_json_resources.hrl").

-export([discover/4, root/1, resources/1, anchors/1, dynamic_anchors/1,
         recursive_anchors/1,
         dialects/1, profiles/1, metaschemas/1, declaration/2,
         merge/2, known/2, resolve/3, resolve_reference/3,
         check_references/1]).
-export_type([index/0, resource_schemas/0, resource_anchors/0, resolver/0]).

-type resource_schemas() :: #{rid() => #{pointer() => json()}}.
-type resource_anchors() :: #{rid() => #{binary() => pointer()}}.
-type resource_recursive_anchors() :: #{rid() => boolean()}.
-type resource_dialects() :: #{rid() => dialect()}.
-type resource_profiles() :: #{rid() => profile()}.
-type declarations() :: #{rid() => addr()}.
-type location_key() :: {rid(), pointer()}.
-type locations() :: #{location_key() => addr()}.

%% Написанный в `$schema` dialect превращает в профиль вызывающий: реестр
%% пользовательских метасхем принадлежит ему, а индекс о store не знает. Вторым
%% элементом успеха идёт каноническое имя прочитанной пользовательской
%% метасхемы либо `undefined` у канонического dialect.
-type resolver() :: fun((uri()) ->
                           {ok, profile(), uri() | undefined} | {error, reason()}).

%% Индекс является промежуточным значением compiler и не входит в compiled().
-opaque index() :: #{root := rid(),
                     resources := resource_schemas(),
                     anchors := resource_anchors(),
                     dynamic_anchors := resource_anchors(),
                     recursive_anchors := resource_recursive_anchors(),
                     profiles := resource_profiles(),
                     metaschemas := [uri()],
                     declarations := declarations(),
                     locations := locations()}.

-record(state, {
    resolve   :: resolver(),
    profiles = #{} :: resource_profiles(),
    metaschemas = [] :: [uri()],
    resources = #{} :: resource_schemas(),
    anchors = #{} :: resource_anchors(),
    dynamic_anchors = #{} :: resource_anchors(),
    recursive_anchors = #{} :: resource_recursive_anchors(),
    locations = #{} :: locations(),
    declarations = #{} :: declarations(),
    %% Все URI, уже занятые resource либо retrieval alias. `anonymous` сюда не
    %% входит: это локальная метка, а не глобальное имя.
    names = #{} :: #{uri() => true}
}).

-type state() :: #state{}.
-type location() :: [binary()].
-type context() :: {rid(), location()}.
-type child() :: {[binary()], json()}.

%% Retrieval задаёт физическое имя документа. Для inline schema это
%% `anonymous`; корневой `$id` при наличии становится canonical root. Profile
%% принадлежит корню документа: его `$schema` прочитан вызывающим до вызова.
%% Resolve нужен встроенным resources, которые меняют dialect собственным
%% `$schema` уже во время обхода.
-spec discover(json(), rid(), profile(), resolver()) ->
          {ok, index()} | {error, #schema_error{}}.
discover(Schema, Retrieval0, #profile{} = Profile, Resolve)
  when (Retrieval0 =:= anonymous orelse is_binary(Retrieval0)),
       is_function(Resolve, 1) ->
    case normalize_retrieval(Retrieval0) of
        {ok, Retrieval} ->
            case root_id(Schema, Retrieval) of
                {ok, Root} ->
                    discover_root(Schema, Retrieval, Root, Profile, Resolve);
                {error, Reason} ->
                    {error, schema_error(Reason,
                                         keyword_addr(Retrieval, [], <<"$id">>))}
            end;
        {error, Reason} ->
            {error, #schema_error{reason = Reason, location = undefined}}
    end;
discover(Schema, Retrieval, Profile, Resolve) ->
    erlang:error(badarg, [Schema, Retrieval, Profile, Resolve]).

-spec root(index()) -> rid().
root(#{root := Root}) ->
    Root.

%% Исходные schemas сгруппированы уже по каноническим resources. Возвращаемая
%% map immutable; location aliases намеренно этим API не раскрываются.
-spec resources(index()) -> resource_schemas().
resources(#{resources := Resources}) ->
    Resources.

%% Static anchors входят в compiled(), но индексируются одновременно со schema
%% positions: `$ref` может стоять раньше объявления цели. Pointer уже
%% каноничен относительно resource, location aliases сюда не просачиваются.
-spec anchors(index()) -> resource_anchors().
anchors(#{anchors := Anchors}) ->
    Anchors.

%% Dynamic anchors живут отдельной картой, потому что читает её только
%% `$dynamicRef`. Имя, объявленное через `$dynamicAnchor`, попадает и сюда, и в
%% обычный anchor index: plain-name fragment он создаёт наравне с `$anchor`.
-spec dynamic_anchors(index()) -> resource_anchors().
dynamic_anchors(#{dynamic_anchors := Anchors}) ->
    Anchors.

%% Recursive anchor — boolean-флаг корня resource, а не именованный fragment.
%% Карта всё равно строится в index phase: здесь уже известны границы `$id`, и
%% emitter не должен повторно решать, является ли schema корнем resource.
-spec recursive_anchors(index()) -> resource_recursive_anchors().
recursive_anchors(#{recursive_anchors := Anchors}) ->
    Anchors.

%% Dialect выбирается на каждом resource: встроенный resource наследует его от
%% объемлющего либо меняет собственным `$schema`. В compiled() dialect так же
%% хранится на каждом resource.
-spec dialects(index()) -> resource_dialects().
dialects(#{profiles := Profiles}) ->
    maps:map(fun(_Rid, #profile{uri = Uri}) -> Uri end, Profiles).

%% Профиль нужен emitter'у: он решает, какие keywords активны. В compiled() из
%% него доходит только dialect URI.
-spec profiles(index()) -> resource_profiles().
profiles(#{profiles := Profiles}) ->
    Profiles.

%% Пользовательские метасхемы, прочитанные встроенными resources. Вызывающий
%% обязан добавить их в `sources`: их `$vocabulary` влияет на артефакт и должно
%% инвалидировать его при изменении.
-spec metaschemas(index()) -> [uri()].
metaschemas(#{metaschemas := Metaschemas}) ->
    Metaschemas.

%% Локация `$id`, объявившего resource, нужна только compile errors при
%% объединении documents или сверке со store. У resource без написанного `$id`
%% declaration совпадает с его корнем.
-spec declaration(rid(), index()) -> addr().
declaration(Rid, #{declarations := Declarations}) ->
    maps:get(Rid, Declarations).

%% Document indexes объединяются до emission `$ref`. Один URI не может
%% обозначать два разных resources или два разных физических location alias:
%% такой compound graph был бы неоднозначен независимо от порядка загрузки.
-spec merge(index(), index()) -> {ok, index()} | {error, #schema_error{}}.
merge(#{root := Root,
        resources := LeftResources,
        anchors := LeftAnchors,
        dynamic_anchors := LeftDynamic,
        recursive_anchors := LeftRecursive,
        profiles := LeftProfiles,
        metaschemas := LeftMetaschemas,
        declarations := LeftDeclarations,
        locations := LeftLocations},
      #{resources := RightResources,
        anchors := RightAnchors,
        dynamic_anchors := RightDynamic,
        recursive_anchors := RightRecursive,
        profiles := RightProfiles,
        metaschemas := RightMetaschemas,
        declarations := RightDeclarations,
        locations := RightLocations}) ->
    case duplicate_resource(LeftResources, RightResources, RightDeclarations) of
        {error, _} = Error ->
            Error;
        ok ->
            case location_conflict(LeftLocations, RightLocations) of
                {error, _} = Error ->
                    Error;
                ok ->
                    {ok, #{root => Root,
                           resources => maps:merge(LeftResources, RightResources),
                           anchors => maps:merge(LeftAnchors, RightAnchors),
                           dynamic_anchors => maps:merge(LeftDynamic, RightDynamic),
                           recursive_anchors => maps:merge(LeftRecursive,
                                                           RightRecursive),
                           profiles => maps:merge(LeftProfiles, RightProfiles),
                           metaschemas => ordsets:union(LeftMetaschemas,
                                                        RightMetaschemas),
                           declarations => maps:merge(LeftDeclarations,
                                                      RightDeclarations),
                           locations => maps:merge(LeftLocations, RightLocations)}}
            end
    end.

%% Проверяет только наличие document/resource base. Fragment здесь намеренно
%% не участвует: отсутствующий target известного resource — dangling/anchor
%% error, а не повод загружать другой document из store.
-spec known(rid(), index()) -> boolean().
known(Base, #{locations := Locations}) ->
    find_location(Base, <<>>, Locations) =/= error.

%% URI-слой отделяет base от fragment. Здесь pointer ищется по физическому
%% location index и сразу превращается в canonical addr(). Plain-name fragment
%% сначала выбирает canonical resource через его root alias, затем ищет anchor.
-spec resolve(rid(), valid_json_uri:target(), index()) -> {ok, addr()} | error.
resolve(Base, root, #{locations := Locations}) ->
    find_location(Base, <<>>, Locations);
resolve(Base, {pointer, Segments}, #{locations := Locations}) ->
    find_location(Base, valid_json_location:pointer(Segments), Locations);
resolve(Base, {anchor, Name},
        #{anchors := Anchors, locations := Locations}) ->
    case find_location(Base, <<>>, Locations) of
        {ok, {Rid, <<>>}} ->
            case maps:get(Rid, Anchors, #{}) of
                #{Name := Pointer} -> {ok, {Rid, Pointer}};
                #{}                -> error
            end;
        error ->
            error
    end.

%% Compiler-facing resolution keeps the successful path canonical and assigns
%% precise compile errors to misses. Pointer to an existing non-schema JSON
%% value is distinct from a pointer that does not exist at all.
-spec resolve_reference(rid(), valid_json_uri:target(), index()) ->
          {ok, addr()} | {error, reason()}.
resolve_reference(Base, Target, Index) ->
    case resolve(Base, Target, Index) of
        {ok, _} = Resolved -> Resolved;
        error              -> reference_error(Base, Target, Index)
    end.

%% Отдельный resolution pass сохраняет порядок фаз compiler: URI и targets
%% проверяются до meta-schema validation, а emitter затем только повторяет
%% тотальный lookup при построении IR. Форму нестроковых значений оставляем
%% метасхеме — compiler отвечает здесь именно за URI/reference semantics.
-spec check_references(index()) -> ok | {error, #schema_error{}}.
check_references(#{root := Root, resources := Resources,
                   profiles := Profiles} = Index) ->
    Rids = [Root | lists:sort(maps:keys(Resources) -- [Root])],
    check_resource_references(Rids, Resources, Profiles, Index).

-spec check_resource_references([rid()], resource_schemas(), resource_profiles(),
                                index()) ->
          ok | {error, #schema_error{}}.
check_resource_references([], _Resources, _Profiles, _Index) ->
    ok;
check_resource_references([Rid | Rest], Resources, Profiles, Index) ->
    Schemas = maps:get(Rid, Resources),
    Profile = maps:get(Rid, Profiles),
    case check_schema_references(Rid, lists:sort(maps:keys(Schemas)), Schemas,
                                 Profile, Index) of
        ok -> check_resource_references(Rest, Resources, Profiles, Index);
        {error, _} = Error -> Error
    end.

-spec check_schema_references(rid(), [pointer()], #{pointer() => json()},
                              profile(), index()) ->
          ok | {error, #schema_error{}}.
check_schema_references(_Rid, [], _Schemas, _Profile, _Index) ->
    ok;
check_schema_references(Rid, [Pointer | Rest], Schemas, Profile, Index) ->
    Schema = maps:get(Pointer, Schemas),
    case check_schema_reference_keywords(Rid, Pointer, Schema, Profile, Index) of
        ok -> check_schema_references(Rid, Rest, Schemas, Profile, Index);
        {error, _} = Error -> Error
    end.

-spec check_schema_reference_keywords(rid(), pointer(), json(), profile(), index()) ->
          ok | {error, #schema_error{}}.
check_schema_reference_keywords(_Rid, _Pointer, Schema, _Profile, _Index)
  when not is_map(Schema) ->
    ok;
check_schema_reference_keywords(Rid, Pointer, Schema, Profile, Index) ->
    Keywords = [Keyword || Keyword <- [<<"$ref">>, <<"$dynamicRef">>,
                                        <<"$recursiveRef">>],
                           valid_json_vocabulary:active(Keyword, Profile)],
    check_reference_keywords(Keywords, Rid, Pointer, Schema, Index).

-spec check_reference_keywords([binary()], rid(), pointer(),
                               #{binary() => json()}, index()) ->
          ok | {error, #schema_error{}}.
check_reference_keywords([], _Rid, _Pointer, _Schema, _Index) ->
    ok;
check_reference_keywords([Keyword | Rest], Rid, Pointer, Schema, Index) ->
    case maps:find(Keyword, Schema) of
        error ->
            check_reference_keywords(Rest, Rid, Pointer, Schema, Index);
        {ok, Value} when is_binary(Value) ->
            case check_reference_value(Keyword, Value, Rid, Pointer, Index) of
                ok -> check_reference_keywords(Rest, Rid, Pointer, Schema, Index);
                {error, _} = Error -> Error
            end;
        {ok, _Other} ->
            %% `type: string` соответствующей метасхемы выпустит schema_invalid
            %% с output выбранного вызывающим режима.
            check_reference_keywords(Rest, Rid, Pointer, Schema, Index)
    end.

-spec check_reference_value(binary(), binary(), rid(), pointer(), index()) ->
          ok | {error, #schema_error{}}.
check_reference_value(<<"$recursiveRef">> = Keyword, Value, Rid, Pointer, _Index)
  when Value =/= <<"#">> ->
    {error, reference_schema_error({bad_keyword_value, Value}, Rid, Pointer,
                                   Keyword)};
check_reference_value(Keyword, Value, Rid, Pointer, Index) ->
    case valid_json_uri:resolve(Value, Rid) of
        {ok, Base, Target} ->
            case resolve_reference(Base, Target, Index) of
                {ok, _Addr} -> ok;
                {error, Reason} ->
                    {error, reference_schema_error(Reason, Rid, Pointer, Keyword)}
            end;
        {error, Reason} ->
            {error, reference_schema_error(Reason, Rid, Pointer, Keyword)}
    end.

-spec reference_schema_error(reason(), rid(), pointer(), binary()) ->
          #schema_error{}.
reference_schema_error(Reason, Rid, Pointer, Keyword) ->
    Segments = valid_json_location:segments(Pointer),
    Location = valid_json_location:pointer([Keyword | Segments]),
    #schema_error{reason = Reason, location = {Rid, Location}}.

-spec normalize_retrieval(rid()) -> {ok, rid()} | {error, reason()}.
normalize_retrieval(anonymous) ->
    {ok, anonymous};
normalize_retrieval(Retrieval) ->
    case valid_json_uri:resolve(Retrieval, anonymous) of
        {ok, Normalized, root} when Normalized =/= anonymous -> {ok, Normalized};
        {ok, _Normalized, _Fragment}                         -> {error, invalid_uri};
        {error, Reason}                                      -> {error, Reason}
    end.

%% Корень без `$id` получает retrieval URI; только inline schema без `$id`
%% остаётся anonymous. Fragment в `$id` запрещён тем же правилом, что в store.
-spec root_id(json(), rid()) -> {ok, rid()} | {error, reason()}.
root_id(#{<<"$id">> := Id}, Retrieval) ->
    resolve_id(Id, Retrieval);
root_id(_Schema, Retrieval) ->
    {ok, Retrieval}.

-spec root_declaration(json(), rid(), rid()) -> addr().
root_declaration(#{<<"$id">> := _Id}, Retrieval, _Root) ->
    keyword_addr(Retrieval, [], <<"$id">>);
root_declaration(_Schema, _Retrieval, Root) ->
    {Root, <<>>}.

-spec discover_root(json(), rid(), rid(), profile(), resolver()) ->
          {ok, index()} | {error, #schema_error{}}.
discover_root(Schema, Retrieval, Root, Profile, Resolve) ->
    Contexts = root_contexts(Root, Retrieval),
    Names = reserve_names([Base || {Base, []} <- Contexts]),
    State0 = #state{resolve = Resolve,
                    profiles = #{Root => Profile},
                    resources = #{Root => #{}},
                    anchors = #{Root => #{}},
                    dynamic_anchors = #{Root => #{}},
                    recursive_anchors = #{Root => false},
                    declarations = #{Root => root_declaration(Schema, Retrieval,
                                                              Root)},
                    names = Names},
    case walk(Schema, Root, [], Contexts, root, Profile, State0) of
        {ok, #state{resources = Resources, anchors = Anchors,
                    dynamic_anchors = DynamicAnchors,
                    recursive_anchors = RecursiveAnchors,
                    profiles = Profiles, metaschemas = Metaschemas,
                    locations = Locations, declarations = Declarations}} ->
            {ok, #{root => Root,
                   resources => Resources,
                   anchors => Anchors,
                   dynamic_anchors => DynamicAnchors,
                   recursive_anchors => RecursiveAnchors,
                   profiles => Profiles,
                   metaschemas => Metaschemas,
                   declarations => Declarations,
                   locations => Locations}};
        {error, _} = Error ->
            Error
    end.

%% Root `$id` уже обработан до начала обхода. На остальных map-nodes `$id`
%% сначала меняет resource boundary, затем node укладывается по новому адресу.
%% Профиль идёт параметром, а не полем состояния: встроенный resource меняет его
%% только для собственного поддерева, и соседние ветки обязаны остаться при
%% профиле объемлющего.
-spec walk(json(), rid(), location(), [context()], root | child, profile(),
           state()) ->
          {ok, state()} | {error, #schema_error{}}.
walk(Schema, Rid, Location, Contexts, RootOrChild, Profile, State)
  when is_boolean(Schema); is_map(Schema) ->
    case enter_resource(Schema, Rid, Location, Contexts, RootOrChild, Profile,
                        State) of
        {ok, NodeRid, NodeLocation, NodeContexts, NodeProfile, Entered} ->
            Addr = addr(NodeRid, NodeLocation),
            case place(Schema, Addr, NodeContexts, NodeProfile, Entered) of
                {ok, Placed} when is_map(Schema) ->
                    walk_children(children(Schema, NodeProfile),
                                  NodeRid, NodeLocation, NodeContexts,
                                  NodeProfile, Placed);
                {ok, Placed} ->
                    {ok, Placed};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end;
walk(Other, Rid, Location, Contexts, _RootOrChild, Profile, State) ->
    %% Некорректная schema position остаётся в сыром index, чтобы единственным
    %% источником синтаксической ошибки стала метасхема. Emitter всё равно имеет
    %% страховочную totality-ветвь на случай прямого внутреннего вызова.
    place(Other, addr(Rid, Location), Contexts, Profile, State).

-spec enter_resource(json(), rid(), location(), [context()], root | child,
                     profile(), state()) ->
          {ok, rid(), location(), [context()], profile(), state()} |
          {error, #schema_error{}}.
enter_resource(_Schema, Rid, Location, Contexts, root, Profile, State) ->
    {ok, Rid, Location, Contexts, Profile, State};
enter_resource(#{<<"$id">> := Id} = Schema, Rid, Location, Contexts, child,
               Profile, State) ->
    IdLocation = keyword_addr(Rid, Location, <<"$id">>),
    case resolve_id(Id, Rid) of
        {ok, NewRid} ->
            case resource_profile(Schema, NewRid, Profile, State) of
                {ok, NewProfile, Resolved} ->
                    case reserve_resource(NewRid, IdLocation, NewProfile,
                                          Resolved) of
                        {ok, Reserved} ->
                            {ok, NewRid, [], [{NewRid, []} | Contexts],
                             NewProfile, Reserved};
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end;
        {error, Reason} ->
            {error, schema_error(Reason, IdLocation)}
    end;
%% `$schema` разрешён только в корне schema resource; в остальных подсхемах он
%% запрещён обоими dialects (core.txt:1377 в 2020-12, core.txt:1320 в 2019-09).
%% Молча игнорировать его нельзя: автор написал бы смену dialect и получил бы
%% dialect объемлющего.
enter_resource(#{<<"$schema">> := _} = Schema, Rid, Location, _Contexts, child,
               _Profile, _State) when not is_map_key(<<"$id">>, Schema) ->
    {error, schema_error({misplaced_keyword, <<"$schema">>},
                         keyword_addr(Rid, Location, <<"$schema">>))};
enter_resource(_Schema, Rid, Location, Contexts, child, Profile, State) ->
    {ok, Rid, Location, Contexts, Profile, State}.

%% Встроенный resource без `$schema` наследует dialect объемлющего
%% (core.txt:2122), со своим — меняет его. Прочитанная здесь пользовательская
%% метасхема запоминается: она обязана попасть в `sources` артефакта.
-spec resource_profile(json(), rid(), profile(), state()) ->
          {ok, profile(), state()} | {error, #schema_error{}}.
resource_profile(#{<<"$schema">> := Dialect}, Rid, _Outer,
                 #state{resolve = Resolve} = State) when is_binary(Dialect) ->
    case Resolve(Dialect) of
        {ok, Profile, Metaschema} ->
            {ok, Profile, add_metaschema(Metaschema, State)};
        {error, Reason} ->
            {error, schema_error(Reason, keyword_addr(Rid, [], <<"$schema">>))}
    end;
resource_profile(#{<<"$schema">> := Other}, Rid, _Outer, _State) ->
    {error, schema_error({bad_keyword_value, Other},
                         keyword_addr(Rid, [], <<"$schema">>))};
resource_profile(_Schema, _Rid, Outer, State) ->
    {ok, Outer, State}.

-spec add_metaschema(uri() | undefined, state()) -> state().
add_metaschema(undefined, State) ->
    State;
add_metaschema(Uri, #state{metaschemas = Metaschemas} = State) ->
    State#state{metaschemas = ordsets:add_element(Uri, Metaschemas)}.

-spec resolve_id(json(), rid()) -> {ok, rid()} | {error, reason()}.
resolve_id(Id, Base) when is_binary(Id) ->
    case valid_json_uri:resolve(Id, Base) of
        {ok, Rid, root} when Rid =/= anonymous -> {ok, Rid};
        {ok, _Rid, _Fragment}                 -> {error, {bad_keyword_value, Id}};
        {error, Reason}                       -> {error, Reason}
    end;
resolve_id(Id, _Base) ->
    {error, {bad_keyword_value, Id}}.

-spec reserve_resource(uri(), addr(), profile(), state()) ->
          {ok, state()} | {error, #schema_error{}}.
reserve_resource(Rid, Location, Profile,
                 #state{resources = Resources, anchors = Anchors,
                        dynamic_anchors = DynamicAnchors,
                        recursive_anchors = RecursiveAnchors,
                        profiles = Profiles,
                        declarations = Declarations, names = Names} = State) ->
    case maps:is_key(Rid, Names) of
        true ->
            {error, schema_error({name_taken, Rid}, Location)};
        false ->
            {ok, State#state{resources = Resources#{Rid => #{}},
                             anchors = Anchors#{Rid => #{}},
                             dynamic_anchors = DynamicAnchors#{Rid => #{}},
                             recursive_anchors = RecursiveAnchors#{Rid => false},
                             profiles = Profiles#{Rid => Profile},
                             declarations = Declarations#{Rid => Location},
                             names = Names#{Rid => true}}}
    end.

-spec place(json(), addr(), [context()], profile(), state()) ->
          {ok, state()} | {error, #schema_error{}}.
place(Schema, {Rid, Pointer} = Addr, Contexts, Profile,
      #state{resources = Resources} = State) ->
    Nodes = maps:get(Rid, Resources),
    WithNode = State#state{resources = Resources#{Rid => Nodes#{Pointer => Schema}}},
    case index_contexts(Contexts, Addr, WithNode) of
        {ok, Indexed} when is_map(Schema) ->
            index_anchors(Schema, Addr, Profile, Indexed);
        {ok, Indexed} ->
            {ok, Indexed};
        {error, _} = Error ->
            Error
    end.

%% Duplicate names inside one resource have undefined behavior in the drafts;
%% the compiler deliberately does not invent a schema error for them. The walk
%% is deterministic, so the last discovered declaration wins internally.
-spec index_anchors(#{binary() => json()}, addr(), profile(), state()) ->
          {ok, state()} | {error, #schema_error{}}.
index_anchors(Schema, Addr, Profile, State) ->
    case anchor_name(<<"$anchor">>, Schema, Addr, Profile) of
        {ok, none} ->
            index_special_anchors(Schema, Addr, Profile, State);
        {ok, Name} ->
            index_special_anchors(Schema, Addr, Profile,
                                  put_anchor(Name, Addr, State));
        {error, _} = Error ->
            Error
    end.

-spec index_special_anchors(#{binary() => json()}, addr(), profile(), state()) ->
          {ok, state()} | {error, #schema_error{}}.
index_special_anchors(Schema, Addr, Profile, State) ->
    case index_dynamic_anchor(Schema, Addr, Profile, State) of
        {ok, Dynamic}      -> index_recursive_anchor(Schema, Addr, Profile, Dynamic);
        {error, _} = Error -> Error
    end.

%% `$dynamicAnchor` существует только в Draft 2020-12; в Draft 2019-09 это
%% unknown keyword, который dialect игнорирует. Кроме точки расширения для
%% `$dynamicRef` он создаёт и обычный plain-name fragment наравне с `$anchor`,
%% поэтому имя попадает в обе карты.
-spec index_dynamic_anchor(#{binary() => json()}, addr(), profile(), state()) ->
          {ok, state()} | {error, #schema_error{}}.
index_dynamic_anchor(Schema, Addr, #profile{draft = ?DRAFT_2020_12} = Profile,
                     State) ->
    case anchor_name(<<"$dynamicAnchor">>, Schema, Addr, Profile) of
        {ok, none} ->
            {ok, State};
        {ok, Name} ->
            {ok, put_dynamic_anchor(Name, Addr, put_anchor(Name, Addr, State))};
        {error, _} = Error ->
            Error
    end;
index_dynamic_anchor(_Schema, _Addr, _Profile, State) ->
    {ok, State}.

%% Draft 2019-09 задаёт boolean anchor, который может влиять только из корня
%% schema resource. `$id` уже перенёс такой node в pointer <<>>, поэтому
%% некорневое объявление можно принять без эффекта, не угадывая его намерение.
%% В Draft 2020-12 это неизвестный keyword и его значение не проверяется.
-spec index_recursive_anchor(#{binary() => json()}, addr(), profile(), state()) ->
          {ok, state()} | {error, #schema_error{}}.
index_recursive_anchor(Schema, {Rid, Pointer},
                       #profile{draft = ?DRAFT_2019_09},
                       #state{recursive_anchors = Anchors} = State) ->
    case maps:find(<<"$recursiveAnchor">>, Schema) of
        error ->
            {ok, State};
        {ok, true} when Pointer =:= <<>> ->
            {ok, State#state{recursive_anchors = Anchors#{Rid => true}}};
        {ok, Value} when is_boolean(Value) ->
            {ok, State};
        {ok, Other} ->
            Location = keyword_addr(Rid, valid_json_location:segments(Pointer),
                                    <<"$recursiveAnchor">>),
            {error, schema_error({bad_keyword_value, Other}, Location)}
    end;
index_recursive_anchor(_Schema, _Addr, _Profile, State) ->
    {ok, State}.

-spec anchor_name(binary(), #{binary() => json()}, addr(), profile()) ->
          {ok, binary() | none} | {error, #schema_error{}}.
anchor_name(Keyword, Schema, {Rid, Pointer}, #profile{draft = Draft}) ->
    case maps:find(Keyword, Schema) of
        error ->
            {ok, none};
        {ok, Name} ->
            case valid_anchor(Name, anchor_dialect(Keyword, Draft)) of
                true ->
                    {ok, Name};
                false ->
                    Location = keyword_addr(
                                 Rid, valid_json_location:segments(Pointer), Keyword),
                    {error, schema_error({bad_keyword_value, Name}, Location)}
            end
    end.

%% Имя `$dynamicAnchor` пишется по правилу Draft 2020-12 всегда: в другом
%% dialect этого keyword просто нет.
-spec anchor_dialect(binary(), dialect()) -> dialect().
anchor_dialect(<<"$dynamicAnchor">>, _Dialect) -> ?DRAFT_2020_12;
anchor_dialect(<<"$anchor">>, Dialect)         -> Dialect.

-spec put_anchor(binary(), addr(), state()) -> state().
put_anchor(Name, {Rid, Pointer}, #state{anchors = Anchors} = State) ->
    Resource = maps:get(Rid, Anchors),
    State#state{anchors = Anchors#{Rid => Resource#{Name => Pointer}}}.

-spec put_dynamic_anchor(binary(), addr(), state()) -> state().
put_dynamic_anchor(Name, {Rid, Pointer},
                   #state{dynamic_anchors = Anchors} = State) ->
    Resource = maps:get(Rid, Anchors),
    State#state{dynamic_anchors = Anchors#{Rid => Resource#{Name => Pointer}}}.

-spec valid_anchor(json(), dialect()) -> boolean().
valid_anchor(Name, Dialect) when is_binary(Name) ->
    Pattern = case Dialect of
                  ?DRAFT_2019_09 -> <<"\\A[A-Za-z][-A-Za-z0-9.:_]*\\z">>;
                  _              -> <<"\\A[A-Za-z_][-A-Za-z0-9._]*\\z">>
              end,
    re:run(Name, Pattern, [{capture, none}]) =:= match;
valid_anchor(_Name, _Dialect) ->
    false.

-spec duplicate_resource(resource_schemas(), resource_schemas(), declarations()) ->
          ok | {error, #schema_error{}}.
duplicate_resource(Left, Right, RightDeclarations) ->
    duplicate_resource_names(lists:sort(maps:keys(Left)), Right,
                             RightDeclarations).

-spec duplicate_resource_names([rid()], resource_schemas(), declarations()) ->
          ok | {error, #schema_error{}}.
duplicate_resource_names([], _Right, _RightDeclarations) ->
    ok;
duplicate_resource_names([Rid | Rest], Right, RightDeclarations) ->
    case maps:is_key(Rid, Right) of
        true ->
            Location = maps:get(Rid, RightDeclarations),
            {error, #schema_error{reason = {name_taken, Rid}, location = Location}};
        false ->
            duplicate_resource_names(Rest, Right, RightDeclarations)
    end.

-spec location_conflict(locations(), locations()) ->
          ok | {error, #schema_error{}}.
location_conflict(Left, Right) ->
    location_conflict(lists:sort(maps:keys(Right)), Left, Right).

-spec location_conflict([location_key()], locations(), locations()) ->
          ok | {error, #schema_error{}}.
location_conflict([], _Left, _Right) ->
    ok;
location_conflict([{Base, _Pointer} = Key | Rest], Left, Right) ->
    RightAddr = maps:get(Key, Right),
    case maps:get(Key, Left, undefined) of
        undefined ->
            location_conflict(Rest, Left, Right);
        RightAddr ->
            location_conflict(Rest, Left, Right);
        _OtherAddr ->
            {error, #schema_error{reason = {name_taken, Base},
                                  location = RightAddr}}
    end.

-spec reference_error(rid(), valid_json_uri:target(), index()) ->
          {error, reason()}.
reference_error(Base, Target,
                #{resources := Resources, locations := Locations}) ->
    case find_location(Base, <<>>, Locations) of
        error ->
            {error, {unknown_document, Base}};
        {ok, {Rid, <<>>}} ->
            reference_target_error(Rid, Target, maps:get(Rid, Resources))
    end.

-spec reference_target_error(rid(), valid_json_uri:target(),
                             #{pointer() => json()}) -> {error, reason()}.
reference_target_error(_Rid, {anchor, _Name}, _Schemas) ->
    {error, unresolved_anchor};
reference_target_error(Rid, root, _Schemas) ->
    %% Известный resource всегда имеет корневой schema node; сюда можно попасть
    %% только при нарушенном внутреннем индексе.
    {error, {dangling_ref, {Rid, <<>>}}};
reference_target_error(Rid, {pointer, Segments}, Schemas) ->
    Pointer = valid_json_location:pointer(Segments),
    Root = maps:get(<<>>, Schemas),
    Reason = case json_at(lists:reverse(Segments), Root) of
                 {ok, _Value} -> {non_schema_target, {Rid, Pointer}};
                 error        -> {dangling_ref, {Rid, Pointer}}
             end,
    {error, Reason}.

%% JSON Pointer lookup нужен только для классификации compile error. Успешная
%% ссылка всё равно определяется location index, а не повторным обходом JSON.
-spec json_at([binary()], json()) -> {ok, json()} | error.
json_at([], Value) ->
    {ok, Value};
json_at([Segment | Rest], Value) when is_map(Value) ->
    case maps:find(Segment, Value) of
        {ok, Child} -> json_at(Rest, Child);
        error       -> error
    end;
json_at([Segment | Rest], Value) when is_list(Value) ->
    case array_index(Segment) of
        {ok, Index} when Index < length(Value) ->
            json_at(Rest, lists:nth(Index + 1, Value));
        _ ->
            error
    end;
json_at(_Segments, _Value) ->
    error.

-spec array_index(binary()) -> {ok, non_neg_integer()} | error.
array_index(<<"0">>) ->
    {ok, 0};
array_index(<<First, _/binary>> = Segment) when First >= $1, First =< $9 ->
    try binary_to_integer(Segment) of
        Index when Index >= 0 -> {ok, Index}
    catch
        error:badarg -> error
    end;
array_index(_Segment) ->
    error.

-spec index_contexts([context()], addr(), state()) ->
          {ok, state()} | {error, #schema_error{}}.
index_contexts([], _Addr, State) ->
    {ok, State};
index_contexts([{Base, Location} | Rest], Addr,
               #state{locations = Locations} = State) ->
    Key = {Base, valid_json_location:pointer(Location)},
    case maps:get(Key, Locations, undefined) of
        undefined ->
            index_contexts(Rest, Addr,
                           State#state{locations = Locations#{Key => Addr}});
        Addr ->
            index_contexts(Rest, Addr, State);
        _OtherAddr ->
            %% Такое возможно только при повторном использовании URI как
            %% retrieval/resource name. Отказываемся вместо молчаливой смены
            %% target; обычный путь ловит конфликт раньше в reserve_resource/3.
            {error, schema_error({name_taken, Base}, Addr)}
    end.

-spec walk_children([child()], rid(), location(), [context()], profile(),
                    state()) ->
          {ok, state()} | {error, #schema_error{}}.
walk_children([], _Rid, _Location, _Contexts, _Profile, State) ->
    {ok, State};
walk_children([{Segments, Schema} | Rest], Rid, Location, Contexts, Profile,
              State) ->
    ChildLocation = push(Segments, Location),
    ChildContexts = [{Base, push(Segments, Relative)} ||
                        {Base, Relative} <- Contexts],
    case walk(Schema, Rid, ChildLocation, ChildContexts, child, Profile, State) of
        {ok, Walked} ->
            walk_children(Rest, Rid, Location, Contexts, Profile, Walked);
        {error, _} = Error ->
            Error
    end.

%% Здесь перечислены только schema positions активных keywords. Значения
%% unknown keywords, annotations, const и enum не обходятся. Контейнер неверной
%% формы оставляется emitter'у, зато элемент корректного контейнера обязан быть
%% schema и потому проходит через walk/6 даже при ошибочном типе.
%%
%% Активность решают vocabularies профиля: keyword выключенной vocabulary
%% является неизвестным, а внутрь неизвестного спускаться нельзя — иначе `$id` и
%% `$anchor` случайно написанной там схемы попали бы в индекс.
-spec children(#{binary() => json()}, profile()) -> [child()].
children(Schema, #profile{draft = Draft} = Profile) ->
    Active = maps:filter(fun(Keyword, _Value) ->
                                 valid_json_vocabulary:active(Keyword, Profile)
                         end, Schema),
    lists:append([
        named_children(<<"$defs">>, Active),
        named_children(<<"definitions">>, Active),
        named_children(<<"properties">>, Active),
        named_children(<<"patternProperties">>, Active),
        named_children(<<"dependentSchemas">>, Active),
        ordered_children(<<"allOf">>, Active),
        ordered_children(<<"anyOf">>, Active),
        ordered_children(<<"oneOf">>, Active),
        prefix_children(Active, Draft),
        items_children(Active, Draft),
        single_children([<<"additionalProperties">>, <<"propertyNames">>,
                         <<"contains">>, <<"not">>, <<"if">>, <<"then">>,
                         <<"else">>, <<"unevaluatedProperties">>,
                         <<"unevaluatedItems">>], Active),
        additional_items_children(Active, Draft)
    ]).

-spec named_children(binary(), #{binary() => json()}) -> [child()].
named_children(Keyword, Schema) ->
    case maps:get(Keyword, Schema, undefined) of
        Values when is_map(Values) ->
            [{[Keyword, Name], Child} || {Name, Child} <- lists:sort(maps:to_list(Values))];
        _Other ->
            []
    end.

-spec ordered_children(binary(), #{binary() => json()}) -> [child()].
ordered_children(Keyword, Schema) ->
    case maps:get(Keyword, Schema, undefined) of
        Values when is_list(Values) ->
            indexed(Keyword, Values, 0);
        _Other ->
            []
    end.

-spec indexed(binary(), [json()], non_neg_integer()) -> [child()].
indexed(_Keyword, [], _Index) ->
    [];
indexed(Keyword, [Child | Rest], Index) ->
    [{[Keyword, integer_to_binary(Index)], Child} |
     indexed(Keyword, Rest, Index + 1)].

-spec prefix_children(#{binary() => json()}, dialect()) -> [child()].
prefix_children(Schema, ?DRAFT_2020_12) ->
    ordered_children(<<"prefixItems">>, Schema);
prefix_children(_Schema, _Dialect) ->
    [].

-spec items_children(#{binary() => json()}, dialect()) -> [child()].
items_children(Schema, ?DRAFT_2020_12) ->
    singleton_unless_list(<<"items">>, Schema);
items_children(Schema, _Dialect) ->
    case maps:get(<<"items">>, Schema, undefined) of
        Values when is_list(Values) -> indexed(<<"items">>, Values, 0);
        _Other                     -> singleton(<<"items">>, Schema)
    end.

-spec additional_items_children(#{binary() => json()}, dialect()) -> [child()].
additional_items_children(_Schema, ?DRAFT_2020_12) ->
    [];
additional_items_children(Schema, _Dialect) ->
    singleton(<<"additionalItems">>, Schema).

-spec single_children([binary()], #{binary() => json()}) -> [child()].
single_children(Keywords, Schema) ->
    lists:append([singleton(Keyword, Schema) || Keyword <- Keywords]).

-spec singleton_unless_list(binary(), #{binary() => json()}) -> [child()].
singleton_unless_list(Keyword, Schema) ->
    case maps:find(Keyword, Schema) of
        {ok, Value} when is_list(Value) -> [];
        {ok, Value}                     -> [{[Keyword], Value}];
        error                           -> []
    end.

-spec singleton(binary(), #{binary() => json()}) -> [child()].
singleton(Keyword, Schema) ->
    case maps:find(Keyword, Schema) of
        {ok, Value} -> [{[Keyword], Value}];
        error       -> []
    end.

-spec root_contexts(rid(), rid()) -> [context()].
root_contexts(Root, Retrieval) ->
    unique_contexts([{Root, []}, {Retrieval, []}], []).

-spec unique_contexts([context()], [context()]) -> [context()].
unique_contexts([], Acc) ->
    lists:reverse(Acc);
unique_contexts([{anonymous, []} | Rest], Acc)
  when Acc =/= [] ->
    %% Inline root с абсолютным `$id` уже именован; anonymous alias ему не
    %% нужен. Для действительно anonymous root это первый и единственный entry.
    unique_contexts(Rest, Acc);
unique_contexts([Context | Rest], Acc) ->
    case lists:member(Context, Acc) of
        true  -> unique_contexts(Rest, Acc);
        false -> unique_contexts(Rest, [Context | Acc])
    end.

-spec reserve_names([rid()]) -> #{uri() => true}.
reserve_names(Names) ->
    maps:from_list([{Name, true} || Name <- Names, Name =/= anonymous]).

-spec push([binary()], location()) -> location().
push(Segments, Location) ->
    lists:reverse(Segments, Location).

-spec addr(rid(), location()) -> addr().
addr(Rid, Location) ->
    {Rid, valid_json_location:pointer(Location)}.

-spec keyword_addr(rid(), location(), binary()) -> addr().
keyword_addr(Rid, Location, Keyword) ->
    addr(Rid, [Keyword | Location]).

-spec find_location(rid(), pointer(), locations()) -> {ok, addr()} | error.
find_location(Base, Pointer, Locations) ->
    case maps:find({Base, Pointer}, Locations) of
        {ok, Addr} -> {ok, Addr};
        error      -> error
    end.

-spec schema_error(reason(), addr()) -> #schema_error{}.
schema_error(Reason, Location) ->
    #schema_error{reason = Reason, location = Location}.
