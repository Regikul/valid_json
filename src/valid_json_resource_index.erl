%% Первая фаза resource compiler: выделение schema resources и построение
%% эфемерного индекса физических locations. Constraint IR здесь не строится;
%% каждый найденный schema node сохраняется исходным JSON под каноническим
%% addr(), чтобы следующая фаза могла скомпилировать его без повторного решения
%% границ `$id`.
-module(valid_json_resource_index).

-include("valid_json_core.hrl").

-export([discover/3, root/1, resources/1, anchors/1, resolve/3,
         resolve_reference/3]).
-export_type([index/0, resource_schemas/0, resource_anchors/0]).

-define(DRAFT_2020_12,
        <<"https://json-schema.org/draft/2020-12/schema">>).
-define(DRAFT_2019_09,
        <<"https://json-schema.org/draft/2019-09/schema">>).

-type resource_schemas() :: #{rid() => #{pointer() => json()}}.
-type resource_anchors() :: #{rid() => #{binary() => pointer()}}.
-type location_key() :: {rid(), pointer()}.
-type locations() :: #{location_key() => addr()}.

%% Индекс является промежуточным значением compiler и не входит в compiled().
-opaque index() :: #{root := rid(),
                     resources := resource_schemas(),
                     anchors := resource_anchors(),
                     locations := locations()}.

-record(state, {
    dialect   :: dialect(),
    resources = #{} :: resource_schemas(),
    anchors = #{} :: resource_anchors(),
    locations = #{} :: locations(),
    %% Все URI, уже занятые resource либо retrieval alias. `anonymous` сюда не
    %% входит: это локальная метка, а не глобальное имя.
    names = #{} :: #{uri() => true}
}).

-type state() :: #state{}.
-type location() :: [binary()].
-type context() :: {rid(), location()}.
-type child() :: {[binary()], json()}.

%% Retrieval задаёт физическое имя документа. Для inline schema это
%% `anonymous`; корневой `$id` при наличии становится canonical root.
-spec discover(json(), rid(), dialect()) ->
          {ok, index()} | {error, #schema_error{}}.
discover(Schema, Retrieval0, Dialect)
  when (Retrieval0 =:= anonymous orelse is_binary(Retrieval0)),
       is_binary(Dialect) ->
    case normalize_retrieval(Retrieval0) of
        {ok, Retrieval} ->
            case root_id(Schema, Retrieval) of
                {ok, Root} -> discover_root(Schema, Retrieval, Root, Dialect);
                {error, Reason} ->
                    {error, schema_error(Reason,
                                         keyword_addr(Retrieval, [], <<"$id">>))}
            end;
        {error, Reason} ->
            {error, #schema_error{reason = Reason, location = undefined}}
    end;
discover(Schema, Retrieval, Dialect) ->
    erlang:error(badarg, [Schema, Retrieval, Dialect]).

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

-spec discover_root(json(), rid(), rid(), dialect()) ->
          {ok, index()} | {error, #schema_error{}}.
discover_root(Schema, Retrieval, Root, Dialect) ->
    Contexts = root_contexts(Root, Retrieval),
    Names = reserve_names([Base || {Base, []} <- Contexts]),
    State0 = #state{dialect = Dialect,
                    resources = #{Root => #{}},
                    anchors = #{Root => #{}},
                    names = Names},
    case walk(Schema, Root, [], Contexts, root, State0) of
        {ok, #state{resources = Resources, anchors = Anchors,
                    locations = Locations}} ->
            {ok, #{root => Root,
                   resources => Resources,
                   anchors => Anchors,
                   locations => Locations}};
        {error, _} = Error ->
            Error
    end.

%% Root `$id` уже обработан до начала обхода. На остальных map-nodes `$id`
%% сначала меняет resource boundary, затем node укладывается по новому адресу.
-spec walk(json(), rid(), location(), [context()], root | child, state()) ->
          {ok, state()} | {error, #schema_error{}}.
walk(Schema, Rid, Location, Contexts, RootOrChild, State)
  when is_boolean(Schema); is_map(Schema) ->
    case enter_resource(Schema, Rid, Location, Contexts, RootOrChild, State) of
        {ok, NodeRid, NodeLocation, NodeContexts, Entered} ->
            Addr = addr(NodeRid, NodeLocation),
            case place(Schema, Addr, NodeContexts, Entered) of
                {ok, Placed} when is_map(Schema) ->
                    walk_children(children(Schema, Placed#state.dialect),
                                  NodeRid, NodeLocation, NodeContexts, Placed);
                {ok, Placed} ->
                    {ok, Placed};
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end;
walk(Other, Rid, Location, _Contexts, _RootOrChild, _State) ->
    {error, schema_error({bad_keyword_value, Other}, addr(Rid, Location))}.

-spec enter_resource(json(), rid(), location(), [context()], root | child, state()) ->
          {ok, rid(), location(), [context()], state()} |
          {error, #schema_error{}}.
enter_resource(_Schema, Rid, Location, Contexts, root, State) ->
    {ok, Rid, Location, Contexts, State};
enter_resource(#{<<"$id">> := Id}, Rid, Location, Contexts, child, State) ->
    IdLocation = keyword_addr(Rid, Location, <<"$id">>),
    case resolve_id(Id, Rid) of
        {ok, NewRid} ->
            case reserve_resource(NewRid, IdLocation, State) of
                {ok, Reserved} ->
                    {ok, NewRid, [], [{NewRid, []} | Contexts], Reserved};
                {error, _} = Error ->
                    Error
            end;
        {error, Reason} ->
            {error, schema_error(Reason, IdLocation)}
    end;
enter_resource(_Schema, Rid, Location, Contexts, child, State) ->
    {ok, Rid, Location, Contexts, State}.

-spec resolve_id(json(), rid()) -> {ok, rid()} | {error, reason()}.
resolve_id(Id, Base) when is_binary(Id) ->
    case valid_json_uri:resolve(Id, Base) of
        {ok, Rid, root} when Rid =/= anonymous -> {ok, Rid};
        {ok, _Rid, _Fragment}                 -> {error, {bad_keyword_value, Id}};
        {error, Reason}                       -> {error, Reason}
    end;
resolve_id(Id, _Base) ->
    {error, {bad_keyword_value, Id}}.

-spec reserve_resource(uri(), addr(), state()) ->
          {ok, state()} | {error, #schema_error{}}.
reserve_resource(Rid, Location,
                 #state{resources = Resources, anchors = Anchors,
                        names = Names} = State) ->
    case maps:is_key(Rid, Names) of
        true ->
            {error, schema_error({name_taken, Rid}, Location)};
        false ->
            {ok, State#state{resources = Resources#{Rid => #{}},
                             anchors = Anchors#{Rid => #{}},
                             names = Names#{Rid => true}}}
    end.

-spec place(json(), addr(), [context()], state()) ->
          {ok, state()} | {error, #schema_error{}}.
place(Schema, {Rid, Pointer} = Addr, Contexts,
      #state{resources = Resources} = State) ->
    Nodes = maps:get(Rid, Resources),
    WithNode = State#state{resources = Resources#{Rid => Nodes#{Pointer => Schema}}},
    case index_contexts(Contexts, Addr, WithNode) of
        {ok, Indexed} when is_map(Schema) -> index_anchor(Schema, Addr, Indexed);
        {ok, Indexed}                     -> {ok, Indexed};
        {error, _} = Error                -> Error
    end.

%% Duplicate names inside one resource have undefined behavior in the drafts;
%% the compiler deliberately does not invent a schema error for them. The walk
%% is deterministic, so the last discovered declaration wins internally.
-spec index_anchor(#{binary() => json()}, addr(), state()) ->
          {ok, state()} | {error, #schema_error{}}.
index_anchor(Schema, {Rid, Pointer}, #state{dialect = Dialect,
                                            anchors = Anchors} = State) ->
    case maps:find(<<"$anchor">>, Schema) of
        error ->
            {ok, State};
        {ok, Name} ->
            case valid_anchor(Name, Dialect) of
                true ->
                    ResourceAnchors = maps:get(Rid, Anchors),
                    {ok, State#state{
                           anchors = Anchors#{Rid => ResourceAnchors#{Name => Pointer}}}};
                false ->
                    Location = keyword_addr(
                                 Rid, valid_json_location:segments(Pointer), <<"$anchor">>),
                    {error, schema_error({bad_keyword_value, Name}, Location)}
            end
    end.

-spec valid_anchor(json(), dialect()) -> boolean().
valid_anchor(Name, Dialect) when is_binary(Name) ->
    Pattern = case Dialect of
                  ?DRAFT_2019_09 -> <<"\\A[A-Za-z][-A-Za-z0-9.:_]*\\z">>;
                  _              -> <<"\\A[A-Za-z_][-A-Za-z0-9._]*\\z">>
              end,
    re:run(Name, Pattern, [{capture, none}]) =:= match;
valid_anchor(_Name, _Dialect) ->
    false.

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

-spec walk_children([child()], rid(), location(), [context()], state()) ->
          {ok, state()} | {error, #schema_error{}}.
walk_children([], _Rid, _Location, _Contexts, State) ->
    {ok, State};
walk_children([{Segments, Schema} | Rest], Rid, Location, Contexts, State) ->
    ChildLocation = push(Segments, Location),
    ChildContexts = [{Base, push(Segments, Relative)} ||
                        {Base, Relative} <- Contexts],
    case walk(Schema, Rid, ChildLocation, ChildContexts, child, State) of
        {ok, Walked} ->
            walk_children(Rest, Rid, Location, Contexts, Walked);
        {error, _} = Error ->
            Error
    end.

%% Здесь перечислены только schema positions активных keywords. Значения
%% unknown keywords, annotations, const и enum не обходятся. Контейнер неверной
%% формы оставляется emitter'у, зато элемент корректного контейнера обязан быть
%% schema и потому проходит через walk/6 даже при ошибочном типе.
-spec children(#{binary() => json()}, dialect()) -> [child()].
children(Schema, Dialect) ->
    lists:append([
        named_children(<<"$defs">>, Schema),
        named_children(<<"properties">>, Schema),
        named_children(<<"patternProperties">>, Schema),
        named_children(<<"dependentSchemas">>, Schema),
        ordered_children(<<"allOf">>, Schema),
        ordered_children(<<"anyOf">>, Schema),
        ordered_children(<<"oneOf">>, Schema),
        prefix_children(Schema, Dialect),
        items_children(Schema, Dialect),
        single_children([<<"additionalProperties">>, <<"propertyNames">>,
                         <<"contains">>, <<"not">>, <<"if">>, <<"then">>,
                         <<"else">>], Schema),
        additional_items_children(Schema, Dialect)
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
