%% Output builder проверяется на собственной границе: вход — дерево units,
%% выход — JSON выбранного формата. Evaluator сюда не участвует.
-module(valid_json_output_tests).

-include_lib("eunit/include/eunit.hrl").
-include("valid_json_core.hrl").

%% Тесты модуля независимы, поэтому eunit прогоняет их параллельно.
eunit_wrapper_(Tests) -> {inparallel, Tests}.

flag_test_() ->
    [?_assertEqual(#{<<"valid">> => true}, project(flag, root(true, []))),
     %% flag не смотрит на units даже когда они собраны.
     ?_assertEqual(#{<<"valid">> => false},
                   project(flag, root(false, [error_unit([<<"type">>], [])])))].

%% Провал перечисляет ошибки, успех — аннотации. Ключ присутствует всегда, хотя
%% бы пустым: output schema требует его при обеих валидностях.
basic_shape_test_() ->
    [?_assertEqual(projected(true, <<"annotations">>, []),
                   project(basic, root(true, []))),
     ?_assertEqual(projected(false, <<"errors">>,
                             [#{<<"valid">>            => false,
                                <<"keywordLocation">>  => <<"/type">>,
                                <<"instanceLocation">> => <<>>,
                                <<"error">> => <<"expected string, got integer">>}]),
                   project(basic, root(false, [error_unit([<<"type">>], [])])))].

%% Корневой unit печатается самим объектом результата: своих локаций он не
%% теряет, а собственный detail стоит рядом с ключом коллекции. Такой detail
%% бывает только у boolean-схемы, у которой нет ни одного keyword.
basic_root_test_() ->
    Boolean = (root(false, []))#output_unit{detail = {error, <<"schema is false">>}},
    [?_assertEqual(#{<<"valid">>            => false,
                     <<"keywordLocation">>  => <<>>,
                     <<"instanceLocation">> => <<>>,
                     <<"error">>            => <<"schema is false">>,
                     <<"errors">>           => []},
                   project(basic, Boolean))].

%% Локации печатаются по тем же правилам, что и вне output: сегменты идут от
%% последнего к первому, "~" и "/" экранируются.
basic_location_test_() ->
    Unit = error_unit([<<"type">>, <<"~a/b">>, <<"properties">>], [<<"~a/b">>]),
    #{<<"errors">> := [Printed]} = project(basic, root(false, [Unit])),
    [?_assertEqual(<<"/properties/~0a~1b/type">>,
                   maps:get(<<"keywordLocation">>, Printed)),
     ?_assertEqual(<<"/~0a~1b">>, maps:get(<<"instanceLocation">>, Printed)),
     %% Анонимный resource URI не синтезирует, поэтому ключа просто нет.
     ?_assertNot(is_map_key(<<"absoluteKeywordLocation">>, Printed))].

%% Ссылка уводит в другой resource, и тогда абсолютная локация печатается
%% отдельным ключом в URI fragment identifier form.
basic_absolute_test_() ->
    Unit = (error_unit([<<"type">>], []))#output_unit{
             absolute_location = {<<"https://example.com/s">>,
                                  [<<"type">>, <<"~a/b">>, <<"properties">>]}},
    #{<<"errors">> := [Printed]} = project(basic, root(false, [Unit])),
    ?_assertEqual(<<"https://example.com/s#/properties/~0a~1b/type">>,
                  maps:get(<<"absoluteKeywordLocation">>, Printed)).

%% В плоский список попадает то, что несёт detail: успех без аннотации остаётся
%% в дереве ради verbose, но в basic не показывается.
basic_selection_test_() ->
    Silent     = unit(true, [<<"type">>], none),
    Annotated  = unit(true, [<<"title">>], {annotation, <<"note">>}),
    Failed     = error_unit([<<"const">>], []),
    [?_assertEqual(projected(true, <<"annotations">>, []),
                   project(basic, root(true, [Silent]))),
     ?_assertEqual([#{<<"valid">>            => true,
                      <<"keywordLocation">>  => <<"/title">>,
                      <<"instanceLocation">> => <<>>,
                      <<"annotation">>       => <<"note">>}],
                   maps:get(<<"annotations">>,
                            project(basic, root(true, [Silent, Annotated])))),
     %% При провале успешные соседи в errors не попадают.
     ?_assertMatch([#{<<"keywordLocation">> := <<"/const">>}],
                   maps:get(<<"errors">>,
                            project(basic, root(false, [Silent, Annotated, Failed]))))].

%% Провалившаяся подсхема не производит аннотаций ни своими keywords, ни
%% keywords своих подсхем, поэтому обход в неё не спускается. При провале
%% корня обходится всё: units успешных ветвей остаются диагностическими.
basic_dropped_test_() ->
    Annotated = unit(true, [<<"properties">>, <<"0">>, <<"anyOf">>], {annotation, [<<"a">>]}),
    Failed    = error_unit([<<"type">>, <<"0">>, <<"anyOf">>], []),
    Branch    = branch(false, [<<"0">>, <<"anyOf">>], [], none, [Annotated, Failed]),
    Applied   = fun(Valid) ->
                        unit(Valid, [<<"anyOf">>], detail(Valid), [], [Branch])
                end,
    [?_assertEqual([], maps:get(<<"annotations">>,
                                project(basic, root(true, [Applied(true)])))),
     ?_assertMatch([#{<<"keywordLocation">> := <<"/anyOf">>},
                    #{<<"keywordLocation">> := <<"/anyOf/0/type">>}],
                   maps:get(<<"errors">>,
                            project(basic, root(false, [Applied(false)]))))].

detail(true)  -> none;
detail(false) -> {error, <<"value does not match any subschema">>}.

%% Дерево разворачивается целиком и в порядке обхода. Unit ветви своего
%% сообщения не имеет и в плоский список не попадает, а провалившаяся
%% boolean-схема попадает: сообщение есть только у неё самой.
basic_depth_test_() ->
    Leaf   = error_unit([<<"type">>, <<"a">>, <<"properties">>], [<<"a">>]),
    Object = branch(false, [<<"a">>, <<"properties">>], [<<"a">>], none, [Leaf]),
    Boolean = branch(false, [<<"b">>, <<"properties">>], [<<"b">>],
                     {error, <<"schema is false">>}, []),
    Applied = unit(false, [<<"properties">>], {error, <<"properties failed">>}, [],
                   [Object, Boolean]),
    #{<<"errors">> := Printed} = project(basic, root(false, [Applied])),
    ?_assertEqual([{<<"/properties">>, <<>>},
                   {<<"/properties/a/type">>, <<"/a">>},
                   {<<"/properties/b">>, <<"/b">>}],
                  [{maps:get(<<"keywordLocation">>, Unit),
                    maps:get(<<"instanceLocation">>, Unit)} || Unit <- Printed]).

project(Format, #output_unit{valid = Valid} = Root) ->
    valid_json_output:project(Format, #eval_result{valid     = Valid,
                                                   evaluated = valid_json_evaluated:neutral(),
                                                   units     = [Root]}).

%% Корневой unit стоит на пустых локациях: вычисление начинается от корня схемы
%% и корня инстанса. Собственного detail у schema object нет.
root(Valid, Nested) ->
    branch(Valid, [], [], none, Nested).

%% Unit самого node: своего сегмента у него нет, он стоит там же, где схема.
branch(Valid, Keywords, Instance, Detail, Nested) ->
    #output_unit{valid             = Valid,
                 keyword_location  = Keywords,
                 absolute_location = undefined,
                 instance_location = Instance,
                 detail            = Detail,
                 nested            = Nested}.

projected(Valid, Key, Units) ->
    #{<<"valid">>            => Valid,
      <<"keywordLocation">>  => <<>>,
      <<"instanceLocation">> => <<>>,
      Key                    => Units}.

error_unit(Keywords, Instance) ->
    unit(false, Keywords, {error, <<"expected string, got integer">>}, Instance, []).

unit(Valid, Keywords, Detail) ->
    unit(Valid, Keywords, Detail, [], []).

unit(Valid, Keywords, Detail, Instance, Nested) ->
    branch(Valid, Keywords, Instance, Detail, Nested).
