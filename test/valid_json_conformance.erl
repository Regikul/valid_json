%% Runner поверх закреплённого JSON Schema Test Suite. Один генератор берёт один
%% файл сьюта и прогоняет его на всех поддерживаемых диалектах.
-module(valid_json_conformance).

-include_lib("eunit/include/eunit.hrl").

-define(DIALECTS, [{"draft2020-12", <<"https://json-schema.org/draft/2020-12/schema">>},
                   {"draft2019-09", <<"https://json-schema.org/draft/2019-09/schema">>}]).

%% Файл подключается целиком и только когда его схемы компилируются полностью.
%% enum.json, required.json и uniqueItems.json ждут applicators фазы P2.
-define(FILES, ["boolean_schema.json", "type.json", "const.json"]).

validation_test_() ->
    [file_tests(Dir, Dialect, File)
     || {Dir, Dialect} <- ?DIALECTS, File <- ?FILES].

file_tests(Dir, Dialect, File) ->
    Path = filename:join([suite_dir(), Dir, File]),
    {filename:join(Dir, File),
     [group_tests(Dialect, Group) || Group <- read_groups(Path)]}.

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
