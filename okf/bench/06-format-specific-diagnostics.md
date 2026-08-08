---
type: Benchmark Report
title: Format-specific diagnostics и плоский Basic collector
description: Эффект отказа от общего diagnostic tree и гарантированного порядка sibling output units.
tags: [benchmark, performance, profiling, validation, output, basic, diagnostics, allocations]
---

# Format-specific diagnostics и плоский Basic collector

Отчёт фиксирует переход от единого diagnostic tree для всех структурных
форматов к разным стратегиям сбора:

* `flag` не собирает diagnostics;
* `basic` сразу накапливает плоские значимые errors или annotations;
* `detailed` и `verbose` сохраняют структурное дерево.

Одновременно порядок sibling units в `errors` и `annotations` исключён из
публичного контракта. JSON Schema output задаёт форму и содержание units, но не
семантический порядок результатов соседних keywords или свойств. Тесты теперь
ищут нужные units либо сравнивают sibling-коллекции как множества. Порядок
индексов JSON instance и массивы, являющиеся значениями annotations, от этого
решения не меняются.

# Состояние кода

Benchmark metadata показывает parent commit `396b6a6`. Фактически измерялся
незакоммиченный change set с format-specific collector, удалёнными runtime
сортировками и обновлёнными тестами. Поэтому результаты относятся к состоянию
рабочего дерева, описанному этим отчётом, а не к чистому `396b6a6`.

Изменение затронуло evaluator, handlers applicators/assertions/annotations,
output projector и тесты. Compile-time канонизация IR, сортировка для
`uniqueItems`, дедупликация annotations и нормализация coverage не удалялись:
они имеют самостоятельную семантику и не являются сортировкой output units.

# Что изменилось

Раньше каждый применённый schema node и keyword создавал unit, после чего
`valid_json_output` рекурсивно обходил дерево и разворачивал его в Basic.
Успешные silent assertions, промежуточные schema containers и applicator
containers создавались даже тогда, когда Basic неизбежно удалял их.

Теперь Basic работает иначе:

1. keyword без `error` или `annotation` передаёт наверх только diagnostics
   детей;
2. keyword со значимым detail добавляет один плоский unit;
3. schema node передаёт плоский список дальше, удаляя effective annotations при
   собственном провале;
4. reference не создаёт structural wrapper;
5. корневой schema unit создаётся один раз в конце evaluator;
6. output projector только сериализует непосредственных детей корня и больше
   не выполняет recursive flatten.

Отказ от порядка позволил не восстанавливать accumulator order после длинных
fold и не сортировать имена instance properties перед validation. Порядок
конкретного запуска обычно остаётся стабильным как следствие обхода BEAM maps и
compiled constraints, но это больше не совместимость API.

# Окружение и методика

* Intel Core i7-12700H, VM видит 4 schedulers;
* OTP 28, ERTS 16.4, Elixir 1.19.5, JIT включён;
* Draft 2020-12, заранее зарегистрированная и скомпилированная schema;
* публичная граница Benchee — горячий `valid_json:validate/3`;
* сценарий `array_100_last_error`: сто объектов, ошибка в последнем;
* 1 s warmup, 2 s latency, 1 s memory и 1 s reductions на точку;
* output suite выполнен три раза последовательно;
* latency ниже — медиана трёх Benchee `Average`, memory и reductions совпали
  во всех повторах.

Контрольная точка «до» взята из
[предыдущего отчёта](04-validation-optimization-progress.md), полученного тем же
runner и с теми же настройками. Абсолютная latency между сессиями чувствительна
к фоновой нагрузке; allocations и reductions детерминированы и являются
основным доказательством эффекта.

# Результат output suite

| Instance | Format | Average до | Average после | Allocated до | Allocated после | Reductions до | Reductions после |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| invalid | `flag` | 196.99 us | 214.28 us | 213 896 B | 213 872 B | 31 281 | 30 589 |
| invalid | `basic` | 377.00 us | 287.59 us | 510 824 B | 307 120 B | 66 795 | 40 694 |
| invalid | `detailed` | 354.99 us | 386.34 us | 491 960 B | 480 720 B | 52 187 | 51 660 |
| invalid | `verbose` | 5.045 ms | 4.927 ms | 1 201 832 B | 1 190 536 B | 161 826 | 160 580 |
| valid | `flag` | 198.54 us | 204.78 us | 214 704 B | 214 680 B | 31 389 | 30 674 |
| valid | `basic` | 907.55 us | 869.18 us | 634 280 B | 421 680 B | 81 489 | 53 331 |
| valid | `detailed` | 1.103 ms | 1.210 ms | 779 912 B | 769 136 B | 89 388 | 89 383 |
| valid | `verbose` | 4.925 ms | 4.844 ms | 1 201 024 B | 1 189 720 B | 162 447 | 160 346 |

Для целевого invalid Basic:

* Average снизился на 23.7%;
* allocations снизились на 39.9%, или на 203 704 B/op;
* reductions снизились на 39.1%, или на 26 101/op.

Для valid Basic payload содержит annotations от ста объектов, поэтому он всё
ещё обязан создавать и сериализовать много output units. Тем не менее
allocations уменьшились на 33.5%, reductions — на 34.6%, а Average — на 4.2%.

Изменение `flag`, `detailed` и `verbose` значительно меньше: они не переходили
на новую форму collector. У них на 0.9–2.3% уменьшились allocations и до 2.3%
reductions благодаря отказу от runtime order normalization. Колебания latency
от −2.3% до +9.7% не сопровождаются ростом внутренней работы и не позволяют
приписать структурным форматам устойчивую регрессию по этому замеру.

# Подтверждение профилем

Полный `tprof` для `array_100_last_error / invalid / basic`:

| Метрика | До | После | Изменение |
| --- | ---: | ---: | ---: |
| Traced calls/op | 32 252 | 21 466 | −33.4% |
| Heap words/op | 63 858 | 38 391 | −39.9% |
| Heap bytes/op | 510 864 B | 307 128 B | −39.9% |

Проектор теперь сериализует шесть оставшихся Basic units. В профиле у
`valid_json_output:unit/1` только 6 calls/op, а recursive `flatten` и `descend`
исчезли. Это подтверждает, что выигрыш получен удалением промежуточного дерева,
а не переносом той же работы в другой модуль.

Крупнейшие оставшиеся allocation-точки полного Basic:

| Функция | Calls/op | Words/op | Доля traced allocation |
| --- | ---: | ---: | ---: |
| `valid_json_eval:eval_at/6` | 401 | 9 419 | 24.5% |
| `valid_json_assert:report/4` | 703 | 4 218 | 11.0% |
| `valid_json_object:branch/5` | 300 | 2 700 | 7.0% |
| named-property comprehension | 400 | 2 400 | 6.3% |
| `valid_json_assert:holds/2` | 703 | 2 106 | 5.5% |
| `valid_json_object:check/3` | 100 | 2 100 | 5.5% |
| `valid_json_unit:build/6` | 205 | 1 845 | 4.8% |

Контрольный evaluator profile `invalid/flag` практически не изменился по heap:
17 464 calls/op и 26 361 words/op против 17 462 и 26 358 до изменения.
Снижение Benchee reductions с 31 281 до 30 589 отражает главным образом
удалённую сортировку имён properties; `tprof` не приписывает стоимость BIF
`lists:sort/1` функциям `valid_json*`.

# Положение относительно Jesse и JSONSchex

На том же большом invalid-массиве повторены соответствующие конкурентные
границы.

| Реализация | Граница | Average | Allocated | Reductions |
| --- | --- | ---: | ---: | ---: |
| Jesse | cold all-errors, Draft 6 | 517.03 us | 1 425 368 B | 82 645 |
| valid_json | cold Basic, Draft 6 | 763.16 us | 481 872 B | 65 833 |
| valid_json | hot Basic, Draft 6 | 269.62 us | 307 072 B | 40 560 |
| valid_json | hot Basic, Draft 2020-12 | 277.90 us | 307 088 B | 40 694 |
| JSONSchex | hot validation, Draft 2020-12 | 74.36 us | 132 168 B | 12 825 |

Эквивалентный cold↔cold срез остаётся в пользу Jesse по latency: 517.03 us
против 763.16 us у valid_json, то есть valid_json медленнее в 1.48x. При этом
его cold Basic выделяет в 2.96 раза меньше памяти и делает на 20.3% меньше
reductions. Эта граница включает приём raw schema, compilation и validation в
каждом вызове valid_json; Jesse на каждом вызове получает raw schema через
`validate_with_schema/3`, но отдельной стадии предварительной compilation не
предоставляет.

Отдельный Jesse cold↔valid_json hot срез показывает эффект заранее
скомпилированной и сохранённой schema: valid_json быстрее в 1.92x, выделяет в
4.64 раза меньше памяти и делает примерно в 2.04 раза меньше reductions. Это не
сравнение двух равнозначных hot validators: у использованной Jesse API нет
соответствующей границы с предварительно скомпилированным schema artifact.

JSONSchex остаётся быстрее, но hot invalid-разрыв сократился с 5.10x до 3.74x.
Разрыв по памяти уменьшился с 3.86x до 2.32x, по reductions — с 5.33x до
3.17x. Valid Flag на valid instance почти не изменился: 204.26 us у valid_json
против 83.90 us у JSONSchex, то есть 2.43x. Это ожидаемо: новая стратегия
нацелена на Basic, а не на verdict-only evaluator.

# Приёмка

После изменения выполнены оба обязательных набора:

* `./silent_rebar3 as ci eunit` — 7 038 tests, 0 failures;
* `./silent_rebar3 as ci conformance` — 5 327 tests, 0 failures.

Golden tests structural output рекурсивно нормализуют только sibling
`errors`/`annotations`. Значения annotations не переупорядочиваются.

# Воспроизведение

```sh
cd _checkouts/valid_json_bench

BENCH_SUITE=output BENCH_CASE=array_100_last_error BENCH_FORMAT=compact \
BENCH_WARMUP=1 BENCH_TIME=2 BENCH_MEMORY_TIME=1 \
BENCH_REDUCTION_TIME=1 mix run bench/compare.exs

PROFILE_CASE=array_100_last_error PROFILE_VALIDITY=invalid \
PROFILE_FORMAT=basic PROFILE_LAYER=full PROFILE_TYPE=all \
PROFILE_ITERATIONS=500 PROFILE_WARMUP=100 PROFILE_TOP=30 \
mix run bench/profile.exs

PROFILE_CASE=array_100_last_error PROFILE_VALIDITY=invalid \
PROFILE_FORMAT=flag PROFILE_LAYER=eval PROFILE_TYPE=all \
PROFILE_ITERATIONS=1000 PROFILE_WARMUP=200 \
mix run bench/profile.exs

BENCH_SUITE=jsonschex BENCH_CASE=array_100_last_error BENCH_FORMAT=compact \
BENCH_WARMUP=1 BENCH_TIME=2 BENCH_MEMORY_TIME=1 \
BENCH_REDUCTION_TIME=1 mix run bench/compare.exs

BENCH_SUITE=jesse BENCH_CASE=array_100_last_error BENCH_FORMAT=compact \
BENCH_WARMUP=1 BENCH_TIME=2 BENCH_MEMORY_TIME=1 \
BENCH_REDUCTION_TIME=1 mix run bench/compare.exs
```
