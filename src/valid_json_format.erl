%% Обработчик keyword `format` и таблица его algorithms. Keyword живёт в одном
%% модуле обеими ролями: annotation обязательна всегда, а assertion добавляется
%% к ней и вердикта annotation не отменяет. Контракт handler'а — okf/architecture
%% /validator-core.md, раздел «Контракт handler'а».
-module(valid_json_format).

-include("valid_json_core.hrl").

-export([check/3]).

-ifdef(TEST).
-export([attribute/2]).
-endif.

%% Аннотацией `format` становится само имя формата, и собирать его нужно даже
%% для незнакомых имён (draft-2020-12/validation.txt:713). Вердикт даёт только
%% ветвь assertion, которую компилятор строит по опции `assert_format` либо по
%% активной Format-Assertion vocabulary.
-spec check(constraint(), json(), #eval_context{}) -> #eval_result{}.
check({format, Name, Assert}, Instance, #eval_context{format = flag}) ->
    valid_json_eval:empty_result(holds(Assert, Name, Instance));
check({format, Name, Assert}, Instance, Context) ->
    report(Name, holds(Assert, Name, Instance), Context).

%% Формат ограничивает только свой тип instance: все стандартные attributes
%% описывают строки, поэтому значение другого типа проходит успешно
%% (validation.txt:565). Имя вне таблицы assertion не проваливает: реализация
%% вправе не проверять любой attribute вовсе (validation.txt:624), а при
%% Format-Assertion незнакомое имя отвергается ещё компилятором.
-spec holds(boolean(), binary(), json()) -> boolean().
holds(false, _Name, _Instance) ->
    true;
holds(true, Name, Instance) when is_binary(Instance) ->
    case attribute(Name, Instance) of
        unsupported -> true;
        Valid       -> Valid
    end;
holds(true, _Name, _Instance) ->
    true.

%% Успешный assertion аннотацию не отменяет: собрать её обязана и реализация
%% Format-Assertion vocabulary (validation.txt:653). Провалившийся unit свои
%% annotations и так теряет, поэтому там остаётся одно сообщение.
-spec report(binary(), boolean(), #eval_context{}) -> #eval_result{}.
report(Name, true, Context) ->
    Unit = valid_json_unit:keyword(<<"format">>, true, {annotation, Name}, Context),
    #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(), units = [Unit]};
report(Name, false, Context) ->
    Unit = valid_json_unit:keyword(<<"format">>, false,
                                   {error, message(Name)}, Context),
    #eval_result{valid = false, evaluated = valid_json_evaluated:neutral(), units = [Unit]}.

-spec message(binary()) -> binary().
message(Name) ->
    <<"value is not a valid ", Name/binary>>.

%% Таблица format algorithms. Имя, которого здесь нет, возвращает
%% `unsupported`: это не «формат неверен», а «проверки нет», и обе ветви
%% вызывающего различают эти ответы. Уровень поддержки каждого имени
%% зафиксирован в okf/architecture/format-attributes.md.
-spec attribute(binary(), binary()) -> boolean() | unsupported.
%% Четыре attributes RFC 3339 разбирает отдельный модуль: арифметика
%% високосного года и leap second рядом с таблицей не помещается.
attribute(<<"date">>, String) ->
    valid_json_format_time:date(String);
attribute(<<"time">>, String) ->
    valid_json_format_time:time(String);
attribute(<<"date-time">>, String) ->
    valid_json_format_time:date_time(String);
attribute(<<"duration">>, String) ->
    valid_json_format_time:duration(String);
%% Сетевые attributes собраны в свой модуль по той же причине: адрес IPv6
%% кончается dotted-quad, а домен письма бывает и address literal, и именем из
%% меток hostname, так что разбирать их порознь не выходит.
attribute(<<"ipv4">>, String) ->
    valid_json_format_net:ipv4(String);
attribute(<<"ipv6">>, String) ->
    valid_json_format_net:ipv6(String);
attribute(<<"hostname">>, String) ->
    valid_json_format_net:hostname(String);
attribute(<<"email">>, String) ->
    valid_json_format_net:email(String);
%% URI-family attributes share the stdlib RFC 3986 parser where possible;
%% pointer/template grammars are kept in a separate module.
attribute(<<"uri">>, String) ->
    valid_json_format_uri:uri(String);
attribute(<<"uri-reference">>, String) ->
    valid_json_format_uri:uri_reference(String);
attribute(<<"uri-template">>, String) ->
    valid_json_format_uri:uri_template(String);
attribute(<<"json-pointer">>, String) ->
    valid_json_format_uri:json_pointer(String);
attribute(<<"relative-json-pointer">>, String) ->
    valid_json_format_uri:relative_json_pointer(String);
attribute(<<"uuid">>, String) ->
    valid_json_format_misc:uuid(String);
attribute(<<"regex">>, String) ->
    valid_json_format_misc:regex(String);
attribute(_Name, _String) ->
    unsupported.
