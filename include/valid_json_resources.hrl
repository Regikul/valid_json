%% Чистый реестр документов слоя resources. Вычислительное ядро эти записи не
%% читает; общий include нужен store, будущему compiler и точным fixtures.
%% Нормативное описание — okf/architecture/validator-resources-runtime.md.

-ifndef(VALID_JSON_RESOURCES_HRL).
-define(VALID_JSON_RESOURCES_HRL, true).

-include("valid_json_core.hrl").

-define(DRAFT_2020_12,
        <<"https://json-schema.org/draft/2020-12/schema">>).
-define(DRAFT_2019_09,
        <<"https://json-schema.org/draft/2019-09/schema">>).

%% Профиль компиляции: dialect и активные vocabularies. `uri` — то, что написано
%% в `$schema` либо выбрано опцией, `draft` — каноническая база, задающая состав
%% и имена keywords. В compiled() профиль не попадает: различия впечатываются в
%% IR, а evaluator dialect не читает.
-record(profile, {
    uri          :: dialect(),
    draft        :: dialect(),
    vocabularies :: [atom()]
}).

-type profile() :: #profile{}.

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
