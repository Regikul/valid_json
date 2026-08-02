%% Copyright 2014 Sean Cribbs
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

%% Based on eunit_progress from rebar3 3.27.0. Successful tests are aggregated:
%% one dot is printed for each success_interval completed tests.
-module(valid_json_eunit_progress).

-behaviour(eunit_listener).

-define(RED, "\e[0;31m").
-define(GREEN, "\e[0;32m").
-define(YELLOW, "\e[0;33m").
-define(CYAN, "\e[0;36m").
-define(RESET, "\e[0m").

-export([
    start/0,
    start/1,
    init/1,
    handle_begin/3,
    handle_end/3,
    handle_cancel/3,
    terminate/2
]).

-record(state, {
    status = #{} :: map(),
    failures = [] :: [[pos_integer()]],
    skips = [] :: [[pos_integer()]],
    timings = [] :: [{integer(), [pos_integer()]}],
    colored = true :: boolean(),
    profile = false :: boolean(),
    success_interval = 100 :: pos_integer(),
    success_count = 0 :: non_neg_integer()
}).

start() ->
    start([]).

start(Options) ->
    eunit_listener:start(?MODULE, Options).

init(Options) ->
    Interval = proplists:get_value(success_interval, Options, 100),
    case is_integer(Interval) andalso Interval > 0 of
        true ->
            #state{
                colored = proplists:get_bool(colored, Options),
                profile = proplists:get_bool(profile, Options),
                success_interval = Interval
            };
        false ->
            erlang:error({bad_success_interval, Interval})
    end.

handle_begin(group, Data, State) ->
    Id = proplists:get_value(id, Data),
    Status = State#state.status,
    State#state{status = Status#{Id => orddict:from_list([{type, group} | Data])}};
handle_begin(test, Data, State) ->
    Id = proplists:get_value(id, Data),
    Status = State#state.status,
    State#state{status = Status#{Id => orddict:from_list([{type, test} | Data])}}.

handle_end(group, Data, State) ->
    State#state{status = merge_on_end(Data, State#state.status)};
handle_end(test, Data, State) ->
    NewStatus = merge_on_end(Data, State#state.status),
    State1 = print_progress(Data, State),
    State2 = record_timing(Data, State1),
    State2#state{status = NewStatus}.

handle_cancel(_Type, Data, State = #state{status = Status, skips = Skips}) ->
    NewStatus = merge_on_end(Data, Status),
    Id = proplists:get_value(id, Data),
    State#state{status = NewStatus, skips = [Id | Skips]}.

terminate({ok, Data}, State) ->
    print_failures(State),
    print_pending(State),
    print_profile(State),
    print_timing(State),
    print_results(Data, State);
terminate({error, Reason}, State) ->
    io:nl(),
    io:nl(),
    print_colored(io_lib:format("Eunit failed: ~25p~n", [Reason]), ?RED, State),
    sync_end(error).

sync_end(Result) ->
    receive
        {stop, Reference, ReplyTo} ->
            ReplyTo ! {result, Reference, Result},
            ok
    end.

print_progress(Data, State) ->
    Id = proplists:get_value(id, Data),
    case proplists:get_value(status, Data) of
        ok ->
            print_progress_success(State);
        {skipped, _Reason} ->
            print_progress_skipped(State),
            State#state{skips = [Id | State#state.skips]};
        {error, Exception} ->
            print_progress_failed(Exception, State),
            State#state{failures = [Id | State#state.failures]}
    end.

record_timing(Data, State = #state{timings = Timings, profile = true}) ->
    Id = proplists:get_value(id, Data),
    case lists:keyfind(time, 1, Data) of
        {time, Time} ->
            %% Negative values put the slowest tests first after sorting.
            NewTimings = [{-Time, Id} | Timings],
            State#state{timings = NewTimings};
        false ->
            State
    end;
record_timing(_Data, State) ->
    State.

print_progress_success(State) ->
    {ShouldPrint, NewState} = record_success(State),
    case ShouldPrint of
        true -> print_colored(".", ?GREEN, State);
        false -> ok
    end,
    NewState.

record_success(State = #state{
    success_interval = Interval,
    success_count = Count
}) ->
    NewCount = Count + 1,
    {NewCount rem Interval =:= 0, State#state{success_count = NewCount}}.

print_progress_skipped(State) ->
    print_colored("*", ?YELLOW, State).

print_progress_failed(_Exception, State) ->
    print_colored("F", ?RED, State).

merge_on_end(Data, Status) ->
    Id = proplists:get_value(id, Data),
    #{Id := Old} = Status,
    New = orddict:merge(fun merge_data/3, Old, orddict:from_list(Data)),
    Status#{Id := New}.

merge_data(_Key, undefined, New) -> New;
merge_data(_Key, Old, undefined) -> Old;
merge_data(_Key, _Old, New) -> New.

print_failures(#state{failures = []}) ->
    ok;
print_failures(State = #state{failures = Failures}) ->
    io:nl(),
    io:fwrite("Failures:~n~n", []),
    lists:foldr(print_failure_fun(State), 1, Failures),
    ok.

print_failure_fun(State = #state{status = Status}) ->
    fun(Key, Count) ->
        #{Key := TestData} = Status,
        TestId = format_test_identifier(TestData),
        io:fwrite("  ~p) ~ts~n", [Count, TestId]),
        print_failure_reason(
            proplists:get_value(status, TestData),
            proplists:get_value(output, TestData),
            State
        ),
        io:nl(),
        Count + 1
    end.

print_failure_reason({skipped, Reason}, _Output, State) ->
    Text = io_lib:format("     ~ts~n", [format_pending_reason(Reason)]),
    print_colored(Text, ?RED, State);
print_failure_reason({error, {_Class, Term, Stack}}, Output, State)
        when is_tuple(Term), tuple_size(Term) =:= 2, is_list(element(2, Term)) ->
    print_assertion_failure(Term, Stack, Output, State),
    print_failure_output(5, Output, State);
print_failure_reason({error, Reason}, Output, State) ->
    print_colored(indent(5, "Failure/Error: ~p~n", [Reason]), ?RED, State),
    print_failure_output(5, Output, State).

print_failure_output(_Indent, <<>>, _State) -> ok;
print_failure_output(_Indent, [<<>>], _State) -> ok;
print_failure_output(_Indent, undefined, _State) -> ok;
print_failure_output(Indent, Output, State) ->
    print_colored(indent(Indent, "Output: ~ts", [Output]), ?CYAN, State).

print_assertion_failure({Type, Props}, Stack, Output, State) ->
    FailureDescription = format_assertion_failure(Type, Props, 5),
    {Module, Function, Arity, Location} = lists:last(prune_trace(Stack)),
    LocationText = io_lib:format(
        "     %% ~ts:~p:in `~ts`",
        [
            proplists:get_value(file, Location),
            proplists:get_value(line, Location),
            format_function_name(Module, Function, Arity)
        ]
    ),
    print_colored(FailureDescription, ?RED, State),
    io:nl(),
    print_colored(LocationText, ?CYAN, State),
    io:nl(),
    print_failure_output(5, Output, State),
    io:nl().

%% A simplified version of eunit_test:prune_trace/2.
prune_trace([Entry | _Rest]) when element(1, Entry) =:= eunit_test ->
    [Entry];
prune_trace(Stack) ->
    lists:takewhile(fun(Entry) -> element(1, Entry) =/= eunit_test end, Stack).

print_pending(#state{skips = []}) ->
    ok;
print_pending(State = #state{status = Status, skips = Skips}) ->
    io:nl(),
    io:fwrite("Pending:~n", []),
    lists:foreach(
        fun(Id) ->
            #{Id := Info} = Status,
            case proplists:get_value(reason, Info) of
                undefined -> ok;
                Reason -> print_pending_reason(Reason, Info, State)
            end
        end,
        lists:reverse(Skips)
    ),
    io:nl().

print_pending_reason(Reason0, Data, State) ->
    Text =
        case proplists:get_value(type, Data) of
            group -> io_lib:format("  ~ts~n", [proplists:get_value(desc, Data)]);
            test -> io_lib:format("  ~ts~n", [format_test_identifier(Data)])
        end,
    Reason = io_lib:format("    %% ~ts~n", [format_pending_reason(Reason0)]),
    print_colored(Text, ?YELLOW, State),
    print_colored(Reason, ?CYAN, State).

print_profile(State = #state{timings = Timings, status = Status, profile = true}) ->
    Top = lists:sublist(lists:sort(Timings), 10),
    TopTime = abs(lists:sum([Time || {Time, _} <- Top])),
    #{[] := TopLevelGroup} = Status,
    TotalTime = proplists:get_value(time, TopLevelGroup),
    case TotalTime =/= undefined andalso TotalTime > 0 andalso Top =/= [] of
        true ->
            TopPercentage = (TopTime / TotalTime) * 100,
            io:nl(),
            io:nl(),
            io:fwrite(
                "Top ~p slowest tests (~ts, ~.1f% of total time):",
                [length(Top), format_time(TopTime), TopPercentage]
            ),
            lists:foreach(print_timing_fun(State), Top),
            io:nl();
        false ->
            ok
    end;
print_profile(#state{profile = false}) ->
    ok.

print_timing(#state{status = Status}) ->
    #{[] := TopLevelGroup} = Status,
    Time = proplists:get_value(time, TopLevelGroup),
    io:nl(),
    io:fwrite("Finished in ~ts~n", [format_time(Time)]),
    ok.

print_results(Data, State) ->
    Pass = proplists:get_value(pass, Data, 0),
    Fail = proplists:get_value(fail, Data, 0),
    Skip = proplists:get_value(skip, Data, 0),
    Cancel = proplists:get_value(cancel, Data, 0),
    Total = Pass + Fail + Skip + Cancel,
    {Color, Result} =
        if
            Fail > 0 -> {?RED, error};
            Skip > 0; Cancel > 0 -> {?YELLOW, error};
            Pass =:= 0 -> {?YELLOW, ok};
            true -> {?GREEN, ok}
        end,
    print_results(Color, Total, Fail, Skip, Cancel, State),
    sync_end(Result).

print_results(Color, 0, _Fail, _Skip, _Cancel, State) ->
    print_colored("0 tests\n", Color, State);
print_results(Color, Total, Fail, Skip, Cancel, State) ->
    SkipText = format_optional_result(Skip, "skipped"),
    CancelText = format_optional_result(Cancel, "cancelled"),
    Text = io_lib:format(
        "~p tests, ~p failures~ts~ts~n",
        [Total, Fail, SkipText, CancelText]
    ),
    print_colored(Text, Color, State).

print_timing_fun(State = #state{status = Status}) ->
    fun({Time, Key}) ->
        #{Key := TestData} = Status,
        TestId = format_test_identifier(TestData),
        io:nl(),
        io:fwrite("  ~ts~n", [TestId]),
        print_colored(["    " | format_time(abs(Time))], ?CYAN, State)
    end.

print_colored(Text, Color, #state{colored = true}) ->
    io:fwrite("~s~ts~s", [Color, Text, ?RESET]);
print_colored(Text, _Color, #state{colored = false}) ->
    io:fwrite("~ts", [Text]).

format_function_name(Module, Function, Arity) ->
    io_lib:format("~ts:~ts/~p", [Module, Function, Arity]).

format_optional_result(0, _Text) ->
    [];
format_optional_result(Count, Text) ->
    io_lib:format(", ~p ~ts", [Count, Text]).

format_test_identifier(Data) ->
    {Module, Function, Arity} = proplists:get_value(source, Data),
    Line =
        case proplists:get_value(line, Data) of
            0 -> "";
            Value -> io_lib:format(":~p", [Value])
        end,
    Description =
        case proplists:get_value(desc, Data) of
            undefined -> "";
            Text -> io_lib:format(": ~ts", [Text])
        end,
    io_lib:format(
        "~ts~ts~ts",
        [format_function_name(Module, Function, Arity), Line, Description]
    ).

format_time(undefined) ->
    "? seconds";
format_time(Time) ->
    io_lib:format("~.3f seconds", [Time / 1000]).

format_pending_reason({module_not_found, Module}) ->
    io_lib:format("Module '~ts' missing", [Module]);
format_pending_reason({no_such_function, {Module, Function, Arity}}) ->
    io_lib:format(
        "Function ~ts undefined",
        [format_function_name(Module, Function, Arity)]
    );
format_pending_reason({exit, Reason}) ->
    io_lib:format("Related process exited with reason: ~p", [Reason]);
format_pending_reason(Reason) ->
    io_lib:format("Unknown error: ~p", [Reason]).

format_assertion_failure(Type, Props, Indent)
        when Type =:= assertion_failed; Type =:= assert ->
    Keys = proplists:get_keys(Props),
    HasEunitProps = ([expression, value] -- Keys) =:= [],
    HasHamcrestProps = ([expected, actual, matcher] -- Keys) =:= [],
    if
        HasEunitProps ->
            Expected = proplists:get_value(expected, Props),
            AssertMacro =
                case Expected of
                    true -> assert;
                    false -> assertNot
                end,
            [
                indent(
                    Indent,
                    "Failure/Error: ?~p(~ts)~n",
                    [AssertMacro, proplists:get_value(expression, Props)]
                ),
                indent(Indent, "  expected: ~p~n", [Expected]),
                case proplists:get_value(value, Props) of
                    Bool when is_boolean(Bool) ->
                        indent(Indent, "       got: ~p", [Bool]);
                    {not_a_boolean, Value} ->
                        indent(Indent, "       got: ~p", [Value])
                end
            ];
        HasHamcrestProps ->
            [
                indent(
                    Indent,
                    "Failure/Error: ?assertThat(~p)~n",
                    [proplists:get_value(matcher, Props)]
                ),
                indent(
                    Indent,
                    "  expected: ~p~n",
                    [proplists:get_value(expected, Props)]
                ),
                indent(
                    Indent,
                    "       got: ~p",
                    [proplists:get_value(actual, Props)]
                )
            ];
        true ->
            [indent(Indent, "Failure/Error: unknown assert: ~p", [Props])]
    end;
format_assertion_failure(Type, Props, Indent)
        when Type =:= assertMatch_failed; Type =:= assertMatch ->
    Expression = proplists:get_value(expression, Props),
    Pattern = proplists:get_value(pattern, Props),
    Value = proplists:get_value(value, Props),
    [
        indent(Indent, "Failure/Error: ?assertMatch(~ts, ~ts)~n", [Pattern, Expression]),
        indent(Indent, "  expected: = ~ts~n", [Pattern]),
        indent(Indent, "       got: ~p", [Value])
    ];
format_assertion_failure(Type, Props, Indent)
        when Type =:= assertNotMatch_failed; Type =:= assertNotMatch ->
    Expression = proplists:get_value(expression, Props),
    Pattern = proplists:get_value(pattern, Props),
    Value = proplists:get_value(value, Props),
    [
        indent(
            Indent,
            "Failure/Error: ?assertNotMatch(~ts, ~ts)~n",
            [Pattern, Expression]
        ),
        indent(Indent, "  expected not: = ~ts~n", [Pattern]),
        indent(Indent, "           got:   ~p", [Value])
    ];
format_assertion_failure(Type, Props, Indent)
        when Type =:= assertEqual_failed; Type =:= assertEqual ->
    Expression = proplists:get_value(expression, Props),
    Expected = proplists:get_value(expected, Props),
    Value = proplists:get_value(value, Props),
    [
        indent(
            Indent,
            "Failure/Error: ?assertEqual(~w, ~ts)~n",
            [Expected, Expression]
        ),
        indent(Indent, "  expected: ~p~n", [Expected]),
        indent(Indent, "       got: ~p", [Value])
    ];
format_assertion_failure(Type, Props, Indent)
        when Type =:= assertNotEqual_failed; Type =:= assertNotEqual ->
    Expression = proplists:get_value(expression, Props),
    Value = proplists:get_value(value, Props),
    [
        indent(
            Indent,
            "Failure/Error: ?assertNotEqual(~p, ~ts)~n",
            [Value, Expression]
        ),
        indent(Indent, "  expected not: == ~p~n", [Value]),
        indent(Indent, "           got:    ~p", [Value])
    ];
format_assertion_failure(Type, Props, Indent)
        when Type =:= assertException_failed; Type =:= assertException ->
    Expression = proplists:get_value(expression, Props),
    Pattern = proplists:get_value(pattern, Props),
    {Class, Term} = extract_exception_pattern(Pattern),
    [
        indent(
            Indent,
            "Failure/Error: ?assertException(~ts, ~ts, ~ts)~n",
            [Class, Term, Expression]
        ),
        case proplists:is_defined(unexpected_success, Props) of
            true ->
                [
                    indent(
                        Indent,
                        "  expected: exception ~ts but nothing was raised~n",
                        [Pattern]
                    ),
                    indent(
                        Indent,
                        "       got: value ~p",
                        [proplists:get_value(unexpected_success, Props)]
                    )
                ];
            false ->
                Exception = proplists:get_value(unexpected_exception, Props),
                [
                    indent(Indent, "  expected: exception ~ts~n", [Pattern]),
                    indent(Indent, "       got: exception ~p", [Exception])
                ]
        end
    ];
format_assertion_failure(Type, Props, Indent)
        when Type =:= assertNotException_failed; Type =:= assertNotException ->
    Expression = proplists:get_value(expression, Props),
    Pattern = proplists:get_value(pattern, Props),
    {Class, Term} = extract_exception_pattern(Pattern),
    Exception = proplists:get_value(unexpected_exception, Props),
    [
        indent(
            Indent,
            "Failure/Error: ?assertNotException(~ts, ~ts, ~ts)~n",
            [Class, Term, Expression]
        ),
        indent(Indent, "  expected not: exception ~ts~n", [Pattern]),
        indent(Indent, "           got: exception ~p", [Exception])
    ];
format_assertion_failure(Type, Props, Indent)
        when Type =:= command_failed; Type =:= command ->
    Command = proplists:get_value(command, Props),
    Expected = proplists:get_value(expected_status, Props),
    Status = proplists:get_value(status, Props),
    [
        indent(Indent, "Failure/Error: ?cmdStatus(~p, ~p)~n", [Expected, Command]),
        indent(Indent, "  expected: status ~p~n", [Expected]),
        indent(Indent, "       got: status ~p", [Status])
    ];
format_assertion_failure(Type, Props, Indent)
        when Type =:= assertCmd_failed; Type =:= assertCmd ->
    Command = proplists:get_value(command, Props),
    Expected = proplists:get_value(expected_status, Props),
    Status = proplists:get_value(status, Props),
    [
        indent(
            Indent,
            "Failure/Error: ?assertCmdStatus(~p, ~p)~n",
            [Expected, Command]
        ),
        indent(Indent, "  expected: status ~p~n", [Expected]),
        indent(Indent, "       got: status ~p", [Status])
    ];
format_assertion_failure(Type, Props, Indent)
        when Type =:= assertCmdOutput_failed; Type =:= assertCmdOutput ->
    Command = proplists:get_value(command, Props),
    Expected = proplists:get_value(expected_output, Props),
    Output = proplists:get_value(output, Props),
    [
        indent(
            Indent,
            "Failure/Error: ?assertCmdOutput(~p, ~p)~n",
            [Expected, Command]
        ),
        indent(Indent, "  expected: ~p~n", [Expected]),
        indent(Indent, "       got: ~p", [Output])
    ];
format_assertion_failure(Type, Props, Indent) ->
    indent(Indent, "~p", [{Type, Props}]).

indent(Indent, Format, Args) ->
    io_lib:format("~" ++ integer_to_list(Indent) ++ "s" ++ Format, [" " | Args]).

extract_exception_pattern(String) ->
    ["{", Class, Term | _Rest] =
        re:split(String, "[, ]{1,2}", [unicode, {return, list}]),
    {Class, Term}.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

success_interval_test() ->
    State0 = init([{success_interval, 3}]),
    {false, State1} = record_success(State0),
    {false, State2} = record_success(State1),
    {true, State3} = record_success(State2),
    {false, State4} = record_success(State3),
    ?assertEqual(4, State4#state.success_count).

invalid_success_interval_test() ->
    ?assertError({bad_success_interval, 0}, init([{success_interval, 0}])).

-endif.
