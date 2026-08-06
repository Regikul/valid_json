%% Алгоритмы четырёх сетевых format attributes: `ipv4`, `ipv6`, `hostname` и
%% `email`. Держатся вместе, потому что ссылаются друг на друга: адрес IPv6
%% кончается dotted-quad, а домен письма бывает и address literal, и именем из
%% тех же меток LDH. Границы каждого — okf/architecture/format-attributes.md.
-module(valid_json_format_net).

-export([ipv4/1, ipv6/1, hostname/1, email/1]).

%% ipv4 — dotted-quad из четырёх десятичных октетов (RFC 2673, раздел 3.2).
%% Ведущий ноль запрещён: он читается как восьмеричная запись и делает адрес
%% двусмысленным.
-spec ipv4(binary()) -> boolean().
ipv4(String) ->
    case binary:split(String, <<".">>, [global]) of
        [_, _, _, _] = Octets -> lists:all(fun is_octet/1, Octets);
        _Other                -> false
    end.

%% ipv6 — восемь групп по одной-четыре hex-цифры (RFC 4291, раздел 2.2). Группы
%% нулей сжимаются одним `::`, а хвост адреса записывается dotted-quad и стоит
%% тогда за две группы (раздел 2.5.5).
-spec ipv6(binary()) -> boolean().
ipv6(String) ->
    ipv6(String, ipv4_allowed, 7).

%% SMTP использует почти ту же запись IPv6, но `::` там заменяет не меньше двух
%% групп, а завершающий IPv4 разбирается правилом Snum с допустимыми ведущими
%% нулями (RFC 5321, раздел 4.1.3).
-spec smtp_ipv6(binary()) -> boolean().
smtp_ipv6(String) ->
    ipv6(String, smtp_ipv4_allowed, 6).

-spec ipv6(binary(), ipv4_allowed | smtp_ipv4_allowed, non_neg_integer()) ->
          boolean().
ipv6(String, Tail, CompressedMaximum) ->
    case binary:split(String, <<"::">>, [global]) of
        [Whole]       -> side(Whole, Tail) =:= {ok, 8};
        [Left, Right] -> compressed(Left, Right, Tail, CompressedMaximum);
        _Other        -> false
    end.

%% hostname — имя из меток LDH (RFC 1123, раздел 2.1). Пределы длины взяты
%% оттуда же: метка не длиннее 63 знаков, имя целиком — 253.
-spec hostname(binary()) -> boolean().
hostname(String) when byte_size(String) > 0, byte_size(String) =< 253 ->
    lists:all(fun(Label) -> byte_size(Label) =< 63 andalso label(Label) end,
              binary:split(String, <<".">>, [global]));
hostname(_String) ->
    false.

%% email — правило `Mailbox` (RFC 5321, раздел 4.1.2): локальная часть, `@` и
%% домен. Формы RFC 5322 — display name, комментарии, перенос строки — сюда не
%% входят, а пределы длины раздела 4.5.3.1 не проверяются.
-spec email(binary()) -> boolean().
email(String) ->
    case split_at_last(String, $@) of
        {ok, Local, Domain} -> local(Local) andalso domain(Domain);
        error               -> false
    end.

-spec is_octet(binary()) -> boolean().
is_octet(<<"0">>) ->
    true;
is_octet(<<Digit, _/binary>> = Octet) when Digit >= $1, Digit =< $9,
                                           byte_size(Octet) =< 3 ->
    is_decimal(Octet) andalso binary_to_integer(Octet) =< 255;
is_octet(_Octet) ->
    false.

%% В отличие от standalone `ipv4`, SMTP Snum не запрещает ведущий ноль.
-spec smtp_ipv4(binary()) -> boolean().
smtp_ipv4(String) ->
    case binary:split(String, <<".">>, [global]) of
        [_, _, _, _] = Octets -> lists:all(fun is_smtp_octet/1, Octets);
        _Other                -> false
    end.

-spec is_smtp_octet(binary()) -> boolean().
is_smtp_octet(Octet) when byte_size(Octet) > 0, byte_size(Octet) =< 3 ->
    is_decimal(Octet) andalso binary_to_integer(Octet) =< 255;
is_smtp_octet(_Octet) ->
    false.

%% binary_to_integer/1 принимает знак и потому сам по себе фильтром не является.
-spec is_decimal(binary()) -> boolean().
is_decimal(<<>>) ->
    true;
is_decimal(<<Digit, Rest/binary>>) when Digit >= $0, Digit =< $9 ->
    is_decimal(Rest);
is_decimal(_Other) ->
    false.

%% В standalone IPv6 сжатие покрывает хотя бы одну группу и оставляет не больше
%% семи выписанных; в SMTP — хотя бы две и не больше шести. Слева от `::`
%% dotted-quad запрещён: он записывает последние две группы адреса, а последними
%% они здесь не будут.
-spec compressed(binary(), binary(), ipv4_allowed | smtp_ipv4_allowed,
                 non_neg_integer()) -> boolean().
compressed(Left, Right, Tail, Maximum) ->
    case {side(Left, hex_only), side(Right, Tail)} of
        {{ok, Before}, {ok, After}} -> Before + After =< Maximum;
        _Other                      -> false
    end.

%% Сторона пуста, когда сжатие стоит с краю адреса; во всех прочих случаях она
%% состоит из непустых групп, разделённых одним двоеточием.
-spec side(binary(), hex_only | ipv4_allowed | smtp_ipv4_allowed) ->
          {ok, non_neg_integer()} | error.
side(<<>>, _Tail) ->
    {ok, 0};
side(Binary, Tail) ->
    groups(binary:split(Binary, <<":">>, [global]), Tail, 0).

-spec groups([binary()], hex_only | ipv4_allowed | smtp_ipv4_allowed,
             non_neg_integer()) ->
          {ok, non_neg_integer()} | error.
groups([Last], ipv4_allowed, Count) ->
    case ipv4(Last) of
        true  -> {ok, Count + 2};
        false -> hextet(Last, Count)
    end;
groups([Last], smtp_ipv4_allowed, Count) ->
    case smtp_ipv4(Last) of
        true  -> {ok, Count + 2};
        false -> hextet(Last, Count)
    end;
groups([Last], hex_only, Count) ->
    hextet(Last, Count);
groups([Group | Rest], Tail, Count) ->
    case hextet(Group, Count) of
        {ok, Next} -> groups(Rest, Tail, Next);
        error      -> error
    end.

-spec hextet(binary(), non_neg_integer()) -> {ok, non_neg_integer()} | error.
hextet(Group, Count) when byte_size(Group) > 0, byte_size(Group) =< 4 ->
    case is_hex(Group) of
        true  -> {ok, Count + 1};
        false -> error
    end;
hextet(_Group, _Count) ->
    error.

-spec is_hex(binary()) -> boolean().
is_hex(<<>>) ->
    true;
is_hex(<<Digit, Rest/binary>>) when Digit >= $0, Digit =< $9;
                                    Digit >= $a, Digit =< $f;
                                    Digit >= $A, Digit =< $F ->
    is_hex(Rest);
is_hex(_Other) ->
    false.

%% Метка: буквы, цифры и дефис, причём дефис не с краю. Начинаться с цифры
%% метка вправе — RFC 1123 разрешил это прямо, поправив RFC 952. Тем же
%% правилом описан `sub-domain` письма, только пределов длины там нет.
-spec label(binary()) -> boolean().
label(<<>>) ->
    false;
label(<<Single>>) ->
    is_letdig(Single);
label(<<First, Rest/binary>>) ->
    Size = byte_size(Rest) - 1,
    Inner = binary:part(Rest, 0, Size),
    Last = binary:last(Rest),
    is_letdig(First) andalso is_letdig(Last) andalso is_ldh(Inner).

-spec is_letdig(byte()) -> boolean().
is_letdig(Char) ->
    (Char >= $0 andalso Char =< $9) orelse
        (Char >= $a andalso Char =< $z) orelse
        (Char >= $A andalso Char =< $Z).

-spec is_ldh(binary()) -> boolean().
is_ldh(<<>>) ->
    true;
is_ldh(<<Char, Rest/binary>>) ->
    (Char =:= $- orelse is_letdig(Char)) andalso is_ldh(Rest).

%% Разделителем служит последний `@`: внутри quoted-string локальной части он
%% обычный знак, а в домене его не бывает вовсе.
-spec split_at_last(binary(), byte()) -> {ok, binary(), binary()} | error.
split_at_last(String, Byte) ->
    case binary:matches(String, <<Byte>>) of
        [] ->
            error;
        Matches ->
            {Position, 1} = lists:last(Matches),
            <<Local:Position/binary, _Byte, Domain/binary>> = String,
            {ok, Local, Domain}
    end.

%% `Local-part` — либо `Dot-string` из непустых atoms, либо `Quoted-string`.
-spec local(binary()) -> boolean().
local(<<$", Rest/binary>>) ->
    quoted(Rest);
local(Local) ->
    lists:all(fun atom_part/1, binary:split(Local, <<".">>, [global])).

-spec atom_part(binary()) -> boolean().
atom_part(<<>>) ->
    false;
atom_part(<<Char, Rest/binary>>) ->
    is_atext(Char) andalso (Rest =:= <<>> orelse atom_part(Rest)).

-spec is_atext(byte()) -> boolean().
is_atext(Char) ->
    is_letdig(Char) orelse lists:member(Char, "!#$%&'*+-/=?^_`{|}~").

%% `Quoted-string` кончается кавычкой, а внутри держит печатные знаки, кроме
%% кавычки и обратной косой, либо `quoted-pair` — косую и любой печатный знак.
-spec quoted(binary()) -> boolean().
quoted(<<$">>) ->
    true;
quoted(<<$\\, Char, Rest/binary>>) when Char >= 32, Char =< 126 ->
    quoted(Rest);
quoted(<<Char, Rest/binary>>) when Char >= 32, Char =< 126,
                                   Char =/= $", Char =/= $\\ ->
    quoted(Rest);
quoted(_Other) ->
    false.

%% Домен — либо имя из тех же меток LDH, либо address literal в квадратных
%% скобках.
-spec domain(binary()) -> boolean().
domain(<<$[, Rest/binary>>) ->
    case byte_size(Rest) of
        0 ->
            false;
        Size ->
            case binary:last(Rest) of
                $] -> address_literal(binary:part(Rest, 0, Size - 1));
                _  -> false
            end
    end;
domain(Domain) ->
    lists:all(fun label/1, binary:split(Domain, <<".">>, [global])).

%% Из address literals разбираются два: dotted-quad и адрес IPv6 под своим
%% тегом. `General-address-literal` с произвольным standardized tag не
%% принимается — знать чужие теги валидатору неоткуда.
-spec address_literal(binary()) -> boolean().
address_literal(<<I, P, V, $6, $:, Address/binary>>)
  when (I =:= $I orelse I =:= $i),
       (P =:= $P orelse P =:= $p),
       (V =:= $V orelse V =:= $v) ->
    smtp_ipv6(Address);
address_literal(Address) ->
    smtp_ipv4(Address).
