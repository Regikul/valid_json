%% Runner поверх закреплённого JSON Schema Test Suite. Один генератор берёт один
%% файл сьюта и прогоняет его на всех поддерживаемых диалектах.
-module(valid_json_conformance).

-include_lib("eunit/include/eunit.hrl").

-define(DIALECTS, [{"draft2020-12", <<"https://json-schema.org/draft/2020-12/schema">>},
                   {"draft2019-09", <<"https://json-schema.org/draft/2019-09/schema">>}]).

%% Файл подключается, когда компилируются схемы почти всех его групп; единичные
%% группы, написанные через keywords следующих фаз, перечислены в ?PENDING.
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
                "items.json", "uniqueItems.json",
                "contains.json", "maxContains.json", "minContains.json",
                "allOf.json", "anyOf.json", "oneOf.json",
                "if-then-else.json", "dependentSchemas.json",
                "default.json", "not.json", "format.json", "content.json",
                "vocabulary.json",
                "ref.json", "defs.json",
                "anchor.json", "refRemote.json", "infinite-loop-detection.json",
                "unevaluatedProperties.json", "unevaluatedItems.json",
                "optional/id.json", "optional/unknownKeyword.json",
                "optional/cross-draft.json",
                "optional/format/date.json", "optional/format/time.json",
                "optional/format/date-time.json",
                "optional/format/duration.json"]).

%% Files, существующие только в одном dialect: `prefixItems.json` появился
%% вместе с самим keyword в Draft 2020-12, обоих файлов `dynamicRef.json` в
%% Draft 2019-09 нет по той же причине, а обязательный `recursiveRef.json`,
%% наоборот, существует только в Draft 2019-09. Files, отложенные до своей фазы,
%% здесь не перечисляются: для этого есть ?PENDING.
-define(DIALECT_FILES, [{"draft2020-12",
                         ["prefixItems.json", "dynamicRef.json",
                          "optional/dynamicRef.json"]},
                        {"draft2019-09", ["recursiveRef.json"]}]).

%% Группы подключённых files, которые ждут keywords следующих фаз: их схемы пока
%% не компилируются вовсе. Фаза, снимающая группу, вычёркивает свою строку
%% вместе с работой — так же, как отмечает выполненный пункт роадмапа.
-define(PENDING, []).

%% Объявленные расхождения основного набора: okf/testing/conformance-policy.md,
%% раздел «Известные расхождения». Группа исключается поимённо, чтобы остальные
%% группы файла продолжали проверяться, а сам список оставался читаемым.
-define(EXCLUDED,
        [{"pattern.json",
          <<"pattern with Unicode property escape requires unicode mode">>},
         {"patternProperties.json",
          <<"patternProperties with Unicode property escape">>}]).

%% Группы, чья цепочка dialects выходит за conformance-профиль
%% (okf/testing/conformance-policy.md, раздел «Conformance-профиль»). От
%% ?EXCLUDED отличается природой: это не расхождение реализации с
%% спецификацией, а объявленная граница профиля. Поэтому и ключ другой —
%% dialect назван, ведь одноимённая группа соседнего dialect может остаться
%% внутри профиля, как и происходит в `cross-draft.json`.
-define(OUT_OF_PROFILE,
        [{"draft2019-09", "optional/cross-draft.json",
          <<"refs to historic drafts are processed as historic drafts">>}]).

%% Ожидаемый размер прогона: {групп, cases}. Число закреплено, чтобы прогон, в
%% котором сьют не нашёлся или файл перестал читаться, не мог оказаться зелёным
%% из-за того, что тестов просто не осталось. Оно меняется вместе с ?FILES,
%% ?EXCLUDED и ?OUT_OF_PROFILE, и менять его иначе нельзя.
-define(CENSUS, {758, 2937}).

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
    %% Dialect директории задаётся опцией, а не подставляется вместо `$schema`:
    %% схема, которая называет свой dialect сама, остаётся сильнее раскладки
    %% сьюта.
    Options = [{default_dialect, Dialect}, {schema_validation, trusted}
               | format_options(File)],
    {filename:join(Dir, File),
     [group_tests(Store, Options, Group)
      || Group <- read_json(Path), included(Dir, File, Group)]}.

%% Профиль format компилируется с включённой проверкой строки: без неё все cases
%% файлов `optional/format/` проходят подряд и подряд же зеленеют. Обязательный
%% `format.json` под правило не попадает по самому пути и остаётся с умолчанием
%% — он закрепляет как раз поведение без вердикта
%% (okf/testing/conformance-policy.md, раздел «Профиль format»).
format_options(File) ->
    case filename:dirname(File) of
        "optional/format" -> [{assert_format, true}];
        _Other            -> []
    end.

%% Расхождение объявлено для обоих dialects сразу, а фазы группы и границы
%% профиля называют dialect: один и тот же keyword появляется в dialects не
%% одновременно, а цепочка ссылок у одноимённых групп бывает разной.
included(Dir, File, #{<<"description">> := Description}) ->
    not lists:member({File, Description}, ?EXCLUDED) andalso
        not lists:member({Dir, File, Description}, ?OUT_OF_PROFILE) andalso
        not lists:member({Dir, File, Description}, ?PENDING).

group_tests(Store, Options, #{<<"description">> := Description,
                              <<"schema">> := Schema,
                              <<"tests">> := Cases}) ->
    Title = unicode:characters_to_list(Description),
    %% Схемы официального fixture-набора здесь являются доверенным входом:
    %% suite проверяет их применение к data, а не сами schemas по метасхеме.
    case valid_json_compile:compile(Store, Schema, Options) of
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
