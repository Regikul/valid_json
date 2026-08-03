%% Активные vocabularies схемы и принадлежность keywords. Модуль отвечает на
%% два вопроса компилятора: какой профиль задаёт dialect и активен ли keyword в
%% этом профиле. Нормативное описание — okf/architecture/validator-resources-
%% runtime.md, раздел «Dialect и vocabularies».
-module(valid_json_vocabulary).

-include("valid_json_resources.hrl").

-export([canonical/1, declared/3, active/2]).

%% Имена vocabularies внутри реализации — атомы: они не зависят от dialect и
%% потому читаются в таблице keywords. URI отличаются префиксом draft, поэтому
%% каждая таблица перечисляет свои тринадцать имён целиком.
-define(VOCABULARIES_2020_12,
        [{<<"https://json-schema.org/draft/2020-12/vocab/core">>, core},
         {<<"https://json-schema.org/draft/2020-12/vocab/applicator">>, applicator},
         {<<"https://json-schema.org/draft/2020-12/vocab/unevaluated">>, unevaluated},
         {<<"https://json-schema.org/draft/2020-12/vocab/validation">>, validation},
         {<<"https://json-schema.org/draft/2020-12/vocab/meta-data">>, meta_data},
         {<<"https://json-schema.org/draft/2020-12/vocab/format-annotation">>,
          format_annotation},
         {<<"https://json-schema.org/draft/2020-12/vocab/content">>, content}]).

%% Format-Assertion в таблицу не входит намеренно. Реализация без полной
%% проверки всех стандартных format attributes обязана отказаться обрабатывать
%% схему, объявившую этот vocabulary значением `true` (validation.txt:651), а
%% таблица алгоритмов открыта до P8. Отсутствие имени в таблице даёт ровно такой
%% отказ; значение `false` остаётся необязательным и игнорируется.

-define(VOCABULARIES_2019_09,
        [{<<"https://json-schema.org/draft/2019-09/vocab/core">>, core},
         {<<"https://json-schema.org/draft/2019-09/vocab/applicator">>, applicator},
         {<<"https://json-schema.org/draft/2019-09/vocab/validation">>, validation},
         {<<"https://json-schema.org/draft/2019-09/vocab/meta-data">>, meta_data},
         {<<"https://json-schema.org/draft/2019-09/vocab/format">>, format},
         {<<"https://json-schema.org/draft/2019-09/vocab/content">>, content}]).

%% Набор канонического dialect повторяет `$vocabulary` его корневой метасхемы.
%% В Draft 2019-09 format объявлен там значением `false`, поэтому в набор он не
%% входит: этот boolean управляет assertion, а обязательная аннотация активна и
%% без него (см. active/2). Format-Assertion Draft 2020-12 в корневую метасхему
%% тоже не входит и включается только пользовательской.
-define(CANONICAL_2020_12,
        [applicator, content, core, format_annotation, meta_data, unevaluated,
         validation]).
-define(CANONICAL_2019_09,
        [applicator, content, core, meta_data, validation]).

%% Профиль канонического dialect встроен: его метасхема известна заранее и
%% читать её ради `$vocabulary` незачем.
-spec canonical(dialect()) -> #profile{}.
canonical(?DRAFT_2020_12 = Draft) ->
    #profile{uri = Draft, draft = Draft, vocabularies = ?CANONICAL_2020_12};
canonical(?DRAFT_2019_09 = Draft) ->
    #profile{uri = Draft, draft = Draft, vocabularies = ?CANONICAL_2019_09}.

%% Профиль, объявленный пользовательской метасхемой. Draft приходит от dialect
%% самой метасхемы: он решает, какие URI vocabularies вообще существуют и как
%% называются keywords. Метасхема без `$vocabulary` считается объявившей все
%% vocabularies своего draft: Core этого требует прямо, остальные — правилом
%% «as if its URI were present with a value of true» из своих разделов.
-spec declared(uri(), json(), dialect()) -> {ok, #profile{}} | {error, reason()}.
declared(Uri, #{<<"$vocabulary">> := Declared}, Draft) when is_map(Declared) ->
    case names(lists:sort(maps:keys(Declared)), Declared, Draft, []) of
        {ok, Active} ->
            case lists:member(core, Active) of
                true  -> {ok, #profile{uri = Uri, draft = Draft,
                                       vocabularies = lists:sort(Active)}};
                false -> {error, core_vocabulary_missing}
            end;
        {error, _} = Error ->
            Error
    end;
declared(_Uri, #{<<"$vocabulary">> := Other}, _Draft) ->
    {error, {bad_keyword_value, Other}};
declared(Uri, _Metaschema, Draft) ->
    #profile{vocabularies = Vocabularies} = canonical(Draft),
    {ok, #profile{uri = Uri, draft = Draft, vocabularies = Vocabularies}}.

%% Неизвестный vocabulary со значением `true` останавливает компиляцию: схема
%% написана на языке, который реализация не понимает. Со значением `false` он
%% остаётся необязательным и просто не включается.
-spec names([uri()], #{uri() => json()}, dialect(), [atom()]) ->
          {ok, [atom()]} | {error, reason()}.
names([], _Declared, _Draft, Acc) ->
    {ok, Acc};
names([Uri | Rest], Declared, Draft, Acc) ->
    case {maps:get(Uri, Declared), name(Uri, Draft)} of
        {Required, _} when not is_boolean(Required) ->
            {error, {bad_keyword_value, Required}};
        {true, {ok, Name}} ->
            names(Rest, Declared, Draft, [Name | Acc]);
        {false, {ok, _Name}} ->
            names(Rest, Declared, Draft, Acc);
        {true, error} ->
            {error, {unrecognized_vocabulary, Uri}};
        {false, error} ->
            names(Rest, Declared, Draft, Acc)
    end.

-spec name(uri(), dialect()) -> {ok, atom()} | error.
name(Uri, Draft) ->
    Table = case Draft of
                ?DRAFT_2020_12 -> ?VOCABULARIES_2020_12;
                ?DRAFT_2019_09 -> ?VOCABULARIES_2019_09
            end,
    case lists:keyfind(Uri, 1, Table) of
        {Uri, Name} -> {ok, Name};
        false       -> error
    end.

%% Keyword неактивного vocabulary остаётся неизвестным: в Draft 2020-12 он
%% станет annotation, в Draft 2019-09 будет проигнорирован.
%%
%% `format` в Draft 2019-09 — исключение: аннотацию спецификация требует
%% собирать независимо от объявленного boolean, и объявлена там эта vocabulary
%% как раз значением `false` (validation.txt:601 и 695). В Draft 2020-12 keyword
%% определяется своей vocabulary; выключенный `format` всё равно доходит до
%% аннотации неизвестным keyword, поэтому наблюдаемый unit тот же.
-spec active(binary(), #profile{}) -> boolean().
active(<<"format">>, #profile{draft = ?DRAFT_2019_09}) ->
    true;
%% `definitions` — не vocabulary keyword, а compatibility-имя из корневых
%% стандартных метасхем обоих dialects; оно резервирует те же locations, что
%% `$defs` (validator-resources-runtime.md, «Dialect и vocabularies»).
active(<<"definitions">>, _Profile) ->
    true;
active(Keyword, #profile{draft = Draft, vocabularies = Active}) ->
    case vocabulary(Keyword, Draft) of
        unknown -> false;
        Name    -> lists:member(Name, Active)
    end.

%% Состав vocabularies взят из vocabulary meta-schemas в priv/json_schema.
%% Keyword, отсутствующий в таблице своего draft, является неизвестным: так
%% `prefixItems` не работает в Draft 2019-09, а `additionalItems` — в 2020-12.
-spec vocabulary(binary(), dialect()) -> atom() | unknown.
vocabulary(<<"$id">>, _Draft)               -> core;
vocabulary(<<"$schema">>, _Draft)           -> core;
vocabulary(<<"$ref">>, _Draft)              -> core;
vocabulary(<<"$anchor">>, _Draft)           -> core;
vocabulary(<<"$defs">>, _Draft)             -> core;
vocabulary(<<"$comment">>, _Draft)          -> core;
vocabulary(<<"$vocabulary">>, _Draft)       -> core;
vocabulary(<<"$dynamicRef">>, ?DRAFT_2020_12)     -> core;
vocabulary(<<"$dynamicAnchor">>, ?DRAFT_2020_12)  -> core;
vocabulary(<<"$recursiveRef">>, ?DRAFT_2019_09)   -> core;
vocabulary(<<"$recursiveAnchor">>, ?DRAFT_2019_09) -> core;

vocabulary(<<"prefixItems">>, ?DRAFT_2020_12)      -> applicator;
vocabulary(<<"additionalItems">>, ?DRAFT_2019_09)  -> applicator;
vocabulary(<<"items">>, _Draft)             -> applicator;
vocabulary(<<"contains">>, _Draft)          -> applicator;
vocabulary(<<"properties">>, _Draft)        -> applicator;
vocabulary(<<"patternProperties">>, _Draft) -> applicator;
vocabulary(<<"additionalProperties">>, _Draft) -> applicator;
vocabulary(<<"propertyNames">>, _Draft)     -> applicator;
vocabulary(<<"dependentSchemas">>, _Draft)  -> applicator;
vocabulary(<<"allOf">>, _Draft)             -> applicator;
vocabulary(<<"anyOf">>, _Draft)             -> applicator;
vocabulary(<<"oneOf">>, _Draft)             -> applicator;
vocabulary(<<"not">>, _Draft)               -> applicator;
vocabulary(<<"if">>, _Draft)                -> applicator;
vocabulary(<<"then">>, _Draft)              -> applicator;
vocabulary(<<"else">>, _Draft)              -> applicator;

%% Отдельная vocabulary для unevaluated keywords появилась только в Draft
%% 2020-12; в Draft 2019-09 они входят в applicator.
vocabulary(<<"unevaluatedItems">>, ?DRAFT_2020_12)      -> unevaluated;
vocabulary(<<"unevaluatedProperties">>, ?DRAFT_2020_12) -> unevaluated;
vocabulary(<<"unevaluatedItems">>, ?DRAFT_2019_09)      -> applicator;
vocabulary(<<"unevaluatedProperties">>, ?DRAFT_2019_09) -> applicator;

vocabulary(<<"type">>, _Draft)              -> validation;
vocabulary(<<"enum">>, _Draft)              -> validation;
vocabulary(<<"const">>, _Draft)             -> validation;
vocabulary(<<"multipleOf">>, _Draft)        -> validation;
vocabulary(<<"maximum">>, _Draft)           -> validation;
vocabulary(<<"exclusiveMaximum">>, _Draft)  -> validation;
vocabulary(<<"minimum">>, _Draft)           -> validation;
vocabulary(<<"exclusiveMinimum">>, _Draft)  -> validation;
vocabulary(<<"maxLength">>, _Draft)         -> validation;
vocabulary(<<"minLength">>, _Draft)         -> validation;
vocabulary(<<"pattern">>, _Draft)           -> validation;
vocabulary(<<"maxItems">>, _Draft)          -> validation;
vocabulary(<<"minItems">>, _Draft)          -> validation;
vocabulary(<<"uniqueItems">>, _Draft)       -> validation;
vocabulary(<<"maxContains">>, _Draft)       -> validation;
vocabulary(<<"minContains">>, _Draft)       -> validation;
vocabulary(<<"maxProperties">>, _Draft)     -> validation;
vocabulary(<<"minProperties">>, _Draft)     -> validation;
vocabulary(<<"required">>, _Draft)          -> validation;
vocabulary(<<"dependentRequired">>, _Draft) -> validation;

vocabulary(<<"title">>, _Draft)             -> meta_data;
vocabulary(<<"description">>, _Draft)       -> meta_data;
vocabulary(<<"default">>, _Draft)           -> meta_data;
vocabulary(<<"deprecated">>, _Draft)        -> meta_data;
vocabulary(<<"readOnly">>, _Draft)          -> meta_data;
vocabulary(<<"writeOnly">>, _Draft)         -> meta_data;
vocabulary(<<"examples">>, _Draft)          -> meta_data;

vocabulary(<<"format">>, ?DRAFT_2020_12)    -> format_annotation;
vocabulary(<<"format">>, ?DRAFT_2019_09)    -> format;

vocabulary(<<"contentEncoding">>, _Draft)   -> content;
vocabulary(<<"contentMediaType">>, _Draft)  -> content;
vocabulary(<<"contentSchema">>, _Draft)     -> content;

vocabulary(_Keyword, _Draft)                -> unknown.
