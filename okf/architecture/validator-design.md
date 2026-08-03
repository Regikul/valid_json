---
type: Architecture
title: Validator design overview
description: Инварианты валидатора, границы core, resources и runtime, классификация keywords, зависимости, план реализации и открытые вопросы.
tags: [json-schema, architecture, validator, roadmap, audit]
status: draft
---

# Назначение и границы

Валидатор разделён на три независимо проверяемые области:

| Область | Ответственность | Независимая проверка |
| --- | --- | --- |
| `core` | модель JSON-значения, constraint IR, evaluator, аннотации и output formats | вручную собранные `compiled()` fixtures |
| `resources` | документы и schema resources, URI, dialect, компиляция и ошибки | compiler fixtures поверх чистого `store()` |
| `runtime` | хранение готовых артефактов, lookup, reload и invalidation | тесты управляющего и ETS без evaluator'а |

Общие типы и вычислительный контракт определены в [validator-core](validator-core.md). Загрузка и эксплуатация определены в [validator-resources-runtime](validator-resources-runtime.md). Экспериментальные основания вынесены в supporting notes и не являются production-зависимостями.

## Карта прежних разделов

Каждый раздел монолитного документа имеет одного нормативного владельца:

| Прежняя тема | Новое место |
| --- | --- |
| «Что является ядром», «Классификация», «Граф зависимостей» | этот overview |
| «Модель JSON-значения», «Регулярные выражения» | validator-core; измерения — value model и regex notes |
| «Представление скомпилированной схемы» | нормативный владелец — validator-core; полные термы явно перенесены в compiled examples |
| «Результат вычисления и вывод» | validator-core |
| «Загрузка ресурсов» | validator-resources-runtime; fixture counts — compiled examples |
| «Владение и перезалив» | validator-resources-runtime |
| «Опорный срез», «Поэтапный план» | единый поэтапный план ниже |
| «Открытые вопросы» | единый аудит ниже |

Нормативные документы определяют решения и интерфейсы. Supporting notes дают воспроизводимые основания, но реализация не должна импортировать из них новые правила по умолчанию.

# Инварианты ядра

Минимальное ядро определяется не числом keywords, а решениями, которые поздно ретрофитить.

| Инвариант | Следствие |
| --- | --- |
| Результат не сводится к boolean | отдельно хранятся эффективное покрытие для `unevaluated*` и полное диагностическое дерево |
| Каждый output unit знает три локации | `keywordLocation`, `absoluteKeywordLocation` и `instanceLocation` строятся во время обхода |
| Все форматы — проекции одного дерева | `flag` разрешает не строить дерево, остальные используют общий внутренний формат |
| Dynamic scope входит в контекст | `$dynamicRef` и `$recursiveRef` разрешаются по стеку ресурсов |
| Keywords параметризованы dialect/vocabulary | различия Draft 2020-12 и Draft 2019-09 снимаются компилятором, не evaluator'ом |
| Значение неизвестного keyword'а не теряется | в 2020-12 оно становится аннотацией; в 2019-09 игнорируется |
| Провал schema object отбрасывает эффективные аннотации | диагностические units при этом сохраняются для `verbose` |
| Режим обхода выводится из output format | short-circuit разрешён только для `flag` и только когда не нужен дальнейший расчёт покрытия |
| Присутствие keyword'а сохраняется в IR | написанный keyword порождает constraint даже при вырожденном значении |
| Ссылки — адреса, не вложенные термы | циклическая схема остаётся конечным, сравнимым и печатаемым значением |

Первый инкремент с одними boolean schemas уже обязан фиксировать `compiled()`, контекст, output unit и публичный `validate/3`.

# Классификация keywords

Состав берётся из vocabulary meta-schemas в [`priv/json_schema/`](../../priv/json_schema/). Таблица описывает поведение; часть соседних keywords компилятор сворачивает в одно составное ограничение.

| Класс | Draft 2020-12 | Отличия Draft 2019-09 |
| --- | --- | --- |
| Чистые assertions | `type`, `enum`, `const`, числовые границы, длины, `pattern`, размеры коллекций, `uniqueItems`, `required`, `dependentRequired` | идентично |
| Assertion над аннотацией | `minContains`, `maxContains` | идентично |
| In-place applicators | `allOf`, `anyOf`, `oneOf`, `not`, `if`/`then`/`else`, `dependentSchemas` | идентично |
| Child applicators | `properties`, `patternProperties`, `additionalProperties`, `propertyNames`, `prefixItems`, `items`, `contains` | `items` также принимает массив; есть `additionalItems`; нет `prefixItems`; `contains` не отмечает элементы |
| Annotation-dependent | `unevaluatedProperties`, `unevaluatedItems` | входят в applicator vocabulary; покрытие массива считается иначе |
| Core/referencing | `$schema`, `$id`, `$anchor`, `$ref`, `$defs`, `$comment`, `$vocabulary`, `$dynamicRef`, `$dynamicAnchor` | вместо dynamic — `$recursiveRef`, `$recursiveAnchor` |
| Compatibility | `definitions` — location-reserving alias `$defs`; `dependencies` не входит в основной профиль; recursive keywords остаются неизвестными annotations | `definitions` — тот же alias; `dependencies` игнорируется как неподдерживаемый; recursive keywords принадлежат Core |
| Annotation-only | `title`, `description`, `default`, `deprecated`, `readOnly`, `writeOnly`, `examples`, content keywords | идентично |
| Format | annotation vocabulary по умолчанию и отдельная assertion vocabulary | одна vocabulary; assertion включается опцией реализации |
| Неизвестные | SHOULD стать аннотацией со своим значением | SHOULD игнорироваться |

`additionalProperties`, оба варианта `items`, `additionalItems`, `minContains`, `maxContains`, `then` и `else` поглощаются составными constraints. `$id`, `$anchor`, `$defs`, совместимый `definitions`, `$schema`, `$vocabulary`, `$dynamicAnchor` и `$comment` потребляются компилятором и собственного constraint не дают.

# Зависимости и порядок вычисления

Это граф вызовов, не расписание работ:

```text
L0  JSON value model
L1  RFC 3986, fragments и JSON Pointer
L2  schema compiler: документ -> compiled()
L3  resource resolution: store, resources, anchors, refs
L4  evaluator и его контекст
    L5a assertions
    L5b applicators
    L5c ref / dynamicRef / recursiveRef
    L5d unevaluated*                зависит от L5b и L5c
L6  output builder
L7  dialect и vocabularies          параметризуют L2
```

Нормативные тексты уровня L1 хранятся локально: [RFC 3986](../references/rfc/rfc3986.txt) для URI и [RFC 6901](../references/rfc/rfc6901.txt) для JSON Pointer. Карта секций, которые действительно нужны валидатору, собрана в [rfc overview](../references/rfc/overview.md).

Schema object есть конъюнкция независимых ограничений. Все статические зависимости снимаются компилятором:

| Constraint | Поглощает |
| --- | --- |
| `properties` | `properties`, `patternProperties`, `additionalProperties` |
| `prefix_items` | `prefixItems`, `items` в 2020-12 |
| `items_array` | массив `items`, `additionalItems` в 2019-09 |
| `contains` | `contains`, `minContains`, `maxContains` |
| `if_then_else` | `if`, `then`, `else` |

Обработчик всё равно выпускает unit по имени фактического keyword. Аннотации от соседних applicators не участвуют в `additionalProperties`; только `unevaluated*` читают объединённое покрытие всех остальных keywords, включая достигнутые по `$ref`.

# Независимая работа

- `core` можно реализовать на вручную выписанных `compiled()` fixtures. Он не читает реестр, не делает URI lookup и не знает ETS.
- `resources` принимает типы core как контракт, строит полный `compiled()` и разрешает ссылки до начала вычисления.
- `runtime` рассматривает `compiled()` как непрозрачное значение: хранит, атомарно заменяет и отдаёт его валидатору.
- Regex harness, числовые эксперименты и полные примеры IR могут развиваться отдельно; их результаты влияют на заявленный conformance, но не связывают production-модули.

# Поэтапный план

Каждая фаза проходит через compiler, evaluator и output и заканчивается запускаемым тестом. Опорный срез прежнего документа включён в P0–P3.

| Фаза | Вертикальный срез и приёмка |
| --- | --- |
| P0 | value model, локации, общий IR и API, `flag`, boolean schemas — `boolean_schema` |
| P1 | чистые assertions, включая гибридный `multipleOf` и regex-контракт — одноимённые validation files |
| P2 | applicators, составные constraints и аннотации, включая `default` и content annotations — соответствующие обязательные files |
| P3 | resources, `store()`, `$id`, `$anchor`, `$ref`, remotes и cycle guard — `ref`, `defs`, `anchor`, `refRemote`, `infinite-loop-detection`, `optional/id`, `optional/unknownKeyword` |
| P4 | `unevaluatedProperties`, `unevaluatedItems`; обязательны группы `unevaluatedItems.json` про вложенные `contains` и про `minContains = 0` |
| P5 | `$dynamicRef`, `$dynamicAnchor` и dynamic scope Draft 2020-12 |
| P6 | vocabularies и Draft 2019-09: `additionalItems`, recursive keywords, cross-draft; включается отдельная проверка каждого resource собственной метасхемой для обоих dialects |
| P7 | `basic`, `detailed`, `verbose` и официальные output tests; недостающее покрытие — собственными golden tests |
| P8 | `format` assertion, content processing и остальные выбранные optional profiles |

Маска покрытия массива живёт сразу в трёх фазах: тип замораживается в P0 вместе с остальным контрактом `#eval_result{}`, разреженную часть начинает заполнять `contains` в P2, а читают её `unevaluated*` только в P4. Поэтому решение о её форме нельзя откладывать до фазы-потребителя.

Runtime-слой не входит в conformance-фазы. `pattern` компилируется через `re` без ECMA-262 rewrite; адаптация описана отдельно. Вне профиля остаются `optional/refOfUnknownKeyword`, два high-precision float cases и объявленные [conformance-расхождения](../testing/conformance-policy.md).

# Открытые вопросы и аудит

Локальные ошибки прежнего текста исправлены при переносе: fragment-only ссылки анонимного корня разрешены, `dependentSchemas` исключён из пользователей JSON equality, отказ на плохом `pattern` назван политикой реализации, а не MUST спецификации, обязательные `default` и content annotations поставлены в P2.

Отдельными решениями закрыты следующие пункты прежнего списка:

- Покрытие массива. `evaluated.items` стал непрерывным prefix плюс разреженное множество индексов от `contains`; форма маски и правило слияния описаны в [validator-core](validator-core.md#два-результата).
- Слой URI. Уровень L1 построен на stdlib `uri_string`, каноническое имя даёт scheme-based normalization, fragment декодируется целиком и однократно, а plain-name anchor не проверяется грамматикой на стороне ссылки. Основания собраны в [validator-resources-runtime](validator-resources-runtime.md#слой-uri).
- Parent-pointer адресация. Compiler поддерживает физические locations
  embedded resources через эфемерный индекс по всем объемлющим resources и
  retrieval URI, но сразу канонизирует их в `addr()`. Индекс не попадает в
  `store()` или IR. Решение и граница описаны в
  [validator-resources-runtime](validator-resources-runtime.md#location-aliases-для-embedded-resources).
- Заявление об output tests. Официальный suite закрепляет только `basic` восемью кейсами, поэтому [conformance policy](../testing/conformance-policy.md#output-tests) теперь прямо требует собственных golden tests для остальных трёх форматов.
- Жизненный цикл документов и артефактов. Документ проходит через upsert и удаление, обе операции принимают список; артефакт заводится на каждый документ реестра, поэтому множество ключей таблицы всегда совпадает с множеством канонических ключей хранилища. Перекомпиляция затрагивает артефакты, чьи `sources` пересекаются с изменениями, и выполняется как транзакция всё-или-ничего. Подробности — в [validator-resources-runtime](validator-resources-runtime.md#артефакт-на-документ).
- Имена документов. Их ровно два, адрес загрузки и канонический URI, и понятие
  document alias отменено: два ключа реестра указывают на один терм документа.
  Это не относится к эфемерным location aliases компилятора. Всё, что дальше
  разрешения имени, оперирует только каноническим. Разбор — в
  [разделе про имена](validator-resources-runtime.md#имена).
- Встроенные метасхемы. Метасхемы двух канонических диалектов вынесены из хранилища в отдельную неизменяемую область, а их скомпилированная форма лежит в `persistent_term`. При этом они остаются обычной целью `$ref`, чего требует обязательный набор. Описание — во [встроенных метасхемах](validator-resources-runtime.md#встроенные-метасхемы).
- Владение таблицей. Процессов два: хранитель, который держит таблицу между воплощениями, и управляющий, который забирает её через `ets:give_away/3` и единственный в неё пишет. Storage сведён к `lookup`, `put` и `delete` над переданной таблицей. Разбор — в [ETS и процессах](validator-resources-runtime.md#ets-и-процессы).
- Лимиты. Валидатор не ограничивает ни глубину обхода, ни размер замыкания, ни число output units, ни время работы. Мы исходим из того, что схема обрабатывается за разумное время и в разумной памяти, а бюджет исполнения принадлежит вызывающему. От бесконечного обхода защищает cycle guard, описанный в [validator-core](validator-core.md#контекст-и-cycle-guard), и его срабатывание остаётся единственной причиной, по которой `validate/3` возвращает ошибку.

Остальные пункты не закрыты. Compatibility profile зафиксирован отдельно:

- `definitions` ведёт как `$defs`, когда выбран один из двух стандартных
  dialects: его entries являются schema positions и собственного output unit у
  контейнера нет;
- `dependencies` не входит в основной профиль. В Draft 2019-09 он остаётся
  неподдерживаемым неизвестным keyword и игнорируется, в Draft 2020-12 —
  неизвестной annotation. Если профиль совместимости будет выбран позже, обе
  старые формы получат один составной constraint и один unit фактического
  keyword;
- `$recursiveRef` и `$recursiveAnchor` исполняются только в Draft 2019-09. В
  Draft 2020-12 они не получают семантику `$dynamicRef` / `$dynamicAnchor` и
  остаются неизвестными annotations;
- `$recursiveAnchor` влияет только в корне schema resource. Некорневое
  boolean-значение принимается, но не меняет resource: `$recursiveRef: "#"`
  всё равно сначала адресует корень resource. Подсхема с `$id` уже является
  корнем нового resource и потому не считается некорневой.

| Владелец | Срок | Вопрос |
| --- | --- | --- |
| `core` | до P7 | Добавить собственные structure/golden tests для `flag`, `detailed`, `verbose`, `$ref`, no-op keywords и отброшенных annotations. |
| `core` | до P8 | Для Format-Assertion выбрать алгоритмы и полную таблицу поддержанных стандартных format attributes. |

Статус остаётся `draft`, пока открыты пункты, влияющие на заявленный профиль или публичный runtime-контракт.
