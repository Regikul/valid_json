%% Точные fixtures таблицы format algorithms. Таблица отвечает только на вопрос
%% о строке и не знает ни об units, ни о режиме вычисления; обе роли keyword
%% покрыты в valid_json_eval_tests.
-module(valid_json_format_tests).

-include_lib("eunit/include/eunit.hrl").

%% Имя вне таблицы не «неверно», а не проверено: этот ответ отличается от false
%% и потому не может провалить assertion. Так остаются annotation-only и
%% пользовательские имена, и стандартные форматы, до которых таблица не дошла.
unsupported_test_() ->
    [?_assertEqual(unsupported,
                   valid_json_format:attribute(<<"idn-email">>, <<"a@b">>)),
     ?_assertEqual(unsupported,
                   valid_json_format:attribute(<<"iri">>, <<"/привет"/utf8>>)),
     ?_assertEqual(unsupported,
                   valid_json_format:attribute(<<"custom-name">>, <<>>)),
     ?_assertEqual(unsupported,
                   valid_json_format:attribute(<<"idn-hostname">>, <<"example">>))].

%% date — правило `full-date`: четыре цифры года, две месяца, две дня. Длина
%% месяца считается с григорианским правилом високосного года, включая вековые.
date_valid_test_() ->
    Valid = [<<"1963-06-19">>, <<"0001-01-01">>, <<"2020-02-29">>,
             <<"0400-02-29">>, <<"2020-01-31">>, <<"2020-04-30">>],
    [?_assert(is_date(String)) || String <- Valid].

date_invalid_test_() ->
    Invalid = [<<"2021-02-29">>, <<"0100-02-29">>, <<"2100-02-29">>,
               <<"2020-04-31">>, <<"1998-13-01">>, <<"2024-00-15">>,
               <<"2024-01-00">>, <<"1998-1-20">>, <<"1998-01-1">>,
               <<"20-01-01">>, <<"12020-01-01">>, <<"+2020-01-01">>,
               <<"2013-350">>, <<"20230328">>, <<"2023-W13-2">>,
               <<"2020.01.01">>, <<"2020-01-01Z">>, <<" 2024-01-15">>,
               <<"2024-01-15 ">>, <<"1963-06-1৪"/utf8>>, <<>>],
    [?_assertNot(is_date(String)) || String <- Invalid].

%% time — правило `full-time`: `partial-time` и обязательный offset. Секунда 60
%% допустима только там, где приведённое смещением время равно 23:59:60 UTC,
%% поэтому проверяются обе стороны суточной границы.
time_valid_test_() ->
    Valid = [<<"08:30:06Z">>, <<"08:30:06z">>, <<"23:20:50.52Z">>,
             <<"08:30:06+00:20">>, <<"12:34:56-00:00">>,
             <<"23:59:60Z">>, <<"01:29:60+01:30">>, <<"23:29:60+23:30">>,
             <<"15:59:60-08:00">>, <<"00:29:60-23:30">>],
    [?_assert(is_time(String)) || String <- Valid].

time_invalid_test_() ->
    Invalid = [<<"12:00:00">>, <<"12:00:00.52">>, <<"24:00:00Z">>,
               <<"00:60:00Z">>, <<"00:00:61Z">>,
               <<"23:59:60+01:00">>, <<"23:58:60Z">>, <<"22:59:60Z">>,
               <<"01:29:60+01:31">>, <<"00:29:60-23:29">>,
               <<"01:02:03+24:00">>, <<"01:02:03+00:60">>,
               <<"01:02:03Z+00:30">>, <<"08:30:06-8:000">>,
               <<"08:30:06#00:20">>, <<"08:30:06 PST">>,
               <<"08:30:06.Z">>, <<"01:01:01,1111">>, <<"8:3:6Z">>,
               <<"ab:cd:ef">>, <<"1২:00:00Z"/utf8>>, <<"Z">>, <<>>],
    [?_assertNot(is_time(String)) || String <- Invalid].

%% date-time — дата, разделитель одиннадцатым байтом и время теми же правилами.
%% Отдельно закрепляется, что разделитель ищется по месту, а не по первому `T`.
date_time_valid_test_() ->
    Valid = [<<"1963-06-19T08:30:06.283185Z">>, <<"1963-06-19t08:30:06z">>,
             <<"1937-01-01T12:00:27.87+00:20">>, <<"1998-12-31T23:59:60Z">>,
             <<"1998-12-31T15:59:60.123-08:00">>],
    [?_assert(is_date_time(String)) || String <- Valid].

date_time_invalid_test_() ->
    Invalid = [<<"1998-12-31T23:59:61Z">>, <<"1998-12-31T23:58:60Z">>,
               <<"1990-02-31T15:59:59.123-08:00">>,
               <<"1990-12-31T15:59:59-24:00">>, <<"1990-12-31T24:00:00Z">>,
               <<"1963-06-19T08:30:06.28123+01:00Z">>,
               <<"1963-06-19T08:30:06">>, <<"1963-06-19 08:30:06Z">>,
               <<"1963-6-19T08:30:06Z">>, <<"2013-350T01:01:01">>,
               <<"+11963-06-19T08:30:06Z">>, <<"T08:30:06Z">>,
               <<"1963-06-19T">>, <<>>],
    [?_assertNot(is_date_time(String)) || String <- Invalid].

%% duration — ABNF Appendix A. Вложенность правил строгая, поэтому units идут
%% только подряд, а недели не сочетаются ни с чем.
duration_valid_test_() ->
    Valid = [<<"P4DT12H30M5S">>, <<"P4Y">>, <<"P0D">>, <<"PT0S">>,
             <<"P1Y2M3DT4H5M6S">>, <<"P1Y2M">>, <<"P1M2D">>, <<"PT1H2M">>,
             <<"PT1M2S">>, <<"P10Y10M10DT10H10M10S">>, <<"P2W">>],
    [?_assert(is_duration(String)) || String <- Valid].

duration_invalid_test_() ->
    Invalid = [<<"P1Y2D">>, <<"PT1H2S">>, <<"P1D2H">>, <<"P2D1Y">>,
               <<"P2S">>, <<"PT1D">>, <<"P1Y2W">>, <<"P1W2D">>, <<"P2W1Y">>,
               <<"P">>, <<"PT">>, <<"P1YT">>, <<"P1DT">>, <<"P1">>,
               <<"PT0.5S">>, <<"4DT12H30M5S">>, <<" P1D">>, <<"P1D ">>,
               <<"P২Y"/utf8>>, <<>>],
    [?_assertNot(is_duration(String)) || String <- Invalid].

is_date(String) ->
    valid_json_format:attribute(<<"date">>, String).

is_time(String) ->
    valid_json_format:attribute(<<"time">>, String).

is_date_time(String) ->
    valid_json_format:attribute(<<"date-time">>, String).

is_duration(String) ->
    valid_json_format:attribute(<<"duration">>, String).

%% uuid — ASCII hex groups 8-4-4-4-12. Version, variant and all-zero value are
%% intentionally accepted; the format checks only the RFC 4122 string shape.
uuid_valid_test_() ->
    Valid = [<<"2EB8AA08-AA98-11EA-B4AA-73B441D16380">>,
             <<"2eb8aa08-aa98-11ea-b4aa-73b441d16380">>,
             <<"2eb8aa08-AA98-11EA-B4Aa-73B441D16380">>,
             <<"00000000-0000-0000-0000-000000000000">>,
             <<"99c17cbb-656f-664a-940f-1a4568f03487">>],
    [?_assert(is_uuid(String)) || String <- Valid].

uuid_invalid_test_() ->
    Invalid = [<<"2eb8aa08-aa98-11ea-b4aa-73b441d1638">>,
               <<"2eb8aa08-aa98-11ea-73b441d16380">>,
               <<"2eb8aa08-aa98-11ea-b4ga-73b441d16380">>,
               <<"2eb8aa08aa9811eab4aa73b441d16380">>,
               <<"urn:uuid:2eb8aa08-aa98-11ea-b4aa-73b441d16380">>,
               <<"2eb8aa08-aa98-11ea-b4aa-73b441d16380-">>,
               <<"২eb8aa08-aa98-11ea-b4aa-73b441d16380"/utf8>>, <<>>],
    [?_assertNot(is_uuid(String)) || String <- Invalid].

is_uuid(String) ->
    valid_json_format:attribute(<<"uuid">>, String).

%% regex — compileability only; matching the expression against a subject is
%% outside the format attribute's contract.
regex_valid_test_() ->
    Valid = [<<"([abc])+\\s+$">>, <<"^a+$">>, <<"">>, <<"[A-Z]+">>],
    [?_assert(is_regex(String)) || String <- Valid].

regex_invalid_test_() ->
    Invalid = [<<"^(abc]">>, <<"(">>, <<"[z-a]">>, <<"\\">>],
    [?_assertNot(is_regex(String)) || String <- Invalid].

is_regex(String) ->
    valid_json_format:attribute(<<"regex">>, String).

%% ipv4 — ровно четыре десятичных октета без ведущих нулей. Отвергаются как
%% чужие записи того же адреса (shorthand, hex, octal, целое число), так и любые
%% посторонние символы: цифры не-ASCII, пробелы, маска, порт и знаки.
ipv4_valid_test_() ->
    [?_assert(is_ipv4(<<"192.168.0.1">>)),
     ?_assert(is_ipv4(<<"0.0.0.0">>)),
     ?_assert(is_ipv4(<<"255.255.255.255">>))].

ipv4_invalid_test_() ->
    Invalid = [<<"127.0.0.0.1">>, <<"127.0.1">>, <<"127.1">>, <<"127.0">>,
               <<"256.256.256.256">>, <<"192.168.0.256">>,
               <<"010.0.0.1">>, <<"0x7f.0.0.1">>, <<"0o10.0.0.1">>,
               <<"0x7f000001">>, <<"2130706433">>, <<"1e2.0.0.1">>,
               <<"192.168..1">>, <<".192.168.0.1">>, <<"192.168.0.1.">>,
               <<"192.168.1.0/24">>, <<"192.168.0.1:80">>,
               <<"+1.2.3.4">>, <<"-1.2.3.4">>, <<"192.168.a.1">>,
               <<" 192.168.0.1">>, <<"192.168.0.1 ">>, <<"192. 168.0.1">>,
               <<"192.168.0.1\n">>, <<"192.168.0.1\t">>,
               <<"192.168.0.1", 0, ".evil.com">>,
               <<"1২7.0.0.1"/utf8>>, <<"１９２.１６８.１.１"/utf8>>, <<>>],
    [?_assertNot(is_ipv4(String)) || String <- Invalid].

is_ipv4(String) ->
    valid_json_format:attribute(<<"ipv4">>, String).

%% ipv6 — восемь групп по одной-четыре hex-цифры, одно сжатие `::` и
%% необязательный dotted-quad в хвосте, стоящий за две группы. Отдельно
%% закрепляется, что dotted-quad не считается адресом сам по себе и не годится
%% слева от сжатия.
ipv6_valid_test_() ->
    Valid = [<<"::1">>, <<"::">>, <<"d6::">>, <<"::abef">>, <<"::42:ff:1">>,
             <<"1:d6::42">>, <<"1:2:3:4:5:6::8">>,
             <<"1:2:3:4:5:6:7:8">>,
             <<"::ffff:192.168.0.1">>, <<"1:2::192.168.0.1">>,
             <<"1000:1000:1000:1000:1000:1000:255.255.255.255">>],
    [?_assert(is_ipv6(String)) || String <- Valid].

ipv6_invalid_test_() ->
    Invalid = [<<"1">>, <<"127.0.0.1">>, <<"1.2.3.4::">>, <<"::1:2.3.4">>,
               <<"12345::">>, <<"::abcef">>, <<"::laptop">>,
               <<"1:2:3:4:5:6:7">>, <<"1:2:3:4:5:6:7:8:9">>,
               <<":2:3:4:5:6:7:8">>, <<"1:2:3:4:5:6:7:">>, <<":2:3:4::8">>,
               <<"1::d6::42">>, <<"1:2:3:4:5:::8">>,
               <<"1::2:192.168.256.1">>, <<"1::2:192.168.ff.1">>,
               <<"1:2:3:4:1.2.3">>,
               <<"100:100:100:100:100:100:100:255.255.255.255">>,
               <<"fe80::/64">>, <<"fe80::a%eth1">>, <<"  ::1">>, <<"::1  ">>,
               <<"1:2:3:4:5:6:7:৪"/utf8>>, <<"1:2::192.16৪.0.1"/utf8>>, <<>>],
    [?_assertNot(is_ipv6(String)) || String <- Invalid].

is_ipv6(String) ->
    valid_json_format:attribute(<<"ipv6">>, String).

%% hostname — метки LDH через точку: дефис не с краю метки, цифра первым знаком
%% законна, метка не длиннее 63 знаков, имя целиком — 253.
hostname_valid_test_() ->
    Valid = [<<"www.example.com">>, <<"hostname">>, <<"h0stn4me">>,
             <<"1host">>, <<"host-name">>, <<"a-0-b.c">>,
             <<(binary:copy(<<"a">>, 63))/binary, ".com">>],
    [?_assert(is_hostname(String)) || String <- Valid].

hostname_invalid_test_() ->
    Invalid = [<<>>, <<".">>, <<".example">>, <<"example.">>,
               <<"-hostname">>, <<"hostname-">>, <<"host_name">>,
               <<"host name">>, <<"example．com"/utf8>>,
               <<(binary:copy(<<"a">>, 64))/binary, ".com">>,
               <<(binary:copy(<<"a.">>, 127))/binary, "com">>],
    [?_assertNot(is_hostname(String)) || String <- Invalid].

is_hostname(String) ->
    valid_json_format:attribute(<<"hostname">>, String).

%% email — правило `Mailbox`: dot-string либо quoted-string, `@` и домен из
%% меток или address literal. Разделителем берётся последний `@`, поэтому
%% quoted-string со своим `@` внутри остаётся верной. SMTP-варианты адресов
%% отличаются от standalone formats: IPv4 допускает ведущие нули, `::` в IPv6
%% заменяет не меньше двух групп, а тег `IPv6:` регистронезависим.
email_valid_test_() ->
    Valid = [<<"joe.bloggs@example.com">>, <<"te~st@example.com">>,
             <<"~test@example.com">>, <<"test~@example.com">>,
             <<"te.s.t@example.com">>,
             <<"\"joe bloggs\"@example.com">>,
             <<"\"joe..bloggs\"@example.com">>,
             <<"\"joe@bloggs\"@example.com">>,
             <<"\"joe\\\"bloggs\"@example.com">>,
             <<"joe.bloggs@[127.0.0.1]">>,
             <<"joe.bloggs@[001.002.003.004]">>,
             <<"joe.bloggs@[IPv6:::1]">>, <<"joe.bloggs@[ipv6:::1]">>],
    [?_assert(is_email(String)) || String <- Valid].

email_invalid_test_() ->
    Invalid = [<<"2962">>, <<"@example.com">>, <<"joe.bloggs@">>,
               <<".test@example.com">>, <<"test.@example.com">>,
               <<"te..st@example.com">>, <<"joe bloggs@example.com">>,
               <<"joe.bloggs@invalid=domain.com">>,
               <<"joe.bloggs@[127.0.0.300]">>,
               <<"joe.bloggs@[IPv6:12345::]">>,
               <<"joe.bloggs@[IPv6:1:2:3:4:5:6::8]">>,
               <<"joe.bloggs@[tag:127.0.0.1]">>,
               <<"joe.bloggs@[127.0.0.1">>, <<"joe.bloggs@127.0.0.1]">>,
               <<"\"joe bloggs@example.com">>,
               <<"user1@oceania.org, user2@oceania.org">>,
               <<"\"Winston Smith\" <winston.smith@recdep.minitrue>">>,
               <<"joe.bloggs@пример.рф"/utf8>>, <<>>],
    [?_assertNot(is_email(String)) || String <- Invalid].

is_email(String) ->
    valid_json_format:attribute(<<"email">>, String).

%% URI-family attributes. Conformance suite дополнительно проверяет полный
%% набор официальных cases обоих dialects.
uri_valid_test_() ->
    Valid = [<<"http://foo.bar/?baz=qux#quux">>,
             <<"http://-.~_!$&'()*+,;=:%40:80%2f::::::@example.com">>,
             <<"ldap://[2001:db8::7]/c=GB?objectClass?one">>,
             <<"mailto:John.Doe@example.com">>,
             <<"urn:oasis:names:specification:docbook:dtd:xml:4.1.2">>,
             <<"http://999.999.999.999/">>],
    Invalid = [<<"//foo.bar/?baz=qux#quux">>, <<"/abc">>, <<"abc">>,
               <<"http:// shouldfail.com">>, <<":// should fail">>,
               <<"https://example.org/foobar®.txt"/utf8>>,
               <<"https://example.org/foobar\\.txt">>,
               <<"https://example.org/foo bar.txt">>,
               <<"http://example.com/%6G">>, <<"http://example.com/%A">>,
               <<"http://example.com/%">>, <<"1http://example.com">>,
               <<"ht_tp://example.com">>, <<"http://example.com:abc/path">>],
    checks(<<"uri">>, Valid, Invalid).

uri_reference_valid_test_() ->
    Valid = [<<>>, <<"http://foo.bar/?baz=qux#quux">>,
             <<"//foo.bar/?baz=qux#quux">>, <<"/abc">>, <<"abc">>,
             <<"#fragment">>, <<"../other.json">>, <<"?query">>],
    Invalid = [<<"\\\\WINDOWS\\fileshare">>, <<"#frag\\ment">>,
               <<"/foobar®.txt"/utf8>>, <<"https://example.org/foobar\\.txt">>,
               <<"http://example.com/%ZZ">>],
    checks(<<"uri-reference">>, Valid, Invalid).

uri_template_valid_test_() ->
    Valid = [<<>>, <<"http://example.com/dictionary/{term:1}/{term}">>,
             <<"http://example.com/dictionary">>, <<"dictionary/{term}">>,
             <<"{var}">>, <<"{+path}">>, <<"{#fragment}">>,
             <<"{.list*}">>, <<"{/segments*}">>, <<"{?query,number}">>,
             <<"{&query}">>, <<"{foo%20bar}">>,
             <<"/привет/{name}"/utf8>>],
    Invalid = [<<"http://example.com/dictionary/{term:1}/{term">>,
               <<"{ }">>, <<"{}">>, <<"{var,,other}">>,
               <<"{var:0}">>, <<"{var:10000}">>, <<"{var**}">>,
               <<"{.}">>, <<"{foo..bar}">>, <<"{foo%ZZ}">>,
               <<"foo%q">>, <<"foo{bar">>, <<"foo}bar">>,
               <<"foo\\bar">>],
    checks(<<"uri-template">>, Valid, Invalid).

json_pointer_valid_test_() ->
    Valid = [<<>>, <<"/foo/bar~0/baz~1/%a">>, <<"/foo//bar">>,
             <<"/foo/bar/">>, <<"/">>, <<"/a~1b">>, <<"/c%d">>,
             <<"/e^f">>, <<"/g|h">>, <<"/i\\j">>, <<"/k\"l">>,
             <<"/foo/-/bar">>, <<"/foo/bar/😎"/utf8>>,
             <<"/foo\0bar\nbaz">>],
    Invalid = [<<"#">>, <<"a">>, <<"0">>, <<"/foo/bar~">>,
               <<"/~0~">>, <<"/~2">>, <<"/~~">>, <<"/~-1">>],
    checks(<<"json-pointer">>, Valid, Invalid).

relative_json_pointer_valid_test_() ->
    Valid = [<<"0">>, <<"1">>, <<"0/foo/bar">>, <<"2/0/baz/1/zip">>,
             <<"0#">>, <<"120/foo/bar">>, <<"100">>, <<"1/~0/~1">>],
    Invalid = [<<"/foo/bar">>, <<"-1/foo/bar">>, <<"+1/foo/bar">>,
               <<"١/foo"/utf8>>, <<"0##">>, <<"01/a">>, <<"01#">>,
               <<>>, <<"1/foo~2">>],
    checks(<<"relative-json-pointer">>, Valid, Invalid).

checks(Name, Valid, Invalid) ->
    [?_assertEqual(true, valid_json_format:attribute(Name, String))
     || String <- Valid] ++
    [?_assertEqual(false, valid_json_format:attribute(Name, String))
     || String <- Invalid].
