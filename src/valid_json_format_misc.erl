%% Небольшие синтаксические алгоритмы format attributes, не относящиеся к
%% времени, сетевым адресам или URI: UUID и регулярное выражение.
-module(valid_json_format_misc).

-export([uuid/1, regex/1]).

%% UUID string representation (RFC 4122, section 3): five groups of ASCII
%% hexadecimal digits with lengths 8-4-4-4-12. Version and variant are not
%% inspected: the format checks only the representation.
-spec uuid(binary()) -> boolean().
uuid(<<A:8/binary, $-, B:4/binary, $-, C:4/binary, $-, D:4/binary, $-,
       E:12/binary>>) ->
    lists:all(fun is_hex/1, [A, B, C, D, E]);
uuid(_String) ->
    false.

%% The `regex` format checks that the string is a compilable regular expression.
%% Use the same engine and options as the `pattern` keyword; the project
%% documents the resulting PCRE/ECMA-262 boundary separately.
-spec regex(binary()) -> boolean().
regex(String) when is_binary(String) ->
    try re:compile(String, [unicode, dollar_endonly]) of
        {ok, _Compiled} -> true;
        {error, _Reason} -> false
    catch
        _Class:_Reason -> false
    end.

-spec is_hex(binary()) -> boolean().
is_hex(<<>>) ->
    true;
is_hex(<<Char, Rest/binary>>) when Char >= $0, Char =< $9;
                                   Char >= $a, Char =< $f;
                                   Char >= $A, Char =< $F ->
    is_hex(Rest);
is_hex(_String) ->
    false.
