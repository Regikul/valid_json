%% Runner поверх закреплённых output tests JSON Schema Test Suite. В отличие от
%% validation runner ожидаемый результат здесь является схемой: ею проверяется
%% фактический standard output выбранного формата.
-module(valid_json_output_conformance).

-include_lib("eunit/include/eunit.hrl").

-define(DIALECTS, [{"draft2020-12",
                    <<"https://json-schema.org/draft/2020-12/schema">>},
                   {"draft2019-09",
                    <<"https://json-schema.org/draft/2019-09/schema">>}]).

%% Снапшот содержит по четыре content-файла и по одному case в каждом dialect;
%% каждый case пока называет только basic. Перепись не позволяет потерянной
%% директории или исчезнувшему формату дать пустой зелёный прогон.
-define(CENSUS, {8, 8, 8}). % {files, cases, requested formats}

eunit_wrapper_(Tests) -> {inparallel, Tests}.

output_test_() ->
    {Files, Cases, Formats, Tests} =
        lists:foldl(fun dialect_tests/2, {0, 0, 0, []}, ?DIALECTS),
    [{"output census", ?_assertEqual(?CENSUS, {Files, Cases, Formats})},
     {inparallel, lists:reverse(Tests)}].

dialect_tests({Dir, Dialect}, {Files0, Cases0, Formats0, Tests0}) ->
    Prefix = filename:join(output_dir(), Dir),
    Store = output_store(Prefix),
    Paths = filelib:wildcard(filename:join([Prefix, "content", "*.json"])),
    {Cases, Tests} =
        lists:foldl(
          fun(Path, {CaseAcc, TestAcc}) ->
                  file_tests(Path, Dir, Dialect, Store, CaseAcc, TestAcc)
          end,
          {0, []}, Paths),
    {Files0 + length(Paths), Cases0 + Cases,
     Formats0 + length(Tests), lists:reverse(Tests, Tests0)}.

%% Output schema регистрируется именно из директории dialect: обе версии имеют
%% разные canonical $id и слегка различаются правилами для reference keyword.
output_store(Prefix) ->
    OutputSchema = read_json(filename:join(Prefix, "output-schema.json")),
    Uri = maps:get(<<"$id">>, OutputSchema),
    {ok, Uri, Store} =
        valid_json_store:add(valid_json_store:new([]), Uri, OutputSchema),
    Store.

file_tests(Path, Dir, Dialect, Store, Cases0, Tests0) ->
    File = filename:basename(Path),
    Groups = read_json(Path),
    lists:foldl(
      fun(#{<<"description">> := GroupDescription,
            <<"schema">> := Schema,
            <<"tests">> := Cases}, {CaseAcc, TestAcc}) ->
              Tests = lists:append(
                        [case_tests(Dir, File, GroupDescription, Schema, Case,
                                    Dialect, Store)
                         || Case <- Cases]),
              {CaseAcc + length(Cases), lists:reverse(Tests, TestAcc)}
      end,
      {Cases0, Tests0}, Groups).

case_tests(Dir, File, GroupDescription, Schema,
           #{<<"description">> := CaseDescription,
             <<"data">> := Data,
             <<"output">> := Expected}, Dialect, Store) ->
    [case_test(Dir, File, GroupDescription, CaseDescription, Schema, Data,
               Name, OutputSchema, Dialect, Store)
     || {Name, OutputSchema} <- lists:sort(maps:to_list(Expected))].

case_test(Dir, File, GroupDescription, CaseDescription, Schema, Data,
          Name, OutputSchema, Dialect, Store) ->
    Format = format(Name),
    Title = unicode:characters_to_list(
              [Dir, "/", File, ": ", GroupDescription, " / ",
               CaseDescription, " [", Name, "]"]),
    {Title,
     fun() ->
             {ok, Artifact} =
                 valid_json_compile:compile(
                   Store, Schema, [{default_dialect, Dialect}]),
             {ok, Actual} =
                 valid_json:validate(Artifact, Data, [{output, Format}]),
             {ok, Verifier} =
                 valid_json_compile:compile(
                   Store, OutputSchema, [{default_dialect, Dialect}]),
             ?assertEqual(
                {ok, #{<<"valid">> => true}},
                valid_json:validate(Verifier, Actual, [{output, flag}]))
     end}.

format(<<"flag">>)     -> flag;
format(<<"basic">>)    -> basic;
format(<<"detailed">>) -> detailed;
format(<<"verbose">>)  -> verbose;
format(Name)            -> erlang:error({unsupported_output_format, Name}).

read_json(Path) ->
    {ok, Binary} = file:read_file(Path),
    json:decode(Binary).

output_dir() ->
    filename:join(suite_dir(), "output-tests").

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
