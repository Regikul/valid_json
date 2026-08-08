---
type: Benchmark Report
title: Результаты оптимизации output locations
description: Повторный benchmark valid_json после ленивого построения absoluteKeywordLocation и fast paths сериализации locations.
tags: [benchmark, performance, profiling, validation, output, locations]
---

# Результаты оптимизации output locations

Этот отчёт повторяет сравнения из [первого benchmark](00-validator-comparison.md),
[замера trust_schema](01-trust-schema.md) и
[профиля validate](02-validate-profile.md) после устранения главного hotspot
структурных output.

В commit `c000a09` output unit перестал разбирать compiled JSON Pointer обратно
в сегменты. Вместо готовой `absoluteKeywordLocation` evaluator сохраняет адрес
schema node, а `basic` и `detailed` материализуют URI только после фильтрации
diagnostic tree. Оставшиеся JSON Pointer и fragment paths получили fast path:
обычный fragment-safe ASCII binary используется без промежуточного копирования.

Публичный output и его external term size не изменились. Изменились только
внутренняя работа и её стоимость.

# Окружение и методика

* Intel Core i7-12700H, VM видит 4 schedulers;
* OTP 28, ERTS 16.4, Elixir 1.19.5, JIT включён;
* `valid_json` — commit `c000a09`;
* Jesse — commit `d06868f`;
* JSONSchex — commit `4ba3c8c`.

Контрольный `nested_object` использовал одну секунду warmup, три секунды
измерения latency, одну секунду memory и одну секунду reductions на точку.
Полный корпус из семи сценариев использовал по одной секунде для каждого из
трёх измерений без отдельного warmup; его latency нужны для диапазонов, а не
для точного сравнения близких результатов.

Перед каждым сравнительным прогоном benchmark выполнял self-check одинакового
valid/invalid verdict у всех реализаций и всех четырёх output formats
`valid_json`. Входы оставались заранее декодированными BEAM terms.

Дополнительно повторены `tprof`-сценарии полного публичного `validate/3`.
`call_memory` считает process-heap words и нужен для атрибуции; абсолютные
latency, allocations и reductions ниже взяты из Benchee.

# Эффект на output formats

Таблица сравнивает новый контрольный прогон с результатами до оптимизации из
`00-validator-comparison.md`. Значения `flag` приведены как контроль: этот путь
не строит units и не должен был измениться.

| Instance | Format | Average до | Average после | Allocated до | Allocated после | Reductions до | Reductions после |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| valid | `flag` | 9.82 μs | 10.54 μs | 17 608 B | 17 608 B | 2 036 | 2 036 |
| valid | `basic` | 86.00 μs | 26.23 μs | 63 536 B | 26 232 B | 6 326 | 3 071 |
| valid | `detailed` | 88.00 μs | 32.22 μs | 68 816 B | 29 392 B | 6 648 | 3 215 |
| valid | `verbose` | 177.04 μs | 115.78 μs | 153 632 B | 40 800 B | 14 660 | 5 175 |
| invalid | `flag` | 4.35 μs | 4.95 μs | 6 800 B | 6 800 B | 793 | 793 |
| invalid | `basic` | 125.50 μs | 65.05 μs | 107 880 B | 36 272 B | 10 346 | 4 184 |
| invalid | `detailed` | 129.24 μs | 65.60 μs | 107 848 B | 37 840 B | 10 146 | 4 159 |
| invalid | `verbose` | 195.34 μs | 127.29 μs | 166 896 B | 46 728 B | 15 854 | 5 555 |

Изменение структурных форматов:

| Instance | Format | Latency | Allocated | Reductions |
| --- | --- | ---: | ---: | ---: |
| valid | `basic` | −69.5% | −58.7% | −51.5% |
| valid | `detailed` | −63.4% | −57.3% | −51.6% |
| valid | `verbose` | −34.6% | −73.4% | −64.7% |
| invalid | `basic` | −48.2% | −66.4% | −59.6% |
| invalid | `detailed` | −49.2% | −64.9% | −59.0% |
| invalid | `verbose` | −34.8% | −72.0% | −65.0% |

Allocations и reductions `flag` совпали с исходным снимком точно. Разница его
Average находится в обычном разбросе короткого микротеста и не имеет
структурной причины.

`verbose` экономит больше памяти, но ускоряется слабее Basic/Detailed. Он обязан
опубликовать почти всё diagnostic tree и потому не получает выигрыша от
pruning. Например, output массива из 100 элементов остаётся термом размером
около 272–273 KB.

# Подтверждение через tprof

Оба контрольных профиля повторены на commit `c000a09` с прежними параметрами.

| Scenario | Метрика | До | После | Изменение |
| --- | --- | ---: | ---: | ---: |
| nested invalid Basic | calls/op | 4 420 | 1 742 | −60.6% |
| nested invalid Basic | heap words/op | 14 700 | 5 190 | −64.7% |
| nested invalid Basic | heap bytes/op | 117 600 | 41 521 | −64.7% |
| array-100, last invalid, Basic | calls/op | 44 984 | 34 658 | −23.0% |
| array-100, last invalid, Basic | heap words/op | 258 403 | 120 481 | −53.4% |
| array-100, last invalid, Basic | heap bytes/op | 2 067 221 | 963 848 | −53.4% |

`valid_json_location:segments/1` и `unescape/1`, ранее выделявшие около половины
памяти большого Basic-сценария, исчезли из validation profile. В nested
сценарии крупнейшей одиночной позицией теперь стал ETS lookup compiled artifact:
649 words, или 12.5% полного traced allocation.

# Сравнение с Jesse, Draft 6

Verdict-oriented `flag` ожидаемо почти не изменился:

| Instance | Реализация | Average | Allocated | Reductions |
| --- | --- | ---: | ---: | ---: |
| valid | `valid_json` hot/flag | 9.88 μs | 17 568 B | 2 053 |
| valid | Jesse cold/default | 18.69 μs | 42 592 B | 3 001 |
| valid | `valid_json` cold/flag | 589.82 μs | 393 728 B | 47 007 |
| invalid | Jesse cold/default | 3.68 μs | 8 040 B | 778 |
| invalid | `valid_json` hot/flag | 4.41 μs | 6 760 B | 859 |
| invalid | `valid_json` cold/flag | 578.20 μs | 382 920 B | 45 834 |

На valid data hot `valid_json` быстрее Jesse в 1.89 раза. На раннем invalid
Jesse быстрее в 1.20 раза. Полный корпус сохраняет прежнюю картину: hot Flag
выигрывает 12 из 14 valid/invalid точек; исключения — nested early failure и
ошибка в первом элементе массива из 100 значений.

Сбор всех ошибок изменился существенно:

| Реализация | Average | Allocated | Reductions |
| --- | ---: | ---: | ---: |
| Jesse cold/all-errors | 20.38 μs | 47 176 B | 3 300 |
| `valid_json` hot/basic | 62.04 μs | 36 280 B | 4 217 |
| `valid_json` cold/trusted basic | 378.64 μs | 237 480 B | 33 275 |
| `valid_json` cold/default basic | 711.77 μs | 412 320 B | 49 152 |

Hot Basic теперь медленнее Jesse в 3.04 раза вместо прежних примерно 6.6–7.2,
но выделяет на 23% меньше памяти. На массивах из 100 объектов обе реализации
практически сравнялись по latency; на recursive-ref invalid `valid_json` стал
примерно в 1.7 раза быстрее Jesse all-errors. На nested object и короткой
строке Jesse по-прежнему быстрее.

# Сравнение с JSONSchex, Draft 2020-12

| Instance | Реализация | Average | Allocated | Reductions |
| --- | --- | ---: | ---: | ---: |
| valid | JSONSchex cold | 21.01 μs | 20 840 B | 4 058 |
| valid | `valid_json` cold/trusted | 302.31 μs | 222 016 B | 30 643 |
| valid | `valid_json` cold/default | 998.30 μs | 695 824 B | 75 055 |
| valid | JSONSchex hot | 2.63 μs | 3 000 B | 345 |
| valid | `valid_json` hot/flag | 9.83 μs | 17 568 B | 2 038 |
| invalid | JSONSchex cold | 21.04 μs | 22 592 B | 4 205 |
| invalid | `valid_json` cold/trusted | 401.85 μs | 240 776 B | 32 757 |
| invalid | `valid_json` cold/default | 1.044 ms | 714 584 B | 77 165 |
| invalid | JSONSchex hot | 2.81 μs | 4 752 B | 616 |
| invalid | `valid_json` hot/basic | 62.29 μs | 36 232 B | 4 187 |

На valid hot-path соотношение почти не изменилось: JSONSchex быстрее в 3.74
раза. На invalid nested Basic разрыв сократился с 39.6 до 22.2 раза.

На полном корпусе JSONSchex быстрее hot `valid_json`:

* в `flag` на valid data — в 1.69–5.83 раза, практически прежний диапазон;
* на invalid data против Basic — в 6.78–46.1 раза вместо прежних 6.6–132;
* в cold-режиме — примерно в 9.7–71 раз вместо прежних 15–113.

Оптимизация не устраняет различие payload: JSONSchex возвращает собственный
список ошибок, а `valid_json` — стандартный JSON Schema Basic output.

# Что произошло с trust_schema

Default cold-path ускорился вместе с output, потому что meta-schema validation
сама строит структурный validation result. Поэтому относительный выигрыш от
`trust_schema` стал меньше, хотя trusted остаётся заметно дешевле.

| Dialect и output | Instance | Default / trusted latency | Default / trusted allocation | Default / trusted reductions |
| --- | --- | ---: | ---: | ---: |
| Draft 6, `flag` | valid | 1.97× | 1.80× | 1.51× |
| Draft 6, `flag` | invalid | 1.88× | 1.85× | 1.53× |
| Draft 6, `basic` | invalid | 1.87× | 1.74× | 1.48× |
| Draft 2020-12, `flag` | valid | 3.11× | 3.13× | 2.45× |
| Draft 2020-12, `basic` | invalid | 2.58× | 2.97× | 2.36× |

В полном корпусе ускорение trusted составляет:

* Draft 6 `flag` — 1.45–5.65 раза;
* Draft 6 invalid `basic` — 1.34–4.19 раза;
* Draft 2020-12 mixed `flag`/`basic` — 1.52–5.08 раза.

Trusted по-прежнему задаёт более чистую границу для профилирования compiler и
нужен доверенным store. Снижение коэффициента не означает его регрессию:
подешевела работа default-path, которую trusted пропускает.

# Новая граница оптимизации

Locations больше не являются главным источником allocations. В
`array-100 / last invalid / basic` верх профиля теперь занимают:

* `valid_json_eval:conjoin/2` — 20 142 words;
* `valid_json_evaluated:neutral/0` — 12 896 words;
* `valid_json_evaluated:normalize/2` — 12 645 words;
* `valid_json_unit:build/6` — 11 745 words;
* `valid_json_eval:eval/3` — 9 419 words.

Следующая работа поэтому должна идти не в URI/JSON Pointer helpers, а в:

1. линейное накопление diagnostic units вместо повторного `LeftUnits ++ RightUnits`;
2. дешёвое neutral coverage и verdict-only path там, где coverage не требуется;
3. потоковый обход массивов без предварительного списка applications;
4. уменьшение стоимости полного diagnostic tree для `verbose`, где pruning
   принципиально невозможен.

# Проверка и воспроизведение

После benchmark выполнены:

* `./silent_rebar3 as ci eunit`: 7027 tests, 0 failures;
* `./silent_rebar3 as ci conformance`: 5327 tests, 0 failures.

Основной runner и профилировщик находятся в `bench/`.

```sh
cd bench

BENCH_FORMAT=compact BENCH_WARMUP=0 BENCH_TIME=1 \
BENCH_MEMORY_TIME=1 BENCH_REDUCTION_TIME=1 \
mix run --no-compile bench/compare.exs

BENCH_SUITE=output BENCH_CASE=nested_object BENCH_FORMAT=compact \
BENCH_WARMUP=1 BENCH_TIME=3 BENCH_MEMORY_TIME=1 BENCH_REDUCTION_TIME=1 \
mix run --no-compile bench/compare.exs

PROFILE_CASE=nested_object PROFILE_VALIDITY=invalid PROFILE_FORMAT=basic \
PROFILE_LAYER=full PROFILE_TYPE=all PROFILE_ITERATIONS=1000 \
mix run --no-compile bench/profile.exs
```

Trusted/default измерялся теми же Benchee options и прямыми вызовами
`valid_json:run_schema/3`, отличавшимися только наличием
`{trust_schema, true}`.
