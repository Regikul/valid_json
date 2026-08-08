---
type: Benchmark Report
title: Сравнение с Jesse и JSONSchex после оптимизации evaluator
description: Текущее положение valid_json относительно Jesse и JSONSchex после сокращения allocations и reductions горячей валидации.
tags: [benchmark, performance, validation, jesse, jsonschex, cold, hot, trusted]
---

# Сравнение с Jesse и JSONSchex после оптимизации evaluator

Отчёт повторяет конкурентные срезы из
[исходного сравнения](00-validator-comparison.md) после серии оптимизаций,
зафиксированных в
[отчёте о прогрессе validate](04-validation-optimization-progress.md).

Краткий итог: hot `valid_json` в режиме `flag` теперь быстрее Jesse почти на
всём корпусе, а Basic быстрее Jesse all-errors на четырёх из шести корректно
сравнимых invalid-сценариев. JSONSchex остаётся быстрее во всех hot- и
cold-точках Draft 2020-12, но разрыв относительно исходного benchmark заметно
сократился.

# Окружение и методика

* Intel Core i7-12700H, VM видит 4 schedulers;
* OTP 28, ERTS 16.4, Elixir 1.19.5, JIT включён;
* `valid_json` — commit `396b6a6`;
* Jesse — commit `d06868f`;
* JSONSchex — commit `4ba3c8c`;
* полный корпус — семь сценариев, valid и invalid instance каждого;
* smoke-run: без отдельного warmup, по 1 s на latency, memory и reductions;
* Benchee не исключал outliers, parallel равен 1;
* входные JSON values были заранее декодированы в BEAM terms.

Сравниваются те же границы, что и раньше:

* Jesse/default против hot и default cold `valid_json` с output `flag`;
* Jesse/all-errors против hot и default cold `valid_json` с output `basic`;
* JSONSchex hot/cold против hot/cold `valid_json`: valid instance использует
  `flag`, invalid — `basic`;
* JSONSchex cold включает `JSONSchex.compile/1` и validation;
* default cold `valid_json:run_schema/3` включает meta-schema validation,
  compilation и validation.

Payload invalid-результатов не идентичен. Jesse и JSONSchex возвращают
собственные error terms, а valid_json строит стандартный JSON Schema Basic
output. Поэтому invalid-сравнение измеряет полезную end-to-end работу API, но
не является изолированным сравнением evaluator.

Как и в исходном benchmark, composition исключён из Jesse all-errors:
`{allowed_errors, infinity}` у Jesse меняет его verdict на этом сценарии.

# Jesse, Draft 6

## Горячий verdict

Hot `valid_json` Flag быстрее Jesse/default в 13 из 14 точек. В выигранных
точках ускорение составляет от 1.09 до 4.65 раза.

| Scenario | Instance | Jesse cold/default | valid_json hot/flag | Результат |
| --- | --- | ---: | ---: | --- |
| `array_10` | invalid | 45.38 μs | 18.92 μs | valid_json 2.40x |
| `array_10` | valid | 52.33 μs | 19.65 μs | valid_json 2.66x |
| `array_100_first_error` | invalid | 4.66 μs | 24.24 μs | Jesse 5.20x |
| `array_100_first_error` | valid | 495.26 μs | 200.31 μs | valid_json 2.47x |
| `array_100_last_error` | invalid | 467.25 μs | 198.66 μs | valid_json 2.35x |
| `array_100_last_error` | valid | 502.09 μs | 199.81 μs | valid_json 2.51x |
| `composition` | invalid | 7.57 μs | 4.66 μs | valid_json 1.62x |
| `composition` | valid | 21.51 μs | 8.17 μs | valid_json 2.63x |
| `nested_object` | invalid | 3.20 μs | 2.94 μs | паритет, valid_json 1.09x |
| `nested_object` | valid | 17.39 μs | 6.08 μs | valid_json 2.86x |
| `recursive_ref` | invalid | 499.10 μs | 107.48 μs | valid_json 4.64x |
| `recursive_ref` | valid | 505.00 μs | 108.54 μs | valid_json 4.65x |
| `scalar_string` | invalid | 2.51 μs | 0.61 μs | valid_json 4.14x |
| `scalar_string` | valid | 3.90 μs | 1.17 μs | valid_json 3.33x |

Единственный устойчивый проигрыш — ошибка в первом элементе массива из 100
значений. Jesse завершает работу сразу, тогда как valid_json до evaluator
проверяет `uniqueItems` и подготавливает array applications. Разница
`nested_object/invalid` в 1.09 раза слишком мала для уверенного вывода из
односекундного smoke-run и считается паритетом.

На representative-точках выигрыш сопровождается меньшей внутренней работой:

| Scenario | Реализация | Allocated | Reductions |
| --- | --- | ---: | ---: |
| array-100 last invalid | Jesse/default | 1 376 000 B | 76 627 |
| array-100 last invalid | valid_json hot/flag | 213 808 B | 31 302 |
| array-100 valid | Jesse/default | 1 423 416 B | 82 525 |
| array-100 valid | valid_json hot/flag | 214 616 B | 31 351 |
| nested invalid | Jesse/default | 8 040 B | 778 |
| nested invalid | valid_json hot/flag | 2 536 B | 412 |
| nested valid | Jesse/default | 42 592 B | 3 001 |
| nested valid | valid_json hot/flag | 5 480 B | 963 |

## Сбор ошибок

Hot Basic быстрее Jesse all-errors в четырёх из шести точек и уступает на
короткой строке и nested object.

| Scenario, invalid | Jesse cold/all-errors | valid_json hot/basic | Результат |
| --- | ---: | ---: | --- |
| `array_10` | 57.21 μs | 45.80 μs | valid_json 1.25x |
| `array_100_first_error` | 510.01 μs | 377.33 μs | valid_json 1.35x |
| `array_100_last_error` | 544.58 μs | 373.94 μs | valid_json 1.46x |
| `nested_object` | 18.97 μs | 56.76 μs | Jesse 2.99x |
| `recursive_ref` | 511.39 μs | 226.38 μs | valid_json 2.26x |
| `scalar_string` | 3.95 μs | 4.89 μs | Jesse 1.24x |

Несмотря на два проигрыша по latency, hot Basic выделяет меньше памяти и делает
меньше reductions во всех шести точках. Например, на поздней ошибке массива
это 510 840 B и 66 494 reductions против 1 425 368 B и 82 643 reductions у
Jesse. На recursive ref — 199 512 B и 24 103 против 985 856 B и 78 727.

## Холодный путь

Default cold valid_json проигрывает Jesse в 12 из 14 точек. Разброс велик,
потому что Jesse/default не имеет отдельной стадии предварительной compilation,
а valid_json выполняет meta-schema validation и строит compiled artifact на
каждом вызове.

На больших поздних обходах разница уже невелика: array-100 last valid_json
медленнее в 1.15–1.25 раза. На recursive-ref valid_json, наоборот, быстрее в
1.06–1.07 раза. На коротких и ранне завершающихся сценариях compilation
доминирует; крайняя точка — nested invalid с проигрышем примерно в 185 раз.

# JSONSchex, Draft 2020-12

## Горячий путь

JSONSchex быстрее во всех 14 точках. На valid data против `flag` текущий
диапазон — 1.27–4.24 раза; на invalid data против Basic — 4.99–42.41 раза.

| Scenario | Instance/output | JSONSchex hot | valid_json hot | Разрыв |
| --- | --- | ---: | ---: | ---: |
| `scalar_string` | valid/flag | 0.91 μs | 1.15 μs | 1.27x |
| `nested_object` | valid/flag | 2.37 μs | 6.07 μs | 2.56x |
| `array_100_last_error` | valid/flag | 79.71 μs | 199.95 μs | 2.51x |
| `recursive_ref` | valid/flag | 32.82 μs | 109.84 μs | 3.35x |
| `composition` | valid/flag | 1.92 μs | 8.12 μs | 4.24x |
| `array_100_first_error` | invalid/basic | 75.77 μs | 377.95 μs | 4.99x |
| `array_100_last_error` | invalid/basic | 74.71 μs | 381.16 μs | 5.10x |
| `recursive_ref` | invalid/basic | 33.28 μs | 221.32 μs | 6.65x |
| `nested_object` | invalid/basic | 2.58 μs | 54.61 μs | 21.14x |
| `composition` | invalid/basic | 2.08 μs | 88.19 μs | 42.41x |

JSONSchex также выделяет меньше памяти и выполняет меньше reductions во всех
hot-точках. Для массива из 100 элементов:

| Instance | Реализация | Allocated | Reductions |
| --- | --- | ---: | ---: |
| valid | JSONSchex hot | 134 648 B | 12 838 |
| valid | valid_json hot/flag | 214 664 B | 31 392 |
| invalid | JSONSchex hot | 132 168 B | 12 825 |
| invalid | valid_json hot/basic | 510 864 B | 68 365 |

## Холодный путь

Default cold valid_json медленнее JSONSchex во всех точках. Текущий диапазон —
6.42–63.25 раза.

| Scenario | Instance | JSONSchex cold | valid_json default cold | Разрыв |
| --- | --- | ---: | ---: | ---: |
| `array_100_last_error` | valid | 88.59 μs | 579.80 μs | 6.55x |
| `array_100_last_error` | invalid | 84.55 μs | 781.78 μs | 9.25x |
| `recursive_ref` | valid | 64.15 μs | 547.18 μs | 8.53x |
| `nested_object` | valid | 19.86 μs | 771.27 μs | 38.83x |
| `nested_object` | invalid | 20.39 μs | 909.64 μs | 44.61x |
| `composition` | invalid | 21.39 μs | 1.353 ms | 63.25x |

# Изменение относительно исходного benchmark

| Срез | Исходный диапазон | После output locations | Сейчас |
| --- | ---: | ---: | ---: |
| JSONSchex hot / valid_json hot Flag, valid | 1.7–6.0x | 1.69–5.83x | 1.27–4.24x |
| JSONSchex hot / valid_json hot Basic, invalid | 6.6–132x | 6.78–46.1x | 4.99–42.41x |
| JSONSchex cold / valid_json default cold | 15–113x | 9.7–71x | 6.42–63.25x |

На контрольном nested object:

* valid hot-разрыв сократился с 4.17x до 2.56x;
* invalid hot-разрыв сократился с 39.6x до 21.14x;
* default cold valid — примерно с 87x до 38.83x;
* default cold invalid — примерно с 94x до 44.61x.

Для Jesse исходный hot Flag выигрывал 12 из 14 точек, текущий — 13 из 14.
Главное качественное изменение произошло в диагностике: исходно Jesse
all-errors был быстрее hot Basic в 1.3–6.8 раза, тогда как сейчас valid_json
выигрывает четыре из шести точек.

# Trusted cold: дополнительный срез

После основного runner выполнен exploratory benchmark trusted cold на
`nested_object` и `array_100_last_error`. Он запускался через `mix run -e`, и
Benchee предупредил, что обе функции были evaluated, а не compiled. Поэтому
числа ниже пригодны для оценки направления и крупных разрывов, но не входят в
основные диапазоны отчёта.

| Конкурент | Scenario | Instance/output | Конкурент cold | valid_json trusted cold | Разрыв |
| --- | --- | --- | ---: | ---: | ---: |
| Jesse | array-100 last | invalid/flag | 492.85 μs | 366.22 μs | valid_json 1.35x |
| Jesse | array-100 | valid/flag | 516.92 μs | 369.63 μs | valid_json 1.40x |
| Jesse | array-100 last | invalid/basic | 531.29 μs | 554.52 μs | паритет |
| JSONSchex | array-100 last | valid/flag | 99.28 μs | 378.26 μs | JSONSchex 3.81x |
| JSONSchex | array-100 last | invalid/basic | 90.71 μs | 598.64 μs | JSONSchex 6.60x |
| JSONSchex | nested | valid/flag | 27.20 μs | 311.76 μs | JSONSchex 11.46x |
| JSONSchex | nested | invalid/basic | 27.00 μs | 385.51 μs | JSONSchex 14.28x |

Trusted снимает meta-schema validation и существенно приближает cold-path к
конкурентам, но не устраняет стоимость compilation. На больших Draft 6
массивах этого уже достаточно для паритета или выигрыша у Jesse. JSONSchex
остаётся быстрее trusted cold на representative Draft 2020-12 сценариях.

# Выводы

Относительно Jesse горячая валидация больше не является общей проблемой:
valid_json лидирует по verdict на всём корпусе, кроме специально ранней ошибки,
и чаще выигрывает при сборе ошибок. Остаются два локальных случая — короткий
scalar и nested Basic — и отдельная стоимость default cold compilation.

Относительно JSONSchex ближайшая точка — короткий valid Flag с разрывом 1.27x.
На больших valid-массивах разрыв около 2.5x, на invalid-массивах с Basic —
около 5x. Наиболее тяжёлые hot-случаи — nested и composition diagnostics, где
доминируют построение стандартного output и обработка applicators.

Следовательно, локальные оптимизации evaluator продолжают приносить пользу,
но для паритета с JSONSchex нужны три отдельные линии работы:

1. hot verdict-only evaluator для `flag`;
2. compilation и публикация артефакта для trusted cold;
3. стоимость построения стандартного Basic output на invalid data.

# Воспроизведение

```sh
cd _checkouts/valid_json_bench

BENCH_SUITE=jesse BENCH_FORMAT=compact BENCH_WARMUP=0 BENCH_TIME=1 \
BENCH_MEMORY_TIME=1 BENCH_REDUCTION_TIME=1 mix run bench/compare.exs

BENCH_SUITE=jsonschex BENCH_FORMAT=compact BENCH_WARMUP=0 BENCH_TIME=1 \
BENCH_MEMORY_TIME=1 BENCH_REDUCTION_TIME=1 mix run bench/compare.exs
```
