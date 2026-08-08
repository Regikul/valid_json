%% Обработчик annotation-only keywords. Спрашивать о значении им нечего и
%% спускаться некуда: вердикт всегда успешен, покрытия они не вносят, а значение
%% keyword целиком становится аннотацией собственного unit. `format` тоже
%% аннотирует, но умеет ещё и проверять, поэтому живёт в valid_json_format.
%% Контракт handler'а — okf/architecture/validator-core.md, раздел «Контракт
%% handler'а».
-module(valid_json_annotate).

-include("valid_json_core.hrl").

-export([check/3]).

%% Instance не участвует: meta-data keywords описывают позицию, а не значение,
%% и применимы к любому типу. В режиме flag units не собираются: там ответ
%% исчерпывается вердиктом, а вердикт эти keywords не меняют.
-spec check(constraint(), json(), #eval_context{}) -> #eval_result{}.
check({annotation, _Keyword, _Value}, _Instance, #eval_context{format = flag}) ->
    valid_json_eval:empty_result(true);
check({annotation, Keyword, Value}, _Instance, Context) ->
    Units = valid_json_unit:keyword_units(
              Keyword, true, {annotation, Value}, [], Context),
    #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(), units = Units};
%% Content keywords описывают строку, закодировавшую не-JSON документ, и к
%% значениям других типов не применяются вовсе (validation.txt:945). Поэтому
%% не-строка даёт успешный unit без annotation — то же правило применимости, что
%% и у assertions над своим типом. Декодировать, разбирать и проверять
%% содержимое строки по умолчанию нельзя (validation.txt:939), так что вердикт
%% успешен и для испорченного содержимого: и `contentEncoding`, и
%% `contentMediaType`, и `contentSchema` остаются чистыми annotations.
check({content, _Keyword, _Value}, _Instance, #eval_context{format = flag}) ->
    valid_json_eval:empty_result(true);
check({content, Keyword, Value}, Instance, Context) when is_binary(Instance) ->
    Units = valid_json_unit:keyword_units(
              Keyword, true, {annotation, Value}, [], Context),
    #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(), units = Units};
check({content, Keyword, _Value}, _Instance, Context) ->
    Units = valid_json_unit:keyword_units(Keyword, true, none, [], Context),
    #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(), units = Units}.
