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
reason(invalid_uri) ->
    "URI is invalid";
reason(invalid_percent_encoding) ->
    "URI contains invalid percent-encoding";
reason(relative_uri_without_base) ->
    "relative URI has no base URI";
reason(unresolved_anchor) ->
    "anchor does not exist in the referenced resource";
reason({dangling_ref, Target}) ->
    ["reference target does not exist: ", target(Target)];
reason({non_schema_target, Target}) ->
    ["reference target is not a schema: ", target(Target)];
reason({unknown_document, Uri}) ->
    ["referenced document is not registered: ", Uri];
reason({unknown_dialect, Uri}) ->
    ["unsupported JSON Schema dialect: ", io_lib:format("~tp", [Uri])];
reason({unrecognized_vocabulary, Uri}) ->
    ["meta-schema requires an unknown vocabulary: ", Uri];
reason(core_vocabulary_missing) ->
    "meta-schema does not require the Core vocabulary";
reason({name_taken, Uri}) ->
    ["URI is already used by another document: ", Uri];
reason({schema_invalid, _RootOutputUnit}) ->
    "schema does not conform to its meta-schema";
reason({metaschema_evaluation_failed, Uri, EvalError}) ->
    ["meta-schema evaluation failed for ", Uri, ": ",
     io_lib:format("~tp", [EvalError])];
reason({bad_keyword_value, Value}) ->
    ["value is not allowed here: ", json:encode(Value)];
%% Причина от re принадлежит библиотеке и структуры не имеет, поэтому печатается
%% как есть.
reason({bad_pattern, Reason}) ->
    ["pattern does not compile: ", io_lib:format("~p", [Reason])];
reason({not_implemented, Keyword}) ->
    ["keyword is not implemented: ", Keyword].

-spec target(addr()) -> unicode:chardata().
target({anonymous, Pointer}) -> ["#", Pointer];
target({Uri, Pointer})       -> [Uri, "#", Pointer].
