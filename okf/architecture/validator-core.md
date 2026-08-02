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

`additionalItems` без `items` игнорируется по спецификации. `contains.MarksEvaluated` равен true в Draft 2020-12 и false в Draft 2019-09; при false разреженная часть маски покрытия всегда пуста, поэтому в Draft 2019-09 маска вырождается в непрерывный prefix. `format.Assert` вычисляет compiler из vocabulary и compile options; binary format name сохраняется открытым значением и всегда доступен для annotation.

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

Defaults применяет handler, а не compiler. Это сохраняет hierarchy для `verbose` и видимые в `basic` пустые annotations. Исключения ограничены keywords, которые спецификация велит игнорировать или которые полностью потребляются compiler (`$id`, `$schema`, anchors, `$defs`, совместимый `definitions`, `$vocabulary`, `$comment`).

## Инварианты компиляции IR

- Все nodes, включая неиспользованные `$defs`, строятся до валидации; ссылки уже разрешены в `addr()`.
- Parent-pointer и retrieval-pointer locations embedded resources
  канонизируются compile-time индексом до построения constraints; aliases в
  `compiled()` не сохраняются.
- Компилятор посещает только schema positions активных keywords и location-reserving `$defs` с совместимым `definitions` ([validation.txt:1416](../references/json-schema/draft-2020-12/validation.txt)); внутрь unknown, `enum`, `const`, `default` и property names он не спускается.
- Dangling и non-schema targets — compile errors. `optional/refOfUnknownKeyword` остаётся вне профиля как undefined behavior.
- Подсхема с `$id` получает новый `rid`; поэтому дочерние переходы всегда хранят полный `addr()`, не голый pointer.
- `#node.unevaluated` отделяет constraints, которые обязаны выполняться последними.
- Написанный keyword сохраняется даже при no-op значении. `undefined` в составном constraint означает только отсутствие keyword; спецификационное default применяет обработчик.
- `additionalProperties`, `prefix/items`, array-form `items/additionalItems`, `contains/min/maxContains` и `if/then/else` сворачиваются статически, но каждый фактический keyword получает собственный output unit.
- `{recursive_ref, ...}` и `{dynamic_ref, ...}` разведены. Флаг `recursive_anchor` принадлежит корню resource. Некорневой `$recursiveAnchor` проверяется как boolean, но флаг не меняет; подсхема с `$id` уже образует новый resource и может объявить собственный флаг.

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

Legacy compatibility не смешивается с vocabulary semantics. `definitions` у
двух стандартных dialects — location-reserving alias `$defs`; оба контейнера
могут присутствовать одновременно и сохраняют собственные pointer locations.
Старый `dependencies` не входит в основной профиль: Draft 2019-09 игнорирует
его, Draft 2020-12 сохраняет как unknown annotation. Recursive keywords имеют
описанную выше семантику только в Draft 2019-09; в Draft 2020-12 они являются
unknown annotations, а не псевдонимами dynamic keywords.

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
6. выпускает собственный unit и кладёт внутрь него units выполненных constraints;
7. снимает frame и resource scope, возвращает `#eval_result{}`.

Порядок обычных constraints семантически свободен. Compiler может ставить дешёвые assertions раньше applicators ради `flag`, но observable tree не должен зависеть от оптимизации: для `basic`, `detailed`, `verbose` units сериализуются в детерминированном schema/keyword order.

Boolean `true` возвращает success с пустым coverage, boolean `false` — failure. Annotations boolean schemas не производят, но остаются обычными адресуемыми nodes: собственный unit выпускают и они, а поскольку keywords у них нет, сообщение о провале несёт этот unit сам.

Resource boundary определяется target `rid`, а не синтаксическим видом перехода: child applicator тоже может войти во встроенный resource с `$id`. Поэтому dynamic scope обновляет общий evaluator вход после `resolve/2`, а не только обработчики ссылок.

## Два результата

Покрытие для `unevaluated*` содержит только эффективные аннотации успешных schema objects ([core.txt:1206](../references/json-schema/draft-2020-12/core.txt)). Диагностическое дерево содержит также провалы и успешные ветви внутри `not`, нужные `verbose` ([core.txt:3254](../references/json-schema/draft-2020-12/core.txt)).

```erlang
-record(eval_result, {
    valid     :: boolean(),
    evaluated :: evaluated(),
    units     :: [#output_unit{}]
}).

-type evaluated() :: #{properties := sets:set(binary()),
                       items      := items_mask()}.

-type items_mask() :: all
                    | {Prefix :: non_neg_integer(), Sparse :: sets:set(non_neg_integer())}.
```

Маска массива канонична: `Sparse` не содержит индексов меньше `Prefix` и не содержит сам `Prefix`. Нейтральный элемент — `{0, sets:new()}`.

Разделение на префикс и разреженную часть обязательно, потому что «максимальный покрытый индекс» неверен. `prefixItems`, `items` и `additionalItems` покрывают непрерывный префикс либо весь массив, но успешный `contains` отмечает произвольные indexes: на схеме `{"allOf": [{"contains": {"multipleOf": 2}}, {"contains": {"multipleOf": 3}}], "unevaluatedItems": {"multipleOf": 5}}` и инстансе `[2, 3, 4, 7, 8]` покрыты индексы 0, 1, 2 и 4, а индекс 3 обязан дойти до `unevaluatedItems`. Максимум дал бы 4 и признал массив покрытым целиком. При этом хранить одно множество всех индексов нельзя: `items` на массиве в сто тысяч элементов материализовал бы сто тысяч целых. Разреженную часть порождает только `contains`, и по спецификации при совпадении со всеми элементами его аннотация равна `true`, поэтому `Sparse` всегда меньше длины массива.

`evaluated` собирается во всех форматах; `units` — во всех, кроме `flag`. При провале schema object его `evaluated` очищается, но `units` сохраняются.

| Конструкция | Покрытие при успехе |
| --- | --- |
| schema object, `allOf` | объединение всех применённых constraints/ветвей |
| `anyOf`, `oneOf` | объединение успешных ветвей |
| `not` | всегда пусто |
| `if`/`then`/`else` | вклад `if` плюс выбранная ветвь |
| `$ref` | покрытие цели |

Annotations, нужные `unevaluated*`, не смешиваются с output details. `evaluated()` — специализированная маска: property names и покрытые array indexes. Единственное правило отбрасывания — пустая маска провалившегося schema object.

Вклад в маску массива дают только эти constraints, каждый при собственном успехе:

| Constraint | Вклад |
| --- | --- |
| `prefix_items` без хвостового `items`, N схем на массив длины L | `all` при `N >= L`, иначе `{N, ∅}` |
| `items`, хвостовой `items` внутри `prefix_items`, `additionalItems` | `all` |
| `items_array` | как `prefix_items` |
| `contains` при `MarksEvaluated = true` | `all`, если совпали все элементы, иначе `{0, MatchedIndexes}` |
| `unevaluated_items` | `all` |

Обработчик `contains` и без того обходит весь массив ради `minContains` и `maxContains`, поэтому возврат совпавших indexes не добавляет стоимости.

Объединение масок — union по множествам и max по префиксу с последующей нормализацией:

```erlang
merge_items(all, _) -> all;
merge_items(_, all) -> all;
merge_items({P1, S1}, {P2, S2}) ->
    normalize(max(P1, P2), sets:union(S1, S2)).

normalize(P, S) ->
    case sets:is_element(P, S) of
        true  -> normalize(P + 1, sets:del_element(P, S));
        false -> {P, sets:filter(fun(I) -> I > P end, S)}
    end.
```

Нормализация нужна не ради компактности: без неё одно и то же покрытие получает разные представления в зависимости от порядка обхода ветвей, и от этого порядка начинают зависеть fixtures. Соседний `prefixItems` при нормализации поглощает индексы `contains`, а не хранит их рядом.

`unevaluated*` читают маску так:

```erlang
unevaluated_indexes(all, _L)                -> [];
unevaluated_indexes({P, _S}, L) when P >= L -> [];
unevaluated_indexes({P, S}, L) ->
    [I || I <- lists:seq(P, L - 1), not sets:is_element(I, S)].
```

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

Units образуют дерево, и уровни в нём чередуются. Каждый node выпускает собственный unit на своей локации, внутри него лежат units его keywords, а внутри unit'а applicator-keyword'а — units nodes, к которым этот keyword применился. Составной constraint чередования не нарушает: units ветви он кладёт внутрь того keyword'а, который её применил.

Собственный unit schema object не несёт ни сообщения, ни аннотации. Он говорит только о том, что подсхема применялась и чем это кончилось, а причину провала называют его дети; спецификация прямо освобождает узлы ветвления от сообщения ([core.txt:3150](../references/json-schema/draft-2020-12/core.txt)). Сообщение появляется у node лишь там, где детей нет вовсе, — у boolean `false`.

Локации — обратные стеки сегментов: push/pop выполняется за O(1), JSON Pointer escaping и URI percent-encoding делаются при печати. `keywordLocation` проходит сквозь ссылки; `absoluteKeywordLocation` строится из канонического resource URI и печатается всегда, кроме anonymous resource.

Эти две локации живут по-разному. `keywordLocation` — накопленный стек: обход добавляет к нему сегмент за сегментом и продолжает его через `$ref`. `absoluteKeywordLocation` ничего не накапливает и выводится из адреса node в момент построения unit: канонический URI даёт `rid`, путь внутри resource — pointer, а последним сегментом идёт имя keyword. Поэтому переход по ссылке не требует ни сброса, ни отдельного стека, а у анонимного resource локация отсутствует сама собой, потому что `id` у него не определён.

Сериализация разделена явно:

- `keywordLocation` и `instanceLocation` — JSON Pointer с `~0`/`~1`, без percent-encoding ([rfc6901.txt:95](../references/rfc/rfc6901.txt));
- `absoluteKeywordLocation` — resource URI, `#`, pointer escaping и затем percent-encoding недопустимых во fragment символов; это URI fragment identifier form указателя ([rfc6901.txt:261](../references/rfc/rfc6901.txt)) поверх грамматики fragment ([rfc3986.txt:1308](../references/rfc/rfc3986.txt));
- empty segment stack печатается пустым pointer; anonymous resource не синтезирует URI.

Draft 2019-09 prose требует fragment-encoded `instanceLocation`, но закреплённые output fixtures и output schema требуют обычный JSON Pointer. Внутренняя форма от выбора не зависит; compatibility policy остаётся открытой.

Каждый constraint порождает unit. Поэтому присутствие `properties: {}`, no-op assertions и полная иерархия `verbose` восстанавливаются без исходной схемы или presence mask.

`flag` — единственный режим с short-circuit, что соответствует рекомендации спецификации ([core.txt:3048](../references/json-schema/draft-2020-12/core.txt)). Даже в нём обрыв запрещён внутри node с непустым `unevaluated`, пока не рассчитано нужное покрытие, и запрет этот действует не только на сам node: успех первой ветви `anyOf`, стоящего сколь угодно глубоко под цепочкой in-place applicators, не отменяет аннотаций остальных ветвей. Переносит запрет поле `coverage` в контексте.

## Проекции output

| Формат | Что строится |
| --- | --- |
| `flag` | только корневое `valid`; units не собираются, short-circuit разрешён |
| `basic` | плоские error/annotation units всех применённых keywords |
| `detailed` | минимальная вложенная структура, сохраняющая значимые branches |
| `verbose` | полностью реализованная hierarchy, включая успехи и отброшенные results |

Все три структурных формата строятся из одного дерева units; отдельного evaluator API на формат нет. Официальный snapshot закрепляет только `basic`, поэтому точные правила схлопывания `detailed` и полнота `verbose` должны быть зафиксированы собственными golden/structure tests до P7.

Корнем `basic` служит unit корневого node: его локации и его собственный detail печатаются прямо в объекте результата, а плоский список идёт в `errors` либо `annotations` — по валидности этого же корня. В список попадает то, что несёт detail: сообщение при провале, аннотацию при успехе. Собирая аннотации, обход не спускается в провалившийся unit: провалившийся schema object не производит аннотаций ни своими keywords, ни keywords своих подсхем ([core.txt:1206](../references/json-schema/draft-2020-12/core.txt)). Из дерева эти аннотации не исчезают — их показывает `verbose`. Поэтому units ветвлений в нём не видны — своего сообщения у них нет, — а провалившаяся boolean-схема видна, потому что сообщение есть только у неё самой. Пустой список остаётся ключом: `errors` обязателен при `valid = false`, `annotations` — при `valid = true`, и второго ключа рядом быть не должно ([output-schema.json](../../test/fixtures/json-schema-test-suite/output-tests/draft2020-12/output-schema.json)).

## Контекст и cycle guard

```erlang
-type format() :: flag | basic | detailed | verbose.

-record(eval_context, {
    schema            :: compiled(),
    node              :: addr(),
    keyword_location  :: [binary()],
    instance_location :: [binary()],
    dynamic_scope     :: [rid()],
    guard             :: sets:set(frame()),
    mode              :: format(),
    coverage          :: boolean()
}).

-type frame() :: {addr(), [binary()]}.
```

`node` — адрес вычисляемого сейчас node. Отдельного поля под текущий resource нет: это первая половина адреса, и граница определяется её сравнением. Вторая половина, pointer, задаёт путь от корня resource и потому полностью определяет абсолютную локацию всех units этого node. Обработчик получает контекст целиком, поэтому строит её сам и ни от кого не наследует.

`coverage` говорит, ждёт ли покрытие этого поддерева какой-нибудь `unevaluated*` выше по обходу. Одного взгляда на собственный `#node.unevaluated` для этого мало: покрытие поднимается по цепочке in-place applicators, поэтому запрет обрыва обязан идти вниз по ней же. Флаг поднимается на входе в node с непустым `unevaluated` и гаснет при спуске в дочернюю schema через `properties`, `items`, `contains`, `propertyNames` и сами `unevaluated*`: покрытие такой schema принадлежит ей самой и наверх не идёт, а значит под ней обрыв снова разрешён.

Guard — множество активных кадров, не глобальный visited set. Кадр добавляется на входе в node и удаляется на выходе: повтор пары schema/instance внутри собственного поддерева означает цикл, тот же повтор в соседней ветви допустим. Dynamic scope в кадр не входит, и `$dynamicRef` этого не изменил: новый resource попадает в scope только с внутреннего конца, а лексический fallback сам вносит resource своей цели, поэтому у повторно встреченной пары динамическая цель та же, что и в прошлый раз. Обратный вариант — положить в кадр сам стек — сломал бы детекцию: стек растёт неограниченно, и кадр не повторился бы никогда.

Обнаружение цикла не даёт validation verdict. Ложных срабатываний у guard'а не бывает: вернуться к той же паре schema/instance, не покидая текущей ветви, можно только по цепочке in-place applicators, а они не сдвигают позицию в инстансе. Значит на повторном заходе не изменилось ничего и обход повторил бы себя дословно. У такой схемы вердикта нет, и `validate/3` возвращает `{error, {no_progress, addr()}}`. Guard гарантирует termination, а не подменяет семантику applicator'а.

# Публичный результат

```erlang
-type option() :: {output, format()}.
-type output() :: json().
-type eval_error() :: {no_progress, addr()}.

-spec validate(compiled(), json(), [option()]) ->
    {ok, output()} | {error, eval_error()}.
```

По умолчанию запрашивается `flag`. `{ok, Output}` возвращается и при `valid = false`; это нормальный результат, а не ошибка. Единственная причина отказа — сработавший cycle guard. Собственных лимитов глубины, памяти и времени валидатор не вводит, поэтому других вариантов ошибки у вычисления нет. Формат входит в вызов evaluator'а, потому что определяет сбор units и возможность short-circuit.

Output всегда является JSON value, уже соответствующим выбранному standard format. Conformance runner может сразу проверять его `output-schema.json`; прикладной caller читает то же поле `valid`. Отдельный wrapper с внутренними records наружу не выходит.
