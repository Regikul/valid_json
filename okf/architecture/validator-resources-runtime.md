---
type: Architecture
title: Validator resources and runtime
description: Schema resources, URI resolution, registry, compilation errors, dialects, ETS ownership, reload and invalidation.
tags: [json-schema, architecture, resources, compiler, registry, ets, runtime]
status: draft
---

# Контракт с core

Этот слой строит типы, определённые в [validator-core](validator-core.md), и не переопределяет их. Результат компиляции — полное транзитивное замыкание resources: все nodes и ссылки готовы, сетевых и registry lookup на пути `validate/3` нет. Runtime хранит `compiled()` как непрозрачное значение.

Resources участвует в JSON Schema conformance; runtime ownership — библиотечная эксплуатационная надстройка и официальным suite не проверяется.

# Schema resources

Schema resource — схема с каноническим абсолютным URI ([core.txt:547](../references/json-schema/draft-2020-12/core.txt)). Корень документа и каждая признанная подсхема с `$id` образуют отдельные resources. Resource является общей областью:

| Область | Данные в `#resource{}` |
| --- | --- |
| base URI и абсолютные локации | `id` |
| dialect | `dialect` |
| статические и динамические anchors | `anchors`, `dynamic_anchors` |
| Draft 2019-09 recursive scope | `recursive_anchor` |
| JSON Pointer space | `nodes` |

Встроенный resource без `$schema` наследует dialect объемлющего ([core.txt:2122](../references/json-schema/draft-2020-12/core.txt)). В Draft 2020-12 это нормативно; для Draft 2019-09 это выбранное implementation-defined поведение. Resource с собственным `$schema` может сменить dialect. Указатели внутри нового resource считаются заново от его корня, поэтому синтаксический путь в документе не используется как `pointer()`.

Компилятор посещает только schema positions, заданные активными applicator keywords или `$defs`. `$id` внутри неизвестного значения не создаёт resource; ссылка в такое место завершается `non_schema_target`. Это сохраняет требуемое поведение `optional/unknownKeyword`; несовместимый `optional/refOfUnknownKeyword` находится вне профиля как undefined behavior.

# Registry без сети

Документы регистрируются до компиляции. `$ref` и `$schema` читают один реестр; незарегистрированный URI — compile error. Conformance remotes кладутся под `http://localhost:1234/...`, метасхемы — из [`priv/json_schema/`](../../priv/json_schema/), без resolver callback или download; URI не означает обязательной сетевой загрузки ([core.txt:1826](../references/json-schema/draft-2020-12/core.txt)).

```erlang
-type store() :: #{uri() => json() | {alias, uri()}}.

fetch(Uri, Store) ->
    case maps:get(Uri, Store, undefined) of
        {alias, Canonical} -> maps:get(Canonical, Store, undefined);
        Doc                -> Doc
    end.
```

Документ хранится один раз. Alias всегда указывает прямо на canonical key, поэтому цепочки и циклы невозможны. Кортеж alias не конфликтует с JSON value model. Map допускает произвольное число внешних aliases; `add/3` создаёт только retrieval/canonical пару, а API добавления остальных имён остаётся частью открытого registry mutation contract.

## Имена

`add/3` получает retrieval URI и корневой `$id`, разрешённый относительно него. Если `$id` отличается, canonical key берётся из `$id`, а retrieval URI становится alias. Занятое другим документом имя даёт `name_taken`, не перезапись.

| Точка входа | `$id` | `rid` / `#resource.id` |
| --- | --- | --- |
| retrieval URI | отсутствует | retrieval URI |
| retrieval URI | совпадает или отличается | разрешённый `$id`; retrieval остаётся именем документа |
| inline term | абсолютный | `$id` |
| inline term | отсутствует | `anonymous` / `undefined` |

Именем документа в `sources` остаётся retrieval/canonical key, из которого resource был получен; embedded `$id` туда отдельным документом не добавляется. Метасхема входит в `sources`, хотя её nodes не входят в `resources`: её `$vocabulary` влияет на артефакт и должна инвалидировать его при изменении.

## Anonymous root

Inline-схема без `$id` доступна только как точка входа и не имеет абсолютной локации. Fragment-only references (`#`, `#foo`, `#/$defs/...`) разрешаются внутри anonymous resource: внешняя base URI им не нужна. Относительный path URI и относительный вложенный `$id` без базы — `relative_uri_without_base`. Абсолютный вложенный `$id` создаёт обычный именованный resource.

# API и фазы компиляции

```erlang
-spec new() -> store().
-spec add(store(), uri(), json()) -> {ok, store()} | {error, schema_error()}.

-spec compile(store(), json(), [copt()]) ->
    {ok, compiled()} | {error, schema_error()}.
-spec compile_uri(store(), uri(), [copt()]) ->
    {ok, compiled()} | {error, schema_error()}.

%% copt() :: {default_dialect, dialect()} | {assert_format, boolean()}.
```

`add/3` делает только корневой проход и не компилирует. `compile_uri/3` сохраняет имя точки входа и base URI; `compile/3` работает с термом вне реестра. Inline `$id`, занятый другим документом, отвергается.

Компиляция идёт от точки входа и втягивает все документы, достигнутые через `$ref` и `$schema`. Порядок регистрации не важен, но реестр должен быть полон. Фазы фиксированы:

1. выбрать dialect корней документов и нарезать resources по `$id`;
2. построить все schema nodes и индексы anchors;
3. разрешить URI/fragments в канонические `addr()`;
4. проверить каждый resource его метасхемой, когда нужные referencing keywords уже реализованы;
5. вернуть замкнутый `compiled()` или первую `schema_error()`.

Резолв не ленивый: dangling refs и отсутствующие documents обнаруживаются до валидации. Parent-pointer URI для embedded resources и детали RFC 3986/JSON Pointer остаются открытыми в [overview](validator-design.md#открытые-вопросы-и-аудит).

## Уже зафиксированные правила resolution

Открытая реализация L1 не отменяет известных границ контракта:

- URI до fragment разрешается относительно текущего base URI; fragment не участвует в registry lookup.
- Empty fragment и `#` обозначают корень выбранного resource.
- JSON Pointer fragment ищется только среди заранее построенных schema nodes; существующий JSON value в non-schema position не является допустимой целью.
- Plain-name fragment разрешается через static anchor index; dynamic/recursive selection начинается лишь после существования лексической цели.
- URI resource хранится без fragment. Результат успешного resolution всегда канонизируется в `addr()` и не переигрывается evaluator'ом.
- Конфликты canonical names/aliases обнаруживаются до построения IR; молчаливая смена target запрещена.

Compiler держит множество уже загруженных documents и resources, поэтому взаимные междокументные refs не вызывают бесконечной компиляции. При этом каждый target проверяется после полного построения pointer space: ранний ref может указывать на node, встреченный позже в тексте.

`sources` — множество документов, прочитанных именно при этой компиляции: entry document, transitive ref documents и dialect meta-schemas. Порядок списка не имеет семантики; для детерминированных golden terms compiler должен выбрать устойчивую сортировку.

# Dialect и vocabularies

Dialect resource выбирается так:

1. корневой `$schema` resource;
2. dialect объемлющего resource;
3. `default_dialect` компиляции, по умолчанию Draft 2020-12.

Для двух канонических dialect URI набор keywords встроен. Пользовательская метасхема загружается из store, а её `$vocabulary` задаёт активные keywords. Неизвестный vocabulary со значением `true` — ошибка, с `false` — игнорируется; Core обязателен и должен быть `true`. Метасхема без `$vocabulary` требует Core. Сам `$vocabulary` действует только при обработке документа как метасхемы.

Поддерживаемые URI vocabularies:

- Draft 2020-12: `core`, `applicator`, `unevaluated`, `validation`, `meta-data`, `format-annotation`, `content`;
- Draft 2019-09: `core`, `applicator`, `validation`, `meta-data`, `format`, `content`.

Итого это 13 URI, потому что префикс dialect входит в имя. В корневой метасхеме 2019-09 `format` объявлен `false`, остальные перечисленные vocabularies — `true`.

Dispatcher компилятора — функция `(active vocabularies, keyword)`. Keyword активного vocabulary создаёт constraint; прочий keyword становится неизвестным — annotation в 2020-12, no-op в 2019-09. Различия впечатаны в IR; evaluator dialect не читает.

`assert_format` меняет IR и потому является compile option. По умолчанию `format` аннотирует. Format-Assertion vocabulary требует проверки независимо от опции; неизвестное имя при ней — compile error, а при опции остаётся annotation-only. Полная таблица format algorithms открыта до P8.

# Проверка схем и ошибки

Каждый schema resource проверяется отдельно своей метасхемой; compound document целиком как один instance не проверяется ([core.txt:2139](../references/json-schema/draft-2020-12/core.txt)). Проверка обязательна и возвращает `schema_invalid` с корневым `basic` output unit. Метасхемы из `priv/` компилируются доверенно, иначе возникает bootstrapping cycle. Механизм включается после P5 для 2020-12 и P6 для 2019-09; до этого compiler выполняет собственные тотальные проверки.

Разделение обязанностей:

| Проверка | Кто выполняет |
| --- | --- |
| типы, границы и формы standard keywords | meta-schema соответствующего resource |
| выбор `$schema` и обязательных vocabularies | compiler до запуска meta-schema |
| regex dialect/compileability | compiler/format policy |
| URI, registry presence и schema target | compiler resolution phase |
| `$schema`/`$vocabulary` вне допустимой позиции | compiler |
| невозможное значение для IR slot | страховочный compiler check |

Так meta-schema остаётся единственным источником синтаксической правды, а compiler остаётся тотальным даже до включения meta-schema validation и на пользовательских dialect errors.

```erlang
-record(schema_error, {
    reason   :: reason(),
    location :: addr() | undefined
}).

-type reason() ::
      {dangling_ref, addr()} | {non_schema_target, addr()}
    | {unknown_document, uri()} | relative_uri_without_base
    | {bad_pattern, term()} | {bad_keyword_value, json()}
    | {unknown_dialect, uri()} | {unrecognized_vocabulary, uri()}
    | core_vocabulary_missing | {misplaced_keyword, binary()}
    | {schema_invalid, #output_unit{}}
    | {name_taken, uri()}.

-spec format_error(#schema_error{}) -> unicode:chardata().
```

Первая ошибка прерывает компиляцию. `location` указывает на keyword, у регистрации она `undefined`. Текст вычисляет `format_error/1`, он не дублируется в записи. Проверка метасхемой покрывает синтаксис; compiler оставляет ошибки, возникающие до её выбора, при URI/reference resolution, при `format`, а также страховочный `bad_keyword_value`.

Одна ошибка, а не список, следует из фаз: повреждение resource slicing делает поздние node/ref errors недостоверными. Накопление потребовало бы отдельного IR для повреждённых nodes. Структура `schema_error()` тестируется точно; `format_error/1` — отдельно и слабо, чтобы редактирование текста не меняло машинный контракт.

Провал instance validation к этому каталогу не относится: `{ok, Output}` с `valid = false` — штатный результат core. Ошибка `validate/3` резервируется для невозможности выполнить вычисление по runtime limits.

# Runtime ownership

Слой разделён на три уровня:

| Уровень | Знает | Не знает |
| --- | --- | --- |
| core/resources | чистые `store()` и `compiled()` | ETS и процессы |
| storage | layout и lookup в переданной таблице | жизненный цикл таблицы |
| owner | документы, options, таблица, reload | устройство IR |

```erlang
-spec lookup(ets:tab(), uri()) -> {ok, compiled()} | {error, not_found}.
```

Точный write-side API (`build`/`replace`/`remove`) остаётся открытым: он должен вернуть owner список готовых `{Name, compiled()}`, а не писать в ETS сам. Это позволяет скомпилировать затронутый набор до транзакции.

## Толстые артефакты

Одна ETS entry содержит `compiled()` вместе со всеми достигнутыми resources. Валидация делает один lookup и не склеивает зависимости. Дублирование памяти принято ради консистентности ссылок и отсутствия поколения/синхронизации на горячем пути.

Нормализованное хранение отдельных resources отвергнуто: после reload зависимости старый artifact мог бы сохранить адрес в новый несовместимый resource, и dangling ref переехал бы из compile time в runtime. Склейка на чтении также потребовала бы N lookup и протокола поколений. Толстый artifact делает согласованность свойством одной immutable entry.

`sources` задаёт invalidation. При изменении документов owner:

1. сканирует artifacts и выбирает те, чьи `sources` пересекаются с изменениями;
2. компилирует их против нового store с прежними compile options;
3. при полном успехе делает один `ets:insert/2` списком; при ошибке сохраняет старые entries.

Список `ets:insert/2` атомарен и изолирован для читателей: они видят старый либо новый набор entries. Удаление имён этой гарантией не закрыто и остаётся частью write-side API. Compile options хранятся рядом с artifact name: один document без `$schema` под разными `default_dialect` даёт разные артефакты.

Ленивая компиляция при lookup запрещена: deployment error должен остановить reload, а не проявиться на случайном запросе. Обратный dependency index не нужен на холодном пути; прямые `sources` живут в самом artifact.

## ETS

Базовый выбор — одна named `protected` table с `read_concurrency`; пишет только owner. Таблица умирает с owner, поэтому `heir` на supervisor обязателен. Документы остаются `store()` в состоянии owner и в ETS не копируются.

Owner запускается до consumers, наполняет table полностью и только затем объявляет готовность. На горячем пути нет fallback к compiler или owner process. `lookup` может вернуть `not_found` для неизвестного публичного имени, но не запускает lazy build.

`persistent_term` отвергнут из-за глобальной цены обновления, gen_server lookup — из-за сериализации и копирования. Диспетчер с переключением между двумя tables остаётся возможной оптимизацией, если массовый `insert` станет заметен; storage interface от этого не меняется.

Dispatcher добавил бы lookup текущего table id и политику выбытия старой table: reader мог получить прежний id непосредственно перед swap. Поэтому он не нужен до измеренной проблемы паузы массового insert или требования атомарно удалять имена.

Политика registry mutation, ключей aliases, возврата таблицы от `heir` и resource budgets остаётся в едином списке [открытых вопросов](validator-design.md#открытые-вопросы-и-аудит).
