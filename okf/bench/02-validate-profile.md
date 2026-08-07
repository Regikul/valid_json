---
type: Benchmark Report
title: Профиль горячей валидации
description: Распределение вызовов, heap allocations и времени внутри valid_json:validate/3 на Draft 2020-12.
tags: [benchmark, performance, profiling, validation, output, allocations]
---

# Профиль горячей валидации

Этот отчёт локализует расходы горячего `valid_json:validate/3`. Schema во всех
измерениях заранее зарегистрирована и скомпилирована: compilation,
meta-schema validation, запуск applications, загрузка модулей и warmup в
профиль не входят.

Это диагностический локальный снимок, а не переносимая характеристика любого
оборудования. Абсолютные latency и allocations следует проверять Benchee на
целевой машине; `tprof` здесь нужен для атрибуции расходов функциям.

# Окружение и методика

* Intel Core i7-12700H, VM видит 4 schedulers;
* OTP 28, ERTS 16.4, Elixir 1.19.5, JIT включён;
* `valid_json` — commit `d7961f9`;
* dialect — Draft 2020-12;
* schema lookup выполняется по каноническому URI одним успешным чтением ETS;
* профилировались только загруженные модули `valid_json*`;
* `call_count`, `call_memory` и `call_time` снимались отдельными прогонами.

Профилировщик находится в локальном benchmark checkout:
`_checkouts/valid_json_bench/bench/profile.exs`. Он умеет измерять пять
границ одного пути:

| Layer | Измеряемая работа |
| --- | --- |
| `full` | публичный `valid_json:validate/3`, включая lookup артефакта |
| `lookup` | только lookup артефакта в store |
| `core` | validation с уже полученным compiled artifact |
| `eval` | evaluator без output projection |
| `output` | проекция заранее вычисленного `#eval_result{}` |

`call_memory` считает выделенные на process heap машинные слова. В этой VM
слово занимает 8 байт. Учёт отличается от Benchee, а instrumentation заметно
замедляет вызовы, поэтому `call_time` используется только для ранжирования
функций, не как абсолютная latency.

# Сводный результат

| Scenario | Output | Calls/op | Heap words/op | Heap bytes/op |
| --- | --- | ---: | ---: | ---: |
| nested object, valid | `flag` | 618 | 2 842 | 22 736 |
| array 100, ошибка в первом элементе | `flag` | 302 | 3 804 | 30 432 |
| array 100, ошибка в последнем элементе | `flag` | 23 062 | 86 669 | 693 352 |
| nested object, invalid | `basic` | 4 420 | 14 700 | 117 600 |
| array 100, ошибка в последнем элементе | `basic` | 44 984 | 258 403 | 2 067 221 |
| recursive tree, valid | `flag` | 8 065 | 33 124 | 264 992 |
| composition, invalid | `basic` | 6 708 | 25 556 | 204 448 |

Значения хорошо воспроизводятся как атрибуция, но включают instrumentation
`tprof` и не заменяют абсолютные числа основного Benchee benchmark.

# Декомпозиция публичного пути

Для `nested object / invalid / basic` один и тот же вызов измерен на четырёх
границах:

| Layer | Heap words/op | Heap bytes/op |
| --- | ---: | ---: |
| artifact lookup | 649 | 5 192 |
| evaluator | 7 040 | 56 320 |
| output projection | 7 008 | 56 064 |
| полный `validate/3` | 14 700 | 117 600 |

Компоненты объясняют полный путь с расхождением всего в три слова. Значит,
Basic почти поровну расходует память на построение внутреннего diagnostic tree
и его преобразование в публичный output. Lookup заметен, но в этом сценарии не
доминирует.

Для более дешёвого `nested object / valid / flag` lookup занимает 649 из 2 842
слов, то есть 22,8%. Копирование compiled artifact из ETS поэтому существенно
именно на коротких verdict-only вызовах.

# Главный hotspot структурных output: locations

В `nested object / invalid / basic` evaluator выделяет:

* `valid_json_location:unescape/1` — 2 542 слова на вызов;
* `valid_json_location:segments/1` — 956 слов;
* list comprehension внутри `segments/1` — 164 слова.

Только эти три позиции дают 52% allocations evaluator. Для каждого output unit
двоичный JSON Pointer из compiled IR разбирается обратно в сегменты, в том
числе для units, которые Basic позднее отбрасывает.

На `array 100 / last invalid / basic` строится 1 305 units. Разбор compiled
pointers расходует около половины всего профиля размером 2,07 MB:

* `unescape/1` — 91 889 слов;
* `segments/1` — 31 140 слов;
* его list comprehension — 5 800 слов.

После этого projection снова обходит location: выполняет JSON Pointer escaping
для keyword и instance locations и percent-encoding absolute locations. На
nested Basic helpers модуля `valid_json_location` дают около 90% self time и
85% allocations самой projection.

Первое направление оптимизации — хранить absolute location в output unit
лениво и материализовать её после фильтрации Basic/Detailed. Желательно
составлять URI непосредственно из resource URI, уже escaped compiled pointer и
keyword tail, не выполняя цикл decode → segments → encode. Для оставшихся
units нужен быстрый путь для сегментов без `~`, `/` и символов, требующих
percent-encoding.

# `flag` платит за невостребованное coverage

На `nested object / valid / flag` за один вызов происходят:

* 43 вызова `valid_json_evaluated:neutral/0`;
* 37 вызовов `valid_json_eval:conjoin/2`;
* 37 вызовов `valid_json_evaluated:merge/2`;
* 34 вызова `valid_json_evaluated:normalize/2`.

Эти четыре функции выделяют 1 057 из 2 842 слов, или 37,2%. Вместе с
`merge_items/2` они занимают около трети измеренного self time.

На `array 100 / last invalid / flag` те же четыре функции выделяют 40 776 слов,
или 47,0% полного профиля. Evaluator многократно создаёт и объединяет maps с
пустыми sets даже там, где текущая ветвь не обязана возвращать coverage.

Первый безопасный шаг — дешёвое представление neutral coverage и fast clauses
для `conjoin`. Более крупное улучшение — verdict-only путь для `flag`, когда
`Context#eval_context.coverage` равен `false`, с сохранением полноценного
coverage только под действительно ожидающим его `unevaluated*`.

# Подготовка массива мешает раннему short-circuit

В `array 100 / first invalid / flag` реально вычисляется schema только первого
элемента, но `valid_json_array:elements/4` заранее материализует applications
для всего массива:

* comprehension вызывается 101 раз и выделяет 900 слов;
* сам `elements/4` выделяет ещё 700 слов.

`uniqueItems` также обязан прочитать весь массив и выделяет 1 096 слов. Вместе
эти операции дают 70,9% allocations раннего провала. Applications стоит
создавать по мере обхода instance, без промежуточных `seq`, `zip` и полного
списка.

Изменение порядка `uniqueItems` и `items` требует отдельного доказательства:
conjunction не зависит от порядка только на обычном boolean-результате, тогда
как evaluator также учитывает coverage и `no_progress`.

# Накопление diagnostic units

В `array 100 / last invalid / basic` функция
`valid_json_eval:conjoin/2` выделяет 20 142 слова против 8 388 в `flag`. Текущее
`LeftUnits ++ RightUnits` внутри fold копирует уже накопленный левый префикс и
может давать сверхлинейную составляющую.

Перед изменением представления нужен отдельный size sweep на 10, 100 и 1 000
элементов. Если кривая подтвердится, варианты — обратное накопление либо
небольшое дерево/difference list с единственной финальной материализацией.

# Вторичные кандидаты

## Store lookup

Compiled artifact nested schema стоит 649 слов, или 5 192 байта, на каждое
копирование из ETS. Устранение копии потребует другой границы публикации,
например аккуратного индекса через `persistent_term`, и затронет обновление,
удаление и восстановление store. Поэтому этот шаг имеет смысл после локальных
оптимизаций evaluator.

## Cycle guard

На `recursive tree / valid / flag` функция `valid_json_eval:eval/3` выделяет
5 709 слов, или 17,2% профиля. Сюда атрибутируется работа path-local guard на
`sets`. Coverage family всё ещё дороже — около 42%.

После упрощения Flag coverage guard следует измерить снова. Возможные
направления — более дешёвое path-local представление либо отказ от guard на
переходах, которые заведомо не могут участвовать в no-progress cycle.

# Приоритет оптимизаций

1. Ленивое и прямое построение absolute locations для Basic и Detailed.
2. Дешёвое neutral coverage и verdict-only путь `flag`, когда coverage не
   требуется.
3. Потоковый обход массивов без предварительного списка applications.
4. Линейное накопление diagnostic units после подтверждающего size sweep.
5. Повторное профилирование cycle guard и публикации артефактов через ETS после
   устранения локальных расходов.

Каждая оптимизация должна пройти EUnit и conformance, а затем сравниваться с
исходным состоянием одновременно через этот profiler и Benchee. Уменьшение
доли функции в `tprof` само по себе не доказывает end-to-end ускорение.

# Воспроизведение

```sh
cd _checkouts/valid_json_bench

PROFILE_CASE=nested_object PROFILE_VALIDITY=valid PROFILE_FORMAT=flag \
PROFILE_LAYER=full PROFILE_TYPE=all PROFILE_ITERATIONS=1000 \
mix run --no-compile bench/profile.exs

PROFILE_CASE=nested_object PROFILE_VALIDITY=invalid PROFILE_FORMAT=basic \
PROFILE_LAYER=eval PROFILE_TYPE=all PROFILE_ITERATIONS=1000 \
mix run --no-compile bench/profile.exs

PROFILE_CASE=nested_object PROFILE_VALIDITY=invalid PROFILE_FORMAT=basic \
PROFILE_LAYER=output PROFILE_TYPE=all PROFILE_ITERATIONS=1000 \
mix run --no-compile bench/profile.exs

PROFILE_CASE=array_100_last_error PROFILE_VALIDITY=invalid \
PROFILE_FORMAT=basic PROFILE_LAYER=full PROFILE_TYPE=all \
PROFILE_ITERATIONS=50 mix run --no-compile bench/profile.exs
```
