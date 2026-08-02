%% Чистый реестр документов слоя resources. Вычислительное ядро эти записи не
%% читает; общий include нужен store, будущему compiler и точным fixtures.
%% Нормативное описание — okf/architecture/validator-resources-runtime.md.

-ifndef(VALID_JSON_RESOURCES_HRL).
-define(VALID_JSON_RESOURCES_HRL, true).

-include("valid_json_core.hrl").

-record(document, {
    retrieval :: uri(),
    canonical :: uri(),
    json      :: json()
}).

-record(store, {
    base = anonymous :: uri() | anonymous,
    documents = #{}  :: #{uri() => #document{}}
}).

-type store() :: #store{}.
-type store_option() :: {base_uri, uri()}.

-endif.
