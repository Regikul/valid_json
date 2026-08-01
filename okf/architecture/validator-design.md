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
| `runtime` | хранение готовых артефактов, lookup, reload и invalidation | тесты владельца и ETS без evaluator'а |

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
| Annotation-only | `title`, `description`, `default`, `deprecated`, `readOnly`, `writeOnly`, `examples`, content keywords | идентично |
| Format | annotation vocabulary по умолчанию и отдельная assertion vocabulary | одна vocabulary; assertion включается опцией реализации |
| Неизвестные | SHOULD стать аннотацией со своим значением | SHOULD игнорироваться |

`additionalProperties`, оба варианта `items`, `additionalItems`, `minContains`, `maxContains`, `then` и `else` поглощаются составными constraints. `$id`, `$anchor`, `$defs`, `$schema`, `$vocabulary`, `$dynamicAnchor` и `$comment` потребляются компилятором и собственного constraint не дают.

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
| P4 | `unevaluatedProperties`, `unevaluatedItems` |
| P5 | `$dynamicRef`, `$dynamicAnchor`; после этого включается проверка ресурсов метасхемой 2020-12 |
| P6 | vocabularies и Draft 2019-09: `additionalItems`, recursive keywords, cross-draft; включается проверка метасхемой 2019-09 |
| P7 | `basic`, `detailed`, `verbose` и официальные output tests; недостающее покрытие — собственными golden tests |
| P8 | `format` assertion, content processing и остальные выбранные optional profiles |

Runtime-слой не входит в conformance-фазы. `pattern` компилируется через `re` без ECMA-262 rewrite; адаптация описана отдельно. Вне профиля остаются `optional/refOfUnknownKeyword`, два high-precision float cases и объявленные [conformance-расхождения](../testing/conformance-policy.md).

# Открытые вопросы и аудит

Локальные ошибки прежнего текста исправлены при переносе: fragment-only ссылки анонимного корня разрешены; `dependentSchemas` исключён из пользователей JSON equality; отказ на плохом `pattern` назван политикой реализации, а не MUST спецификации; обязательные `default`/content annotations поставлены в P2. Остальные пункты не закрыты.

| Владелец | Срок | Вопрос |
| --- | --- | --- |
| `runtime` | до слоя владельца | Определить `add`/`replace`/`remove`, ключи алиасов, судьбу anonymous artifacts и возврат ETS от `heir`. |
| `runtime` | до слоя владельца | Согласовать write-side storage API: сборка должна вернуть владельцу набор артефактов для одного `ets:insert/2`; унифицировать порядок аргументов с `lookup`. |
| `resources` | до P3 | Решить parent-pointer адресацию встроенных ресурсов: location aliases либо явное исключение из профиля. |
| `resources` | до P3 | Выбрать L1: RFC 3986 normalization/resolve, percent-decoding, fragment/Pointer order, URN, anchors и URI aliases. |
| `resources` | до P6 | Решить строгость некорневого `$recursiveAnchor`: игнорировать либо отвергать схемой/компилятором. |
| `core` | до P6 | Определить compatibility profile для legacy `definitions`, `dependencies` и recursive keywords из корневых meta-schemas. |
| `core` | до P7 | Зафиксировать Draft 2019-09 `instanceLocation`: локальная спецификация требует URI-fragment form, fixtures — JSON Pointer. |
| `core` | до P7 | Добавить собственные structure/golden tests для `flag`, `detailed`, `verbose`, `$ref`, no-op keywords и отброшенных annotations. |
| `core` | до P4 | Уточнить `evaluated.items`: один integer не выражает разреженные indexes, отмеченные успешными `contains`; нужен set/ranges либо доказанный другой инвариант. |
| `core` | до P7 | Исправить завышенное утверждение conformance-policy: официальные fixtures закрепляют только `basic`. |
| `core` | до P8 | Для Format-Assertion выбрать алгоритмы и полную таблицу поддержанных стандартных format attributes. |
| `runtime` | до слоя владельца | Определить лимиты глубины, closure, output units, regex time и общего бюджета либо явно делегировать их вызывающему. |

Статус остаётся `draft`, пока открыты пункты, влияющие на заявленный профиль или публичный runtime-контракт.
