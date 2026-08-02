%% Текст ошибки схемы. В самой записи его нет: машинный контракт исчерпывается
%% причиной и локацией, а формулировка остаётся политикой реализации и может
%% меняться, не задевая вызывающих
%% (okf/architecture/validator-resources-runtime.md, «Ошибки схемы»).
-module(valid_json_error).

-include("valid_json_core.hrl").

-export([format_error/1]).

-spec format_error(#schema_error{}) -> unicode:chardata().
format_error(#schema_error{reason = Reason, location = undefined}) ->
    reason(Reason);
format_error(#schema_error{reason = Reason, location = Location}) ->
    [location(Location), ": ", reason(Reason)].

%% У анонимного resource URI нет, поэтому от локации остаётся один fragment.
-spec location(addr()) -> unicode:chardata().
location({anonymous, Pointer}) -> ["#", Pointer];
location({Uri, Pointer})       -> [Uri, "#", Pointer].

-spec reason(reason()) -> unicode:chardata().
reason({bad_keyword_value, Value}) ->
    ["value is not allowed here: ", json:encode(Value)];
%% Причина от re принадлежит библиотеке и структуры не имеет, поэтому печатается
%% как есть.
reason({bad_pattern, Reason}) ->
    ["pattern does not compile: ", io_lib:format("~p", [Reason])];
reason({not_implemented, Keyword}) ->
    ["keyword is not implemented: ", Keyword].
