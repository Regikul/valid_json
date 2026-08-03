%% Обработчик annotation-only keywords и аннотирующего `format`. Спрашивать о
%% значении им нечего и
%% спускаться некуда: вердикт всегда успешен, покрытия они не вносят, а значение
%% keyword целиком становится аннотацией собственного unit. Контракт handler'а —
%% okf/architecture/validator-core.md, раздел «Контракт handler'а».
-module(valid_json_annotate).

-include("valid_json_core.hrl").

-export([check/3]).

%% Instance не участвует: meta-data keywords описывают позицию, а не значение,
%% и применимы к любому типу. В режиме flag units не собираются: там ответ
%% исчерпывается вердиктом, а вердикт эти keywords не меняют.
-spec check(constraint(), json(), #eval_context{}) -> #eval_result{}.
check({annotation, _Keyword, _Value}, _Instance, #eval_context{mode = flag}) ->
    #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(), units = []};
check({annotation, Keyword, Value}, _Instance, Context) ->
    Unit = valid_json_unit:keyword(Keyword, true, {annotation, Value}, Context),
    #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(), units = [Unit]};
%% Аннотацией `format` становится само имя формата, и собирать его нужно даже
%% для незнакомых имён (draft-2020-12/validation.txt:713). Ветвь assertion
%% компилятор пока не строит: её алгоритмы и таблица имён остаются в P8.
check({format, _Name, false}, _Instance, #eval_context{mode = flag}) ->
    #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(), units = []};
check({format, Name, false}, _Instance, Context) ->
    Unit = valid_json_unit:keyword(<<"format">>, true, {annotation, Name}, Context),
    #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(), units = [Unit]};
%% Content keywords описывают строку, закодировавшую не-JSON документ, и к
%% значениям других типов не применяются вовсе (validation.txt:945). Поэтому
%% не-строка даёт успешный unit без annotation — то же правило применимости, что
%% и у assertions над своим типом. Декодировать, разбирать и проверять
%% содержимое строки по умолчанию нельзя (validation.txt:939), так что вердикт
%% успешен и для испорченного содержимого: и `contentEncoding`, и
%% `contentMediaType`, и `contentSchema` остаются чистыми annotations.
check({content, _Keyword, _Value}, _Instance, #eval_context{mode = flag}) ->
    #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(), units = []};
check({content, Keyword, Value}, Instance, Context) when is_binary(Instance) ->
    Unit = valid_json_unit:keyword(Keyword, true, {annotation, Value}, Context),
    #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(), units = [Unit]};
check({content, Keyword, _Value}, _Instance, Context) ->
    Unit = valid_json_unit:keyword(Keyword, true, none, Context),
    #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(), units = [Unit]}.
