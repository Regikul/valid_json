%% Чистый реестр документов слоя resources. Вычислительное ядро эти записи не
%% читает; общий include нужен store, будущему compiler и точным fixtures.
%% Нормативное описание — okf/architecture/validator-resources-runtime.md.

-ifndef(VALID_JSON_RESOURCES_HRL).
-define(VALID_JSON_RESOURCES_HRL, true).

-include("valid_json_core.hrl").

-define(STANDARD_STORE, valid_json).
%% `base_uri` стандартного хранилища. Схемы приложения, которому хватает одного
%% набора, принадлежат самой библиотеке, и назвать их именем чужого сервиса
%% нельзя. Домен `.internal` зарезервирован ICANN за частными сетями, поэтому
%% имя схемы никогда не совпадёт с адресом, за которым что-то отвечает.
-define(STANDARD_BASE_URI, <<"https://valid_json.internal/schemas/">>).

-define(DRAFT_2020_12,
        <<"https://json-schema.org/draft/2020-12/schema">>).
-define(DRAFT_2019_09,
        <<"https://json-schema.org/draft/2019-09/schema">>).
-define(DRAFT_07,
        <<"http://json-schema.org/draft-07/schema">>).
-define(DRAFT_06,
        <<"http://json-schema.org/draft-06/schema">>).

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

%% Политика проверки корней resources их метасхемами: значение называет формат,
%% в котором докладывается провал. Это решение компиляции, и ядро его не читает.
%% `trusted` пропускает проверку целиком и существует только в test build, где
%% схемы fixtures выписаны вручную и заведомо валидны; поставляемая библиотека
%% проверяет всегда.
-type schema_validation() :: trusted | format().

-record(document, {
    registered :: uri(),
    canonical :: uri(),
    json      :: json()
}).

-record(store, {
    base = anonymous :: uri() | anonymous,
    documents = #{}  :: #{uri() => #document{}}
}).

-type store() :: #store{}.
%% Опция самого реестра. Опции размещённого хранилища шире и принадлежат
%% управляющему: реестр про диалект и format ничего не знает.
-type registry_option() :: {base_uri, uri()}.

-endif.
