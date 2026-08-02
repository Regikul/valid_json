%% Output builder проверяется на собственной границе: вход — дерево units,
%% выход — JSON выбранного формата. Evaluator сюда не участвует.
-module(valid_json_output_tests).

-include_lib("eunit/include/eunit.hrl").
-include("valid_json_core.hrl").

%% Тесты модуля независимы, поэтому eunit прогоняет их параллельно.
eunit_wrapper_(Tests) -> {inparallel, Tests}.

flag_test_() ->
    [?_assertEqual(#{<<"valid">> => true}, project(flag, true, [])),
     %% flag не смотрит на units даже когда они собраны.
     ?_assertEqual(#{<<"valid">> => false},
                   project(flag, false, [error_unit([<<"type">>], [])]))].

%% Провал перечисляет ошибки, успех — аннотации. Ключ присутствует всегда:
%% output schema требует errors или error при valid = false.
basic_shape_test_() ->
    [?_assertEqual(root(true, <<"annotations">>, []), project(basic, true, [])),
     ?_assertEqual(root(false, <<"errors">>,
                        [#{<<"valid">>            => false,
                           <<"keywordLocation">>  => <<"/type">>,
                           <<"instanceLocation">> => <<>>,
                           <<"error">>            => <<"expected string, got integer">>}]),
                   project(basic, false, [error_unit([<<"type">>], [])]))].

%% Локации печатаются по тем же правилам, что и вне output: сегменты идут от
%% последнего к первому, "~" и "/" экранируются.
basic_location_test_() ->
    Unit = error_unit([<<"type">>, <<"~a/b">>, <<"properties">>], [<<"~a/b">>]),
    #{<<"errors">> := [Printed]} = project(basic, false, [Unit]),
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
    #{<<"errors">> := [Printed]} = project(basic, false, [Unit]),
    ?_assertEqual(<<"https://example.com/s#/properties/~0a~1b/type">>,
                  maps:get(<<"absoluteKeywordLocation">>, Printed)).

%% В плоский список попадают только несущие units: успех без аннотации остаётся
%% в дереве ради verbose, но в basic не показывается.
basic_selection_test_() ->
    Silent     = unit(true, [<<"type">>], none),
    Annotated  = unit(true, [<<"title">>], {annotation, <<"note">>}),
    Failed     = error_unit([<<"const">>], []),
    [?_assertEqual(root(true, <<"annotations">>, []), project(basic, true, [Silent])),
     ?_assertEqual([#{<<"valid">>            => true,
                      <<"keywordLocation">>  => <<"/title">>,
                      <<"instanceLocation">> => <<>>,
                      <<"annotation">>       => <<"note">>}],
                   maps:get(<<"annotations">>,
                            project(basic, true, [Silent, Annotated]))),
     %% При провале успешные соседи в errors не попадают.
     ?_assertMatch([#{<<"keywordLocation">> := <<"/const">>}],
                   maps:get(<<"errors">>,
                            project(basic, false, [Silent, Annotated, Failed])))].

project(Format, Valid, Units) ->
    valid_json_output:project(Format, #eval_result{valid     = Valid,
                                                   evaluated = valid_json_evaluated:neutral(),
                                                   units     = Units}).

root(Valid, Key, Nested) ->
    #{<<"valid">>            => Valid,
      <<"keywordLocation">>  => <<>>,
      <<"instanceLocation">> => <<>>,
      Key                    => Nested}.

error_unit(Keywords, Instance) ->
    unit(false, Keywords, {error, <<"expected string, got integer">>}, Instance).

unit(Valid, Keywords, Detail) ->
    unit(Valid, Keywords, Detail, []).

unit(Valid, Keywords, Detail, Instance) ->
    #output_unit{valid             = Valid,
                 keyword_location  = Keywords,
                 absolute_location = undefined,
                 instance_location = Instance,
                 detail            = Detail,
                 nested            = []}.
