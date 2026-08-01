# Roadmap

Рабочий чеклист реализации валидатора. Пункты внутри фазы выполняются сверху
вниз; новые задачи добавляются в подходящий раздел фазы. Общий checkbox фазы
закрывается, когда выполнены её реализация, тесты и приёмка.

Проектные решения задаются не здесь. Нормативные тексты находятся в
[OKF bundle](okf/): границы и порядок фаз — в
[validator-design](okf/architecture/validator-design.md), контракт ядра — в
[validator-core](okf/architecture/validator-core.md), resources и runtime — в
[validator-resources-runtime](okf/architecture/validator-resources-runtime.md).

Обозначения:

- `[x]` — реализовано и подтверждено тестом;
- `[~]` — выполнено частично; невыполненный остаток назван в тексте пункта;
- `[ ]` — не начато или ещё не принято;
- checkbox фазы — итоговый статус, он не заменяет дочерние пункты.

Правила простановки отметок — в [AGENTS.md](AGENTS.md).

## P0 — контракт ядра и опорный срез

- [ ] **Фаза P0 завершена**
- [x] Зафиксировать общие типы, IR и records ядра в `valid_json_core.hrl`.
- [x] Провести публичный вызов `validate/3` через core, evaluator и output.
- [x] Реализовать формат `flag` и значение по умолчанию для output option.
- [x] Реализовать вычисление boolean-схем и пустого `#node{}`.
- [x] Поднять conformance runner для `boolean_schema.json` обоих dialects.
- [x] Подтвердить текущий срез: `rebar3 compile` и 36 EUnit-тестов без
  провалов.
- [ ] Добавить построение `#output_unit{}` для boolean-схем и пустого node.
- [ ] Реализовать операции над стеками `keywordLocation`,
  `absoluteKeywordLocation` и `instanceLocation`.
- [ ] Реализовать JSON Pointer escaping и печать абсолютной URI fragment
  location.
- [ ] Добавить минимальную проекцию `basic` для вручную собранных fixtures;
  полную приёмку формата оставить в P7.
- [ ] Покрыть локации и `basic` structure-тестами, включая пустой сегмент,
  `~`, `/` и anonymous resource.
- [ ] Покрыть cycle guard fixtures: self-reference возвращает
  `{error, {no_progress, Addr}}`, повтор адреса в соседней ветви разрешён.
- [~] Реализовать операции маски массива: merge и normalize сделаны; получение
  списка непокрытых индексов ждёт своего потребителя в P4.
- [x] Покрыть маску тестами на `all`, префикс, разреженные индексы и
  независимость результата от порядка слияния.
- [~] Реализовать модель JSON-значения: `is_type/2`, `is_multiple_of/2`,
  подсчёт code points и `is_unique/1` сделаны; `type_of/1` ждёт сообщений об
  ошибках в units.
- [x] Покрыть модель значения тестами на integer/number, все семь JSON types,
  три ветви кратности, Unicode code points и JSON equality в уникальности.
- [ ] Зафиксировать в runner ожидаемое число групп и test cases, чтобы пустой
  прогон не мог быть зелёным.
- [ ] Приёмка P0: все core fixtures и `boolean_schema.json` обоих dialects
  проходят без провалов.

## P1 — чистые assertions

- [ ] **Фаза P1 завершена**
- [x] Добавить компиляцию schema object в `#node{}` без подключения registry:
  сделана для всех assertion keywords фазы; адресация дочерних schemas — уже
  задача P2.
- [x] Реализовать общий dispatcher constraints и объединение `valid`,
  `evaluated` и `units` внутри node.
- [x] Реализовать `type`, `enum` и `const` с JSON equality.
- [x] Реализовать `multipleOf`, включая гибридную проверку integer/float.
- [x] Реализовать `maximum`, `exclusiveMaximum`, `minimum` и
  `exclusiveMinimum`.
- [x] Реализовать `maxLength`, `minLength` и подсчёт Unicode code points.
- [x] Компилировать `pattern` через `re`, сохраняя исходный pattern рядом с
  `re:mp()` и возвращая compile error для неподдержанного выражения.
- [x] Реализовать `maxItems`, `minItems` и `uniqueItems`.
- [x] Реализовать `maxProperties`, `minProperties`, `required` и
  `dependentRequired`.
- [~] Сохранять написанные no-op assertions в IR и выпускать для них output
  unit: `uniqueItems: false` и `minLength: 0` доходят до IR и вычисляются,
  выпуск units ждёт проекции `basic`.
- [x] Добавить точные compiler fixtures для IR каждого assertion, включая
  нормализацию десятичной формы `nonNegativeInteger`.
- [x] Добавить evaluator fixtures для применимого и неприменимого типа
  instance каждого assertion.
- [~] Подключить к runner одноимённые validation files обоих dialects:
  подключены `type.json`, `const.json`, `multipleOf.json`, `maximum.json`,
  `exclusiveMaximum.json`, `minimum.json`, `exclusiveMinimum.json`,
  `maxLength.json`, `minLength.json`, `pattern.json`, `maxItems.json`,
  `minItems.json`, `maxProperties.json`, `minProperties.json` и
  `dependentRequired.json`. `enum.json`, `required.json` и `uniqueItems.json`
  содержат группы со схемами `properties`, `prefixItems` и `items`, поэтому
  целиком подключаются только после P2.
- [x] Научить runner исключать группы, объявленные расхождениями в
  conformance-policy: сейчас это `^\p{Letter}+$` в `pattern.json`.
- [ ] Приёмка P1: все обязательные assertion files проходят с учётом
  объявленных regex- и high-precision-расхождений.

## P2 — applicators и аннотации

- [ ] **Фаза P2 завершена**
- [ ] Научить compiler адресовать дочерние schemas и строить все nodes до
  начала вычисления.
- [ ] Реализовать `allOf`, `anyOf`, `oneOf` и `not` с корректным объединением и
  отбрасыванием effective coverage.
- [ ] Реализовать составной constraint `if` / `then` / `else`.
- [ ] Реализовать `dependentSchemas`.
- [ ] Реализовать составной object constraint: `properties`,
  `patternProperties` и `additionalProperties`.
- [ ] Реализовать `propertyNames`.
- [ ] Реализовать schema-form `items` для обоих dialects.
- [ ] Реализовать `prefixItems` и хвостовой `items` для Draft 2020-12.
- [ ] Реализовать `contains`, `minContains` и `maxContains`; в Draft 2020-12
  записывать совпавшие индексы в разреженную часть маски.
- [ ] Реализовать annotation-only keywords: `title`, `description`, `default`,
  `deprecated`, `readOnly`, `writeOnly`, `examples` и content annotations.
- [ ] Сохранять диагностические units провалившихся ветвей, но очищать их
  effective coverage и annotations.
- [ ] Выпускать отдельный unit для каждого фактически написанного keyword
  внутри составного constraint.
- [ ] Добавить compiler fixtures на адреса дочерних nodes и нормализацию
  составных constraints.
- [ ] Добавить evaluator fixtures на short-circuit в `flag`, полный обход в
  структурных режимах и правила покрытия ветвей.
- [ ] Подключить соответствующие обязательные applicator, annotation и content
  validation files обоих dialects.
- [ ] Приёмка P2: обязательные files этой фазы проходят, а `contains` оставляет
  каноническую маску для P4.

## P3 — resources и обычные ссылки

- [ ] **Фаза P3 завершена**
- [ ] Закрыть решение об адресации встроенных resources через parent pointer:
  location aliases или явное исключение из профиля.
- [ ] Реализовать URI-слой: resolution, normalization, fragment handling и
  JSON Pointer/anchor lookup.
- [ ] Реализовать чистый `store()` с регистрацией retrieval и canonical URI.
- [ ] Реализовать `compile/3`: dialect по `$schema` или опции, обход schema
  positions и построение полного `compiled()`.
- [ ] Выделять отдельный resource для корня документа и каждой подсхемы с
  `$id`.
- [ ] Индексировать `$anchor`, `$defs` и nodes каждого resource.
- [ ] Разрешать `$ref` в `addr()` на этапе компиляции; dangling и non-schema
  targets возвращать как compile errors.
- [ ] Реализовать переходы evaluator через `{ref, Addr}` с сохранением
  keyword location и сменой absolute location на границе resource.
- [ ] Подключить remote fixtures к conformance runner без сетевых обращений во
  время `validate/3`.
- [ ] Обрабатывать неизвестные keywords согласно dialect и не обходить schema,
  случайно записанные внутри их значений.
- [ ] Заменить boolean-only заглушку компилятора в conformance runner на
  production compiler.
- [ ] Добавить compiler fixtures на anonymous root, embedded resources,
  anchors, remotes, ошибки ссылок и циклический конечный IR.
- [ ] Добавить evaluator fixtures на resource boundary, обе ветви `#node{}` и
  cycle guard через реальные `$ref`.
- [ ] Приёмка P3: проходят `ref`, `defs`, `anchor`, `refRemote`,
  `infinite-loop-detection`, `optional/id` и `optional/unknownKeyword`.

## P4 — unevaluated keywords

- [ ] **Фаза P4 завершена**
- [ ] Компилировать `unevaluatedProperties` и `unevaluatedItems` отдельно от
  обычных constraints.
- [ ] Выполнять unevaluated constraints только после всех обычных constraints
  schema object.
- [ ] Объединять покрытие properties от applicators и достигнутых `$ref`.
- [ ] Объединять префиксное и разреженное покрытие items от `items`,
  `prefixItems`, `contains`, applicators и `$ref`.
- [ ] Не переносить coverage из провалившегося schema object и из внутренней
  успешной схемы `not`.
- [ ] Покрыть evaluator fixtures вложенными applicators, ссылками и
  разреженными совпадениями `contains`.
- [ ] Приёмка P4: проходят `unevaluatedProperties.json` и
  `unevaluatedItems.json`, обязательно группы про вложенные `contains` и
  `minContains = 0`.

## P5 — динамические ссылки Draft 2020-12

- [ ] **Фаза P5 завершена**
- [ ] Индексировать `$dynamicAnchor` в resource.
- [ ] Компилировать `$dynamicRef` в лексическую цель и имя dynamic anchor.
- [ ] Поддержать dynamic scope при переходе через границы resources.
- [ ] Разрешать динамическую цель от внутреннего resource к внешнему с
  fallback на лексическую цель.
- [ ] Проверить, достаточно ли пары schema/instance в cycle guard; при
  необходимости включить dynamic scope в frame.
- [ ] Добавить compiler и evaluator fixtures на переопределение, fallback,
  циклы и несколько уровней dynamic scope.
- [ ] Включить проверку schema resources метасхемой Draft 2020-12.
- [ ] Приёмка P5: проходит обязательный `dynamicRef.json` и выбранные
  `optional/dynamicRef` cases.

## P6 — vocabularies и Draft 2019-09

- [ ] **Фаза P6 завершена**
- [ ] Закрыть compatibility profile для legacy `definitions`, `dependencies`
  и recursive keywords из корневых метасхем.
- [ ] Решить судьбу некорневого `$recursiveAnchor`: игнорировать или отвергать
  схемой/компилятором.
- [ ] Реализовать разбор `$vocabulary` и включение keywords по активным
  vocabularies.
- [ ] Реализовать array-form `items` и `additionalItems` Draft 2019-09.
- [ ] Реализовать `$recursiveAnchor` и `$recursiveRef` отдельным IR и правилом
  разрешения.
- [ ] Учесть различия annotations, unknown keywords и покрытия `contains`
  между Draft 2019-09 и Draft 2020-12.
- [ ] Реализовать cross-draft переходы и наследование dialect для embedded и
  remote resources.
- [ ] Включить проверку schema resources метасхемой Draft 2019-09.
- [ ] Добавить compiler fixtures для vocabulary errors, recursive scope и
  cross-draft closure.
- [ ] Приёмка P6: проходят обязательные files Draft 2019-09 и выбранные
  `optional/cross-draft`, compatibility и recursive cases.

## P7 — стандартные output formats

- [ ] **Фаза P7 завершена**
- [ ] Зафиксировать представление `instanceLocation` Draft 2019-09:
  URI-fragment form из спецификации или JSON Pointer из fixtures.
- [ ] Завершить сериализацию `keywordLocation`, `absoluteKeywordLocation` и
  `instanceLocation` для обоих dialects.
- [ ] Реализовать полную плоскую проекцию `basic` из общего дерева units.
- [ ] Реализовать минимальную значимую иерархию `detailed`.
- [ ] Реализовать полную иерархию `verbose`, включая успехи и отброшенные
  annotations.
- [ ] Обеспечить детерминированный порядок units независимо от оптимизации
  evaluator.
- [ ] Валидировать фактический output соответствующей output schema.
- [ ] Добавить golden/structure tests для `flag`, `basic`, `detailed`,
  `verbose`, `$ref`, no-op keywords и отброшенных annotations.
- [ ] Подключить официальные output tests обоих dialects.
- [ ] Приёмка P7: проходят все официальные output cases и собственные golden
  tests четырёх заявленных форматов.

## P8 — format, content и optional profiles

- [ ] **Фаза P8 завершена**
- [ ] Выбрать алгоритмы и состав поддерживаемых Format-Assertion attributes.
- [ ] Зафиксировать таблицу: format name, dialect, annotation/assertion,
  алгоритм и ограничения.
- [ ] Реализовать `format` как annotation или assertion в зависимости от
  vocabulary и compile options.
- [ ] Реализовать выбранную обработку `contentEncoding`, `contentMediaType` и
  `contentSchema`, сохранив обязательные annotations.
- [ ] Явно выбрать остальные optional profiles, поддерживаемые библиотекой.
- [ ] Подключить выбранные `optional/format`, content и прочие optional files к
  runner.
- [ ] Задокументировать результаты дополнительных capability profiles и все
  намеренные исключения.
- [ ] Приёмка P8: выбранные optional profiles проходят без необъявленных
  исключений.

## Runtime — хранение и эксплуатация

Runtime не входит в conformance-фазы и развивается отдельным чеклистом.

- [ ] **Runtime-слой завершён**
- [ ] Реализовать ETS storage API: `lookup`, пакетный `put` и пакетный
  `delete`.
- [ ] Реализовать хранителя таблицы с `heir` и управляющий процесс —
  единственный writer.
- [ ] Собрать `rest_for_one` supervision tree: хранитель перед управляющим.
- [ ] Реализовать первичную компиляцию реестра до объявления готовности.
- [ ] Реализовать transactional reload: пересборка по пересечению `sources`,
  commit только при полном успехе.
- [ ] Реализовать удаление с ошибкой `{referenced_by, Uri, Refs}`.
- [ ] Хранить встроенные метасхемы отдельно и публиковать их compiled form через
  `persistent_term`.
- [ ] Покрыть storage, ownership transfer, restart, reload, rollback и
  invalidation отдельными тестами без evaluator.

## Сквозные задачи

- [ ] Добавить CI-команды для compile, EUnit и выбранных conformance profiles.
- [ ] Публиковать количество запущенных групп и cases по каждому dialect/file.
- [ ] Поддерживать отдельные точные fixtures на границах compiler, resolver,
  evaluator и output builder.
- [ ] После закрытия каждой фазы обновлять README с фактически подтверждённым
  уровнем поддержки.
- [ ] Не включать в профиль `optional/refOfUnknownKeyword`, два
  high-precision float cases и задокументированные ECMA-262/PCRE расхождения,
  пока для них не принято отдельное решение.
