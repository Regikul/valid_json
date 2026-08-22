%% Данные встроенных метасхем. Сгенерированный include содержит только плоский
%% immutable индекс «канонический URI документа — исходный JSON binary».
-module(valid_json_metaschema_data).

-include("valid_json_metaschema_data.hrl").
-include("valid_json_core.hrl").

-export([entries/0, entry/1]).

-spec entries() -> [{uri(), binary()}].
entries() ->
    lists:sort(maps:to_list(data())).

-spec entry(uri()) -> binary() | undefined.
entry(Uri) when is_binary(Uri) ->
    maps:get(Uri, data(), undefined).

-spec data() -> #{uri() => binary()}.
data() ->
    ?VALID_JSON_METASCHEMA_ENTRIES.
