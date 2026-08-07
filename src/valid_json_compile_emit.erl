%% Emission готового resource index в канонический constraint IR. Документы и
%% store уже замкнуты предыдущей фазой; каждый дочерний переход и `$ref`
%% немедленно заменяется каноническим addr().
-module(valid_json_compile_emit).

-include("valid_json_resources.hrl").

-export([emit/3]).

%% Keywords, которые ничего не проверяют и только отдают своё значение
%% аннотацией. Список назван отдельно: он нужен и порядку обхода, и разбору.
-define(ANNOTATIONS, [<<"title">>, <<"description">>, <<"default">>,
                      <<"deprecated">>, <<"readOnly">>, <<"writeOnly">>,
                      <<"examples">>]).

%% Content keywords тоже только аннотируют, но применимы к одним строкам и
%% потому собираются отдельным тегом IR. Порядок между собой взят из
%% validation.txt, разделы 8.3-8.5.
-define(CONTENT, [<<"contentEncoding">>, <<"contentMediaType">>,
                  <<"contentSchema">>]).

%% Порядок constraints в node задан статически. Наблюдаемое дерево units не
%% должно зависеть от порядка обхода map, поэтому обход идёт по этому списку,
%% а не по maps:keys/1. Элемент — один constraint: обычно это сам keyword, а
%% составной перечисляет свои keywords списком и компилируется за один шаг.
%% Annotation-only keywords стоят в конце: сначала идёт то, что определяет
%% вердикт, потом то, что только описывает значение.
-define(ORDER, [<<"$ref">>, <<"$dynamicRef">>, <<"$recursiveRef">>,
                <<"type">>, <<"enum">>, <<"const">>,
                <<"multipleOf">>,
                <<"maximum">>, <<"exclusiveMaximum">>,
                <<"minimum">>, <<"exclusiveMinimum">>,
                <<"maxLength">>, <<"minLength">>, <<"pattern">>,
                <<"maxItems">>, <<"minItems">>, <<"uniqueItems">>,
                <<"maxProperties">>, <<"minProperties">>,
                <<"required">>, <<"dependentRequired">>,
                <<"dependencies">>,
                [<<"prefixItems">>, <<"items">>, <<"additionalItems">>],
                [<<"contains">>, <<"minContains">>, <<"maxContains">>],
                [<<"properties">>, <<"patternProperties">>,
                 <<"additionalProperties">>],
                <<"propertyNames">>,
                <<"allOf">>, <<"anyOf">>, <<"oneOf">>, <<"not">>,
                [<<"if">>, <<"then">>, <<"else">>],
                <<"dependentSchemas">>,
                <<"format">> | ?ANNOTATIONS ++ ?CONTENT]).

%% Constraints, которые обязаны выполняться после всех остальных: они читают
%% объединённое покрытие соседей. Порядок между собой тот же, что и у обычных
%% array и object applicators в ?ORDER; применяются они к разным типам инстанса,
%% поэтому наблюдаем он только в дереве units.
-define(UNEVALUATED, [<<"unevaluatedItems">>, <<"unevaluatedProperties">>]).

%% Полностью потребляются компилятором и собственного constraint не дают.
%% `$defs` отдельно обходит свои schema entries до emission constraints.
%% `$dynamicAnchor` перечислен без оговорки о dialect: в Draft 2019-09 такого
%% keyword нет, но неизвестные keywords он и так игнорирует, поэтому результат
%% совпадает.
%% `$vocabulary` действует только при обработке документа как метасхемы
%% (core.txt:1390): активные vocabularies уже выбраны, а здесь keyword лишь
%% потребляется.
-define(CONSUMED, [<<"$schema">>, <<"$id">>, <<"$anchor">>, <<"$defs">>,
                   <<"definitions">>, <<"$vocabulary">>,
                   <<"$comment">>, <<"$dynamicAnchor">>]).

%% Активность keyword решают vocabularies профиля; на сам draft emitter смотрит
%% только там, где спецификации расходятся при одинаковом наборе vocabularies:
%% раскладка array applicators и покрытие `contains`.
-type nodes() :: #{pointer() => schema_node()}.
-type node_sets() :: #{rid() => nodes()}.
-type position() :: {rid(), [binary()]}.

%% Накопитель emission. Index immutable и нужен только для канонизации дочерних
%% переходов; в compiled() он не попадает. `profile` — профиль испускаемого
%% сейчас resource, а полная map нужна при переходе между documents.
%% `assert_format` приходит опцией компиляции и на всём проходе один: артефакт
%% принадлежит одной паре schema/options целиком.
-record(state, {
    profile       :: profile(),
    profiles      :: #{rid() => profile()},
    index         :: valid_json_resource_index:index(),
    resources     :: node_sets(),
    assert_format :: boolean()
}).

-type state() :: #state{}.

-spec emit(valid_json_resource_index:index(), [uri()], boolean()) ->
          {ok, compiled()} | {error, #schema_error{}}.
emit(Index, Sources, AssertFormat) ->
    Root = valid_json_resource_index:root(Index),
    Schemas = valid_json_resource_index:resources(Index),
    Dialects = valid_json_resource_index:dialects(Index),
    Profiles = valid_json_resource_index:profiles(Index),
    Empty = maps:map(fun(_Rid, _Nodes) -> #{} end, Schemas),
    State = #state{profile = maps:get(Root, Profiles),
                   profiles = Profiles,
                   index = Index,
                   resources = Empty,
                   assert_format = AssertFormat},
    case emit_resources(Root, Schemas, State) of
        {ok, #state{resources = Resources}} ->
            Anchors = {valid_json_resource_index:anchors(Index),
                       valid_json_resource_index:dynamic_anchors(Index),
                       valid_json_resource_index:recursive_anchors(Index)},
            {ok, artifact(Root, Resources, Anchors, Dialects, Sources)};
        {error, _} = Error ->
            Error
    end.

%% Root испускается первым, остальные resources — по URI. Внутри resource
%% pointers тоже отсортированы. Порядок не влияет на итоговые maps, зато первая
%% compile error остаётся воспроизводимой.
-spec emit_resources(rid(), valid_json_resource_index:resource_schemas(), state()) ->
          {ok, state()} | {error, #schema_error{}}.
emit_resources(Root, Resources, State) ->
    Rids = [Root | lists:sort(maps:keys(Resources) -- [Root])],
    Step = fun(_Rid, {error, _} = Error) ->
                   Error;
              (Rid, {ok, Built}) ->
                   emit_resource(Rid, maps:get(Rid, Resources), Built)
           end,
    lists:foldl(Step, {ok, State}, Rids).

-spec emit_resource(rid(), #{pointer() => json()}, state()) ->
          {ok, state()} | {error, #schema_error{}}.
emit_resource(Rid, Schemas, #state{profiles = Profiles} = State0) ->
    State = State0#state{profile = maps:get(Rid, Profiles)},
    Step = fun(_Pointer, {error, _} = Error) ->
                   Error;
              (Pointer, {ok, Built}) ->
                   Position = {Rid, valid_json_location:segments(Pointer)},
                   compile_node(maps:get(Pointer, Schemas), Position, Built)
           end,
    lists:foldl(Step, {ok, State}, lists:sort(maps:keys(Schemas))).

%% Position уже каноничен относительно текущего resource. Дочерняя schema
%% взята из discovery map, поэтому после `$id` её position уже начинается с
%% корня нового rid. Сам emitter в дочерние nodes не спускается.
-spec compile_node(json(), position(), state()) ->
          {ok, state()} | {error, #schema_error{}}.
compile_node(Schema, Position, State) when is_boolean(Schema) ->
    {ok, place(Position, Schema, State)};
compile_node(Schema, Position, #state{profile = Profile} = State)
  when is_map(Schema) ->
    case ref_only(Schema, Profile) of
        true ->
            compile_ref_node(Schema, Position, State);
        false ->
            case definition_containers(Schema, Position, State) of
                {ok, WithDefinitions} ->
                    case node_constraints(Schema, Position, WithDefinitions) of
                        {ok, Constraints, Unevaluated, Built} ->
                            Markers = output_markers(Schema),
                            Extras = extra_constraints(Schema, Profile),
                            Node = #node{constraints =
                                             Markers ++ Constraints ++ Extras,
                                         unevaluated = Unevaluated},
                            {ok, place(Position, Node, Built)};
                        {error, _} = Error ->
                            Error
                    end;
                {error, _} = Error ->
                    Error
            end
    end;
%% На позиции schema стоит значение, которое schema не является. Для slot IR оно
%% невозможно, а называет его собственная локация.
compile_node(Other, Position, _State) ->
    {error, schema_error({bad_keyword_value, Other}, Position)}.

%% Draft 6/7: объект с `$ref` — это ссылка, и все прочие свойства объекта
%% игнорируются (draft-07 core, 8.3; то же правило в Draft 6). Discovery уже
%% посетил `$id`/`$schema` и structural children; emitter выпускает только
%% reference semantics, чтобы общий evaluator остался без dialect-ветвей.
-spec ref_only(#{binary() => json()}, profile()) -> boolean().
ref_only(Schema, #profile{draft = Draft})
  when Draft =:= ?DRAFT_06; Draft =:= ?DRAFT_07 ->
    maps:is_key(<<"$ref">>, Schema);
ref_only(_Schema, _Profile) ->
    false.

-spec compile_ref_node(#{binary() => json()}, position(), state()) ->
          {ok, state()} | {error, #schema_error{}}.
compile_ref_node(Schema, Position, State) ->
    case reference(<<"$ref">>, Schema, Position, State) of
        {ok, _Target, Addr} ->
            Node = #node{constraints = [{ref, Addr}], unevaluated = []},
            {ok, place(Position, Node, State)};
        {error, _} = Error ->
            Error
    end.

%% Definition containers не вычисляют instance, но являются видимыми
%% успешными keyword results в normative verbose example. Marker ничего не
%% меняет в validity/coverage и остаётся невидимым в плоском basic.
-spec output_markers(#{binary() => json()}) -> [constraint()].
output_markers(Schema) ->
    [{marker, Keyword}
     || Keyword <- [<<"$defs">>, <<"definitions">>],
        maps:is_key(Keyword, Schema)].

%% Значения unknown keywords не являются schema positions: discovery их уже не
%% посещал, а emitter лишь сохраняет исходное JSON value как annotation в
%% 2020-12. В classic drafts (6, 7 и 2019-09) неизвестные keywords не дают IR.
%% Сортировка делает annotation order независимым от устройства map.
-spec extra_constraints(#{binary() => json()}, profile()) -> [constraint()].
extra_constraints(Schema, #profile{draft = Draft} = Profile) ->
    Active = lists:append([active_keywords(Group, Profile) || Group <- ?ORDER]) ++
        [Keyword || Keyword <- ?UNEVALUATED,
                    valid_json_vocabulary:active(Keyword, Profile)],
    Extras = lists:sort(maps:keys(Schema) -- (Active ++ ?CONSUMED)),
    unknown_constraints(Extras, Schema, Draft).

-spec unknown_constraints([binary()], #{binary() => json()}, dialect()) ->
          [constraint()].
unknown_constraints(Keywords, Schema, ?DRAFT_2020_12) ->
    [{annotation, Keyword, maps:get(Keyword, Schema)} || Keyword <- Keywords];
unknown_constraints(_Keywords, _Schema, ?DRAFT_2019_09) ->
    [];
unknown_constraints(_Keywords, _Schema, ?DRAFT_06) ->
    [];
unknown_constraints(_Keywords, _Schema, ?DRAFT_07) ->
    [].

-spec place(position(), schema_node(), state()) -> state().
place({Rid, Location}, Node, #state{resources = Resources} = State) ->
    Nodes = maps:get(Rid, Resources),
    Pointer = valid_json_location:pointer(Location),
    State#state{resources = Resources#{Rid => Nodes#{Pointer => Node}}}.

%% `$defs` и совместимый `definitions` — schema containers без собственного
%% constraint. Entries уже лежат в discovery map и будут выпущены общим
%% проходом; здесь остаётся только проверка формы самих контейнеров.
-spec definition_containers(#{binary() => json()}, position(), state()) ->
          {ok, state()} | {error, #schema_error{}}.
definition_containers(Schema, Position, State) ->
    definition_containers([<<"$defs">>, <<"definitions">>], Schema,
                          Position, State).

-spec definition_containers([binary()], #{binary() => json()}, position(), state()) ->
          {ok, state()} | {error, #schema_error{}}.
definition_containers([], _Schema, _Position, State) ->
    {ok, State};
definition_containers([Keyword | Rest], Schema, Position, State) ->
    case maps:find(Keyword, Schema) of
        error ->
            definition_containers(Rest, Schema, Position, State);
        {ok, Definitions} when is_map(Definitions) ->
            definition_containers(Rest, Schema, Position, State);
        {ok, Other} ->
            {error, schema_error({bad_keyword_value, Other},
                                 below(Keyword, Position))}
    end.

-spec below(binary(), position()) -> position().
below(Segment, {Rid, Location}) ->
    {Rid, [Segment | Location]}.

%% Physical position разрешается относительно текущего resource. Index сразу
%% возвращает canonical addr; pointer снова превращается в обратный стек, чтобы
%% следующие keywords дописывались тем же способом, что и раньше.
-spec canonical(position(), state()) -> position().
canonical({Rid, Location} = Position, #state{index = Index}) ->
    case valid_json_resource_index:resolve(Rid, {pointer, Location}, Index) of
        {ok, {CanonicalRid, Pointer}} ->
            {CanonicalRid, valid_json_location:segments(Pointer)};
        error ->
            erlang:error({missing_schema_location, addr(Position)})
    end.

-spec addr(position()) -> addr().
addr({Rid, Location}) ->
    {Rid, valid_json_location:pointer(Location)}.

-spec schema_error(reason(), position()) -> #schema_error{}.
schema_error(Reason, Position) ->
    #schema_error{reason = Reason, location = addr(Position)}.

%% Оба поля node собираются одним проходом по схеме, но лежат раздельно:
%% `unevaluated*` читают объединённое покрытие соседей и потому обязаны
%% выполняться последними (validator-core.md, «Инварианты компиляции IR»).
-spec node_constraints(#{binary() => json()}, position(), state()) ->
          {ok, [constraint()], [constraint()], state()} | {error, #schema_error{}}.
node_constraints(Schema, Position, State) ->
    case constraints(Schema, Position, State) of
        {ok, Constraints, Built} ->
            case unevaluated(Schema, Position, Built) of
                {ok, Unevaluated, Grown} -> {ok, Constraints, Unevaluated, Grown};
                {error, _} = Error       -> Error
            end;
        {error, _} = Error ->
            Error
    end.

%% Своего сегмента у подсхемы нет: она стоит на самом keyword, как и
%% `additionalProperties`. Ненаписанный keyword constraint не даёт.
-spec unevaluated(#{binary() => json()}, position(), state()) ->
          {ok, [constraint()], state()} | {error, #schema_error{}}.
unevaluated(Schema, Position, #state{profile = Profile} = State) ->
    Keywords = [Keyword || Keyword <- ?UNEVALUATED,
                           valid_json_vocabulary:active(Keyword, Profile)],
    Step = fun(_Keyword, {error, _} = Error) ->
                   Error;
              (Keyword, {ok, Acc, Built}) ->
                   case maps:find(Keyword, Schema) of
                       error ->
                           {ok, Acc, Built};
                       {ok, Value} ->
                           case subschema(Value, below(Keyword, Position), Built) of
                               {ok, Addr, Grown} ->
                                   {ok, [{unevaluated_tag(Keyword), Addr} | Acc], Grown};
                               {error, _} = Error ->
                                   Error
                           end
                   end
           end,
    case lists:foldl(Step, {ok, [], State}, Keywords) of
        {ok, Acc, Built}   -> {ok, lists:reverse(Acc), Built};
        {error, _} = Error -> Error
    end.

-spec unevaluated_tag(binary()) -> atom().
unevaluated_tag(<<"unevaluatedItems">>)      -> unevaluated_items;
unevaluated_tag(<<"unevaluatedProperties">>) -> unevaluated_properties.

%% Обход групп несёт accumulator итоговых resources, но applicator только
%% записывает канонические адреса: сами дочерние nodes выпускает общий проход.
%% Группа, ни один keyword которой не написан, constraint не даёт. Ответ `none`
%% означает обратное: keywords написаны, но вычислять по ним нечего.
-spec constraints(#{binary() => json()}, position(), state()) ->
          {ok, [constraint()], state()} | {error, #schema_error{}}.
constraints(Schema, Position, State) ->
    Step = fun(_Group, {error, _} = Error) ->
                   Error;
              (Group, {ok, Acc, Built}) ->
                   case lists:any(fun(Keyword) -> maps:is_key(Keyword, Schema) end,
                                  active_keywords(Group, Built#state.profile)) of
                       false ->
                           {ok, Acc, Built};
                       true ->
                           case constraint(Group, Schema, Position, Built) of
                               {ok, none, Grown}       -> {ok, Acc, Grown};
                               {ok, Constraint, Grown} -> {ok, [Constraint | Acc], Grown};
                               {error, _} = Error      -> Error
                           end
                   end
           end,
    case lists:foldl(Step, {ok, [], State}, ?ORDER) of
        {ok, Acc, Built}   -> {ok, lists:reverse(Acc), Built};
        {error, _} = Error -> Error
    end.

%% Одиночный keyword записан в ?ORDER сам собой, группа — списком.
-spec keywords(binary() | [binary()]) -> [binary()].
keywords(Keyword) when is_binary(Keyword) -> [Keyword];
keywords(Group)                           -> Group.

%% Keyword выключенной vocabulary не собирает constraint и не влияет на соседей
%% по составному: он неизвестен и уходит в extra_constraints/2. Так `prefixItems`
%% не влияет на `items` в Draft 2019-09, `$dynamicRef` не работает там вовсе, а
%% recursive keywords не работают в Draft 2020-12 — их нет в vocabularies этих
%% draft. По той же причине `format` остаётся активным в обоих: аннотация
%% обязательна независимо от объявления vocabulary.
-spec active_keywords(binary() | [binary()], profile()) -> [binary()].
active_keywords(Group, Profile) ->
    [Keyword || Keyword <- keywords(Group),
                valid_json_vocabulary:active(Keyword, Profile)].

%% Разбор идёт по элементу ?ORDER целиком, а не по написанному подмножеству:
%% элемент — статический литерал, и по нему видно, какой constraint собирается.
-spec constraint(binary() | [binary()], #{binary() => json()}, position(), state()) ->
          {ok, constraint() | none, state()} | {error, #schema_error{}}.
constraint([<<"properties">>, <<"patternProperties">>, <<"additionalProperties">>],
           Schema, Position, State) ->
    object(Schema, Position, State);
constraint([<<"if">>, <<"then">>, <<"else">>], Schema, Position, State) ->
    conditional(Schema, Position, State);
constraint([<<"prefixItems">>, <<"items">>, <<"additionalItems">>],
           Schema, Position, State) ->
    array(Schema, Position, State);
constraint([<<"contains">>, <<"minContains">>, <<"maxContains">>],
           Schema, Position, State) ->
    contains(Schema, Position, State);
constraint(<<"$ref">> = Keyword, Schema, Position, State) ->
    case reference(Keyword, Schema, Position, State) of
        {ok, _Target, Addr} -> {ok, {ref, Addr}, State};
        {error, _} = Error  -> Error
    end;
%% Динамичность решается на компиляции. Keyword ведёт себя динамически только
%% тогда, когда fragment — plain name, а лексическая цель несёт одноимённый
%% `$dynamicAnchor` (core.txt, 8.2.3.2); во всех остальных случаях это обычный
%% `$ref`, и IR это фиксирует прямо. Evaluator остаётся с единственным вопросом:
%% какой resource dynamic scope объявил это имя раньше всех.
constraint(<<"$dynamicRef">> = Keyword, Schema, Position, State) ->
    case reference(Keyword, Schema, Position, State) of
        {ok, {anchor, Name}, Addr} ->
            case dynamic_anchor(Name, Addr, State) of
                true  -> {ok, {dynamic_ref, Name, Addr}, State};
                false -> {ok, {ref, Addr}, State}
            end;
        {ok, _Target, Addr} ->
            {ok, {ref, Addr}, State};
        {error, _} = Error ->
            Error
    end;
%% Draft 2019-09 определяет recursive resolution только для пустого fragment.
%% Лексическая цель всегда канонический корень resource; динамический выбор
%% остаётся evaluator'у, потому что зависит от runtime scope.
constraint(<<"$recursiveRef">> = Keyword, Schema, Position, State) ->
    case maps:get(Keyword, Schema) of
        <<"#">> ->
            case reference(Keyword, Schema, Position, State) of
                {ok, _Target, Addr} -> {ok, {recursive_ref, Addr}, State};
                {error, _} = Error  -> Error
            end;
        Other ->
            {error, schema_error({bad_keyword_value, Other},
                                 below(Keyword, Position))}
    end;
%% Своего сегмента у ветви нет: она стоит на самом keyword, как и у
%% `additionalProperties`.
constraint(<<"propertyNames">> = Keyword, Schema, Position, State) ->
    case subschema(maps:get(Keyword, Schema), below(Keyword, Position), State) of
        {ok, Addr, Built}  -> {ok, {property_names, Addr}, Built};
        {error, _} = Error -> Error
    end;
%% Раскладка та же, что у `properties`: имя свойства становится сегментом
%% локации. Отличие только в применении — подсхема достаётся всему instance.
constraint(<<"dependentSchemas">> = Keyword, Schema, Position, State) ->
    case named(maps:get(Keyword, Schema), below(Keyword, Position), State) of
        {ok, Addrs, Built}  -> {ok, {dependent_schemas, Addrs}, Built};
        {error, _} = Error -> Error
    end;
constraint(<<"dependencies">> = Keyword, Schema, Position, State) ->
    case dependencies(maps:get(Keyword, Schema), below(Keyword, Position),
                      State) of
        {ok, Constraint, Built} -> {ok, Constraint, Built};
        {error, _} = Error      -> Error
    end;
constraint(<<"allOf">> = Keyword, Schema, Position, State) ->
    branches(all_of, Keyword, maps:get(Keyword, Schema), Position, State);
constraint(<<"anyOf">> = Keyword, Schema, Position, State) ->
    branches(any_of, Keyword, maps:get(Keyword, Schema), Position, State);
constraint(<<"oneOf">> = Keyword, Schema, Position, State) ->
    branches(one_of, Keyword, maps:get(Keyword, Schema), Position, State);
constraint(<<"not">> = Keyword, Schema, Position, State) ->
    case subschema(maps:get(Keyword, Schema), below(Keyword, Position), State) of
        {ok, Addr, Built}  -> {ok, {'not', Addr}, Built};
        {error, _} = Error -> Error
    end;
%% `format` аннотирует в обоих dialects. В Draft 2019-09 корневая метасхема
%% объявляет format vocabulary значением `false`, но этот boolean управляет
%% только assertion: аннотацию спецификация требует собирать независимо от него
%% (validation.txt:601 и 695). Assertion включает опция `assert_format`; вторая
%% его половина, Format-Assertion vocabulary, требует полной таблицы algorithms
%% и потому остаётся неподдержанной. Имя формата обязано быть строкой
%% (validation.txt:565): слот IR открыт для любого имени, но не для любого типа.
constraint(<<"format">> = Keyword, Schema, Position,
           #state{assert_format = Assert} = State) ->
    case maps:get(Keyword, Schema) of
        Name when is_binary(Name) ->
            {ok, {format, Name, Assert}, State};
        Other ->
            {error, schema_error({bad_keyword_value, Other},
                                 below(Keyword, Position))}
    end;
%% Значение annotation-only keyword уходит в IR как есть, без проверки и
%% нормализации. Типы этих keywords ограничивает метасхема, но валидатор её не
%% применяет, поэтому `default: []` рядом с `type: integer` остаётся корректной
%% схемой (suite, `default.json`), а `bad_keyword_value` здесь невозможен.
constraint(Keyword, Schema, Position, State) ->
    case lists:member(Keyword, ?ANNOTATIONS) of
        true  -> {ok, {annotation, Keyword, maps:get(Keyword, Schema)}, State};
        false -> content(Keyword, Schema, Position, State)
    end.

%% Значение content keyword уходит в IR как есть, по тем же причинам, что и у
%% annotation-only: типы ограничивает метасхема, а валидатор её не применяет.
%% Значение `contentSchema` схемой является, но schema position не образует:
%% к instance она не применяется никогда, поэтому обход внутрь давал бы только
%% отказ на подсхеме, которую спецификация не вычисляет. Форму этого значения
%% проверяет метасхема, а в IR оно остаётся собственным значением аннотации.
-spec content(binary(), #{binary() => json()}, position(), state()) ->
          {ok, constraint() | none, state()} | {error, #schema_error{}}.
content(Keyword, Schema, Position, State) ->
    case lists:member(Keyword, ?CONTENT) of
        true  -> {ok, {content, Keyword, maps:get(Keyword, Schema)}, State};
        false -> asserted(Keyword, Schema, Position, State)
    end.

%% Начальное разрешение у `$ref` и `$dynamicRef` одно и то же: reference берётся
%% от base текущего resource, а промах называется той же ошибкой. Наружу уходит
%% и сам target: по нему `$dynamicRef` отличает plain-name fragment от pointer.
-spec reference(binary(), #{binary() => json()}, position(), state()) ->
          {ok, valid_json_uri:target(), addr()} | {error, #schema_error{}}.
reference(Keyword, Schema, {Rid, _} = Position, #state{index = Index}) ->
    Value = maps:get(Keyword, Schema),
    case is_binary(Value) of
        false ->
            {error, schema_error({bad_keyword_value, Value}, below(Keyword, Position))};
        true ->
            case valid_json_uri:resolve(Value, Rid) of
                {ok, Base, Target} ->
                    case valid_json_resource_index:resolve_reference(Base, Target,
                                                                     Index) of
                        {ok, Addr} ->
                            {ok, Target, Addr};
                        {error, Reason} ->
                            {error, schema_error(Reason, below(Keyword, Position))}
                    end;
                {error, Reason} ->
                    {error, schema_error(Reason, below(Keyword, Position))}
            end
    end.

%% Совпасть должно не только имя, но и позиция: одноимённый `$anchor` в том же
%% resource динамической цели не создаёт.
-spec dynamic_anchor(binary(), addr(), state()) -> boolean().
dynamic_anchor(Name, {Rid, Pointer}, #state{index = Index}) ->
    Anchors = valid_json_resource_index:dynamic_anchors(Index),
    maps:find(Name, maps:get(Rid, Anchors, #{})) =:= {ok, Pointer}.

-spec asserted(binary(), #{binary() => json()}, position(), state()) ->
          {ok, constraint(), state()} | {error, #schema_error{}}.
asserted(Keyword, Schema, Position, State) ->
    case assertion(Keyword, maps:get(Keyword, Schema)) of
        {ok, Constraint} -> {ok, Constraint, State};
        {error, Reason}  -> {error, schema_error(Reason, below(Keyword, Position))}
    end.

%% Три object applicators сворачиваются в один constraint: `additionalProperties`
%% смотрит только на соседние `properties` и `patternProperties`, и статически
%% сохранённые имена с паттернами не дают воспользоваться общим накопителем
%% аннотаций (validator-core.md, «Составные constraints»). Ненаписанный keyword
%% оставляет свой слот `undefined`.
-spec object(#{binary() => json()}, position(), state()) ->
          {ok, constraint(), state()} | {error, #schema_error{}}.
object(Schema, Position, State) ->
    Slots = [{<<"properties">>, fun named/3},
             {<<"patternProperties">>, fun patterned/3},
             {<<"additionalProperties">>, fun subschema/3}],
    case slots(Slots, Schema, Position, State) of
        {ok, [Additional, Patterns, Props], Built} ->
            {ok, {properties, Props, Patterns, Additional}, Built};
        {error, _} = Error ->
            Error
    end.

%% `then` и `else` без `if` спецификация велит игнорировать целиком и запрещает
%% вычислять — и ради вердикта, и ради аннотаций (core.txt:2379 и 2422),
%% поэтому constraint без `if` не собирается. Сами nodes всё равно присутствуют:
%% discovery признал эти schema positions, и общий emission их обработает.
-spec conditional(#{binary() => json()}, position(), state()) ->
          {ok, constraint() | none, state()} | {error, #schema_error{}}.
conditional(Schema, Position, State) ->
    Slots = [{Keyword, fun subschema/3} || Keyword <- [<<"if">>, <<"then">>, <<"else">>]],
    case slots(Slots, Schema, Position, State) of
        {ok, [_Else, _Then, undefined], Built} ->
            {ok, none, Built};
        {ok, [Else, Then, If], Built} ->
            {ok, {if_then_else, If, Then, Else}, Built};
        {error, _} = Error ->
            Error
    end.

%% `prefixItems` с хвостовым `items` — раскладка Draft 2020-12. В Draft 2019-09
%% ту же работу делают array-form `items` и `additionalItems`, а неизвестный там
%% `prefixItems` игнорируется. Одиночный `items` со schema-значением одинаков в
%% обоих dialects.
-spec array(#{binary() => json()}, position(), state()) ->
          {ok, constraint() | none, state()} | {error, #schema_error{}}.
array(Schema, Position, #state{profile = #profile{draft = Draft}} = State) ->
    case layout(Draft, Schema) of
        prefix -> prefixed(Schema, Position, State);
        array  -> arrayed(Schema, Position, State);
        single -> single(Schema, Position, State);
        none   -> {ok, none, State}
    end.

%% `additionalItems` без array-form `items` спецификация велит игнорировать
%% (validation Draft 2019-09, 9.3.1.2), поэтому constraint не собирается — как у
%% `then` без `if`. Сама подсхема всё равно остаётся node: discovery признал эту
%% schema position, и общий emission её обработает.
-spec layout(dialect(), #{binary() => json()}) -> prefix | array | single | none.
layout(?DRAFT_2020_12, Schema) ->
    case maps:is_key(<<"prefixItems">>, Schema) of
        true  -> prefix;
        false -> single
    end;
layout(_Dialect, Schema) ->
    case maps:find(<<"items">>, Schema) of
        {ok, Value} when is_list(Value) -> array;
        {ok, _Value}                    -> single;
        error                           -> none
    end.

%% Своего сегмента у хвостового `items` нет: он стоит на самом keyword, как и
%% `additionalProperties` рядом с `properties`.
-spec prefixed(#{binary() => json()}, position(), state()) ->
          {ok, constraint(), state()} | {error, #schema_error{}}.
prefixed(Schema, Position, State) ->
    Slots = [{<<"prefixItems">>, fun ordered/3}, {<<"items">>, fun subschema/3}],
    case slots(Slots, Schema, Position, State) of
        {ok, [Tail, Addrs], Built} -> {ok, {prefix_items, Addrs, Tail}, Built};
        {error, _} = Error         -> Error
    end.

%% Раскладка Draft 2019-09: сегментом каждой схемы префикса становится её
%% десятичный индекс, а `additionalItems` стоит на самом keyword и достаётся
%% остатку массива.
-spec arrayed(#{binary() => json()}, position(), state()) ->
          {ok, constraint(), state()} | {error, #schema_error{}}.
arrayed(Schema, Position, State) ->
    Slots = [{<<"items">>, fun ordered/3}, {<<"additionalItems">>, fun subschema/3}],
    case slots(Slots, Schema, Position, State) of
        {ok, [Tail, Addrs], Built} -> {ok, {items_array, Addrs, Tail}, Built};
        {error, _} = Error         -> Error
    end.

-spec single(#{binary() => json()}, position(), state()) ->
          {ok, constraint(), state()} | {error, #schema_error{}}.
single(Schema, Position, State) ->
    Keyword = <<"items">>,
    case subschema(maps:get(Keyword, Schema), below(Keyword, Position), State) of
        {ok, Addr, Built}  -> {ok, {items, Addr}, Built};
        {error, _} = Error -> Error
    end.

%% `minContains` и `maxContains` без `contains` спецификация оставляет без
%% эффекта (validation.txt:459 и 474), поэтому constraint не собирается. Значения
%% всё равно разбираются: ошибка в них обязана останавливать компиляцию, как у
%% `then` без `if`. Покрывает индексы `contains` только в Draft 2020-12 — в Draft
%% 2019-09 его аннотация на `unevaluatedItems` не влияет.
-spec contains(#{binary() => json()}, position(), state()) ->
          {ok, constraint() | none, state()} | {error, #schema_error{}}.
contains(Schema, Position, #state{profile = #profile{draft = Draft}} = State) ->
    Keyword = <<"contains">>,
    case bounds(Schema, Position) of
        {ok, Min, Max} ->
            case maps:find(Keyword, Schema) of
                error ->
                    {ok, none, State};
                {ok, Value} ->
                    case subschema(Value, below(Keyword, Position), State) of
                        {ok, Addr, Built} ->
                            Marks = Draft =:= ?DRAFT_2020_12,
                            {ok, {contains, Addr, Min, Max, Marks}, Built};
                        {error, _} = Error ->
                            Error
                    end
            end;
        {error, _} = Error ->
            Error
    end.

-spec bounds(#{binary() => json()}, position()) ->
          {ok, non_neg_integer() | undefined, non_neg_integer() | undefined}
        | {error, #schema_error{}}.
bounds(Schema, Position) ->
    case {bound(<<"minContains">>, Schema, Position),
          bound(<<"maxContains">>, Schema, Position)} of
        {{ok, Min}, {ok, Max}}  -> {ok, Min, Max};
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

-spec bound(binary(), #{binary() => json()}, position()) ->
          {ok, non_neg_integer() | undefined} | {error, #schema_error{}}.
bound(Keyword, Schema, Position) ->
    case maps:find(Keyword, Schema) of
        error ->
            {ok, undefined};
        {ok, Value} ->
            case non_negative(Value) of
                {ok, Count}     -> {ok, Count};
                {error, Reason} ->
                    {error, schema_error(Reason, below(Keyword, Position))}
            end
    end.

%% Слоты составного constraint: написанный keyword строит свой кусок IR, а
%% ненаписанный оставляет `undefined`. Результат приходит в обратном порядке —
%% так его и разбирают вызывающие.
-spec slots([{binary(), function()}], #{binary() => json()}, position(), state()) ->
          {ok, [term()], state()} | {error, #schema_error{}}.
slots(Slots, Schema, Position, State) ->
    Step = fun(_Slot, {error, _} = Error) ->
                   Error;
              ({Keyword, Build}, {ok, Acc, Built}) ->
                   case maps:find(Keyword, Schema) of
                       error ->
                           {ok, [undefined | Acc], Built};
                       {ok, Value} ->
                           case Build(Value, below(Keyword, Position), Built) of
                               {ok, Slot, Grown}  -> {ok, [Slot | Acc], Grown};
                               {error, _} = Error -> Error
                           end
                   end
           end,
    lists:foldl(Step, {ok, [], State}, Slots).

%% Имя свойства становится сегментом локации. Обход идёт по отсортированным
%% именам, чтобы первая ошибка не зависела от порядка обхода map.
-spec named(json(), position(), state()) ->
          {ok, #{binary() => addr()}, state()} | {error, #schema_error{}}.
named(Value, Position, State) when is_map(Value) ->
    Step = fun(_Name, {error, _} = Error) ->
                   Error;
              (Name, {ok, Acc, Built}) ->
                   Child = below(Name, Position),
                   case subschema(maps:get(Name, Value), Child, Built) of
                       {ok, Addr, Grown}  -> {ok, Acc#{Name => Addr}, Grown};
                       {error, _} = Error -> Error
                   end
           end,
    lists:foldl(Step, {ok, #{}, State}, lists:sort(maps:keys(Value)));
    named(Value, Position, _State) ->
    {error, schema_error({bad_keyword_value, Value}, Position)}.

%% Draft 6/7: `dependencies` объединяет обе формы — property dependency (массив
%% имён) и schema dependency (подсхема). Значения уже допустимой формы
%% компилируются напрямую; формальную корректность значения оставляет метасхема.
-spec dependencies(json(), position(), state()) ->
          {ok, constraint(), state()} | {error, #schema_error{}}.
dependencies(Value, Position, State) when is_map(Value) ->
    Step = fun(_Name, {error, _} = Error) ->
                   Error;
              (Name, {ok, Acc, Built}) ->
                   case maps:get(Name, Value) of
                       Dependency when is_map(Dependency); is_boolean(Dependency) ->
                           case subschema(Dependency, below(Name, Position),
                                          Built) of
                               {ok, Addr, Grown} ->
                                   {ok, Acc#{Name => Addr}, Grown};
                               {error, _} = Error ->
                                   Error
                           end;
                       Names when is_list(Names) ->
                           case lists:all(fun is_binary/1, Names) of
                               true  -> {ok, Acc#{Name => Names}, Built};
                               false ->
                                   {error, schema_error(
                                             {bad_keyword_value, Names},
                                             below(Name, Position))}
                           end;
                       Other ->
                           {error, schema_error({bad_keyword_value, Other},
                                                below(Name, Position))}
                   end
           end,
    case lists:foldl(Step, {ok, #{}, State}, lists:sort(maps:keys(Value))) of
        {ok, Dependencies, Built} ->
            {ok, {dependencies, Dependencies}, Built};
        {error, _} = Error ->
            Error
    end;
dependencies(Value, Position, _State) ->
    {error, schema_error({bad_keyword_value, Value}, Position)}.

%% Сегмент локации — исходный текст паттерна. Порядок списка задан сортировкой
%% по нему же: от порядка обхода map наблюдаемое дерево units зависеть не должно.
-spec patterned(json(), position(), state()) ->
          {ok, [{regex(), addr()}], state()} | {error, #schema_error{}}.
patterned(Value, Position, State) when is_map(Value) ->
    Step = fun(_Source, {error, _} = Error) ->
                   Error;
              (Source, {ok, Acc, Built}) ->
                   Child = below(Source, Position),
                   case re:compile(Source, [unicode, dollar_endonly]) of
                       {error, Reason} ->
                           {error, schema_error({bad_pattern, Reason}, Child)};
                       {ok, Compiled} ->
                           case subschema(maps:get(Source, Value), Child, Built) of
                               {ok, Addr, Grown} ->
                                   {ok, [{{Source, Compiled}, Addr} | Acc], Grown};
                               {error, _} = Error ->
                                   Error
                           end
                   end
           end,
    case lists:foldl(Step, {ok, [], State}, lists:sort(maps:keys(Value))) of
        {ok, Acc, Built}   -> {ok, lists:reverse(Acc), Built};
        {error, _} = Error -> Error
    end;
patterned(Value, Position, _State) ->
    {error, schema_error({bad_keyword_value, Value}, Position)}.

%% Своего сегмента у такой ветви нет: она стоит на самом keyword.
-spec subschema(json(), position(), state()) ->
          {ok, addr(), state()} | {error, #schema_error{}}.
subschema(Value, Position, State) when is_boolean(Value); is_map(Value) ->
    Canonical = canonical(Position, State),
    {ok, addr(Canonical), State};
subschema(Value, Position, _State) ->
    {error, schema_error({bad_keyword_value, Value}, Position)}.

%% Слот из списка подсхем: сегментом становится десятичный индекс, как у ветвей
%% списочных applicators.
-spec ordered(json(), position(), state()) ->
          {ok, [addr()], state()} | {error, #schema_error{}}.
ordered(Value, Position, State) when is_list(Value) ->
    indexed(Value, Position, State, 0, []);
ordered(Value, Position, _State) ->
    {error, schema_error({bad_keyword_value, Value}, Position)}.

%% Пустой список ветвей метасхема запрещает, но в slot IR он ложится, поэтому
%% компилятор доводит его до вычисления — как `type: []` и `enum: []`.
-spec branches(atom(), binary(), json(), position(), state()) ->
          {ok, constraint(), state()} | {error, #schema_error{}}.
branches(Tag, Keyword, Value, Position, State) when is_list(Value) ->
    case indexed(Value, below(Keyword, Position), State, 0, []) of
        {ok, Addrs, Built} -> {ok, {Tag, Addrs}, Built};
        {error, _} = Error -> Error
    end;
branches(_Tag, Keyword, Value, Position, _State) ->
    {error, schema_error({bad_keyword_value, Value}, below(Keyword, Position))}.

%% Сегмент ветви — её десятичный индекс: он же стоит в локации units.
-spec indexed([json()], position(), state(), non_neg_integer(), [addr()]) ->
          {ok, [addr()], state()} | {error, #schema_error{}}.
indexed([], _Position, State, _Index, Acc) ->
    {ok, lists:reverse(Acc), State};
indexed([Schema | Rest], Position, State, Index, Acc) ->
    Child = below(integer_to_binary(Index), Position),
    case subschema(Schema, Child, State) of
        {ok, Addr, Built}  -> indexed(Rest, Position, Built, Index + 1,
                                      [Addr | Acc]);
        {error, _} = Error -> Error
    end.

%% Assertions в дочерние schemas не спускаются, поэтому причина ошибки не несёт
%% ни имени keyword, ни локации: их дописывает вызывающий.
-spec assertion(binary(), json()) -> {ok, constraint()} | {error, reason()}.
assertion(<<"type">>, Value) ->
    Names = case Value of
                _ when is_binary(Value) -> [Value];
                _ when is_list(Value)   -> Value;
                _                       -> invalid
            end,
    case type_names(Names) of
        {ok, Types} -> {ok, {type, Types}};
        error       -> {error, {bad_keyword_value, Value}}
    end;
assertion(<<"enum">>, Values) when is_list(Values) ->
    {ok, {enum, Values}};
assertion(<<"const">>, Value) ->
    {ok, {const, Value}};
%% Неположительный multipleOf запрещён метасхемой и отвергается компилятором:
%% иначе делитель 0 дошёл бы до вычисления.
assertion(<<"multipleOf">>, Value) when is_number(Value), Value > 0 ->
    {ok, {multiple_of, Value}};
assertion(<<"maximum">>, Value) when is_number(Value) ->
    {ok, {maximum, Value}};
assertion(<<"exclusiveMaximum">>, Value) when is_number(Value) ->
    {ok, {exclusive_maximum, Value}};
assertion(<<"minimum">>, Value) when is_number(Value) ->
    {ok, {minimum, Value}};
assertion(<<"exclusiveMinimum">>, Value) when is_number(Value) ->
    {ok, {exclusive_minimum, Value}};
%% Опции и запрет на неявное якорение заданы в validator-core.md, раздел
%% «Регулярные выражения». Исходный текст остаётся рядом с re:mp() ради
%% диагностики, а некомпилируемое выражение останавливает компиляцию: это одна
%% из проверок, которые остаются за компилятором и после включения метасхемы.
assertion(<<"pattern">>, Value) when is_binary(Value) ->
    case re:compile(Value, [unicode, dollar_endonly]) of
        {ok, Compiled}  -> {ok, {pattern, {Value, Compiled}}};
        {error, Reason} -> {error, {bad_pattern, Reason}}
    end;
assertion(<<"maxLength">>, Value) ->
    counted(max_length, Value);
assertion(<<"minLength">>, Value) ->
    counted(min_length, Value);
assertion(<<"maxItems">>, Value) ->
    counted(max_items, Value);
assertion(<<"minItems">>, Value) ->
    counted(min_items, Value);
assertion(<<"maxProperties">>, Value) ->
    counted(max_properties, Value);
assertion(<<"minProperties">>, Value) ->
    counted(min_properties, Value);
%% uniqueItems: false — написанный no-op: он остаётся в IR и выпускает
%% собственный unit, поэтому компилятор его не выбрасывает.
assertion(<<"uniqueItems">>, Value) when is_boolean(Value) ->
    {ok, {unique_items, Value}};
assertion(<<"required">>, Value) ->
    case is_list(Value) andalso lists:all(fun is_binary/1, Value) of
        true  -> {ok, {required, Value}};
        false -> {error, {bad_keyword_value, Value}}
    end;
assertion(<<"dependentRequired">>, Value) ->
    Names = fun(List) -> is_list(List) andalso lists:all(fun is_binary/1, List) end,
    case is_map(Value) andalso lists:all(Names, maps:values(Value)) of
        true  -> {ok, {dependent_required, Value}};
        false -> {error, {bad_keyword_value, Value}}
    end;
assertion(_Keyword, Value) ->
    {error, {bad_keyword_value, Value}}.

-spec counted(atom(), json()) -> {ok, constraint()} | {error, reason()}.
counted(Tag, Value) ->
    case non_negative(Value) of
        {ok, Count}     -> {ok, {Tag, Count}};
        {error, Reason} -> {error, Reason}
    end.

%% Метасхема требует здесь nonNegativeInteger, а `type: "integer"` принимает и
%% десятичную форму: `2.0` — то же целое. Слот IR целочисленный, поэтому форма
%% нормализуется на входе, а не размазывается по обработчикам.
-spec non_negative(json()) -> {ok, non_neg_integer()} | {error, reason()}.
non_negative(Value) when is_integer(Value), Value >= 0 ->
    {ok, Value};
non_negative(Value) when is_float(Value), Value >= 0.0, Value == trunc(Value) ->
    {ok, trunc(Value)};
non_negative(Value) ->
    {error, {bad_keyword_value, Value}}.

-spec type_names([json()] | invalid) -> {ok, [json_type()]} | error.
type_names(invalid) ->
    error;
type_names(Names) ->
    Step = fun(_Name, error)      -> error;
              (Name, {ok, Acc})   ->
                   case type_name(Name) of
                       {ok, Type} -> {ok, [Type | Acc]};
                       error      -> error
                   end
           end,
    case lists:foldl(Step, {ok, []}, Names) of
        {ok, Acc} -> {ok, lists:reverse(Acc)};
        error     -> error
    end.

-spec type_name(json()) -> {ok, json_type()} | error.
type_name(<<"null">>)    -> {ok, null};
type_name(<<"boolean">>) -> {ok, boolean};
type_name(<<"object">>)  -> {ok, object};
type_name(<<"array">>)   -> {ok, array};
type_name(<<"number">>)  -> {ok, number};
type_name(<<"integer">>) -> {ok, integer};
type_name(<<"string">>)  -> {ok, string};
type_name(_)             -> error.

-spec artifact(rid(), node_sets(),
               {valid_json_resource_index:resource_anchors(),
                valid_json_resource_index:resource_anchors(),
                #{rid() => boolean()}},
               #{rid() => dialect()}, [uri()]) -> compiled().
artifact(Root, NodeSets, {AnchorSets, DynamicSets, RecursiveSets}, Dialects, Sources) ->
    Resources = maps:map(
                  fun(Rid, Nodes) ->
                          #resource{id               = resource_id(Rid),
                                    dialect          = maps:get(Rid, Dialects),
                                    anchors          = maps:get(Rid, AnchorSets),
                                    dynamic_anchors  = maps:get(Rid, DynamicSets),
                                    recursive_anchor = maps:get(Rid, RecursiveSets),
                                    nodes            = Nodes}
                  end,
                  NodeSets),
    #{root      => Root,
      sources   => Sources,
      resources => Resources}.

-spec resource_id(rid()) -> uri() | undefined.
resource_id(anonymous) -> undefined;
resource_id(Rid)       -> Rid.
