%% Синтаксические алгоритмы URI-семейства из таблицы format attributes.
%% URI и URI-reference разбираются generic parser'ом stdlib после отдельной
%% проверки percent-encoding: uri_string:parse/1 принимает некоторые неполные
%% escape-последовательности как обычный текст, а RFC 3986 этого не допускает.
%% Остальные три имени имеют собственные ABNF и разбираются здесь напрямую.
-module(valid_json_format_uri).

-export([uri/1, uri_reference/1, uri_template/1,
         json_pointer/1, relative_json_pointer/1]).

%% RFC 3986 URI: обязательная scheme, generic syntax без scheme-specific
%% проверки host или path.
-spec uri(binary()) -> boolean().
uri(String) when is_binary(String) ->
    strict_uri(String, true).

%% RFC 3986 URI-reference: абсолютная URI, relative-ref или пустая ссылка.
-spec uri_reference(binary()) -> boolean().
uri_reference(String) when is_binary(String) ->
    strict_uri(String, false).

-spec strict_uri(binary(), boolean()) -> boolean().
strict_uri(String, RequireScheme) ->
    case ascii_uri(String) of
        false -> false;
        true ->
            try valid_json_uri_backend:parse(String) of
                Parsed when is_map(Parsed) ->
                    not RequireScheme orelse maps:is_key(scheme, Parsed);
                _Other ->
                    false
            catch
                _Class:_Reason ->
                    false
            end
    end.

%% RFC 3986 работает с ASCII и percent-encoded октетами. Синтаксис остальных
%% символов проверяет uri_string, а здесь фиксируется обязательная форма
%% `% HEXDIG HEXDIG` и отбрасывается raw non-ASCII.
-spec ascii_uri(binary()) -> boolean().
ascii_uri(<<>>) ->
    true;
ascii_uri(<<$%, H1, H2, Rest/binary>>) ->
    is_hex(H1) andalso is_hex(H2) andalso ascii_uri(Rest);
ascii_uri(<<$%, _Rest/binary>>) ->
    false;
ascii_uri(<<C, Rest/binary>>) when C =< 16#7f ->
    ascii_uri(Rest);
ascii_uri(_Other) ->
    false.

-spec is_hex(byte()) -> boolean().
is_hex(C) when C >= $0, C =< $9 -> true;
is_hex(C) when C >= $A, C =< $F -> true;
is_hex(C) when C >= $a, C =< $f -> true;
is_hex(_Other) -> false.

%% RFC 6570, section 2. URI Template принимает printable Unicode literals,
%% выражения `{...}` и полный набор операторов/modifiers Level 4. Расширение
%% переменных здесь не выполняется: format проверяет только grammar.
-spec uri_template(binary()) -> boolean().
uri_template(String) when is_binary(String) ->
    try unicode:characters_to_list(String) of
        Chars when is_list(Chars) -> template(Chars);
        _Other -> false
    catch
        _Class:_Reason -> false
    end.

-spec template([char()]) -> boolean().
template([]) ->
    true;
template([${ | Rest]) ->
    case expression_body(Rest, []) of
        {ok, Body, Tail} -> valid_expression(Body) andalso template(Tail);
        error -> false
    end;
template([$} | _Rest]) ->
    false;
template([$% | Rest]) ->
    case pct_chars(Rest) of
        {ok, Tail} -> template(Tail);
        error -> false
    end;
template([C | Rest]) ->
    literal_char(C) andalso template(Rest).

-spec expression_body([char()], [char()]) -> {ok, [char()], [char()]} | error.
expression_body([], _Acc) ->
    error;
expression_body([$} | Rest], Acc) ->
    {ok, lists:reverse(Acc), Rest};
expression_body([C | Rest], Acc) ->
    expression_body(Rest, [C | Acc]).

-spec valid_expression([char()]) -> boolean().
valid_expression([]) ->
    false;
valid_expression(Body) ->
    {Operator, Variables} = split_operator(Body),
    _ = Operator,
    valid_variable_list(Variables).

-spec split_operator([char()]) -> {none | char(), [char()]}.
split_operator([C | Rest]) when C =:= $+; C =:= $#;
                               C =:= $.; C =:= $/;
                               C =:= $;; C =:= $?;
                               C =:= $&; C =:= $=;
                               C =:= $,, C =:= $!;
                               C =:= $@; C =:= $| ->
    {C, Rest};
split_operator(Body) ->
    {none, Body}.

-spec valid_variable_list([char()]) -> boolean().
valid_variable_list([]) ->
    false;
valid_variable_list(Variables) ->
    Parts = split_char($,, Variables),
    Parts =/= [] andalso lists:all(fun valid_varspec/1, Parts).

-spec valid_varspec([char()]) -> boolean().
valid_varspec([]) ->
    false;
valid_varspec(VarSpec) ->
    {Name, Modifier} = split_modifier(VarSpec),
    valid_varname(Name) andalso valid_modifier(Modifier).

-spec split_modifier([char()]) -> {[char()], none | explode | {prefix, [char()]}}.
split_modifier(VarSpec) ->
    case lists:splitwith(fun(C) -> C =/= $* andalso C =/= $: end, VarSpec) of
        {Name, []} ->
            {Name, none};
        {Name, [$*]} ->
            {Name, explode};
        {Name, [$: | Digits]} ->
            {Name, {prefix, Digits}};
        {Name, _Other} ->
            {Name, invalid}
    end.

-spec valid_modifier(none | explode | {prefix, [char()]} | invalid) -> boolean().
valid_modifier(none) ->
    true;
valid_modifier(explode) ->
    true;
valid_modifier({prefix, [First | Rest]}) when First >= $1, First =< $9,
                                               length(Rest) =< 3 ->
    lists:all(fun(D) -> D >= $0 andalso D =< $9 end, Rest);
valid_modifier(_Other) ->
    false.

-spec valid_varname([char()]) -> boolean().
valid_varname([]) ->
    false;
valid_varname(Name) ->
    Segments = split_char($., Name),
    Segments =/= [] andalso
        lists:all(fun valid_varchar_segment/1, Segments).

-spec valid_varchar_segment([char()]) -> boolean().
valid_varchar_segment([]) ->
    false;
valid_varchar_segment(Chars) ->
    valid_varchar_segment(Chars, false).

-spec valid_varchar_segment([char()], boolean()) -> boolean().
valid_varchar_segment([], Seen) ->
    Seen;
valid_varchar_segment([C | Rest], _Seen)
  when (C >= $A andalso C =< $Z) orelse
       (C >= $a andalso C =< $z) orelse
       (C >= $0 andalso C =< $9) orelse C =:= $_ ->
    valid_varchar_segment(Rest, true);
valid_varchar_segment([$%, H1, H2 | Rest], _Seen)
  when (H1 >= $0 andalso H1 =< $9) orelse
       (H1 >= $A andalso H1 =< $F) orelse
       (H1 >= $a andalso H1 =< $f) ->
    case is_hex(H2) of
        true -> valid_varchar_segment(Rest, true);
        false -> false
    end;
valid_varchar_segment(_Other, _Seen) ->
    false.

-spec split_char(char(), [char()]) -> [[char()]].
split_char(Separator, Chars) ->
    split_char(Separator, Chars, [], []).

-spec split_char(char(), [char()], [char()], [[char()]]) -> [[char()]].
split_char(_Separator, [], Current, Acc) ->
    lists:reverse([lists:reverse(Current) | Acc]);
split_char(Separator, [Separator | Rest], Current, Acc) ->
    split_char(Separator, Rest, [], [lists:reverse(Current) | Acc]);
split_char(Separator, [C | Rest], Current, Acc) ->
    split_char(Separator, Rest, [C | Current], Acc).

-spec pct_chars([char()]) -> {ok, [char()]} | error.
pct_chars([H1, H2 | Rest]) ->
    case is_hex(H1) andalso is_hex(H2) of
        true -> {ok, Rest};
        false -> error
    end;
pct_chars(_Other) ->
    error.

%% literals из RFC 6570, section 2.1. `{`, `}` и `%` обрабатываются снаружи;
%% `%` здесь намеренно не считается literal без тройки percent-encoding.
-spec literal_char(char()) -> boolean().
literal_char(C) when C =:= 16#21;
                    C >= 16#23, C =< 16#24;
                    C =:= 16#26;
                    C >= 16#28, C =< 16#3b;
                    C =:= 16#3d;
                    C >= 16#3f, C =< 16#5b;
                    C =:= 16#5d;
                    C =:= 16#5f;
                    C >= 16#61, C =< 16#7a;
                    C =:= 16#7e ->
    true;
literal_char(C) ->
    ucschar(C) orelse iprivate(C).

-spec ucschar(char()) -> boolean().
ucschar(C) when C >= 16#a0, C =< 16#d7ff -> true;
ucschar(C) when C >= 16#f900, C =< 16#fdcf -> true;
ucschar(C) when C >= 16#fdf0, C =< 16#ffef -> true;
ucschar(C) when C >= 16#10000, C =< 16#1fffd -> true;
ucschar(C) when C >= 16#20000, C =< 16#2fffd -> true;
ucschar(C) when C >= 16#30000, C =< 16#3fffd -> true;
ucschar(C) when C >= 16#40000, C =< 16#4fffd -> true;
ucschar(C) when C >= 16#50000, C =< 16#5fffd -> true;
ucschar(C) when C >= 16#60000, C =< 16#6fffd -> true;
ucschar(C) when C >= 16#70000, C =< 16#7fffd -> true;
ucschar(C) when C >= 16#80000, C =< 16#8fffd -> true;
ucschar(C) when C >= 16#90000, C =< 16#9fffd -> true;
ucschar(C) when C >= 16#a0000, C =< 16#afffd -> true;
ucschar(C) when C >= 16#b0000, C =< 16#bfffd -> true;
ucschar(C) when C >= 16#c0000, C =< 16#cfffd -> true;
ucschar(C) when C >= 16#d0000, C =< 16#dfffd -> true;
ucschar(C) when C >= 16#e1000, C =< 16#efffd -> true;
ucschar(_Other) -> false.

-spec iprivate(char()) -> boolean().
iprivate(C) when C >= 16#e000, C =< 16#f8ff -> true;
iprivate(C) when C >= 16#f0000, C =< 16#ffffd -> true;
iprivate(C) when C >= 16#100000, C =< 16#10fffd -> true;
iprivate(_Other) -> false.

%% RFC 6901 JSON Pointer: пустая строка либо `/` и reference tokens. Внутри
%% token разрешены любые octets, кроме неэкранированной `~`.
-spec json_pointer(binary()) -> boolean().
json_pointer(<<>>) ->
    true;
json_pointer(<<$/, Rest/binary>>) ->
    pointer_tail(Rest);
json_pointer(_Other) ->
    false.

-spec pointer_tail(binary()) -> boolean().
pointer_tail(<<>>) ->
    true;
pointer_tail(<<$~, $0, Rest/binary>>) ->
    pointer_tail(Rest);
pointer_tail(<<$~, $1, Rest/binary>>) ->
    pointer_tail(Rest);
pointer_tail(<<$~, _Rest/binary>>) ->
    false;
pointer_tail(<<_C, Rest/binary>>) ->
    pointer_tail(Rest).

%% Relative JSON Pointer, section 3: non-negative array index followed by `#`
%% or a JSON Pointer. Leading zeroes are forbidden.
-spec relative_json_pointer(binary()) -> boolean().
relative_json_pointer(<<$0, Rest/binary>>) ->
    relative_suffix(Rest);
relative_json_pointer(<<D, Rest/binary>>) when D >= $1, D =< $9 ->
    nonzero_digits(Rest);
relative_json_pointer(_Other) ->
    false.

-spec nonzero_digits(binary()) -> boolean().
nonzero_digits(<<D, Rest/binary>>) when D >= $0, D =< $9 ->
    nonzero_digits(Rest);
nonzero_digits(Rest) ->
    relative_suffix(Rest).

-spec relative_suffix(binary()) -> boolean().
relative_suffix(<<$#>>) ->
    true;
relative_suffix(<<>>) ->
    true;
relative_suffix(<<$/, _Rest/binary>> = Pointer) ->
    json_pointer(Pointer);
relative_suffix(_Other) ->
    false.
