---
type: Architecture
title: Validator computational core
description: Модель JSON-значения, constraint IR, evaluator, аннотации, output formats и публичный контракт валидации.
tags: [json-schema, architecture, validator, erlang, evaluator, output]
status: draft
---

# Контракт слоя

Core вычисляет `validate(compiled(), json(), options)` и не знает, откуда взялись документы, как разрешались URI и где хранится артефакт. Компилятор resources обязан передать ему полностью построенный, замкнутый `compiled()` без ленивых ссылок. Runtime вправе считать этот терм непрозрачным.

# Модель JSON-значения

Значение — нативный терм Erlang, совпадающий с результатом `json:decode/1` OTP 27:

| JSON | Erlang | Семантика |
| --- | --- | --- |
| `null` | `null` | |
| boolean | `true` или `false` | |
| целый number | `integer()` | произвольная точность |
| дробный number | `float()` | IEEE-754 double |
| string | `binary()` | валидный UTF-8 |
| array | `[json()]` | |
| object | `#{binary() => json()}` | порядок и дубликаты ключей не наблюдаются |

```erlang
-type json()      :: null | boolean() | number() | binary()
                   | [json()] | #{binary() => json()}.
-type json_type() :: null | boolean | object | array | number | integer | string.
```

## Равенство и типы

JSON equality есть Erlang `==`: оно рекурсивно считает `1` и `1.0` равными, не смешивает boolean/string/array/null и точно сравнивает bignum с float. На нём держатся `const`, `enum` и `uniqueItems`. Последний по умолчанию квадратичен; линейная оптимизация допустима только через локальную канонизацию чисел, не меняющую значения аннотаций.

`type: "integer"` принимает любой number с нулевой дробной частью:

```erlang
is_type(integer, V) -> is_integer(V) orelse (is_float(V) andalso V == trunc(V));
is_type(number,  V) -> is_number(V).
```

`type_of/1` используется только в диагностике. Целочисленные значения восьми schema keywords (`min/maxLength`, `min/maxItems`, `min/maxProperties`, `min/maxContains`) нормализуются компилятором через `trunc/1` после проверки `is_number(V), V == trunc(V), V >= 0`; непредставимое значение даёт `bad_keyword_value`.

## Точность чисел

Целые точны, дробные литералы теряют исходную десятичную запись. Это сознательный профиль: два high-precision cases из `optional/bignum` не поддерживаются. Границы и воспроизводимые измерения приведены в [value model notes](validator-value-model-notes.md).

`multipleOf` использует гибрид:

1. два целых — `rem`;
2. конечное частное — `Q = V / M`, затем `Q == round(Q)`;
3. переполнение деления — точное сравнение дробей, полученных из IEEE-754 `p / 2^q`.

Это покрывает обязательный suite и float-overflow cases, но `0.3` при `multipleOf: 0.1` может получить неверный десятичный ответ: оба значения уже округлены декодером. `multipleOf =< 0` отвергается при компиляции.

## Строки

`minLength` и `maxLength` считают Unicode code points, не байты, UTF-16 units или grapheme clusters ([validation.txt:385](../references/json-schema/draft-2020-12/validation.txt)):

```erlang
cp_length(B) -> cp_length(B, 0).
cp_length(<<>>, N)                 -> N;
cp_length(<<_/utf8, R/binary>>, N) -> cp_length(R, N + 1).
```

Декодер гарантирует корректный UTF-8. До прохода используются границы `byte_size(B) div 4 =< CP =< byte_size(B)`; считать строку нужно только когда границы не дают ответа. Unicode examples и обоснование тотальности вынесены в [value model notes](validator-value-model-notes.md).

# Регулярные выражения

Движок — `re`; собственная реализация ECMA-262 в core не входит:

```erlang
-type regex() :: {binary(), re:mp()}.

re:compile(Pattern, [unicode, dollar_endonly]).
```

Паттерн не оборачивается якорями, опции `anchored`, `multiline` и `ucp` не передаются: неявное якорение запрещено MUST ([core.txt:709](../references/json-schema/draft-2020-12/core.txt)). Исходный binary хранится рядом с `re:mp()` для диагностики. Ошибка `re:compile/2` завершает компиляцию схемы согласно политике реализации; спецификация задаёт ECMA-262 как SHOULD, не MUST ([core.txt:679](../references/json-schema/draft-2020-12/core.txt)).

Расхождения PCRE, воспроизводимый замер и необязательные две ступени rewrite описаны в [ECMA-262 to PCRE adaptation](ecma-to-pcre-adaptation.md). Rewrite локален в подготовке паттерна и не меняет IR или evaluator.

# Скомпилированная схема

## Общие типы

```erlang
-type uri()     :: binary().
-type pointer() :: binary().                 % от корня resource; <<>> — корень
-type rid()     :: uri() | anonymous.
-type addr()    :: {rid(), pointer()}.
-type dialect() :: uri().

-type compiled() :: #{root      := rid(),
                       sources   := [uri()],
                       resources := #{rid() => #resource{}}}.
-type schema_node() :: boolean() | #node{}.

-record(resource, {
    id                       :: uri() | undefined,
    dialect                  :: dialect(),
    anchors                  :: #{binary() => pointer()},
    dynamic_anchors          :: #{binary() => pointer()},
    recursive_anchor = false :: boolean(),
    nodes                    :: #{pointer() => schema_node()}
}).

-record(node, {
    constraints :: [constraint()],
    unevaluated :: [constraint()]
}).
```

`root` — точка входа; `sources` — документы и метасхемы, от которых зависит артефакт; `resources` — полное замыкание вычислимых resources. У анонимного корня `rid = anonymous`, `id = undefined`; только тогда `absoluteKeywordLocation` опускается.

Boolean schema хранится значением `true` или `false` и не производит аннотаций ([core.txt:1048](../references/json-schema/draft-2020-12/core.txt)). `{}` остаётся `#node{constraints = []}`: эти формы семантически равны, но не обязаны давать одинаковый IR. Исходный JSON в `compiled()` не хранится.

## Constraint IR

```erlang
-type constraint() ::
      {ref, addr()}
    | {dynamic_ref, binary(), addr()}
    | {recursive_ref, addr()}

    | {multiple_of, number()}
    | {maximum, number()} | {exclusive_maximum, number()}
    | {minimum, number()} | {exclusive_minimum, number()}
    | {max_length, non_neg_integer()} | {min_length, non_neg_integer()}
    | {pattern, regex()}
    | {max_items, non_neg_integer()} | {min_items, non_neg_integer()}
    | {unique_items, boolean()}
    | {max_properties, non_neg_integer()} | {min_properties, non_neg_integer()}
    | {required, [binary()]}
    | {dependent_required, #{binary() => [binary()]}}
    | {type, [json_type()]}
    | {enum, [json()]}
    | {const, json()}

    | {all_of, [addr()]} | {any_of, [addr()]} | {one_of, [addr()]}
    | {'not', addr()}
    | {if_then_else, addr(), addr() | undefined, addr() | undefined}
    | {dependent_schemas, #{binary() => addr()}}

    | {properties, #{binary() => addr()} | undefined,
                   [{regex(), addr()}] | undefined,
                   addr() | undefined}
    | {property_names, addr()}
    | {items, addr()}
    | {prefix_items, [addr()], addr() | undefined}
    | {items_array, [addr()], addr() | undefined}
    | {contains, addr(),
                 non_neg_integer() | undefined,
                 non_neg_integer() | undefined,
                 MarksEvaluated :: boolean()}

    | {annotation, binary(), json()}
    | {format, binary(), Assert :: boolean()}

    | {unevaluated_properties, addr()}
    | {unevaluated_items, addr()}.
```

Тег есть данные; имён модулей и closures в IR нет. Единственная непрозрачная часть — сравнимый `re:mp()`. Различия dialect разрешаются компилятором: разные раскладки получают разные tags, отличающееся поведение — явное поле (`MarksEvaluated`, `Assert`). Evaluator не читает `#resource.dialect`.

## Составные constraints

Сворачивание соседних keywords устраняет ложную runtime-зависимость. Например, `additionalProperties` учитывает только соседние `properties` и `patternProperties`, но не аннотации из `allOf`. Статически сохранённые names/patterns не позволяют случайно использовать общий accumulator.

| Тег | Раскладка keywords | Локации вложенных units |
| --- | --- | --- |
| `properties` | три object applicators | `/properties/name`, `/patternProperties/pattern`, `/additionalProperties` |
| `items` | одна schema на все элементы в обоих dialects | `/items` |
| `prefix_items` | 2020-12 `prefixItems` и хвостовой `items` | `/prefixItems/N`, `/items` |
| `items_array` | 2019-09 array `items` и `additionalItems` | `/items/N`, `/additionalItems` |
| `contains` | `contains`, `minContains`, `maxContains` | по имени фактического keyword |
| `if_then_else` | `if`, `then`, `else` | по выбранным фактическим keywords |

`additionalItems` без `items` игнорируется по спецификации. `contains.MarksEvaluated` равен true в Draft 2020-12 и false в Draft 2019-09. `format.Assert` вычисляет compiler из vocabulary и compile options; binary format name сохраняется открытым значением и всегда доступен для annotation.

## Контракт handler'а

Каждый handler получает constraint, instance value и `#eval_context{}` и возвращает `#eval_result{}`. Он не читает schema JSON, dialect или registry. Applicator вызывает общий вход evaluator'а по `addr()`; прямой вызов чужого handler запрещён, иначе потеряются локации, dynamic scope и cycle guard.

Keywords применяются только к своим instance types. Значение другого типа даёт успешный unit без error/annotation, а не отказ: например `maxLength` не ограничивает number, `properties` не ограничивает array. `type`, `enum`, `const` и applicators над любым значением являются исключениями по собственной семантике, не по dispatcher'у.

Handler составного constraint обязан различать фактические keywords. Один object обход может породить units для `properties`, `patternProperties` и `additionalProperties`; одно сканирование массива — для `contains`, `minContains`, `maxContains`. IR объединяет работу, но не объединяет наблюдаемый output.

Ошибки сообщений хранятся как binary только в output unit и строятся из constraint/instance во время вычисления. Они не влияют на `valid` или `evaluated` и не используются другими handlers.

## Присутствие и нормализация

IR различает отсутствующий keyword и написанное default/no-op значение:

| Schema text | IR consequence |
| --- | --- |
| keyword отсутствует | slot `undefined` либо нет constraint |
| `properties: {}` | `properties` constraint с пустой map и пустая annotation при применении |
| `uniqueItems: false` | `{unique_items, false}` и собственный unit |
| `minLength: 0` | `{min_length, 0}` и собственный unit |
| `minContains: 1` | явный `1`; отсутствие остаётся `undefined` |

Defaults применяет handler, а не compiler. Это сохраняет hierarchy для `verbose` и видимые в `basic` пустые annotations. Исключения ограничены keywords, которые спецификация велит игнорировать или которые полностью потребляются compiler (`$id`, `$schema`, anchors, `$defs`, `$vocabulary`, `$comment`).

## Инварианты компиляции IR

- Все nodes, включая неиспользованные `$defs`, строятся до валидации; ссылки уже разрешены в `addr()`.
- Компилятор посещает только schema positions активных keywords и location-reserving `$defs` ([core.txt:2169](../references/json-schema/draft-2020-12/core.txt)); внутрь unknown, `enum`, `const`, `default` и property names он не спускается.
- Dangling и non-schema targets — compile errors. `optional/refOfUnknownKeyword` остаётся вне профиля как undefined behavior.
- Подсхема с `$id` получает новый `rid`; поэтому дочерние переходы всегда хранят полный `addr()`, не голый pointer.
- `#node.unevaluated` отделяет constraints, которые обязаны выполняться последними.
- Написанный keyword сохраняется даже при no-op значении. `undefined` в составном constraint означает только отсутствие keyword; спецификационное default применяет обработчик.
- `additionalProperties`, `prefix/items`, array-form `items/additionalItems`, `contains/min/maxContains` и `if/then/else` сворачиваются статически, но каждый фактический keyword получает собственный output unit.
- `{recursive_ref, ...}` и `{dynamic_ref, ...}` разведены. Флаг `recursive_anchor` принадлежит корню resource; открытая строгость некорневого anchor описана в [overview](validator-design.md#открытые-вопросы-и-аудит).

Разрешение адреса в готовом артефакте тотально:

```erlang
resolve({Rid, Ptr}, #{resources := Rs}) ->
    #resource{nodes = Nodes} = maps:get(Rid, Rs),
    maps:get(Ptr, Nodes).
```

Полные Erlang-термы, циклические ссылки и несколько resources вынесены в [compiled examples](validator-compiled-examples.md).

## Тестовая граница IR

Compiler и evaluator проверяются раздельно, не через один end-to-end verdict:

| Слой | Fixture | Проверка |
| --- | --- | --- |
| compiler | schema JSON + options | точное равенство полного `compiled()` |
| address resolver | готовый `compiled()` + `addr()` | тотальный выбор ожидаемого node |
| evaluator | вручную собранный `compiled()` + instance | `#eval_result{}` и units до JSON projection |
| output builder | дерево units | golden JSON каждого формата |

Эталон regex constraint создаёт `re:mp()` тем же `re:compile/2`, затем сравнивает весь терм; разбирать внутренний bytecode нельзя. Все остальные элементы IR — обычные Erlang data и должны быть печатаемы и сравнимы без элизий.

Так core развивается без registry и URI parser, а resources compiler — без необходимости доказывать свою корректность только итоговым boolean. End-to-end conformance остаётся отдельной приёмкой фаз.

## Выполнение ссылок

`{ref, Addr}` переходит по лексически разрешённому адресу. Keyword location продолжает путь через `/$ref`, тогда как absolute location после перехода строится от target resource.

`{dynamic_ref, Name, Lexical}` сначала имеет валидную лексическую цель, затем ищет одноимённый dynamic anchor по `dynamic_scope`. В стек входят resources, а не произвольные nodes. Если подходящей динамической цели нет, используется `Lexical`.

`{recursive_ref, LexicalRoot}` — отдельная форма Draft 2019-09. Если лексический resource не помечен `recursive_anchor`, она ведёт как обычный ref. Иначе выбирается корень самого внешнего помеченного resource в dynamic scope. Имени anchor в теге нет: `$recursiveAnchor` boolean, а допустимая форма `$recursiveRef` целит в `#`.

Ни один тег не хранит target node термом. Это сохраняет конечность cycles, независимость compile order и один механизм для static/dynamic references.

## Компактный пример

Схема `{"type":"object","properties":{"a":{"type":"integer"}}}` компилируется в один resource:

```erlang
#{root => anonymous, sources => [], resources => #{anonymous =>
  #resource{id = undefined, dialect = D, anchors = #{},
    dynamic_anchors = #{}, nodes = #{
      <<>> => #node{constraints = [
        {type, [object]},
        {properties, #{<<"a">> => {anonymous, <<"/properties/a">>}},
                     undefined, undefined}], unevaluated = []},
      <<"/properties/a">> =>
        #node{constraints = [{type, [integer]}], unevaluated = []}}}}}.
```

# Вычисление

## Обход node

Evaluator выполняет node в одном порядке, независимо от dialect:

1. проверяет active-frame guard;
2. добавляет resource в dynamic scope при входе через resource boundary;
3. выполняет `constraints`, накапливая validity, coverage и diagnostic units;
4. при необходимости выполняет `unevaluated` над оставшимися properties/items;
5. очищает effective coverage, если весь schema object провалился;
6. снимает frame и resource scope, возвращает `#eval_result{}`.

Порядок обычных constraints семантически свободен. Compiler может ставить дешёвые assertions раньше applicators ради `flag`, но observable tree не должен зависеть от оптимизации: для `basic`, `detailed`, `verbose` units сериализуются в детерминированном schema/keyword order.

Boolean `true` возвращает success с пустым coverage и unit без detail; boolean `false` возвращает failure. Boolean schemas не производят annotations, но участвуют в hierarchy и guard как обычные адресуемые nodes.

Resource boundary определяется target `rid`, а не синтаксическим видом перехода: child applicator тоже может войти во встроенный resource с `$id`. Поэтому dynamic scope обновляет общий evaluator вход после `resolve/2`, а не только обработчики ссылок.

## Два результата

Покрытие для `unevaluated*` содержит только эффективные аннотации успешных schema objects ([core.txt:1206](../references/json-schema/draft-2020-12/core.txt)). Диагностическое дерево содержит также провалы и успешные ветви внутри `not`, нужные `verbose` ([core.txt:3254](../references/json-schema/draft-2020-12/core.txt)).

```erlang
-record(eval_result, {
    valid     :: boolean(),
    evaluated :: evaluated(),
    units     :: [#output_unit{}]
}).

-type evaluated() :: #{properties => sets:set(binary()),
                       items      => non_neg_integer() | all}.
```

Поле `items` пока не заморожено: integer подходит для непрерывного prefix, но успешный `contains` может отметить разреженные indexes. До P4 требуется выбрать set/ranges или доказать иной эквивалентный инвариант; это явно вынесено в аудит overview и не должно быть молча реализовано как «максимальный индекс».

`evaluated` собирается во всех форматах; `units` — во всех, кроме `flag`. При провале schema object его `evaluated` очищается, но `units` сохраняются.

| Конструкция | Покрытие при успехе |
| --- | --- |
| schema object, `allOf` | объединение всех применённых constraints/ветвей |
| `anyOf`, `oneOf` | объединение успешных ветвей |
| `not` | всегда пусто |
| `if`/`then`/`else` | вклад `if` плюс выбранная ветвь |
| `$ref` | покрытие цели |

Annotations, нужные `unevaluated*`, не смешиваются с output details. `evaluated()` — специализированная маска: property names и верхняя граница покрытых array indexes (`all` при полном покрытии). Единственная операция объединения — union/max; единственное правило отбрасывания — пустая маска провалившегося schema object.

Это разделение обязательно для `not`: успешная внутренняя schema попадает в diagnostic units, потому что `verbose` показывает все результаты, но никогда не вносит effective coverage. Аналогично annotation-only keyword внутри провалившегося schema object остаётся виден в diagnostic tree и не выходит эффективной annotation в `basic`.

## Output unit и локации

```erlang
-record(output_unit, {
    valid             :: boolean(),
    keyword_location  :: [binary()],
    absolute_location :: {uri(), [binary()]} | undefined,
    instance_location :: [binary()],
    detail            :: {error, binary()} | {annotation, json()} | none,
    nested            :: [#output_unit{}]
}).
```

Локации — обратные стеки сегментов: push/pop выполняется за O(1), JSON Pointer escaping и URI percent-encoding делаются при печати. `keywordLocation` проходит сквозь ссылки; `absoluteKeywordLocation` строится из канонического resource URI и печатается всегда, кроме anonymous resource.

Сериализация разделена явно:

- `keywordLocation` и `instanceLocation` — JSON Pointer с `~0`/`~1`, без percent-encoding;
- `absoluteKeywordLocation` — resource URI, `#`, pointer escaping и затем percent-encoding недопустимых во fragment символов;
- empty segment stack печатается пустым pointer; anonymous resource не синтезирует URI.

Draft 2019-09 prose требует fragment-encoded `instanceLocation`, но закреплённые output fixtures и output schema требуют обычный JSON Pointer. Внутренняя форма от выбора не зависит; compatibility policy остаётся открытой.

Каждый constraint порождает unit. Поэтому присутствие `properties: {}`, no-op assertions и полная иерархия `verbose` восстанавливаются без исходной схемы или presence mask.

`flag` — единственный режим с short-circuit, что соответствует рекомендации спецификации ([core.txt:3048](../references/json-schema/draft-2020-12/core.txt)). Даже в нём обрыв запрещён внутри node с непустым `unevaluated`, пока не рассчитано нужное покрытие.

## Проекции output

| Формат | Что строится |
| --- | --- |
| `flag` | только корневое `valid`; units не собираются, short-circuit разрешён |
| `basic` | плоские error/annotation units всех применённых keywords |
| `detailed` | минимальная вложенная структура, сохраняющая значимые branches |
| `verbose` | полностью реализованная hierarchy, включая успехи и отброшенные results |

Все три структурных формата строятся из одного дерева units; отдельного evaluator API на формат нет. Официальный snapshot закрепляет только `basic`, поэтому точные правила схлопывания `detailed` и полнота `verbose` должны быть зафиксированы собственными golden/structure tests до P7.

## Контекст и cycle guard

```erlang
-type format() :: flag | basic | detailed | verbose.

-record(eval_context, {
    schema            :: compiled(),
    resource          :: rid(),
    keyword_location  :: [binary()],
    instance_location :: [binary()],
    dynamic_scope     :: [rid()],
    guard             :: sets:set(frame()),
    mode              :: format()
}).

-type frame() :: {addr(), [binary()]}.
```

Guard — множество активных кадров, не глобальный visited set. Кадр добавляется на входе в node и удаляется на выходе: повтор пары schema/instance внутри собственного поддерева означает цикл, тот же повтор в соседней ветви допустим. Если P5 выявит зависимость от dynamic scope, он добавляется третьим элементом frame без изменения остального контракта.

Само обнаружение цикла не задаёт validation verdict автоматически. Для direct self-ref без progress evaluator должен прекратить бесконечный обход согласованным result/error; точная политика связывается с `infinite-loop-detection` в P3 и будущим общим budget. Guard гарантирует termination, а не подменяет семантику applicator'а.

# Публичный результат

```erlang
-type option() :: {output, format()}.
-type output() :: json().

-spec validate(compiled(), json(), [option()]) ->
    {ok, output()} | {error, term()}.
```

По умолчанию запрашивается `flag`. `{ok, Output}` возвращается и при `valid = false`; это нормальный результат, не ошибка. `{error, term()}` означает невозможность провести вычисление, например исчерпанный бюджет. Формат входит в вызов evaluator'а, потому что определяет сбор units и возможность short-circuit.

Output всегда является JSON value, уже соответствующим выбранному standard format. Conformance runner может сразу проверять его `output-schema.json`; прикладной caller читает то же поле `valid`. Отдельный wrapper с внутренними records наружу не выходит.
