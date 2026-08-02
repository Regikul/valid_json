%% Runner поверх закреплённого JSON Schema Test Suite. Один генератор берёт один
%% файл сьюта и прогоняет его на всех поддерживаемых диалектах.
-module(valid_json_conformance).

-include_lib("eunit/include/eunit.hrl").

-define(DIALECTS, [{"draft2020-12", <<"https://json-schema.org/draft/2020-12/schema">>},
                   {"draft2019-09", <<"https://json-schema.org/draft/2019-09/schema">>}]).

%% Файл подключается, когда компилируются схемы почти всех его групп; единичные
%% группы, написанные через keywords следующих фаз, перечислены в ?PENDING.
%% `ref.json` и `defs.json` подключаются в P6: у обоих есть группа с `$ref` на
%% корневую метасхему, а она сама компилируется не раньше той фазы, и в
%% `defs.json` эта группа единственная.
-define(FILES, ["boolean_schema.json", "type.json", "const.json", "enum.json",
                "multipleOf.json",
                "maximum.json", "exclusiveMaximum.json",
                "minimum.json", "exclusiveMinimum.json",
                "maxLength.json", "minLength.json", "pattern.json",
                "maxItems.json", "minItems.json",
                "maxProperties.json", "minProperties.json",
                "required.json", "dependentRequired.json",
                "properties.json", "patternProperties.json",
                "additionalProperties.json", "propertyNames.json",
                "contains.json", "maxContains.json", "minContains.json",
                "allOf.json", "anyOf.json", "oneOf.json",
                "if-then-else.json", "dependentSchemas.json",
                "default.json", "not.json",
                "anchor.json", "refRemote.json", "infinite-loop-detection.json",
                "unevaluatedProperties.json",
                "optional/id.json", "optional/unknownKeyword.json"]).

%% Files, подключённые только к одному dialect: раскладка второго ждёт своей
%% фазы. `prefixItems.json` в Draft 2019-09 не существует вовсе, а тамошние
%% `uniqueItems.json` и `items.json` опираются на array-form `items` и
%% `additionalItems` из P6. По той же причине там отложен и весь
%% `unevaluatedItems.json`: из двадцати шести групп восемнадцать написаны через
%% array-form `items`, `additionalItems` или recursive keywords, и ?PENDING в
%% таком объёме перестал бы читаться. Обоих файлов `dynamicRef.json` в
%% Draft 2019-09 нет вовсе: keyword появился только в 2020-12.
-define(DIALECT_FILES, [{"draft2020-12",
                         ["prefixItems.json", "uniqueItems.json", "items.json",
                          "unevaluatedItems.json", "dynamicRef.json",
                          "optional/dynamicRef.json"]}]).

%% Группы подключённых files, которые ждут keywords следующих фаз: их схемы пока
%% не компилируются вовсе. Фаза, снимающая группу, вычёркивает свою строку
%% вместе с работой — так же, как отмечает выполненный пункт роадмапа.
-define(PENDING,
        [%% P6, recursive keywords Draft 2019-09
         {"draft2019-09", "unevaluatedProperties.json",
          <<"unevaluatedProperties with $recursiveRef">>}]).

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
-define(CENSUS, {572, 1902}).

%% Сьют адресует свои remote documents относительно этого base, повторяя в URI
%% раскладку директории `remotes`. Число документов закреплено по той же
%% причине, что и перепись: потерянная директория не должна давать зелёный
%% прогон, в котором remote refs просто перестали проверяться.
-define(REMOTE_BASE, <<"http://localhost:1234/">>).
-define(REMOTES, 41).

validation_test_() ->
    {Loaded, Store} = remotes_store(),
    Tests = [file_tests(Store, Dir, Dialect, File)
             || {Dir, Dialect} <- ?DIALECTS, File <- files(Dir)],
    [remotes_test(Loaded), census_test(Tests), {inparallel, Tests}].

%% Все remote documents регистрируются заранее и целиком: во время прогона сети
%% нет, а замыкание берёт из store только то, что достижимо по `$ref`. Сам
%% `validate/3` store не принимает вовсе — artifact уже толстый.
remotes_store() ->
    Files = filelib:wildcard(filename:join(remotes_dir(), "**/*.json")),
    Entries = [{remote_uri(File), read_json(File)} || File <- Files],
    {ok, _Names, Store} = valid_json_store:add(valid_json_store:new([]), Entries),
    {length(Files), Store}.

remotes_test(Loaded) ->
    {"remotes", ?_assertEqual(?REMOTES, Loaded)}.

remote_uri(Path) ->
    Relative = string:prefix(Path, remotes_dir() ++ "/"),
    unicode:characters_to_binary([?REMOTE_BASE, Relative]).

%% Общий список плюс files, подключённые только к этому dialect.
files(Dir) ->
    ?FILES ++ proplists:get_value(Dir, ?DIALECT_FILES, []).

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

file_tests(Store, Dir, Dialect, File) ->
    Path = filename:join([tests_dir(), Dir, File]),
    {filename:join(Dir, File),
     [group_tests(Store, Dialect, Group)
      || Group <- read_json(Path), included(Dir, File, Group)]}.

%% Расхождение объявлено для обоих dialects сразу, а фазы группы ждут порознь:
%% один и тот же keyword появляется в них не одновременно.
included(Dir, File, #{<<"description">> := Description}) ->
    not lists:member({File, Description}, ?EXCLUDED) andalso
        not lists:member({Dir, File, Description}, ?PENDING).

%% Dialect директории задаётся опцией, а не подставляется вместо `$schema`:
%% схема, которая называет свой dialect сама, остаётся сильнее раскладки сьюта.
group_tests(Store, Dialect, #{<<"description">> := Description,
                              <<"schema">> := Schema,
                              <<"tests">> := Cases}) ->
    Title = unicode:characters_to_list(Description),
    case valid_json_compile:compile(Store, Schema, [{default_dialect, Dialect}]) of
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

read_json(Path) ->
    {ok, Binary} = file:read_file(Path),
    json:decode(Binary).

tests_dir() ->
    filename:join(suite_dir(), "tests").

remotes_dir() ->
    filename:join(suite_dir(), "remotes").

suite_dir() ->
    Relative = ["test", "fixtures", "json-schema-test-suite"],
    Candidates =
        case code:lib_dir(valid_json) of
            {error, _} -> [filename:join(Relative)];
            AppDir     -> [filename:join([AppDir | Relative]), filename:join(Relative)]
        end,
    case lists:search(fun filelib:is_dir/1, Candidates) of
        {value, Dir} -> Dir;
        false        -> erlang:error({suite_not_found, Candidates})
    end.
