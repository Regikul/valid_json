%% End-to-end golden tests standard output: schema проходит compiler и evaluator,
%% а проверка сравнивает уже публичный JSON результата.
-module(valid_json_output_golden_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DRAFTS, [{<<"2020-12">>,
                  <<"https://json-schema.org/draft/2020-12/schema">>},
                 {<<"2019-09">>,
                  <<"https://json-schema.org/draft/2019-09/schema">>}]).

eunit_wrapper_(Tests) -> {inparallel, Tests}.

%% keywordLocation продолжает written path через $ref, а absolute location
%% строится от фактически применённой target schema.
reference_test_() ->
    [?_assertEqual(
        root(false, Id, <<"errors">>,
             [unit(false, <<"/$ref/type">>,
                   <<Id/binary, "#/$defs/value/type">>,
                   <<"error">>, <<"expected string, got integer">>)]),
        basic(schema(Dialect, Id,
                     #{<<"$defs">> =>
                           #{<<"value">> => #{<<"type">> => <<"string">>}},
                       <<"$ref">> => <<"#/$defs/value">>}),
              1))
     || {Tag, Dialect} <- ?DRAFTS,
        Id <- [id(Tag, <<"reference">>)]].

%% Написанный, но неприменимый к типу instance assertion остаётся unit в дереве,
%% однако detail не несёт и в плоской проекции basic отсутствует.
no_op_test_() ->
    [?_assertEqual(
        root(true, Id, <<"annotations">>, []),
        basic(schema(Dialect, Id, #{<<"minLength">> => 2}), 1))
     || {Tag, Dialect} <- ?DRAFTS,
        Id <- [id(Tag, <<"no-op">>)]].

%% Аннотация успешного keyword внутри провалившейся ветви остаётся в diagnostic
%% tree, но провалившийся schema object её не производит в effective basic.
dropped_annotation_test_() ->
    Branch = #{<<"properties">> => #{<<"a">> => true},
               <<"type">> => <<"string">>},
    [?_assertEqual(
        root(true, Id, <<"annotations">>, []),
        basic(schema(Dialect, Id, #{<<"anyOf">> => [Branch, true]}),
              #{<<"a">> => 1}))
     || {Tag, Dialect} <- ?DRAFTS,
        Id <- [id(Tag, <<"dropped-annotation">>)]].

%% Полный структурный обход видит рекурсивную вторую ветвь, но первая `true`
%% уже определяет verdict anyOf. Все output formats обязаны сохранить успех, а
%% различающиеся JSON-проекции — пройти официальную output schema своего draft.
recursive_decisive_output_test_() ->
    [?_test(assert_recursive_output(Format, Dialect, Id))
     || {Tag, Dialect} <- ?DRAFTS,
        Format <- [flag, basic, detailed, verbose],
        Id <- [id(Tag, <<"recursive-decisive">>)]].

%% Constraint order задан emitter'ом, а не внутренним порядком map. Golden
%% фиксирует наблюдаемый порядок всех одновременно провалившихся assertions.
error_order_test_() ->
    [?_assertEqual(
        root(false, Id, <<"errors">>,
             [unit(false, <<"/type">>, <<Id/binary, "#/type">>,
                   <<"error">>, <<"expected string, got integer">>),
              unit(false, <<"/enum">>, <<Id/binary, "#/enum">>,
                   <<"error">>, <<"value is not one of the enumerated values">>),
              unit(false, <<"/const">>, <<Id/binary, "#/const">>,
                   <<"error">>, <<"value is not equal to the constant">>),
              unit(false, <<"/maximum">>, <<Id/binary, "#/maximum">>,
                   <<"error">>, <<"value is greater than the maximum 5">>)]),
        basic(schema(Dialect, Id,
                     #{<<"maximum">> => 5,
                       <<"const">> => 2,
                       <<"enum">> => [1],
                       <<"type">> => <<"string">>}),
              10))
     || {Tag, Dialect} <- ?DRAFTS,
        Id <- [id(Tag, <<"error-order">>)]].

%% Annotation-only keywords тоже идут в статическом порядке, независимо от map.
annotation_order_test_() ->
    [?_assertEqual(
        root(true, Id, <<"annotations">>,
             [unit(true, <<"/title">>, <<Id/binary, "#/title">>,
                   <<"annotation">>, <<"title">>),
              unit(true, <<"/description">>, <<Id/binary, "#/description">>,
                   <<"annotation">>, <<"description">>),
              unit(true, <<"/default">>, <<Id/binary, "#/default">>,
                   <<"annotation">>, 42)]),
        basic(schema(Dialect, Id,
                     #{<<"default">> => 42,
                       <<"description">> => <<"description">>,
                       <<"title">> => <<"title">>}),
              null))
     || {Tag, Dialect} <- ?DRAFTS,
        Id <- [id(Tag, <<"annotation-order">>)]].

%% Нормативная polygon-форма: silent successes и успешный первый item удалены,
%% цепочка items/source-ref свёрнута, а canonical target сохраняет развилку
%% required/additionalProperties. Порядок соответствует статическому emitter.
detailed_normative_test_() ->
    Point = #{<<"type">> => <<"object">>,
              <<"properties">> =>
                  #{<<"x">> => #{<<"type">> => <<"number">>},
                    <<"y">> => #{<<"type">> => <<"number">>}},
              <<"additionalProperties">> => false,
              <<"required">> => [<<"x">>, <<"y">>]},
    Instance = [#{<<"x">> => 2.5, <<"y">> => 1.3},
                #{<<"x">> => 1, <<"z">> => 6.7}],
    [?_test(
        begin
            Target = nested_vunit(
                       false, <<"/items/$ref">>,
                       <<Id/binary, "#/$defs/point">>, <<"/1">>,
                       none, none,
                       [detail_vunit(
                          false, <<"/items/$ref/required">>,
                          <<Id/binary, "#/$defs/point/required">>, <<"/1">>,
                          <<"error">>,
                          <<"object is missing required property \"y\"">>),
                        detail_vunit(
                          false, <<"/items/$ref/additionalProperties">>,
                          <<Id/binary, "#/$defs/point/additionalProperties">>,
                          <<"/1/z">>, <<"error">>, <<"schema is false">>)]),
            Expected = root(
                         false, Id, <<"errors">>,
                         [detail_vunit(false, <<"/minItems">>,
                                       <<Id/binary, "#/minItems">>, <<>>,
                                       <<"error">>,
                                       <<"array has fewer than 3 items">>),
                          Target]),
            Schema = schema(
                       Dialect, Id,
                       #{<<"$defs">> => #{<<"point">> => Point},
                         <<"type">> => <<"array">>,
                         <<"items">> => #{<<"$ref">> => <<"#/$defs/point">>},
                         <<"minItems">> => 3}),
            assert_detailed(Dialect, Expected, Schema, Instance)
        end)
     || {Tag, Dialect} <- ?DRAFTS,
        Id <- [id(Tag, <<"detailed-normative">>)]].

%% Local effective annotation не теряется при наличии nested annotation;
%% промежуточная schema с единственным child схлопывается.
detailed_annotation_test_() ->
    [?_test(
        begin
            Properties = nested_vunit(
                           true, <<"/properties">>,
                           <<Id/binary, "#/properties">>, <<>>,
                           <<"annotation">>, [<<"a">>],
                           [detail_vunit(
                              true, <<"/properties/a/description">>,
                              <<Id/binary, "#/properties/a/description">>,
                              <<"/a">>, <<"annotation">>, <<"child">>)]),
            Expected = root(
                         true, Id, <<"annotations">>,
                         [Properties,
                          detail_vunit(true, <<"/title">>,
                                       <<Id/binary, "#/title">>, <<>>,
                                       <<"annotation">>, <<"root">>)]),
            Schema = schema(
                       Dialect, Id,
                       #{<<"properties">> =>
                             #{<<"a">> => #{<<"description">> => <<"child">>}},
                         <<"title">> => <<"root">>}),
            assert_detailed(Dialect, Expected, Schema, #{<<"a">> => 1})
        end)
     || {Tag, Dialect} <- ?DRAFTS,
        Id <- [id(Tag, <<"detailed-annotations">>)]].

%% No-op и diagnostic annotation failed anyOf branch не являются effective
%% detailed results; успешный root остаётся без пустого annotations array.
detailed_empty_test_() ->
    Failed = #{<<"title">> => <<"dropped">>, <<"type">> => <<"string">>},
    [?_test(
        assert_detailed(
          Dialect, plain_root(true, Id),
          schema(Dialect, Id,
                 #{<<"minLength">> => 2,
                   <<"anyOf">> => [Failed, true]}),
          #{<<"a">> => 1}))
     || {Tag, Dialect} <- ?DRAFTS,
        Id <- [id(Tag, <<"detailed-empty">>)]].

%% Failed `not` отбрасывает successful inner results и остаётся leaf со своей
%% локальной ошибкой.
detailed_not_test_() ->
    [?_test(
        assert_detailed(
          Dialect,
          root(false, Id, <<"errors">>,
               [detail_vunit(false, <<"/not">>, <<Id/binary, "#/not">>, <<>>,
                             <<"error">>, <<"value matches the subschema">>)]),
          schema(Dialect, Id,
                 #{<<"not">> => #{<<"type">> => <<"integer">>,
                                    <<"title">> => <<"inside">>}}),
          1))
     || {Tag, Dialect} <- ?DRAFTS,
        Id <- [id(Tag, <<"detailed-not">>)]].

%% Короткий normative verbose example: silent successful assertion виден,
%% successful boolean под properties не создаёт служебный уровень, а локальная
%% ошибка applicator сосуществует с ошибкой применённой boolean-схемы.
verbose_normative_test_() ->
    Keywords = #{<<"type">> => <<"object">>,
                 <<"properties">> => #{<<"validProp">> => true},
                 <<"additionalProperties">> => false},
    Instance = #{<<"validProp">> => 5,
                 <<"disallowedProp">> => <<"value">>},
    [?_test(
        assert_verbose(
          Dialect,
          root(false, Id, <<"errors">>,
               [vunit(true, <<"/type">>, <<Id/binary, "#/type">>, <<>>),
                detail_vunit(true, <<"/properties">>,
                             <<Id/binary, "#/properties">>, <<>>,
                             <<"annotation">>, [<<"validProp">>]),
                nested_vunit(
                  false, <<"/additionalProperties">>,
                  <<Id/binary, "#/additionalProperties">>, <<>>,
                  <<"error">>,
                  <<"additional object properties do not match the schema">>,
                  [detail_vunit(false, <<"/additionalProperties">>,
                                <<Id/binary, "#/additionalProperties">>,
                                <<"/disallowedProp">>, <<"error">>,
                                <<"schema is false">>)])]),
          schema(Dialect, Id, Keywords), Instance))
     || {Tag, Dialect} <- ?DRAFTS,
        Id <- [id(Tag, <<"verbose-normative">>)]].

%% Reference остаётся двумя уровнями: physical `$ref` и canonical target
%% schema. `$defs` виден как успешный compile-time keyword marker.
verbose_reference_test_() ->
    [?_test(
        begin
            Type = detail_vunit(false, <<"/$ref/type">>,
                                <<Id/binary, "#/$defs/value/type">>, <<>>,
                                <<"error">>, <<"expected string, got integer">>),
            Target = nested_vunit(false, <<"/$ref">>,
                                  <<Id/binary, "#/$defs/value">>, <<>>,
                                  none, none, [Type]),
            Ref = nested_vunit(false, <<"/$ref">>,
                               <<Id/binary, "#/$ref">>, <<>>,
                               none, none, [Target]),
            Expected = root(false, Id, <<"errors">>,
                            [vunit(true, <<"/$defs">>,
                                   <<Id/binary, "#/$defs">>, <<>>),
                             Ref]),
            Schema = schema(Dialect, Id,
                            #{<<"$defs">> =>
                                  #{<<"value">> => #{<<"type">> => <<"string">>}},
                              <<"$ref">> => <<"#/$defs/value">>}),
            assert_verbose(Dialect, Expected, Schema, 1)
        end)
     || {Tag, Dialect} <- ?DRAFTS,
        Id <- [id(Tag, <<"verbose-reference">>)]].

%% Неприменимый к типу assertion остаётся успешным silent unit в verbose.
verbose_no_op_test_() ->
    [?_test(
        assert_verbose(
          Dialect,
          root(true, Id, <<"annotations">>,
               [vunit(true, <<"/minLength">>,
                      <<Id/binary, "#/minLength">>, <<>>)]),
          schema(Dialect, Id, #{<<"minLength">> => 2}), 1))
     || {Tag, Dialect} <- ?DRAFTS,
        Id <- [id(Tag, <<"verbose-no-op">>)]].

%% Успешная внутренняя schema, опровергнутая `not`, не исчезает: её silent
%% assertion и annotation лежат в `errors` провалившегося родителя.
verbose_not_test_() ->
    [?_test(
        begin
            Not = nested_vunit(
                    false, <<"/not">>, <<Id/binary, "#/not">>, <<>>,
                    <<"error">>, <<"value matches the subschema">>,
                    [vunit(true, <<"/not/type">>,
                           <<Id/binary, "#/not/type">>, <<>>),
                     detail_vunit(true, <<"/not/title">>,
                                  <<Id/binary, "#/not/title">>, <<>>,
                                  <<"annotation">>, <<"inside">>)]),
            assert_verbose(
              Dialect, root(false, Id, <<"errors">>, [Not]),
              schema(Dialect, Id,
                     #{<<"not">> => #{<<"type">> => <<"integer">>,
                                        <<"title">> => <<"inside">>}}),
              1)
        end)
     || {Tag, Dialect} <- ?DRAFTS,
        Id <- [id(Tag, <<"verbose-not">>)]].

%% Diagnostic annotation провалившейся anyOf-ветви остаётся в полном дереве,
%% хотя effective basic её отбрасывает. Коллекция называется по valid родителя,
%% поэтому invalid branch лежит в annotations успешного `anyOf`.
verbose_dropped_annotation_test_() ->
    BranchSchema = #{<<"properties">> => #{<<"a">> => true},
                     <<"type">> => <<"string">>},
    [?_test(
        begin
            FailedBranch = nested_vunit(
                             false, <<"/anyOf/0">>,
                             <<Id/binary, "#/anyOf/0">>, <<>>,
                             none, none,
                             [detail_vunit(false, <<"/anyOf/0/type">>,
                                           <<Id/binary, "#/anyOf/0/type">>, <<>>,
                                           <<"error">>,
                                           <<"expected string, got object">>),
                              detail_vunit(true, <<"/anyOf/0/properties">>,
                                           <<Id/binary, "#/anyOf/0/properties">>,
                                           <<>>, <<"annotation">>, [<<"a">>])]),
            AnyOf = nested_vunit(true, <<"/anyOf">>,
                                 <<Id/binary, "#/anyOf">>, <<>>,
                                 none, none, [FailedBranch]),
            assert_verbose(
              Dialect, root(true, Id, <<"annotations">>, [AnyOf]),
              schema(Dialect, Id, #{<<"anyOf">> => [BranchSchema, true]}),
              #{<<"a">> => 1})
        end)
     || {Tag, Dialect} <- ?DRAFTS,
        Id <- [id(Tag, <<"verbose-dropped-annotation">>)]].

schema(Dialect, Id, Keywords) ->
    Keywords#{<<"$schema">> => Dialect, <<"$id">> => Id}.

id(Tag, Case) ->
    <<"https://example.com/output/", Tag/binary, "/", Case/binary>>.

basic(Schema, Instance) ->
    Dialect = maps:get(<<"$schema">>, Schema),
    %% Golden fixtures статичны и проверяют только проекцию output.
    {ok, Artifact} =
        valid_json_compile:compile(valid_json_store:new([]), Schema,
                                   [{default_dialect, Dialect},
                                    {schema_validation, trusted}]),
    valid_json_core:validate(Artifact, Instance, [{output, basic}]).

assert_detailed(Dialect, Expected, Schema, Instance) ->
    assert_structured(detailed, Dialect, Expected, Schema, Instance).

assert_verbose(Dialect, Expected, Schema, Instance) ->
    assert_structured(verbose, Dialect, Expected, Schema, Instance).

assert_recursive_output(Format, Dialect, Id) ->
    Schema = schema(Dialect, Id,
                    #{<<"anyOf">> => [true, #{<<"$ref">> => <<"#">>}]}),
    {ok, Artifact} =
        valid_json_compile:compile(valid_json_store:new([]), Schema,
                                   [{default_dialect, Dialect},
                                    {schema_validation, trusted}]),
    {ok, #{<<"valid">> := true} = Actual} =
        valid_json_core:validate(Artifact, 1, [{output, Format}]),
    assert_output_schema(Dialect, Actual).

assert_structured(Format, Dialect, {ok, Expected}, Schema, Instance) ->
    {ok, Artifact} =
        valid_json_compile:compile(valid_json_store:new([]), Schema,
                                   [{default_dialect, Dialect},
                                    {schema_validation, trusted}]),
    {ok, Actual} = valid_json_core:validate(Artifact, Instance, [{output, Format}]),
    ?assertEqual(Expected, Actual),
    assert_output_schema(Dialect, Actual).

assert_output_schema(Dialect, Actual) ->
    OutputSchema = read_json(filename:join(output_dir(Dialect),
                                           "output-schema.json")),
    Uri = maps:get(<<"$id">>, OutputSchema),
    {ok, Uri, Store} =
        valid_json_store:add(valid_json_store:new([]), Uri, OutputSchema),
    Wrapper = #{<<"$schema">> => Dialect, <<"$ref">> => Uri},
    {ok, Verifier} =
        valid_json_compile:compile(Store, Wrapper,
                                   [{default_dialect, Dialect},
                                    {schema_validation, trusted}]),
    ?assertEqual({ok, #{<<"valid">> => true}},
                 valid_json_core:validate(Verifier, Actual, [{output, flag}])).

root(Valid, Id, Key, Nested) ->
    {ok, #{<<"valid">>                    => Valid,
           <<"keywordLocation">>          => <<>>,
           <<"absoluteKeywordLocation">>  => <<Id/binary, "#">>,
           <<"instanceLocation">>         => <<>>,
           Key                             => Nested}}.

plain_root(Valid, Id) ->
    {ok, vunit(Valid, <<>>, <<Id/binary, "#">>, <<>>)}.

unit(Valid, Keyword, Absolute, DetailKey, Detail) ->
    #{<<"valid">>                    => Valid,
      <<"keywordLocation">>          => Keyword,
      <<"absoluteKeywordLocation">>  => Absolute,
      <<"instanceLocation">>         => <<>>,
      DetailKey                       => Detail}.

vunit(Valid, Keyword, Absolute, Instance) ->
    #{<<"valid">>                    => Valid,
      <<"keywordLocation">>          => Keyword,
      <<"absoluteKeywordLocation">>  => Absolute,
      <<"instanceLocation">>         => Instance}.

detail_vunit(Valid, Keyword, Absolute, Instance, DetailKey, Detail) ->
    (vunit(Valid, Keyword, Absolute, Instance))#{DetailKey => Detail}.

nested_vunit(Valid, Keyword, Absolute, Instance, DetailKey, Detail, Nested) ->
    Unit = case DetailKey of
               none -> vunit(Valid, Keyword, Absolute, Instance);
               _    -> detail_vunit(Valid, Keyword, Absolute, Instance,
                                    DetailKey, Detail)
           end,
    Unit#{nested_key(Valid) => Nested}.

nested_key(false) -> <<"errors">>;
nested_key(true)  -> <<"annotations">>.

read_json(Path) ->
    {ok, Binary} = file:read_file(Path),
    json:decode(Binary).

output_dir(<<"https://json-schema.org/draft/2020-12/schema">>) ->
    output_dir("draft2020-12");
output_dir(<<"https://json-schema.org/draft/2019-09/schema">>) ->
    output_dir("draft2019-09");
output_dir(Dir) ->
    Relative = ["test", "fixtures", "json-schema-test-suite", "output-tests", Dir],
    Candidates =
        case code:lib_dir(valid_json) of
            {error, _} -> [filename:join(Relative)];
            AppDir     -> [filename:join([AppDir | Relative]), filename:join(Relative)]
        end,
    case lists:search(fun filelib:is_dir/1, Candidates) of
        {value, Path} -> Path;
        false         -> erlang:error({output_suite_not_found, Candidates})
    end.
