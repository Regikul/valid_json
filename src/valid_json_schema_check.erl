%% Проверка корней schema resources их собственными метасхемами. Канонические
%% метасхемы берутся из контекста store: размещённый store читает опубликованные
%% bundles, одноразовый держит их обычным значением. Пользовательские метасхемы
%% остаются документами store и компилируются один раз на текущий проход.
-module(valid_json_schema_check).

-include("valid_json_resources.hrl").

-export([check/4]).

-type cache() :: #{uri() => compiled()}.

-spec check(valid_json_resource_index:index(), store(), schema_validation(), boolean()) ->
          {ok, [uri()]} | {error, #schema_error{}}.
check(_Index, _Store, _Mode, true) ->
    %% Profile resolution and compiler safety checks have already happened in
    %% the closure/index phases. Trust only removes this meta-evaluation pass.
    {ok, []};
check(Index, #store{} = Store, Mode, false) ->
    Root = valid_json_resource_index:root(Index),
    Resources = valid_json_resource_index:resources(Index),
    Profiles = valid_json_resource_index:profiles(Index),
    Rids = [Root | lists:sort(maps:keys(Resources) -- [Root])],
    Instances = resource_instances(Rids, Resources, Index),
    check_resources(Rids, Instances, Profiles, Store, Mode, #{}, []).

-spec check_resources([rid()], #{rid() => json()}, #{rid() => profile()},
                      store(), schema_validation(), cache(), [uri()]) ->
          {ok, [uri()]} | {error, #schema_error{}}.
check_resources([], _Instances, _Profiles, _Store, _Mode, _Cache, Sources) ->
    {ok, Sources};
check_resources([Rid | Rest], Instances, Profiles, Store, Mode, Cache0, Sources0) ->
    Profile = maps:get(Rid, Profiles),
    case metaschema(Profile, Store, Mode, Cache0) of
        {ok, Compiled, Cache, MetaSources} ->
            Schema = maps:get(Rid, Instances, undefined),
            case validate(Compiled, Profile#profile.uri, Rid, Schema, Mode) of
                ok ->
                    Sources = ordsets:union(Sources0, MetaSources),
                    check_resources(Rest, Instances, Profiles, Store, Mode,
                                    Cache, Sources);
                {error, _} = Error ->
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%% При проверке enclosing resource содержимое embedded resource не является
%% его подсхемой: оно будет отдельно проверено своим dialect. Заменяем такую
%% schema position на `true`, сохраняя валидность самого контейнера родителя.
-spec resource_instances([rid()],
                         valid_json_resource_index:resource_schemas(),
                         valid_json_resource_index:index()) -> #{rid() => json()}.
resource_instances(Rids, Resources, Index) ->
    Raw = maps:from_list(
            [{Rid, maps:get(<<>>, maps:get(Rid, Resources))} || Rid <- Rids]),
    lists:foldl(fun(Rid, Instances) ->
                        mask_declaration(Rid,
                                         valid_json_resource_index:declaration(
                                           Rid, Index),
                                         Instances)
                end,
                Raw,
                Rids).

-spec mask_declaration(rid(), addr(), #{rid() => json()}) -> #{rid() => json()}.
mask_declaration(Rid, {Parent, Pointer}, Instances) ->
    Segments = valid_json_location:segments(Pointer),
    case {Rid =/= Parent, maps:is_key(Parent, Instances), Segments} of
        {true, true, [<<"$id">> | SchemaLocation]} ->
            ParentSchema = maps:get(Parent, Instances),
            Masked = replace_at(ParentSchema, lists:reverse(SchemaLocation), true),
            Instances#{Parent => Masked};
        _ ->
            %% Document roots are declared relative to retrieval aliases (or
            %% anonymous), not to another resource, and therefore are not masks.
            Instances
    end.

-spec replace_at(json(), [binary()], json()) -> json().
replace_at(_Value, [], Replacement) ->
    Replacement;
replace_at(Value, [Segment | Rest], Replacement) when is_map(Value) ->
    Child = maps:get(Segment, Value),
    Value#{Segment => replace_at(Child, Rest, Replacement)};
replace_at(Value, [Segment | Rest], Replacement) when is_list(Value) ->
    Index = binary_to_integer(Segment),
    {Before, [Child | After]} = lists:split(Index, Value),
    Before ++ [replace_at(Child, Rest, Replacement) | After].

-spec metaschema(profile(), store(), schema_validation(), cache()) ->
          {ok, compiled(), cache(), [uri()]} | {error, #schema_error{}}.
metaschema(#profile{uri = ?DRAFT_2020_12}, Store, _Mode, Cache) ->
    {ok, valid_json_metaschema:compiled(?DRAFT_2020_12, Store), Cache, []};
metaschema(#profile{uri = ?DRAFT_2019_09}, Store, _Mode, Cache) ->
    {ok, valid_json_metaschema:compiled(?DRAFT_2019_09, Store), Cache, []};
metaschema(#profile{uri = ?DRAFT_07}, Store, _Mode, Cache) ->
    {ok, valid_json_metaschema:compiled(?DRAFT_07, Store), Cache, []};
metaschema(#profile{uri = ?DRAFT_06}, Store, _Mode, Cache) ->
    {ok, valid_json_metaschema:compiled(?DRAFT_06, Store), Cache, []};
metaschema(#profile{uri = Uri, draft = Draft}, Store, Mode, Cache) ->
    case maps:find(Uri, Cache) of
        {ok, Compiled} ->
            {ok, Compiled, Cache, maps:get(sources, Compiled)};
        error ->
            %% Метасхема без собственного `$schema` наследует default draft,
            %% уже вычисленный при построении profile этого resource.
            case valid_json_compile:compile_uri(
                   Store, Uri, [{default_dialect, Draft},
                                {schema_validation, Mode}]) of
                {ok, Compiled} ->
                    {ok, Compiled, Cache#{Uri => Compiled},
                     maps:get(sources, Compiled)};
                {error, _} = Error ->
                    Error
            end
    end.

-spec validate(compiled(), uri(), rid(), json(), schema_validation()) ->
          ok | {error, #schema_error{}}.
validate(Compiled, MetaUri, Rid, Schema, Format)
  when Format =:= flag; Format =:= basic;
       Format =:= detailed; Format =:= verbose ->
    case valid_json_eval:run(Compiled, Schema, Format) of
        {ok, #eval_result{valid = true}} ->
            ok;
        {ok, #eval_result{valid = false} = Result} ->
            {error, #schema_error{
                      reason = schema_invalid,
                      location = {Rid, <<>>},
                      validation_output = valid_json_output:project(Format, Result)}};
        {error, EvalError} ->
            {error, #schema_error{
                      reason = {metaschema_evaluation_failed, MetaUri, EvalError},
                      location = {Rid, <<>>}}}
    end.
