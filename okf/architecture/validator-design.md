---
type: Architecture
title: Validator core design
description: Инварианты ядра валидатора, классификация keywords обоих диалектов, модель JSON-значения, регулярные выражения, представление скомпилированной схемы, загрузка ресурсов и поэтапный план реализации.
tags: [json-schema, architecture, validator, keywords, compiled-schema, roadmap]
status: draft
---

# Что является ядром

Минимальное ядро определяется не набором ключевых слов, а набором инвариантов движка. Ключевые слова добавляются дёшево — новый тег ограничения и ветка в evaluator'е. Перечисленные ниже инварианты ретрофитить нельзя: их отсутствие означает переписывание движка.

| Инвариант | Основание | Что ломается при отсрочке |
| --- | --- | --- |
| Результат вычисления — не boolean: рядом с валидностью идут покрытие для `unevaluated*` и диагностическое дерево, и это **два разных набора** | `unevaluated*` определены через аннотации ([core.txt:828](../references/json-schema/draft-2020-12/core.txt)), но `verbose` возвращает и те, что отброшены ([core.txt:3253](../references/json-schema/draft-2020-12/core.txt)) | Evaluator и все обработчики |
| Тройка локаций в каждом output unit: `keywordLocation` (проходит сквозь `$ref`), `absoluteKeywordLocation`, `instanceLocation` | Требуется форматами `basic`, `detailed`, `verbose`; строится только по ходу обхода | Сигнатура рекурсии, все обработчики |
| Внутреннее представление результата — дерево output units, из которого выводятся все четыре формата | `flag` есть проекция дерева; обратное преобразование невозможно | Слой вывода |
| Стек динамических scope в контексте вычисления | `$dynamicRef` и `$recursiveRef` разрешаются по стеку schema resources, а не лексически | Контекст рекурсии |
| Таблица keywords параметризована диалектом: `$schema` → vocabularies → набор тегов | Draft 2019-09 и Draft 2020-12 — разные таблицы над одним движком | Компилятор, cross-draft |
| Значение неизвестного keyword'а сохраняется целиком | Неизвестные keywords дают аннотации в Draft 2020-12 ([core.txt:475](../references/json-schema/draft-2020-12/core.txt)) | Компилятор схем |
| Аннотации отбрасываются при провале schema object ([core.txt:1207](../references/json-schema/draft-2020-12/core.txt)) | Комбинатор результатов не сводится к конъюнкции валидностей | Комбинаторы |
| Режим обхода живёт в контексте вычисления и выводится из формата вывода | `flag` допускает обрыв, `verbose` не допускает; `contains` обязан обойти все элементы ради аннотаций | Безопасность оптимизации |

Следствие: инкремент, в котором реализован единственный keyword `type`, уже возвращает полноценный output unit с локациями и пустым списком аннотаций.

# Классификация keywords

Состав взят из vocabulary meta-schemas в [`priv/json_schema/`](../../priv/json_schema/).

| Класс поведения | Draft 2020-12 | Отличия Draft 2019-09 |
| --- | --- | --- |
| Assertion, чистые: instance → boolean, без подсхем | `type`, `enum`, `const`, `multipleOf`, `maximum`, `exclusiveMaximum`, `minimum`, `exclusiveMinimum`, `maxLength`, `minLength`, `pattern`, `maxItems`, `minItems`, `uniqueItems`, `maxProperties`, `minProperties`, `required`, `dependentRequired` | идентично |
| Assertion над аннотацией | `minContains`, `maxContains` | идентично |
| In-place applicators: та же instance location, аннотации поднимаются к родителю | `allOf`, `anyOf`, `oneOf`, `not`, `if`, `then`, `else`, `dependentSchemas` | идентично |
| Child applicators: спуск по instance, производят аннотации | `properties`, `patternProperties`, `additionalProperties`, `propertyNames`, `prefixItems`, `items`, `contains` | `items` принимает schema или массив; есть `additionalItems`; нет `prefixItems`; `contains` не производит аннотацию |
| Annotation-dependent, выполняются последними | `unevaluatedProperties`, `unevaluatedItems` | входят в applicator vocabulary; `unevaluatedItems` учитывает только `items`, `additionalItems` и себя ([core.txt:2320](../references/json-schema/draft-2019-09/core.txt)) |
| Core и referencing | `$schema`, `$id`, `$anchor`, `$ref`, `$defs`, `$comment`, `$vocabulary`, `$dynamicRef`, `$dynamicAnchor` | вместо dynamic — `$recursiveRef`, `$recursiveAnchor` |
| Annotation-only | `title`, `description`, `default`, `deprecated`, `readOnly`, `writeOnly`, `examples`, `contentEncoding`, `contentMediaType`, `contentSchema` | идентично |
| Format | `format`, две vocabulary: annotation (по умолчанию) и assertion | одна vocabulary, только annotation |
| Неизвестные | SHOULD трактоваться как аннотация со значением keyword'а ([core.txt:475](../references/json-schema/draft-2020-12/core.txt)) | SHOULD игнорироваться ([core.txt:444](../references/json-schema/draft-2019-09/core.txt)) |

Таблица описывает семантику спецификации, а не состав скомпилированного терма. Собственное ограничение получает не каждый keyword: `additionalProperties`, `items`, `additionalItems`, `minContains`, `maxContains`, `then` и `else` поглощаются составными ограничениями (см. «Зависимости внутри одного schema object»), а `$id`, `$anchor`, `$defs`, `$schema`, `$vocabulary`, `$dynamicAnchor` и `$comment` не дают ограничений вовсе — они потребляются компилятором.

# Граф зависимостей

## Структура: направление зависимостей

Ниже — граф вызовов между слоями, а не расписание работ. Слой в одиночку непроверяем: компилятор без evaluator и вывода даёт структуру, которую не с чем сравнить. Порядок работ задаётся вертикальными срезами и описан в «Поэтапном плане».

```
L0  Модель JSON-значения      числа, строки, равенство, ключи объектов
L1  URI по RFC 3986           resolve, normalize, JSON Pointer, fragment
L2  Компилятор схем           документ → compiled(): выделение ресурсов по $id,
                              индексы якорей, составные ограничения, полный индекс узлов
L3  Resource resolution       резолвер внутри ресурса — нужен рано, вместе с первыми
                              ссылками; store() и add/3 — поздно, в P3; до этого
                              compile/3 от терма даёт один анонимный ресурс
L4  Evaluator                 контекст: keyword location, instance location,
                              текущий ресурс, dynamic scope stack, cycle guard,
                              режим
      L5a  Обработчики assertion       не зависят ни от чего
      L5b  Обработчики applicator      зависят от L4
      L5c  $ref, $dynamicRef           зависят от L3 и dynamic scope
      L5d  unevaluated*                зависят от аннотаций L5b и L5c
L6  Output builder            дерево units → flag, basic, detailed, verbose
L7  Dialect и vocabulary      $schema → набор тегов, $vocabulary, cross-draft
```

`unevaluated*` зависит от `$ref` транзитивно: аннотации приходят из подсхем, достигнутых по ссылке. Поэтому L5c реализуется раньше L5d — иначе поведение окажется корректным только на схемах без ссылок.

## Зависимости внутри одного schema object

Schema object — конъюнкция ограничений: они независимы и неупорядочены. Почти все внутриобъектные зависимости не рантаймовые, а статические, и снимаются компилятором.

`additionalProperties` смотрит не на результат вычисления, а на статически известное множество: имена из `properties` и регулярные выражения из `patternProperties` записаны в тексте схемы. То же с `items` в Draft 2020-12 — он применяется к индексам от длины `prefixItems`, известной при компиляции, — и с `additionalItems` в Draft 2019-09. `minContains` и `maxContains` суть параметры того же обхода массива, что делает `contains`. `then` и `else` без `if` не имеют силы.

Поэтому они не отдельные ограничения, а части составных:

| Составное ограничение | Поглощает |
| --- | --- |
| `properties` | `properties`, `patternProperties`, `additionalProperties` |
| `items` | `prefixItems` и `items` (2020-12); `items` и `additionalItems` (2019-09) |
| `contains` | `contains`, `minContains`, `maxContains` |
| `if_then_else` | `if`, `then`, `else` |

Обязательство обработчика составного ограничения: выпускать output units с именем фактического keyword'а, чтобы `keywordLocation` был `/additionalProperties`, а не `/properties`.

Сворачивание в компилятор не только упрощает структуру, но и исключает ошибку, которую порядок выполнения не исключает. Схема

```json
{ "allOf": [ { "properties": { "a": {} } } ], "additionalProperties": false }
```

на экземпляре `{"a": 1}` **невалидна**: `additionalProperties` учитывает только соседние `properties` и `patternProperties` того же schema object, но не аннотации, пришедшие через `allOf`. Обработчик, читающий общий накопитель аннотаций, увидел бы аннотацию из `allOf` и ошибочно пропустил экземпляр. Статический аргумент такой ошибки не допускает по построению.

В рантайме остаётся единственная зависимость: `unevaluatedProperties` и `unevaluatedItems` читают аннотации, накопленные всеми остальными keywords, включая пришедшие через in-place applicators и `$ref`. Статически это не вычислимо. Различие бинарное, номера фазы для него не нужно — его выражает отдельное поле узла.

# Модель JSON-значения

## Отображение

Значение представляется нативным термом Erlang, без обёрток и тегов. Отображение совпадает с тем, что даёт `json:decode/1` из stdlib OTP 27 — внешний декодер не нужен.

| JSON | Erlang | Примечание |
| --- | --- | --- |
| `null` | `null` | |
| `true`, `false` | `true`, `false` | |
| number, целый литерал | `integer()` | произвольная точность |
| number, дробный литерал | `float()` | IEEE-754 double |
| string | `binary()` | валидный UTF-8 |
| array | `list()` | |
| object | `#{binary() => json()}` | порядок и дубликаты ключей теряются |

```erlang
-type json()      :: null | boolean() | number() | binary() | [json()] | #{binary() => json()}.
-type json_type() :: null | boolean | object | array | number | integer | string.
```

Отображение инъективно везде, кроме чисел: `<<"null">>` не равно `null`, `<<>>` не равно `[]`, `<<"true">>` не равно `true`. Потеря порядка и дубликатов ключей безразлична: дубликаты RFC 8259 оставляет неопределёнными, а порядок ни один keyword не наблюдает.

## Равенство

Равенство JSON есть `==`. Собственная функция сравнения не нужна: `==` рекурсивно приводит числа и при этом не смешивает типовые классы.

```
1 == 1.0                                     -> true
#{<<"a">>=>[1,#{}]} == #{<<"a">>=>[1.0,#{}]} -> true
true == 1                                    -> false
null == <<"null">>                           -> false
[] == <<>>                                   -> false
9007199254740993 == 9007199254740992.0       -> false
```

Последняя строка существенна: сравнение целого с дробным точно и на bignum, поэтому набор «float and integers are equal up to 64-bit representation limits» из `const.json` проходит без специальной обработки. На `==` держатся `const`, `enum`, `uniqueItems` и `dependentSchemas`.

`uniqueItems` на `==` квадратичен. Линейный вариант через мапу требует канонизирующего ключа — рекурсивной замены `float()` с нулевой дробной частью на `integer()`, после которой `=:=` совпадает с `==`. Канонизация выполняется локально внутри обработчика, а не на входе валидатора: глобальная исказила бы значения аннотаций, которые отдаются наружу как есть.

## Различение целого и дробного

Ни один keyword не различает `1` и `1.0`. `type: "integer"` обязан принимать `1.0`, `const: 1` обязан принимать `1.0`, `uniqueItems` считает `[1.0, 1.00, 1]` неуникальным. Различие существует в терме Erlang и не существует в семантике JSON Schema.

Поэтому `type` — не поиск по тегу, а дизъюнкция предикатов, в которой `integer` шире лексического целого:

```erlang
is_type(integer, V) -> is_integer(V) orelse (is_float(V) andalso V == trunc(V));
is_type(number,  V) -> is_number(V);
```

`type_of/1`, возвращающий `json_type()`, остаётся, но только для диагностики в сообщениях об ошибках; проверка `type` через него не идёт.

## Границы точности

Числа вне диапазона double распадаются на три случая, и потерей является только третий.

| Случай | Поведение | Следствие |
| --- | --- | --- |
| Целое любой величины | точно, bignum | целочисленный блок `optional/bignum` проходит даром |
| Float-литерал вне диапазона (`1e400`) | декодер бросает исключение | ни один сценарий suite такого не требует |
| Больше 17 значащих цифр | округляется до ближайшего double | два сценария «float comparison with high precision» из `optional/bignum` вне профиля |

Точные decimal не вводятся. Они потребовали бы собственного декодера и хранения исходного литерала при каждом числе, а взамен сделали бы ручным всё сравнение, которое сейчас даёт `==` — ради двух сценариев опционального набора.

Строки: длины в `minLength` и `maxLength` считаются в code points, что на UTF-8-бинарнике даёт `string:length/1`. Декодер отвергает битый UTF-8 и одиночные суррогаты, поэтому обработчики строк работают с заведомо корректным значением.

## Где двоичные дроби проступают наружу

Единственное место, где выбор double виден в алгоритме, — `multipleOf`. Наивное `V / M` роняет `badarith` при переполнении, и suite зажимает алгоритм с трёх сторон сразу:

| Схема | Данные | Ожидание |
| --- | --- | --- |
| `multipleOf: 0.0001` | `0.0075` | true |
| `type: integer`, `multipleOf: 0.5` | `1e308` | true |
| `type: integer`, `multipleOf: 0.123456789` | `1e308` | false |

Первый случай требует «десятичного» ответа, два других переполняют деление, причём с разными исходами. Работающий гибрид: при двух целых — `rem`; при представимом частном — `Q = V / M` и проверка `Q == round(Q)`, которой достаточно, поскольку `0.0075 / 0.0001` даёт ровно `75.0`; при переполнении — точная арифметика над разложением double в дробь `p / 2^q`, дающая `0.5 → 1/2¹` и `0.123456789 → 8895999182988127/2⁵⁶` и потому оба нужных ответа на bignum.

Существенно, что модель значения ради этого не меняется: гибрид покрывает и обязательный набор, и оба переполненческих сценария опционального.

# Регулярные выражения

## Что требует спецификация

Единственное **MUST** относится к якорям ([core.txt:709](../references/json-schema/draft-2020-12/core.txt)):

> Implementations MUST NOT take regular expressions to be anchored, neither at the beginning nor at the end. This means, for instance, the pattern "es" matches "expression".

Оно выполняется даром: `re:run/3` по умолчанию ищет подстроку. Требование состоит в том, чтобы это не сломать — не оборачивать паттерн в `^…$` и не передавать опцию `anchored`.

Диалект ECMA-262 и Unicode-режим заявлены как SHOULD ([core.txt:679](../references/json-schema/draft-2020-12/core.txt)), сопровождённые рекомендацией авторам схем ограничиться подмножеством токенов. Слабость этих SHOULD и делает частичную поддержку допустимой.

## Решение

Движок — `re` из stdlib, без собственной реализации ECMA-262. Опции компиляции:

```erlang
re:compile(Pattern, [unicode, dollar_endonly])
```

`multiline` и `anchored` не передаются никогда: в ECMA-262 без флага `m` `^` и `$` относятся к границам ввода, а якорение запрещено приведённым выше MUST. `dollar_endonly` выравнивает `$` с ECMA-262, где это конец ввода, тогда как в PCRE по умолчанию `$` совпадает ещё и перед финальным переводом строки. `ucp` не передаётся — она перекладывает ошибку с `\s` на `\d`, а не устраняет её.

```erlang
-type regex() :: {binary(), re:mp()}.
```

Исходный текст паттерна хранится рядом со скомпилированным, и держит его одна причина — диагностика. `re:mp()` есть `{re_pattern, _, _, _, <<…>>}`, байткод, из которого исходник не восстанавливается; без него сообщение об ошибке не может назвать паттерн, которому не соответствовала строка. Больше взять его негде: схема в скомпилированном терме не хранится. Для `patternProperties` текст ещё читается из указателя — `<<"/patternProperties/^x-">>`, — а для `pattern` в указателе стоит только имя keyword'а.

Обоснованием это не является для теста компилятора: эталон с `re:mp()` строится тем же вызовом компиляции, что и сам компилятор, и потому сличается напрямую.

Невалидный паттерн — ошибка компиляции схемы, по той же логике, что и висячая ссылка: спецификация требует от `pattern` быть регулярным выражением, и подстановки на этот случай мы не изобретаем.

Слой опирается на гарантию модели значения: `re:run/3` с опцией `unicode` бросает `badarg` на некорректном UTF-8. Безопасность обеспечена тем, что декодер уже отверг битые строки и одиночные суррогаты, — это зависимость, а не везение.

## Чем за это заплачено

Замер: 63 строковых сценария `pattern` из обязательного набора и `optional/ecmascript-regex`, прогнанные через `re`.

| Опции | Прошло |
| --- | --- |
| `[unicode]` | 41/63 |
| `[unicode, ucp]` | 42/63 |
| `[unicode, dollar_endonly]` | 41/63 |
| `[unicode, ucp, dollar_endonly]` | 42/63 |

Расхождения с ECMA-262, в порядке значимости:

| Расхождение | Проявление |
| --- | --- |
| Длинные имена Unicode-свойств | `\p{Letter}` даёт ошибку компиляции, `\p{L}` компилируется |
| `\w` шире нормы | под опцией `unicode` матчит `é`; в ECMA-262 остаётся `[A-Za-z0-9_]` даже под флагом `u` |
| `\s` уже нормы | ECMA-262 включает NBSP, BOM, U+2003, U+2029; PCRE без `ucp` — только ASCII |

Уже корректны без вмешательства: `\d`, `\D`, `\t`, `\cC`, ASCII-диапазоны, отсутствие якорения. `optional/non-bmp-regex` проходит целиком (7/7) и потому не относится к опциональным профилям.

Красными остаются `optional/ecmascript-regex` целиком и группа `^\p{Letter}+$` в `pattern.json` и `patternProperties.json` — последняя относится к обязательному набору, и до её закрытия conformance для Draft 2020-12 не заявляется.

## Отложенный эксперимент

Адаптация выполняется переписыванием паттерна перед `re:compile/2` и распадается на две независимые ступени.

Первая — таблица псевдонимов General_Category: `\p{Letter}` → `\p{L}` и подобные. Требует сканера, отличающего `\p{…}` от escape-последовательностей, но не разбора синтаксиса. Закрывает обязательную группу.

Вторая — переписывание классов символов: `\d` → `[0-9]`, `\w` → `[A-Za-z0-9_]`, `\s` → явный класс ECMA-262 и то же для дополнений. Подстановкой не делается: `\W` внутри `[...]` не разворачивается в `[^...]`, нужен разбор синтаксиса классов. Закрывает `optional/ecmascript-regex`.

Эксперимент ставится после того, как остальной конвейер заработает: обе ступени локальны в одной функции подготовки паттерна и не влияют ни на форму скомпилированного терма, ни на evaluator.

# Представление скомпилированной схемы

## Ресурс

> A JSON Schema resource is a schema which is canonically identified by an absolute URI. — [core.txt:547](../references/json-schema/draft-2020-12/core.txt)

Всякий ресурс есть схема; не всякая схема есть ресурс. Ресурсность — роль, которую схема получает вместе с каноническим URI: корень документа плюс подсхемы с `$id`. Один документ может содержать несколько ресурсов.

Ресурс является областью действия четырёх вещей, и потому он же — единица компиляции:

| Область действия | Задаётся | Следствие для компилятора |
| --- | --- | --- |
| Base URI | `$id` | относительные ссылки внутри считаются от него |
| Диалект | `$schema`, допустимый только в корне ресурса ([core.txt:797](../references/json-schema/draft-2020-12/core.txt)); при отсутствии — диалект объемлющего ресурса | набор тегов выбирается на границе ресурса |
| Пространство `$anchor` | якорь виден в пределах своего ресурса | индекс якорей строится на ресурс |
| Звено динамического стека | `$dynamicAnchor` | на стек кладутся ресурсы, индекс динамических якорей живёт в ресурсе |

Встретив `$id` в подсхеме, компилятор отрезает её в отдельный ресурс. Поэтому встроенный и вынесенный в отдельный файл варианты дают одинаковую скомпилированную форму — то поведенческое тождество, которого требует [core.txt:1965](../references/json-schema/draft-2020-12/core.txt).

Наследование диалекта — то же тождество, взятое с другой стороны, и в двух диалектах оно обосновано по-разному. Draft 2020-12 требует его нормативно: «schema resources which do not define with which dialect they should be processed MUST be processed with the same dialect as the enclosing resource» ([core.txt:2122](../references/json-schema/draft-2020-12/core.txt)), и там же разрешает встроенному ресурсу объявить **другой** диалект. Draft 2019-09 секции про диалекты не имеет вовсе: `$schema` «SHOULD be used in a resource root schema», при отсутствии поведение implementation-defined, а разные `$schema` в одном документе — тоже implementation-defined при SHOULD одинаковых ([core.txt:1318](../references/json-schema/draft-2019-09/core.txt)). Правило берётся одно на оба: в 2020-12 это исполнение MUST, в 2019-09 — осознанный выбор внутри implementation-defined. Довод тот же: иначе смысл ресурса менялся бы от того, встроен он или вынесен в файл.

Приёмкой этот выбор проверяется лишь наполовину. Встроенных ресурсов без `$schema` в `tests/` обоих диалектов 99 в 17 файлах — они подтверждают, что отказ компиляции здесь неверен, но между «наследует объемлющий» и «берёт умолчание компиляции» не различают: диалект объемлющего в них всегда совпадает с диалектом точки входа. Встроенный `$schema` встречается ровно один раз — группа «`$ref` with `$recursiveAnchor`» в [`draft2019-09/ref.json`](../../test/fixtures/json-schema-test-suite/tests/draft2019-09/ref.json), и он тоже совпадает с объемлющим. Встроенного ресурса с **другим** диалектом в наборе нет, поэтому вторая половина решения держится на записанном доводе, а не на тесте.

## Тип

```erlang
-type uri()     :: binary().    % абсолютный URI без фрагмента
-type pointer() :: binary().    % JSON Pointer от корня ресурса; <<"">> — корень
-type rid()     :: uri() | anonymous.
-type addr()    :: {rid(), pointer()}.
-type dialect() :: uri().       % нормализованное значение $schema

-type compiled()    :: #{root      := rid(),
                         sources   := [uri()],
                         resources := #{rid() => #resource{}}}.
-type schema_node() :: boolean() | #node{}.

-record(resource, {
    id              :: uri() | undefined,   % undefined только у анонимного корня
    dialect         :: dialect(),
    anchors         :: #{binary() => pointer()},
    dynamic_anchors :: #{binary() => pointer()},
    nodes           :: #{pointer() => schema_node()}
}).

-record(node, {
    constraints :: [constraint()],
    unevaluated :: [constraint()]
}).
```

Булева схема хранится собой: `true` или `false` прямо в `nodes`. Полей у неё быть не может — она не имеет keywords и потому не производит аннотаций ([core.txt:1048](../references/json-schema/draft-2020-12/core.txt)). Все три локации output unit берутся из контекста вычисления и `addr()`, а не из узла, поэтому и провал `false` описывается полностью.

`rid()` — идентификатор ресурса внутри скомпилированного терма. Для именованного ресурса это его каноническое имя, для корня схемы, пришедшей термом из кода, — атом `anonymous`. Откуда берутся имена и почему их бывает ноль, одно или два, описано в «Загрузке ресурсов».

`sources` — имена документов реестра, из которых собран этот терм. Не выводится из `resources`: там лежат `rid` ресурсов, включая встроенные с собственным `$id`, а нужны имена документов. Поле нужно перезаливу — по нему видно, какие артефакты устарели после изменения документа; см. «Владение и перезалив». Метасхемы входят в `sources` наравне с документами схем: реестр читается на компиляции и по `$ref`, и по `$schema`, а `$vocabulary` метасхемы определяет набор активных keywords — значит её правка обесценивает собранные под ней артефакты ровно так же, как правка самой схемы.

`dialect()` — URI метасхемы дословно, а не имя из перечисления. Перечисление из двух значений выразить `$schema` не может: он законно указывает на зарегистрированную пользовательскую метасхему, и в обязательном наборе такое есть (см. «Метасхемы»). Набор тегов из URI выводится компилятором, в скомпилированном терме не хранится и на вычислении не нужен — см. «Диалект».

Исходный JSON ресурса в скомпилированном терме не хранится: всё, что нужно на вычислении, уже скопировано в ограничения — значения `enum`, `const`, аннотаций и неизвестных keywords. Благодаря этому эталонный терм в тесте компилятора выписывается целиком, без элизий. Сырой документ живёт в `store()` — это другая структура и другая стадия.

Схема `{}` в `true` не схлопывается. Семантически они эквивалентны, но схлопывание — это лишнее правило, а не экономия: компилятор, идущий по тексту схемы, естественно даёт `#node{constraints = []}`, и чтобы получить вместо него `true`, нужна отдельная проверка. Пустой `constraints` вычисляется даром.

Инвариант «`unevaluated*` последними» выражен типом, а не дисциплиной сортировки: нарушить его нельзя. Свободный порядок внутри `constraints` оставляет запас на сортировку по стоимости — дешёвые assertions перед applicators, что экономит в режиме `flag` с ранним обрывом; это оптимизация, а не корректность.

## Ограничения

```erlang
-type constraint() ::
    %% ссылки
      {ref,           addr()}
    | {dynamic_ref,   binary(), addr()}        % имя якоря + лексическая цель
    | {recursive_ref, addr()}                  % 2019-09

    %% assertions над числом
    | {multiple_of, number()}
    | {maximum, number()} | {exclusive_maximum, number()}
    | {minimum, number()} | {exclusive_minimum, number()}

    %% assertions над строкой
    | {max_length, non_neg_integer()} | {min_length, non_neg_integer()}
    | {pattern, regex()}

    %% assertions над массивом
    | {max_items, non_neg_integer()} | {min_items, non_neg_integer()}
    | unique_items

    %% assertions над объектом
    | {max_properties, non_neg_integer()} | {min_properties, non_neg_integer()}
    | {required, [binary()]}
    | {dependent_required, #{binary() => [binary()]}}

    %% assertions над любым значением
    | {type, [json_type()]}
    | {enum, [json()]}
    | {const, json()}

    %% in-place applicators
    | {all_of, [addr()]} | {any_of, [addr()]} | {one_of, [addr()]}
    | {'not', addr()}
    | {if_then_else, addr(), addr() | undefined, addr() | undefined}
    | {dependent_schemas, #{binary() => addr()}}

    %% child applicators
    | {properties, #{binary() => addr()},      % properties
                   [{regex(), addr()}],        % patternProperties
                   addr() | undefined}         % additionalProperties
    | {property_names, addr()}
    | {items, [addr()], addr() | undefined}    % prefixItems + items | items + additionalItems
    | {contains, addr(), non_neg_integer(), non_neg_integer() | infinity}

    %% аннотации и format
    | {annotation, binary(), json()}           % title, default, contentSchema, неизвестные
    | {format, atom()}                         % только при format-assertion vocabulary

    %% annotation-dependent, живут в #node.unevaluated
    | {unevaluated_properties, addr()}
    | {unevaluated_items, addr()}.
```

Тег есть данные: имён модулей в терме нет. Диспетчеризация — `case` по тегу в evaluator'е, а реализации живут в отдельных модулях, имена которых в скомпилированную схему не попадают. Благодаря этому весь терм состоит из атомов, бинарников, чисел, кортежей и мап: его можно напечатать, сравнить с эталоном и положить в файл. Тест компилятора именно этим и будет.

Единственная непрозрачная составляющая — `re:mp()` внутри `regex()`: при печати она нечитаема, но детерминирована и сравнима, поэтому эталон с ней строится тем же вызовом компиляции и сличается напрямую.

Три следствия читаются прямо из типа.

`{items, [addr()], addr() | undefined}` обслуживает оба диалекта одной формой. В 2020-12 первый элемент — `prefixItems`, второй — `items`. В 2019-09 `items` в форме массива даёт первый, `additionalItems` — второй, а `items` в форме схемы даёт `{items, [], Addr}`. Различается только имя keyword'а в output unit, и обработчик берёт его из `#resource.dialect`.

`unique_items` — атом без аргумента, и появляется он только при `"uniqueItems": true`. При `false` компилятор не порождает ничего: ограничения, не ограничивающего ничего, в терме нет.

У корня ресурса `constraints` вполне может быть пуст при непустом JSON — например у `{"$id": …, "$defs": {…}}`, где оба keyword'а потребляются компилятором.

## Адресация

`addr()` — не отдельная система имён, а путь по самой структуре:

```erlang
resolve({Rid, Ptr}, #{resources := Rs}) ->
    #resource{nodes = Nodes} = maps:get(Rid, Rs),
    maps:get(Ptr, Nodes).
```

Одна функция обслуживает `$ref`, спуск в подсхему, вход во встроенный ресурс и стартовую точку валидации. Поиска по URI здесь нет и быть не может: `$ref` разрешён в `addr()` ещё при компиляции, и многоимённость документов до этого уровня не доходит — она живёт на границе `store()` и там же кончается.

`#resource.id` — каноническое имя ресурса, то самое, что уходит в `absoluteKeywordLocation`. Оно есть у всякого ресурса, кроме корня схемы, пришедшей термом из кода без `$id`: у него `id = undefined`, `rid = anonymous`, и `absoluteKeywordLocation` для узлов внутри него опускается — [core.txt:2919](../references/json-schema/draft-2020-12/core.txt) разрешает это, «if the schema does not declare an absolute URI as its `$id`».

## Решения

**Ссылки хранятся адресами, а не указателями на термы.** `$ref` компилируется в `addr()`, узел достаётся по нему в момент вычисления. Причины: циклы (`infinite-loop-detection.json`) остаются конечными и сравнимыми термами; ресурс компилируется независимо, и адрес в него валиден независимо от порядка обхода, то есть обратной правки уже собранных термов не нужно; а `$dynamicRef` в принципе разрешим только в рантайме. Один механизм вместо двух.

**Подсхемы адресуются полным `addr()`, а не голым pointer'ом.** Синтаксически вложенная подсхема может принадлежать другому ресурсу, если несёт `$id`.

**Компилируется структура, а не замыкания.** Замыкания несовместимы с адресными ссылками, сравнимостью термов в cycle guard и печатью скомпилированной схемы в тесте.

**Компилируется всё заранее и без исключений.** Индекс узлов заполняется целиком при компиляции документа, поэтому сличение терма с эталоном тотально: ничего не «доедет позже». `resolve/2` остаётся в единственной приведённой выше форме — тотальной, без ветки восстановления. Это распространяется и на междокументные ссылки: компиляция тянет транзитивное замыкание по `store()`, поэтому состояния «ресурс, на который есть ссылка, ещё не скомпилирован» не существует.

**Резолв — отдельная фаза, а не часть обхода.** Порядок жёсткий: нарезка ресурсов с определением диалектов → построение `nodes` и индексов якорей → разрешение ссылок в `addr()`. Иначе не сходится: куда спускаться, решает диалект ресурса, а он читается из `$schema` в корне ресурса до всякой диспетчеризации; ссылка же может целить в ресурс, чей набор узлов ещё не построен. Отсюда же и «компилируется всё заранее»: адресуемость узла определяется только после того, как pointer space собран целиком, поэтому подсхемы под известными keywords компилируются полностью — включая ветки `$defs`, на которые никто не ссылается.

**Позиции, не признанные схемой, не компилируются.** Схемность есть свойство позиции, а не текста:

> Subschema objects (or booleans) are recognized by their use with known applicator keywords or with location-reserving keywords such as `$defs`… — [core.txt:2169](../references/json-schema/draft-2020-12/core.txt)

Компилятор идёт только туда, куда подсхему поместил известный keyword. Внутрь значения неизвестного keyword'а он не спускается, как не спускается внутрь `enum`, `const`, `default`, `examples` и внутрь имён свойств в `properties`.

«Известный» здесь означает «активный в диалекте ресурса», поэтому множество адресуемых узлов зависит от диалекта, хотя правила разрешения ссылок — нет. Сам резолв выключить нельзя: `$ref`, `$id`, `$anchor`, `$defs`, `$dynamicRef`, `$recursiveRef` принадлежат Core, а Core обязателен при любом наборе словарей, поэтому base URI, индекс якорей, dynamic scope и границы ресурсов от словарей не зависят вовсе. Зависит только `nodes`: под диалектом без applicator vocabulary `properties` — не applicator, компилятор внутрь не идёт, и `#/properties/foo` становится висячей ссылкой. Один и тот же документ с одной и той же ссылкой под одним диалектом собирается, под другим — ошибка компиляции. Это та же неопределённость из [core.txt:2176](../references/json-schema/draft-2020-12/core.txt), взятая с другой стороны, и то же правило её закрывает. `$defs` под него не попадает никогда: он location-reserving и в Core ([core.txt:1248](../references/json-schema/draft-2020-12/core.txt)), то есть обходится при любом наборе словарей, — а это и есть локация, рекомендованная спецификацией для bundling'а.

Два опциональных набора давят на это правило с противоположных сторон, и оба удовлетворяются им же. `optional/unknownKeyword.json` требует, чтобы `$id` внутри неизвестной структуры **не** был зарегистрирован как идентификатор: там три ветки `anyOf`, и верный ответ получается, только если два поддельных `$id` проигнорированы. `optional/refOfUnknownKeyword.json` требует обратного — уметь отработать `$ref` в такую позицию. Наивное «компилируем всё, что похоже на объект» проходит второй набор и валит первый.

Спецификация разрешает конфликт в пользу первого, объявляя второй сценарий неопределённым:

> Multi-level structures of unknown keywords are capable of introducing nested subschemas, which would be subject to the processing rules for `$id`. Therefore, having a reference target in such an unrecognized structure cannot be reliably implemented, and the resulting behavior is undefined. Similarly, a reference target under a known keyword, for which the value is known not to be a schema, results in undefined behavior… — [core.txt:2176](../references/json-schema/draft-2020-12/core.txt)

Реализации, у которых такие ссылки случайно работают, спецификация отдельно дисквалифицирует: «this behavior is implementation-specific and MUST NOT be relied upon for interoperability». Поэтому `optional/refOfUnknownKeyword.json` осознанно вне профиля — это отказ от одной из трактовок неопределённого поведения, а не от требования. Наблюдаемое поведение на этом наборе стоит назвать точно: не «`false` вместо `true`», а ошибка компиляции — suite там ожидает успешной валидации, и в отчёте это выглядит иначе, чем провал теста.

Проверено по обоим обязательным наборам: внутридокументные `$ref` целятся только в `#`, `#/$defs/…`, `#/properties/…`, `#/items/N`, `#/prefixItems/N`. Ни одна обязательная ссылка не смотрит в позицию, не являющуюся схемой.

**Висячая ссылка отвергается, а не угадывается.** После сборки ресурса множество его узлов известно, поэтому `$ref` с указателем в несуществующий узел уже скомпилированного ресурса — ошибка компиляции; её форма и локация заданы в «Ошибках компиляции». Междокументная ссылка проверяется там же: компиляция втягивает замыкание из `store()`, поэтому и незарегистрированный документ, и несуществующий указатель внутри него обнаруживаются на компиляции. Выбор поддержан примечанием самой спецификации: интерпретировать не-схему как схему «has security implications and may produce unpredictable results».

## Примеры

Булева схема `true`:

```erlang
D = <<"https://json-schema.org/draft/2020-12/schema">>,
#{ root      => anonymous,
   sources   => [],
   resources => #{anonymous =>
     #resource{id = undefined, dialect = D,
               anchors = #{}, dynamic_anchors = #{},
               nodes = #{<<"">> => true}}} }
```

Дальше показано только содержимое `resources` — обёртка с `root` и `sources` во всех примерах одинакова, `D` то же самое.

Составное ограничение над объектом:

```json
{ "type": "object", "required": ["a"],
  "properties": { "a": { "type": "integer" } },
  "patternProperties": { "^x-": true },
  "additionalProperties": false }
```

```erlang
#{ anonymous => #resource{id = undefined, dialect = D,
                          anchors = #{}, dynamic_anchors = #{},
     nodes = #{
       <<"">> => #node{unevaluated = [], constraints = [
          {type, [object]},
          {required, [<<"a">>]},
          {properties,
             #{<<"a">> => {anonymous, <<"/properties/a">>}},
             [{Re, {anonymous, <<"/patternProperties/^x-">>}}],
             {anonymous, <<"/additionalProperties">>}}]},
       <<"/properties/a">>          => #node{constraints = [{type, [integer]}], unevaluated = []},
       <<"/patternProperties/^x-">> => true,
       <<"/additionalProperties">>  => false}} }
```

Три keyword'а свёрнуты в одно ограничение, но подсхема каждого остаётся самостоятельным узлом по своему указателю — иначе локацию ошибки внутри `/patternProperties/^x-` было бы нечем построить.

Рекурсия через `$defs`:

```json
{ "$id": "https://example.com/tree",
  "$defs": { "node": { "type": "object",
    "properties": { "children": { "type": "array", "items": { "$ref": "#/$defs/node" } } } } },
  "$ref": "#/$defs/node" }
```

```erlang
T = <<"https://example.com/tree">>,
#{ T => #resource{id = T, dialect = D, anchors = #{}, dynamic_anchors = #{},
     nodes = #{
       <<"">> => #node{constraints = [{ref, {T, <<"/$defs/node">>}}], unevaluated = []},

       <<"/$defs/node">> => #node{unevaluated = [], constraints = [
          {type, [object]},
          {properties, #{<<"children">> => {T, <<"/$defs/node/properties/children">>}},
                       [], undefined}]},

       <<"/$defs/node/properties/children">> => #node{unevaluated = [], constraints = [
          {type, [array]},
          {items, [], {T, <<"/$defs/node/properties/children/items">>}}]},

       <<"/$defs/node/properties/children/items">> =>
          #node{constraints = [{ref, {T, <<"/$defs/node">>}}], unevaluated = []}}} }
```

`$defs` не породил ограничения — его содержимое просто попало в индекс узлов. Цикл замкнут через адреса, поэтому терм конечен, сравним и печатаем; на этом же держится cycle guard, ключом которого служит `frame()` — см. «Результат вычисления и вывод».

Встроенный ресурс — единственный случай, где меняется верхний уровень:

```json
{ "$id": "https://example.com/foo",
  "items": { "$id": "https://example.com/bar", "additionalProperties": { } } }
```

```erlang
#{ <<"https://example.com/foo">> => #resource{id = <<"https://example.com/foo">>, …,
     nodes = #{<<"">> => #node{unevaluated = [],
        constraints = [{items, [], {<<"https://example.com/bar">>, <<"">>}}]}}},

   <<"https://example.com/bar">> => #resource{id = <<"https://example.com/bar">>, …,
     nodes = #{
       <<"">> => #node{unevaluated = [], constraints = [
          {properties, #{}, [], {<<"https://example.com/bar">>, <<"/additionalProperties">>}}]},
       <<"/additionalProperties">> => #node{constraints = [], unevaluated = []}}} }
```

Указатели внутри `bar` отсчитываются от его корня — `"/additionalProperties"`, а не `"/items/additionalProperties"`.

Неизвестный keyword даёт аннотационное ограничение, несущее своё сырое значение:

```json
{ "myCustom": { "sub": { "type": "string" } } }
```

```erlang
#node{unevaluated = [], constraints = [
   {annotation, <<"myCustom">>, #{<<"sub">> => #{<<"type">> => <<"string">>}}}]}
```

Узел `"/myCustom/sub"` не создаётся и не появится позже: эта позиция схемой не считается. `$ref` в неё отвергается как ошибка компиляции — независимо от того, из своего документа он пришёл или из чужого.

В Draft 2019-09 того же ограничения нет: там неизвестный keyword игнорируется, а не аннотируется, и `constraints` остаётся пустым.

# Результат вычисления и вывод

## Наборов два, а не один

Schema object с ложным assertion result аннотаций не производит ([core.txt:1206](../references/json-schema/draft-2020-12/core.txt)) — на этом держатся `unevaluated*`. Но `verbose` обязан вернуть и их: «all results are returned. This includes sub-schema validation results that would otherwise be removed (e.g. annotations for failed validations, successful validations inside a `not` keyword)» ([core.txt:3254](../references/json-schema/draft-2020-12/core.txt)). Это два разных набора данных, и тройка «валидность, аннотации, ошибки» их смешивает.

Подтверждено обязательной частью output-набора — [`content/general.json`](../../test/fixtures/json-schema-test-suite/output-tests/draft2020-12/content/general.json), группа «failed validation produces no annotations»: схема `{"type": "string", "readOnly": true}` на данных `1` обязана дать `errors` и не дать ни `annotations`, ни поля `annotation` ни в одном unit'е. `readOnly` аннотацию произвёл — наружу она не вышла.

```erlang
-record(eval_result, {
    valid     :: boolean(),
    evaluated :: evaluated(),      % покрытие для unevaluated*: только успешные ветки
    units     :: [#output_unit{}]  % диагностика: всё, включая провалы и успехи внутри not
}).

-type evaluated() :: #{properties => sets:set(binary()),
                       items      => non_neg_integer() | all}.
```

`evaluated()` — посчитанная маска покрытия, а не общий список аннотаций, отфильтрованный в месте потребления. Потребитель у неё ровно один — `unevaluated*`; правило слияния одно — объединение; правило отбрасывания одно — при `valid = false` вернуть пустую. Общий список пришлось бы тащить по горячему пути и в режиме `flag`, где ни одна аннотация не будет напечатана, а `unevaluated*` всё равно берёт из него только покрытие. Цена решения — если появится keyword, зависящий от произвольной аннотации, маску придётся расширить; это один тип и его правила слияния, ни форму `compiled()`, ни публичный контракт такое расширение не задевает.

Диалектные различия в маску попадают на компиляции, а не ветвлением на вычислении: в 2020-12 `contains` вносит вклад в `items`, в 2019-09 не производит аннотации вовсе и не вносит. `minContains` и `maxContains` через `evaluated()` не ходят — они свёрнуты в составное ограничение с `contains` и получают счётчик напрямую.

## Правила подъёма

| Конструкция | `valid` | `evaluated` | `units` |
| --- | --- | --- | --- |
| Успешный schema object | все ограничения | объединение своих и поднятых | все |
| Провалившийся schema object | — | **пустая** | все, включая аннотации провалившихся |
| `allOf` | конъюнкция | объединение по всем ветвям, если сам успешен | все ветви |
| `anyOf`, `oneOf` | по своему правилу | объединение только успешных ветвей | все ветви |
| `not` | инверсия | пустая всегда | все, с исходным `valid` вложенных |
| `if`/`then`/`else` | по выбранной ветке | `if` вносит вклад независимо от того, применялась ли `then` | все три |
| `$ref` | цели | цели | цели, с продолженным `keyword_location` |

Строка `not` — та, ради которой разделение и заводится: внутри него успешное вычисление обязано попасть в `units` и обязано не попасть в `evaluated`.

## Output unit

```erlang
-record(output_unit, {
    valid             :: boolean(),
    keyword_location  :: [binary()],               % обратный стек сегментов
    absolute_location :: {uri(), [binary()]} | undefined,
    instance_location :: [binary()],               % обратный стек сегментов
    detail            :: {error, binary()} | {annotation, json()} | none,
    nested            :: [#output_unit{}]
}).
```

Локации хранятся **сегментами, а не склеенной строкой**. Обход кладёт и снимает сегмент за O(1) вместо конкатенации бинарника на каждом шаге; экранирование выполняется один раз при печати; `absolute_location` и `keyword_location` печатаются из одного значения по разным правилам; а расхождение источников по `instanceLocation` в Draft 2019-09 становится параметром печати, а не другой формой хранения.

Правила печати заданы снапшотом. [`content/escape.json`](../../test/fixtures/json-schema-test-suite/output-tests/draft2020-12/content/escape.json) пиннит `keywordLocation: "/properties/~0a~1b/type"`, `instanceLocation: "/~0a~1b"` и `absoluteKeywordLocation: "https://…/escape/0#/properties/~0a~1b/type"`, а официальная [`output/schema.json`](../../priv/json_schema/draft-2020-12/output/schema.json) объявляет обоим указателям `format: json-pointer`, а абсолютной локации — `format: uri`. Отсюда:

* `keywordLocation` и `instanceLocation` — обычный JSON Pointer с экранированием `~0` и `~1`, без percent-encoding; `keywordLocation` проходит сквозь `$ref` и `$dynamicRef` ([core.txt:2882](../references/json-schema/draft-2020-12/core.txt));
* `absoluteKeywordLocation` — канонический URI ресурса, `#`, тот же указатель, и **дополнительно** percent-encoding символов, недопустимых во фрагменте по RFC 3986. Фикстурами это не покрыто и держится на решении; всплывает на первом же имени свойства с пробелом.

Когда абсолютная локация печатается: спецификация разрешает опускать её, если dynamic scope не проходил через ссылку или у схемы нет абсолютного `$id` ([core.txt:2920](../references/json-schema/draft-2020-12/core.txt)), но output-схема требует её при `/$ref/` или `/$dynamicRef/` в `keywordLocation`, а [`content/readOnly.json`](../../test/fixtures/json-schema-test-suite/output-tests/draft2020-12/content/readOnly.json) ждёт её и вовсе без ссылок. Правило одно и оба условия покрывает: печатаем всегда, когда `#resource.id =/= undefined`, опускаем только у анонимного ресурса.

## Формат задаёт режим

Отдельной опции short-circuit нет. «`verbose` с обрывом» противоречив, «`basic` с обрывом на первой ошибке» неконформен — `basic` обязан перечислить все. Поэтому обрыв разрешён только при `flag`, где его и рекомендует спецификация ([core.txt:3048](../references/json-schema/draft-2020-12/core.txt)).

Связь режима со сбором данных разная у двух наборов:

* `evaluated` собирается **всегда**, в любом формате: `unevaluated*` от формата вывода не зависит;
* `units` собираются только при формате, отличном от `flag`.

Обрыв при `flag` разрешён не везде: внутри schema object с непустым `#node.unevaluated` ветви нельзя прерывать, их покрытие ещё понадобится. Это известно на компиляции — поле уже есть в `#node{}`.

## Контекст вычисления

```erlang
-record(eval_context, {
    schema            :: compiled(),
    resource          :: rid(),          % текущий ресурс — источник абсолютной локации
    keyword_location  :: [binary()],
    instance_location :: [binary()],
    dynamic_scope     :: [rid()],
    guard             :: sets:set(frame()),
    mode              :: format()
}).

-type frame() :: {addr(), [binary()]}.   % узел и instance location
```

## Cycle guard — множество активных кадров

Не глобальный visited set. Это названо прямо в приёмке P3: [`infinite-loop-detection.json`](../../test/fixtures/json-schema-test-suite/tests/draft2020-12/infinite-loop-detection.json) — «evaluating the same schema location against the same data location twice is not a sign of an infinite loop». Обе ветви `allOf` применяют `#/$defs/int` к `/foo`, и реализация с visited set поднимет ложную тревогу. Кадр кладётся на входе в узел и снимается на выходе: повтор внутри собственного поддерева — цикл, повтор в соседней ветви — норма.

Dynamic scope в идентичность кадра не входит: у `$dynamicRef` цель разрешается в другой `addr()`, поэтому кадры и так расходятся после разыменования. Решение с контрольной точкой — перепроверить на `optional/dynamicRef` в P5; при ложном срабатывании в кадр добавляется третий элемент.

## Публичный результат

```erlang
-type format() :: flag | basic | detailed | verbose.
-type option() :: {output, format()}.        % умолчание — flag
-type output() :: json().                    % документ формата из опции

-spec validate(compiled(), json(), [option()]) -> {ok, output()} | {error, term()}.
```

Возвращается тот самый документ, который определяет спецификация: conformance-раннер отдаёт его в output-схему без слоя преобразования, а прикладной код читает `valid` из него же. Отдельного тега для провала валидации нет — провал есть нормальный результат вычисления, а не ошибка вызова, и `valid` в документе уже есть; `{error, term()}` остаётся только за невозможностью провести вычисление.

Формат — параметр вычисления, а не отдельная функция печати над сохранённым деревом: от него зависит режим сбора, поэтому «посчитали в `flag`, попросили `verbose`» — неисполнимый вызов, которого в API быть не должно.

# Загрузка ресурсов

## Сети нет

> The use of URIs to identify remote schemas does not necessarily mean anything is downloaded, but instead JSON Schema implementations SHOULD understand ahead of time which schemas they will be using, and the URIs that identify them. — [core.txt:1826](../references/json-schema/draft-2020-12/core.txt)

Ядро ничего не скачивает. Документы кладутся в реестр заранее, компиляция берёт их оттуда, а `$ref` на незарегистрированный URI — ошибка компиляции. Тот же механизм обслуживает и conformance suite (содержимое `remotes/` регистрируется под `http://localhost:1234/…` без единого сетевого вызова), и прикладной код, и метасхемы из [`priv/json_schema/`](../../priv/json_schema/) — отдельного resolver-callback'а не требуется.

## Реестр

```erlang
%% Ключ — каноническое имя документа; второе имя, если есть, — алиас.
-type store() :: #{uri() => json() | {alias, uri()}}.

fetch(Uri, Store) ->
    case maps:get(Uri, Store, undefined) of
        {alias, Canonical} -> maps:get(Canonical, Store, undefined);
        Doc                -> Doc
    end.
```

Копия документа ровно одна: два ключа с одинаковым содержимым разошлись бы при первом же `remove/2` или перерегистрации. Цепочек алиасов не бывает по построению — алиас ставится только на канонический ключ, а канонический ключ определяется при добавлении и потом не меняется, поэтому хоп всегда один и цикл не собрать. Неоднозначности между `{alias, _}` и документом нет: в модели значения кортежей не бывает ни на одном уровне.

## API

```erlang
-spec new() -> store().
-spec add(store(), uri(), json()) -> {ok, store()} | {error, schema_error()}.

-spec compile(store(), json(), [copt()])    -> {ok, compiled()} | {error, schema_error()}.
-spec compile_uri(store(), uri(), [copt()]) -> {ok, compiled()} | {error, schema_error()}.

-spec validate(compiled(), json(), [option()]) -> {ok, output()} | {error, term()}.

%% copt()   :: {default_dialect, dialect()}
%% option() :: {output, format()} — см. «Результат вычисления и вывод»
```

`add/3` — неглубокий проход: читается корневой `$id`, документ кладётся под каноническое имя, второе имя добавляется алиасом. Ничего не компилируется. Если любое из двух имён уже занято другим документом — ошибка, не перезапись: сценарий «зарегистрировали remotes и молча затёрли метасхему» иначе не отлаживается.

Обе формы компиляции идут от точки входа и втягивают по ссылкам транзитивное замыкание. Отсюда три следствия: порядок регистрации не важен, взаимные ссылки между документами не мешают, и `$schema` разрешается тем же лукапом. Единственное требование к порядку — реестр наполнен до первой компиляции.

Формы разделены потому, что у них разный base URI, а не ради удобства. `compile_uri/3` даёт корню каноническое имя найденного документа, и относительные ссылки внутри считаются от него. `compile/3` компилирует терм, которого в реестре нет: без `$id` он даёт `root = anonymous`, и относительная ссылка из такого корня — ошибка компиляции. Выразить одно через другое нельзя — `compile(Store, fetch(Uri, Store), Opts)` потеряет имя.

Если терм, переданный в `compile/3`, объявляет корневой `$id`, уже занятый в реестре, — это ошибка, а не переопределение. Правило то же, что в `add/3`, и по той же причине.

`default_dialect` — диалект корня документа, у которого нет `$schema`; умолчание умолчания — URI Draft 2020-12. Опция компиляции, а не поле реестра и не отдельная точка входа: `store()` держит документ значением, и пара «документ плюс диалект» ломает и один хоп `fetch/2`, и инвариант единственной копии, а `compile/3` работает с термом, которого в реестре нет вовсе. Отдельная точка входа для conformance-раннера хуже параметра тем, что раннеру нужны оба диалекта, то есть точек будет две, и приёмка пойдёт не тем API, каким ходит приложение.

## Ошибки компиляции

```erlang
-record(schema_error, {
    reason   :: reason(),
    location :: addr() | undefined      % undefined — у ошибок регистрации
}).

-type reason() ::
      {dangling_ref,            addr()}     % указатель в несуществующий узел
    | {non_schema_target,       addr()}     % цель — не схемная позиция
    | {unknown_document,        uri()}      % нет в реестре
    | relative_uri_without_base             % относительная ссылка из анонимного корня
    | {bad_pattern,             term()}     % re:compile вернул ошибку
    | {unknown_dialect,         uri()}      % $schema вне признаваемого набора
    | {unrecognized_vocabulary, uri()}      % обязательный словарь неизвестен
    | core_vocabulary_missing               % $vocabulary без Core либо Core: false
    | {misplaced_keyword,       binary()}   % $schema или $vocabulary не там, где MUST
    | {name_taken,              uri()}.     % регистрация: имя занято другим документом

-spec format_error(#schema_error{}) -> unicode:chardata().
```

**Первая ошибка прерывает компиляцию.** Довод не в простоте, а в фазах: порядок «нарезка ресурсов → построение узлов → резолв» делает ошибку ранней фазы фатальной для поздних — не нарезав ресурс, некуда разрешать ссылки. Накопить все ошибки одной фазы технически можно, но для этого нужно представление повреждённого узла в промежуточной структуре, то есть ровно та сущность, которую мы не хотим замораживать ради удобства сообщений. Отвергнутый вариант — `{error, [schema_error()]}` — записан здесь вместе с ценой: пользователь с пятью битыми ссылками чинит их за пять компиляций, а поменять форму потом нельзя, клиенты матчат на неё.

**Текст сообщения не хранится, а вычисляется.** Он дублировал бы данные, не поддавался локализации и делал бы тесты хрупкими: эталон поехал бы от правки формулировки. Приёмка от этого разделяется на две независимые — структура сравнивается точно, `format_error/1` проверяется слабо (не падает, возвращает непустой chardata). Это и есть исполнимая форма обещания «ошибка компиляции с внятным сообщением».

**Локация указывает на keyword, а не на schema object** — `{Rid, <<"/properties/foo/$ref">>}`, не `{Rid, <<"/properties/foo">>}`. Те же термины, в которых строится `absoluteKeywordLocation`: понятие локации одно на компиляцию и на вычисление.

**Регистрация и компиляция делят один тип.** Причины не пересекаются, стадия видна из причины, у регистрационных ошибок локации внутри схемы нет — поэтому `location = undefined`, а не отдельная запись. Имя `#schema_error{}` выбрано так, чтобы не путалось с провалом валидации инстанса: провал — это `{ok, Output}` с `valid = false` и ошибкой не называется нигде.

Возврат, а не исключение: провал компиляции — ожидаемый исход обработки внешних данных, а не дефект вызова.

Причины `validate/3` в этот набор не входят. Там ошибкой является невозможность провести вычисление — исчерпанный бюджет и подобное, — и её причины определяются вместе с политикой пределов; см. «Ресурсные ограничения» в открытых вопросах.

Каталог наполняется по фазам: в P0 из него не достижима ни одна причина, потому что булевы схемы не ломаются. Приёмки со стороны сьюта у него нет вовсе — официальный набор исходит из того, что все схемы компилируются, и единственный файл, упирающийся в компиляционную ошибку под нашими решениями, — `optional/refOfUnknownKeyword` — объявлен вне профиля. Значит каталогу нужен собственный набор тестов, по схеме на причину; он ставится рядом с собственными golden-тестами вывода, а не считается покрытым.

## Имена

`add/3` даёт документу [0–2] имени: retrieval URI, под которым его зарегистрировали, и канонический URI из `$id`, разрешённый относительно первого. Какое из них каноническое, выбирает не реализация:

> Unless the `"$id"` keyword described in an earlier section is present in the root schema, this base URI SHOULD be considered the canonical URI of the schema document's root schema resource. — [core.txt:1820](../references/json-schema/draft-2020-12/core.txt)

| retrieval URI | `$id` | ключи в `store()` | `rid()` | `#resource.id` |
| --- | --- | --- | --- | --- |
| есть | нет | retrieval | retrieval | retrieval |
| есть | совпадает | retrieval | retrieval | retrieval |
| есть | отличается | канонический + алиас | `$id` | `$id` |
| нет | есть | — | `$id` | `$id` |
| нет | нет | — | `anonymous` | `undefined` |

Для именованного ресурса ключ в `store()`, `rid()` и `#resource.id` — одна и та же строка. Четвёртая строка — встроенные ресурсы и inline-схема с `$id`; они возникают при компиляции, а не при регистрации, поэтому в реестре их нет.

Ограничивать `store()` двумя именами незачем: карта держит любое их число даром, а спецификация прямо на это рассчитывает — «Implementations SHOULD be able to associate arbitrary URIs with an arbitrary schema» ([core.txt:1835](../references/json-schema/draft-2020-12/core.txt)).

## Анонимный корень

Схема, пришедшая термом из кода и не объявившая `$id`, — самый частый случай, а не краевой: в `tests/draft2020-12/` и `tests/draft2019-09/` вместе с `optional/` таких 807.

Имени у неё нет, поэтому сослаться на неё нельзя ни изнутри, ни снаружи — попасть в неё можно только вызовом API. Это и есть верная семантика: она корень валидации, а не цель ссылки.

Анонимен при этом **корневой ресурс**, а не документ. Вложенный абсолютный `$id` порождает полноценный именованный ресурс, на который сослаться уже можно, — в suite таких схем 14, например «Location-independent identifier with absolute URI» из [`anchor.json`](../../test/fixtures/json-schema-test-suite/tests/draft2020-12/anchor.json):

```json
{ "$ref": "http://localhost:1234/draft2020-12/bar#foo",
  "$defs": { "A": { "$id": "http://localhost:1234/draft2020-12/bar",
                    "$anchor": "foo", "type": "integer" } } }
```

Base URI у анонимного корня взять неоткуда, поэтому относительный `$ref` и относительный вложенный `$id` из него — ошибка компиляции, а не повод синтезировать имя. На conformance это не влияет: среди тех же 807 схем ноль относительных ссылок и ноль относительных вложенных `$id`.

## Метасхемы

`$schema` может указывать на зарегистрированный документ, а не только на канонический URI диалекта. Первая группа [`vocabulary.json`](../../test/fixtures/json-schema-test-suite/tests/draft2020-12/vocabulary.json) ставит его на `http://localhost:1234/draft2020-12/metaschema-no-validation.json`, а тот объявляет `$vocabulary` без validation vocabulary — и `"minimum": 10` в схеме обязан перестать быть assertion'ом.

Значит реестр должен быть наполнен **до компиляции**, а не до валидации: набор тегов выбирается по `$vocabulary` документа, который ещё надо достать. Метасхемы `priv/` регистрируются тем же `add/3` при инициализации.

## Диалект

Диалект ресурса определяется в три шага, и только первый из них — выбор реализации:

1. есть `$schema` в корне ресурса — берётся он;
2. нет, но ресурс встроенный — берётся диалект объемлющего (см. «Ресурс»);
3. нет и ресурс корневой — берётся `default_dialect` из опций компиляции.

Третий шаг спецификация оставляет реализации: «If absent from the document root schema, the resulting behavior is implementation-defined» ([core.txt:1378](../references/json-schema/draft-2020-12/core.txt)). Умолчание применяется к корню любого документа замыкания, а не только точки входа, — то есть документ без `$schema`, втянутый по ссылке, получает диалект вызова, а не своей директории. Цена измерима и по обязательному набору не стреляет: `$schema` нет у 6 файлов из 41 в `remotes/` (`nested-absolute-ref-to-string`, `urn-ref-string`, `different-id-ref-string` в обоих диалектах), и каждый адресуется только из `refRemote.json` своей директории; оба cross-draft remote'а `$schema` объявляют. Если понадобится диалект на документ — это правка уровня реестра, форму `compiled()` она не задевает.

Из URI компилятор выводит набор активных keywords: для двух канонических URI — встроенной таблицей, для всего прочего — разбором `$vocabulary` метасхемы из реестра (P6; до него нераспознанный URI диалекта — ошибка компиляции, что согласуется с conformance-профилем из двух диалектов). Требования спецификации к этому разбору: нераспознанный словарь со значением `true` обязывает отказаться обрабатывать схему, со значением `false` — продолжить ([core.txt:1421](../references/json-schema/draft-2020-12/core.txt)); Core обязателен всегда, метасхема с `$vocabulary` обязана перечислить его с `true`, а `false` у Core или его отсутствие — undefined с рекомендацией поднимать ошибку ([core.txt:1293](../references/json-schema/draft-2020-12/core.txt), [core.txt:1237](../references/json-schema/draft-2019-09/core.txt)); метасхема без `$vocabulary` считается требующей Core ([core.txt:1306](../references/json-schema/draft-2020-12/core.txt)); сам `$vocabulary` MUST игнорироваться в документах, обрабатываемых не как метасхема ([core.txt:1439](../references/json-schema/draft-2020-12/core.txt)).

Дальше диспетчер компилятора — функция пары, а не keyword'а: `(набор словарей, keyword)`. Правило одно и без исключений: keyword активного словаря даёт ограничение, всякий прочий трактуется как неизвестный — в Draft 2020-12 становится аннотацией со своим значением, в Draft 2019-09 игнорируется. Спецификация распространяет обе трактовки на keywords выключенных словарей явно ([core.txt:1429](../references/json-schema/draft-2020-12/core.txt), [core.txt:1380](../references/json-schema/draft-2019-09/core.txt)), поэтому отдельной ветки «выключенный keyword» в компиляторе нет. Проверка на [`vocabulary.json`](../../test/fixtures/json-schema-test-suite/tests/draft2020-12/vocabulary.json): в первой группе applicator включён, validation выключен — `"badProperty": false` внутри `properties` продолжает валить инстанс, `minimum: 10` перестаёт, `$id` и `$schema` работают как часть Core; во второй нераспознанный словарь объявлен со значением `false`, поэтому схема обрабатывается и `"type": "number"` активен.

**Evaluator диалекта не читает.** `#resource.dialect` не участвует в вычислении: вся разница диалектов впечатана в `constraints` при компиляции, и на этом же держится cross-draft — `$ref` из схемы 2020-12 в ресурс 2019-09 вычисляется общими правилами. Поле нужно диагностике, сообщениям компилятора и перезаливу. Если однажды понадобится прочитать его на вычислении — это признак того, что что-то недосчитано компилятором.

## Измерения по `remotes/`

41 файл, 21 корневой `$id`, из них 4 расходятся с путём размещения (`different-id-ref-string.json` и `urn-ref-string.json` в обоих диалектах), и 2 вложенных `$id`. Все `$ref` из `tests/` в remotes идут по retrieval URI: расходящиеся `$id` извне не адресуются вовсе — они там затем, чтобы поймать реализацию, которая выкинула retrieval URI и оставила только канонический.

Обратный случай — `$ref` во встроенный ресурс чужого документа, который сам ни под каким именем не зарегистрирован, — не разрешается: чтобы найти вложенный `$id`, документ нужно сперва скомпилировать, а повода к нему обратиться нет. В suite не встречается, оба вложенных `$id` в `remotes/` адресуются только изнутри своего файла.

# Владение и перезалив

Всё описанное выше — значения: `store()`, `compiled()`, чистые функции между ними. Сервису этого мало: схемы надо где-то держать между запросами и уметь менять на ходу, потому что перезалив схемы после найденного бага и правка схемы на лету в разработке — обычное дело, а не край. Ниже — слой, который этим владеет. Он остаётся библиотечным, но лежит поверх ядра и в conformance не участвует.

## Три уровня

| Уровень | Знает | Не знает |
| --- | --- | --- |
| Ядро | `store()`, `compiled()`, чистые функции между ними | таблиц |
| Хранилище | как разложить артефакты по таблице и достать обратно | откуда таблица взялась |
| Владелец | документы, таблицу, порядок перезалива | устройства схем |

```erlang
%% Уровень хранилища; таблица приходит снаружи, жизненным циклом он не владеет.
-spec build(store(), ets:tab()) -> ok | {error, term()}.
-spec lookup(ets:tab(), uri())  -> {ok, compiled()} | {error, not_found}.
```

Ядро остаётся публичным, а не внутренним: conformance suite гоняет 807 анонимных схем, которым таблицы не нужны вовсе, и весь компилятор тестируется без окружения — вызовом функции, а не поднятием процесса.

## Артефакты толстые

В таблице лежит `compiled()` целиком, вместе с ресурсами втянутых документов. Валидация — один `ets:lookup` и никакой сборки на чтении.

Нормализованный вариант — хранить только собственные ресурсы документа и склеивать полный набор при выдаче — отвергнут. Он экономит память, которой тут килобайты, а платит на горячем пути: N lookup'ов вместо одного, склейка поверх, и согласованность выдачи приходится обеспечивать протоколом (поколение в ключе или сериализующий процесс), тогда как у одноключевого чтения она есть даром. Хуже другое: узлы `B` держат `{rid(), pointer()}` в `A`, и существование указателя проверено при компиляции против прежнего `A`. Пережившая перезалив `A` нормализованная запись `B` формально цела, а ссылка висячая — падение переезжает из компиляции в рантайм.

Цена толстых артефактов — дублирование разделяемых ресурсов между записями. Оно меньше, чем кажется: в замыкание входят только цели `$ref`. Метасхемы туда не попадают — `$schema` читается при компиляции, чтобы выбрать набор тегов по `$vocabulary`, и ресурсом не становится; зарегистрированные, но не упомянутые документы не втягиваются вовсе. В `sources` метасхема при этом записывается: в `resources` её нет, а инвалидировать артефакт при её правке необходимо — иначе схема останется собранной по прежнему набору словарей. Если общий фрагмент действительно размножается по десяткам схем, ближайший шаг — компилировать группу имён одним вызовом в одну запись с общими ресурсами.

## Перезалив — транзакция

Порядок такой:

1. по `sources` найти артефакты, задетые изменившимися документами: сам документ и всё, что его втянуло;
2. скомпилировать этот набор против нового реестра;
3. при полном успехе — один `ets:insert/2` списком; при любой ошибке остаться на старых артефактах.

`insert/2` со списком атомарен и изолирован, поэтому читатель видит либо все старые записи, либо все новые. Промежуточного состояния нет, вторая таблица не нужна, устаревших таблиц не бывает.

Ленивое наполнение — компилировать при промахе — отвергнуто. Оно превращает ошибку деплоя в отложенное падение случайного запроса через час и в другом эндпоинте, тогда как эта схема останавливает перезалив и оставляет трафик на рабочих артефактах. Вдобавок после подмены промахи идут одновременно и все упираются в единственный процесс, который видит документы. Здесь же горячий путь не имеет ветки промаха вовсе: таблица полна по построению.

Артефакт не является функцией одного документа: тот же документ без корневого `$schema` под разными `default_dialect` даёт разный `compiled()`. Поэтому владелец обязан хранить опции компиляции рядом с именем, под которым положил артефакт, и пересобирать с ними же; «имя документа → артефакт» — отображение только при фиксированных опциях.

Обратный индекс «кто зависит от `A`» не заводится. Направление хранения прямое — артефакт помнит свои `sources`, посчитанные в момент его собственной компиляции и меняющиеся только вместе с ним. Индекс существовал бы отдельно от артефактов, требовал синхронизации при каждой сборке и умел бы рассинхронизироваться; вместо него — скан по маленьким спискам на холодном пути.

## Хранение

Одна именованная таблица: имя даёт стабильную точку входа, читателю ничего не передают. Режим `protected` с `read_concurrency` — все записи происходят на перезаливе, внутри процесса-владельца, горячий путь только читает. Таблица умирает вместе с владельцем, поэтому `heir` на супервизор обязателен.

Документам таблица не нужна: они читаются только при компиляции, то есть на холодном пути и только владельцем, — им довольно быть картой `store()` в его состоянии.

Отвергнутые варианты хранения:

* **`persistent_term` для артефактов** — чтение без копирования, но глобальный скан GC на каждую запись. Профиль «записали на старте, читаем вечно» здесь не выполняется.
* **gen_server на пути чтения** — все валидации выстраиваются в одну очередь сообщений, а терм копируется дважды: в состояние процесса и обратно ответом. Это ровно то, ради обхода чего ETS и берут.
* **Таблица-диспетчер** — отдельная запись с tid текущего хранилища; перезалив строит новую таблицу в стороне и переключает указатель. Стоит рассмотреть, если пауза массового `insert` окажется заметной или понадобится атомарное удаление имён. Интерфейс уровня хранилища от этого выбора не зависит: `lookup/2` всё равно получает таблицу снаружи, — поэтому переход не затрагивает ядро. Цена — лишний lookup на каждой валидации и политика выбытия старой таблицы, потому что читатель мог получить её tid за мгновение до подмены.

# Опорный срез

Срез, на котором проявлены все инварианты из первого раздела. Он не совпадает с первым инкрементом и достигается к концу P3.

| Категория | Состав |
| --- | --- |
| Boolean schemas | `true`, `false` |
| Core | `$schema`, `$id`, `$defs`, `$anchor`, `$ref` |
| Assertions | `type`, `enum`, `const`, `required` |
| Applicators | `properties`, `items`, `prefixItems`, `allOf`, `anyOf`, `oneOf`, `not` |
| Аннотации | `title` как представитель класса |
| Вывод | все четыре формата, проверяются `flag` и `basic` |

`properties` и `items` дают производство аннотаций. `allOf` и `anyOf` — их подъём и отбрасывание при провале. `$ref`, `$id`, `$anchor` — выделение ресурсов и расхождение `keywordLocation` с `absoluteKeywordLocation`. `oneOf` и `not` — запрет short-circuit. Остальные keywords заполняют набор тегов.

Первый исполняемый инкремент существенно меньше: булевы схемы и формат `flag`, без единого keyword'а. Он уже фиксирует форму `compiled()`, контекст вычисления, output unit и публичное API — то есть всё, что дорого менять позже.

# Поэтапный план

План построен по вертикальным срезам: каждый инкремент проходит сквозь компилятор, evaluator и вывод целиком и заканчивается запускаемым тестом. Приёмка определяется файлами из [`test/fixtures/json-schema-test-suite/tests/`](../../test/fixtures/json-schema-test-suite/tests/).

| Фаза | Содержание | Приёмочные наборы |
| --- | --- | --- |
| P0 | `json()`, `is_type/2` и равенство; построение локаций — стек сегментов, экранирование `~0`/`~1`, fragment-кодирование абсолютной локации; `compiled()`, `#eval_context{}`, `#eval_result{}`, `#output_unit{}`, формат `flag`, булевы схемы | `boolean_schema` |
| P1 | Чистые assertions | `type`, `enum`, `const`, `maximum`, `minimum`, `exclusiveMaximum`, `exclusiveMinimum`, `maxLength`, `minLength`, `maxItems`, `minItems`, `maxProperties`, `minProperties`, `pattern`, `required`, `uniqueItems`, `multipleOf`, `dependentRequired` |
| P2 | In-place и child applicators, производство аннотаций, составные ограничения | `allOf`, `anyOf`, `oneOf`, `not`, `if-then-else`, `properties`, `patternProperties`, `additionalProperties`, `items`, `prefixItems`, `propertyNames`, `dependentSchemas`, `contains`, `minContains`, `maxContains` |
| P3 | Schema resources, `store()` и `add/3`, `$ref`, cycle guard | `ref`, `defs`, `anchor`, `refRemote`, `infinite-loop-detection`, `optional/id`, `optional/unknownKeyword` |
| P4 | `unevaluatedProperties`, `unevaluatedItems` | `unevaluatedItems`, `unevaluatedProperties` |
| P5 | `$dynamicRef`, `$dynamicAnchor` | `dynamicRef`, `optional/dynamicRef`, `optional/anchor` |
| P6 | Vocabulary-слой и таблица Draft 2019-09: `additionalItems`, `$recursiveRef`, иная семантика `unevaluatedItems` | весь `draft2019-09/`, `vocabulary`, `optional/cross-draft` |
| P7 | Форматы `detailed` и `verbose`, проверка вывода через `output-tests/` | `output-tests/draft2020-12`, `output-tests/draft2019-09` |
| P8 | Опциональные профили | `optional/format-assertion`, `optional/format`, `content`, `optional/bignum`, `optional/float-overflow` |

Уровни хранилища и владельца в фазы не входят: приёмочного набора у них нет — conformance suite обращается к ядру напрямую. Их место определяется потребностью приложения, а не планом.

`format` в annotation-режиме относится к P2, в assertion-режиме — к P8, поскольку это отдельная vocabulary.

`multipleOf` в P1 требует гибридного алгоритма — см. «Где двоичные дроби проступают наружу».

`pattern` и `patternProperties` компилируются через `re` без адаптации паттерна; `optional/non-bmp-regex` проходит на ней даром и в опциональные профили не входит. Обе ступени адаптации вынесены в отложенный эксперимент — см. «Регулярные выражения».

Вне профиля осознанно остаются: `optional/refOfUnknownKeyword` целиком — как неопределённое поведение, от трактовки которого мы отказались (см. «Решения»), и два сценария «float comparison with high precision» из `optional/bignum` — как следствие модели значения.

Красной до первой ступени эксперимента остаётся группа `^\p{Letter}+$` в `pattern.json` и `patternProperties.json` — она входит в обязательный набор.

# Открытые вопросы и выявленные расхождения

Список ведётся по трём категориям. **Ошибки** — утверждения документа, расходящиеся с проверяемым фактом; правятся локально и формы не меняют. **Архитектурные решения** — выборы, задающие форму `compiled()`, контекста вычисления или публичного API. **Открытые вопросы** — то, что требует ответа, но ни того, ни другого не задевает.

У каждого пункта стоит срок закрытия: «до P*N*» — до соответствующей фазы «Поэтапного плана»; «до заморозки IR» — до конца P0, где фиксируются форма терма, контекст вычисления и output unit; «до слоя владельца» — до появления кода, описанного в «Владении и перезаливе»; «до снятия `draft`» — без привязки к фазе. Статус `draft` сохраняется, пока открыт хотя бы один пункт с отметкой «до заморозки IR» или «до снятия `draft`».

## Ошибки

* **`string:length/1` считает не то.** *(до P1)* Спецификация определяет длину строки как число characters по RFC 8259, то есть code points ([validation.txt:385](../references/json-schema/draft-2020-12/validation.txt)); `string:length/1` возвращает число grapheme clusters. Расходятся на комбинирующих последовательностях: `"e"` с combining acute — два code point'а и один кластер, поэтому при `minLength: 2` получится `false` вместо `true`. Обязательный набор этого не ловит: в `maxLength.json` и `minLength.json` стоит `💩`, у которого обе метрики равны единице. Нужен отдельный проход по UTF-8.

* **Дробная запись целочисленных значений не предусмотрена.** *(до P1)* Восемь файлов обязательного набора задают целочисленный keyword дробным литералом: `maxLength: 2.0`, `minLength: 2.0`, `maxItems: 2.0`, `minItems: 1.0`, `maxProperties: 2.0`, `minProperties: 1.0`, `minContains: 2.0`, `maxContains: 1.0`. Типы объявляют `non_neg_integer()`, а нормализация при компиляции нигде не описана. Что делать с `2.5` и `-1`, тоже не сказано — см. «Решить, насколько компилятор проверяет схему».

* **Запрет для анонимного корня сформулирован шире, чем нужно.** *(до P3)* «Сослаться на неё нельзя ни изнутри, ни снаружи» и «относительный `$ref` из неё — ошибка компиляции» смешивают две разные формы: fragment-only ссылки `#`, `#foo`, `#/$defs/…`, которые разрешаются внутри текущего ресурса и внешнего имени не требуют, и ссылки с path-компонентом, для которых base URI действительно нужен. В основном наборе каждого диалекта 24 группы используют `$ref: "#…"` при отсутствии корневого `$id` — 25, если считать также `$dynamicRef` и `$recursiveRef`, — и ноль групп используют ссылку с path. Форму `compiled()` это не задевает: `{ref, {anonymous, <<"/properties/foo">>}}` и якоря анонимного ресурса выражаются уже сейчас. Правится текст и политика компилятора.

* **Описание `\w` неверно, а замеры не воспроизводимы.** *(до P1)* На OTP 27 с `[unicode]` без `ucp` поведение несогласовано: `\w` матчит `é` и поглощает оба байта, `\w+` на том же субъекте даёт `nomatch`; `^\w$` матчит, `^\w+$` — нет; под `[unicode, ucp]` матчат все формы. Утверждение «под опцией `unicode` матчит `é`» верно только для одиночного `\w`. Отсюда второе: таблица 41/63 и 42/63 снята на движке, дающем противоречивые ответы на том самом конструкте, который характеризуется, а скрипт замера в репозиторий не попал — до появления harness'а с зафиксированными паттернами числа не проверяемы. Неполон и довод против `ucp`: он не только «перекладывает ошибку с `\s` на `\d`», но и снимает эту аномалию, что в разделе не названо.

* **`dependentSchemas` не держится на `==`.** *(до снятия `draft`)* Он проверяет наличие свойства и применяет подсхему ко всему объекту; JSON equality там не участвует. На `==` держатся `const`, `enum` и `uniqueItems`.

* **«Спецификация требует от `pattern` быть регулярным выражением» — слишком сильно.** *(до снятия `draft`)* MUST относится только к тому, что значение является строкой; соответствие диалекту ECMA-262 сформулировано как SHOULD ([validation.txt:412](../references/json-schema/draft-2020-12/validation.txt)). Отказ компиляции остаётся законной собственной политикой, но обосновывать его нормативным требованием нельзя.

* **`content` и `default` расставлены по фазам неверно.** *(до P2)* `content.json` и `default.json` лежат в обязательном наборе обоих диалектов, а `content` числится в P8 среди опциональных профилей; `default` не указан в приёмке ни одной фазы.

* **Уровень хранилища не поддерживает описанный перезалив.** *(до снятия `draft`)* `build(store(), ets:tab()) -> ok` компилирует весь реестр и пишет в таблицу сам, тогда как перезалив требует скомпилировать подмножество и отдать владельцу список для одного `ets:insert/2`. Нужна форма вида `build(store(), [uri()]) -> {ok, [{uri(), compiled()}]}`. Там же мелочь: у `build/2` и `lookup/2` разный порядок аргументов.

* **Frontmatter отстал от содержания.** *(до снятия `draft`)* `description` и `tags` не упоминают ни владение артефактами, ни эту секцию, хотя `index.md` про владение уже обновлён.

* **`conformance-policy.md` завышает покрытие.** *(до P7; правка в другом файле)* Утверждение «Все четыре заявленных формата проверяются официальными fixtures» неверно. В закреплённом снапшоте на каждый диалект приходится по четыре файла в `output-tests/*/content/`, по одному тесту в каждом, и во всех единственный формат — `basic`; директории `structure` нет вовсе, а README сьюта прямо говорит, что content-тестам достаточно `basic`.

## Архитектурные решения

* **`{items, …}` требует диалект на вычислении.** *(до заморозки IR)* Форма `{items, [addr()], addr() | undefined}` едина для обоих диалектов, а имя keyword'а для output unit обработчик берёт из `#resource.dialect` («Ограничения») — то есть ветвится по диалекту на вычислении, что противоречит решению «evaluator диалекта не читает» («Диалект»). Различие `prefixItems`/`items` против `items`/`additionalItems` известно на компиляции, значит имя должно нестись самим ограничением. Вопрос в форме: третий элемент кортежа, отдельный тег на диалект или общий механизм «какими keywords порождено» для всех составных ограничений — `properties`, `contains`, `if`/`then`/`else` свёрнуты так же и тоже обязаны восстанавливать `keywordLocation`. Смежно с «Решить, хранится ли присутствие keyword'а»: обе задачи упираются в то, сколько исходного текста схемы несёт скомпилированный терм.

* **Решить, хранится ли присутствие keyword'а.** *(до заморозки IR)* Скомпилированная форма необратимо теряет сведения о явно присутствовавших keywords: `"uniqueItems": false` не даёт ограничения и неотличим от отсутствия; `{contains, Addr, 1, infinity}` не различает отсутствующий `minContains` и явный `"minContains": 1`; поглощённые составным ограничением пустые `properties` и `patternProperties` неразличимы; исходный schema object не хранится. `verbose` описан как «fully realized hierarchy that exactly matches that of the schema» ([core.txt:3239](../references/json-schema/draft-2020-12/core.txt)), но структурных fixtures, способных решить спор о его границах, в снапшоте нет. Решать приходится до фиксации формы терма: после неё восстановить присутствие будет нечем. Варианты — presence-mask и исходный keyword location у каждого скомпилированного keyword'а, отдельное дерево keyword nodes, либо явное сужение обязательств `verbose`.

* **Добавить состояние `$recursiveAnchor`.** *(до заморозки IR)* В Draft 2019-09 `$recursiveRef` ведёт себя как `$ref`, кроме случая, когда его цель содержит `"$recursiveAnchor": true` ([core.txt:1762](../references/json-schema/draft-2019-09/core.txt)). В `#resource{}` есть только `anchors` и `dynamic_anchors`, такого поля нет, поэтому P6 в описанной форме нереализуем. Вместе с полем фиксируется алгоритм: допустимое значение `"#"`, лексическая цель и поиск внешнего ресурса в dynamic scope.

* **Решить, насколько компилятор проверяет схему.** *(до P3)* Сейчас отвергаются битый `pattern` и висячая ссылка; про `maxLength: -1`, `maxLength: 2.5`, `type: "wrong"`, `$id` с фрагментом и невалидный `$anchor` не сказано ничего. Позиции: не проверять ничего сверх нужного для компиляции; проверять синтаксис каждого известного keyword'а; валидировать схему целиком против её метасхемы. Требования к разбору `$vocabulary` и отказу на нераспознанном словаре перечислены в «Диалекте» и здесь не дублируются; открытым в этой части остаётся одно — состав явного списка признаваемых URI словарей, то есть таблицы внутри вывода набора тегов.

* **Зафиксировать позицию по `multipleOf` и десятичным значениям.** *(до снятия `draft`)* Гибрид проходит все одиннадцать обязательных сценариев обоих диалектов и `optional/float-overflow`, но `0.3` при `multipleOf: 0.1` даёт `false`, тогда как спецификация определяет keyword через целочисленный результат деления ([validation.txt:341](../references/json-schema/draft-2020-12/validation.txt)). Расхождение принадлежит модели значения, а не алгоритму: к моменту проверки оба числа уже double, десятичные литералы потеряны декодером, и ближайший к `0.3` double не кратен ближайшему к `0.1`. Два выхода неравны по цене. Расширить оговорку «Границ точности» на `multipleOf` и сузить заявление о соответствии — одно предложение. Ввести точные десятичные — переписывание L0: собственный декодер, хранение исходного литерала при каждом числе и ручное сравнение вместо `==`, на котором держатся `const`, `enum` и `uniqueItems`. Выбранный вариант записывается решением, второй — отвергнутым, с ценой, чтобы вопрос не открывался заново.

* **Решить форму `format`.** *(до заморозки IR)* `{format, atom()}` превращает имя формата из текста схемы в атом, а схемы перезаливаются на ходу — это внешние данные в таблице атомов. Нужен либо `binary()`, либо `binary_to_existing_atom` с определённым поведением на неизвестном имени. Там же не сказано, во что компилируется `format` в annotation-режиме.

* **Определить API изменения реестра.** *(до слоя владельца)* `add/3` на занятое имя даёт ошибку, `replace` и `remove` в API отсутствуют, при этом `remove/2` упоминается в тексте «Реестра». Либо эти функции появляются, либо принимается правило «владелец собирает новый `store()` целиком», и упоминание убирается. Смежное: чем ключуется таблица артефактов — только каноническим именем или алиасами тоже; где живут безымянные артефакты `compile/3`; как таблица возвращается от `heir` перезапущенному владельцу.

## Открытые вопросы

* **Parent-pointer адресация встроенных ресурсов.** *(до P3)* Спецификация разрешает идентифицировать встроенный ресурс JSON Pointer'ом как от его канонического URI, так и от URI любого содержащего ресурса ([core.txt:1952](../references/json-schema/draft-2020-12/core.txt)), и тут же не рекомендует авторам схем этой формой пользоваться. `resolve/2` знает только `{rid(), pointer()}`, поэтому `foo#/items` будет отвергнут. Либо индекс location aliases в канонический `addr()`, либо явное объявление формы вне профиля — с поправкой к заявлению о соответствии.

* **Draft 2019-09 `instanceLocation`.** *(до P7)* Локальный Core требует URI fragment-encoded JSON Pointer ([core.txt:2620](../references/json-schema/draft-2019-09/core.txt)), а закреплённые фикстуры пиннят обычный указатель — `"instanceLocation": {"const": "/~0a~1b"}` — и `output-schema.json` объявляет для него `format: json-pointer`. Печатаем по фикстурам, и формы хранения выбор не задевает: локации лежат сегментами. Открытым остаётся только оформление — расхождение источников нужно зафиксировать как errata или compatibility policy, а не разрешать молча в коде.

* **Собственные structure-тесты вывода.** *(до P7)* Официальные fixtures покрывают только `basic`, поэтому `flag`, `detailed` и `verbose` подтверждать нечем. Нужны свои golden-тесты, покрывающие `$ref`, аннотации провалившихся веток, no-op keywords и схлопывание `detailed`.

* **Красная приёмка P1.** *(до P1)* Фаза включает `pattern`, чья группа `^\p{Letter}+$` объявлена красной до отложенного эксперимента, которому фаза не назначена. Либо первая ступень адаптации входит в P1, либо `pattern` выносится в отдельную фазу. (`patternProperties` относится к P2.)

* **Legacy-блок корневых метасхем.** *(до P6)* `definitions`, `dependencies`, `$recursiveAnchor` и `$recursiveRef` объявлены в `properties` самой корневой метасхемы Draft 2020-12 с `deprecated: true`, а `definitions` и `dependencies` — в корневой метасхеме Draft 2019-09; ни один из них не входит ни в одну vocabulary-метасхему. Классификация в своих границах верна, но это стоит сказать явно: метасхема разрешает их синтаксически, активными keywords они не становятся, поведенческая поддержка — отдельный compatibility profile вместе с `optional/dependencies-compatibility.json` обоих диалектов.

* **L1: разрешение URI и JSON Pointer.** *(до P3)* Не выбраны ни реализация, ни правила: нормализация, percent-decoding, порядок обработки fragment и JSON Pointer, пустой фрагмент, URN-базы, конфликты якорей и алиасы URI. Построение локаций сюда не входит — оно решено в «Результате вычисления и вывода» и относится к P0; открыт только разбор и разрешение.

* **Format-Assertion.** *(до P8)* Объявление поддержки этой vocabulary означает синтаксическую проверку всех стандартных format attributes, а не произвольного подмножества ([validation.txt:651](../references/json-schema/draft-2020-12/validation.txt)). Нужны выбранные алгоритмы и таблица фактически поддержанных форматов.

* **Ресурсные ограничения.** *(до слоя владельца)* Cycle guard защищает от циклов в схеме, но не от враждебного экземпляра: глубина вложенности растит стек, `uniqueItems` на `==` квадратичен, `patternProperties` даёт произведение ключей на паттерны. Нужна политика пределов — глубина схемы и экземпляра, размер замыкания, число output units, время regex, общий бюджет вычисления — либо явная запись, что это забота вызывающего. Отсутствие сетевой загрузки закрывает только один класс угроз.
