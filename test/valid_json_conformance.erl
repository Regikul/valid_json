%% Runner поверх закреплённого JSON Schema Test Suite. Один генератор берёт один
%% файл сьюта и прогоняет его на всех поддерживаемых диалектах.
-module(valid_json_conformance).

-include_lib("eunit/include/eunit.hrl").

-define(DIALECTS, [{"draft2020-12", <<"https://json-schema.org/draft/2020-12/schema">>},
                   {"draft2019-09", <<"https://json-schema.org/draft/2019-09/schema">>}]).

%% Файл подключается целиком и только когда его схемы компилируются полностью.
%% Из applicator-файлов ждут своего: `not.json` — `unevaluatedProperties`,
%% `additionalProperties.json` — `dependentSchemas` и `propertyNames`,
%% `uniqueItems.json` — array applicators.
-define(FILES, ["boolean_schema.json", "type.json", "const.json", "enum.json",
                "multipleOf.json",
                "maximum.json", "exclusiveMaximum.json",
                "minimum.json", "exclusiveMinimum.json",
                "maxLength.json", "minLength.json", "pattern.json",
                "maxItems.json", "minItems.json",
                "maxProperties.json", "minProperties.json",
                "required.json", "dependentRequired.json",
                "properties.json", "patternProperties.json",
                "allOf.json", "anyOf.json", "oneOf.json",
                "if-then-else.json"]).

%% Объявленные расхождения основного набора: okf/testing/conformance-policy.md,
%% раздел «Известные расхождения». Группа исключается поимённо, чтобы остальные
%% группы файла продолжали проверяться, а сам список оставался читаемым.
-define(EXCLUDED,
        [{"pattern.json",
          <<"pattern with Unicode property escape requires unicode mode">>},
         {"patternProperties.json",
          <<"patternProperties with Unicode property escape">>}]).

%% Ожидаемый размер прогона: {групп, cases}. Число закреплено, чтобы прогон, в
%% котором сьют не нашёлся или файл перестал читаться, не мог оказаться зелёным
%% из-за того, что тестов просто не осталось. Оно меняется вместе с ?FILES и
%% ?EXCLUDED, и менять его иначе нельзя.
-define(CENSUS, {268, 980}).

validation_test_() ->
    Tests = [file_tests(Dir, Dialect, File)
             || {Dir, Dialect} <- ?DIALECTS, File <- ?FILES],
    [census_test(Tests) | Tests].

%% Перепись идёт по уже построенным тестам, а не по второму обходу сьюта:
%% считается ровно то, что будет запущено.
census_test(Tests) ->
    {"census", ?_assertEqual(?CENSUS, lists:foldl(fun count_file/2, {0, 0}, Tests))}.

count_file({_Name, Groups}, {Files, Cases}) ->
    {Files + length(Groups), Cases + lists:sum([count_group(G) || G <- Groups])}.

%% Группа, схема которой не скомпилировалась, выпускает один падающий тест
%% вместо своих cases, поэтому её вклад тоже виден в переписи.
count_group({_Title, Cases}) when is_list(Cases)     -> length(Cases);
count_group({_Title, Fun}) when is_function(Fun, 0)  -> 1.

file_tests(Dir, Dialect, File) ->
    Path = filename:join([suite_dir(), Dir, File]),
    {filename:join(Dir, File),
     [group_tests(Dialect, Group) || Group <- read_groups(Path), included(File, Group)]}.

included(File, #{<<"description">> := Description}) ->
    not lists:member({File, Description}, ?EXCLUDED).

group_tests(Dialect, #{<<"description">> := Description,
                       <<"schema">> := Schema,
                       <<"tests">> := Cases}) ->
    Title = unicode:characters_to_list(Description),
    case valid_json_compile:compile(Schema, Dialect) of
        {ok, Compiled} ->
            {Title, [case_test(Compiled, Case) || Case <- Cases]};
        {error, Reason} ->
            {Title, fun() -> erlang:error({compile_failed, Reason}) end}
    end.

case_test(Compiled, #{<<"description">> := Description,
                      <<"data">> := Data,
                      <<"valid">> := Expected}) ->
    Title = unicode:characters_to_list(Description),
    {Title,
     fun() ->
         ?assertEqual({ok, #{<<"valid">> => Expected}},
                      valid_json:validate(Compiled, Data, [{output, flag}]))
     end}.

read_groups(Path) ->
    {ok, Binary} = file:read_file(Path),
    json:decode(Binary).

suite_dir() ->
    Relative = ["test", "fixtures", "json-schema-test-suite", "tests"],
    Candidates =
        case code:lib_dir(valid_json) of
            {error, _} -> [filename:join(Relative)];
            AppDir     -> [filename:join([AppDir | Relative]), filename:join(Relative)]
        end,
    case lists:search(fun filelib:is_dir/1, Candidates) of
        {value, Dir} -> Dir;
        false        -> erlang:error({suite_not_found, Candidates})
    end.
