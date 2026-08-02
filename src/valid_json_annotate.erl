%% Обработчик annotation-only keywords. Спрашивать о значении им нечего и
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
    #eval_result{valid = true, evaluated = valid_json_evaluated:neutral(), units = [Unit]}.
