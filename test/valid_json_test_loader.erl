%% Подставной загрузчик: тот самый случай, ради которого заведено поведение.
%% Библиотека не знает ни драйверов баз, ни чужих протоколов, поэтому загрузчик
%% пишет приложение — здесь его изображает функция в аргументе.
-module(valid_json_test_loader).

-behaviour(valid_json_loader).

-export([load/1, base_uri/1]).

load(#{load := Fun}) ->
    Fun().

base_uri(#{base := Base}) ->
    {ok, Base};
base_uri(#{}) ->
    undefined.
