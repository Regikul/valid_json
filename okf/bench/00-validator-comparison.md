---
type: Benchmark Report
title: Сравнение производительности valid_json, Jesse и JSONSchex
description: Методика и локальные результаты cold/hot-валидации для Draft 6 и Draft 2020-12, а также стоимость стандартных output formats valid_json.
tags: [benchmark, performance, json-schema, jesse, jsonschex, output]
---

# Сравнение производительности валидаторов

Этот отчёт фиксирует локальный снимок производительности `valid_json`, Jesse и
JSONSchex. Это не переносимая на любое оборудование характеристика: перед
расчётом ёмкости результаты нужно повторить на целевой машине и версии VM.

Исходный benchmark находится в локальном, игнорируемом Git каталоге
`_checkouts/valid_json_bench`. Он использует соседние checkout'ы библиотек, не
изменяя их исходный код.

# Предмет сравнения

Сравнение попарное, потому что интересующие реализации поддерживают разные
dialects:

| Dialect | Сравнение | Вызовы внутри измеряемой функции |
| --- | --- | --- |
| Draft 6 | cold/cold | `jesse:validate_with_schema/3` и `valid_json:run_schema/3` |
| Draft 6 | cold/hot | `jesse:validate_with_schema/3` и заранее зарегистрированная схема через `valid_json:validate/3` |
| Draft 2020-12 | cold/cold | `JSONSchex.compile/1` + `JSONSchex.validate/2` и `valid_json:run_schema/3` |
| Draft 2020-12 | hot/hot | `JSONSchex.validate/2` с готовым артефактом и `valid_json:validate/3` с зарегистрированной схемой |

Jesse не компилирует schema. Его `add_schema/2` только помещает исходный term в
хранилище, поэтому этот путь не измеряется: он добавил бы lookup, но не сделал
бы исполнение горячим. В обоих сравнениях Jesse получает исходную schema через
`validate_with_schema/3`.

Под cold здесь понимается холодная schema в уже запущенной VM. Запуск VM и
applications, загрузка модулей, первичная публикация встроенных meta-schemas и
JSON decoding не входят в измеряемую функцию. На входе у всех валидаторов уже
находятся одинаковые BEAM terms.

Cold-строка показывает end-to-end стоимость подготовки schema и валидации, но
не одинаковую работу. `valid_json:run_schema/3` в том числе проверяет schema
соответствующей meta-schema и компилирует её. JSONSchex выполняет собственный
контракт `compile/1`, а Jesse schema не компилирует вовсе.

# Соответствие результатов

На valid data Jesse и JSONSchex сравниваются с `valid_json` в режиме `flag`.
Для invalid data есть два среза:

* Jesse по умолчанию останавливается на первой ошибке; ближайший режим
  `valid_json` — `flag`. Payload неодинаков: Jesse всё равно создаёт одну
  внутреннюю диагностическую ошибку, а `flag` возвращает только verdict;
* Jesse с `{allowed_errors, infinity}` сравнивается с `valid_json` в режиме
  `basic`. Оба собирают плоское множество ошибок, но Jesse возвращает внутренние
  tuples, а `valid_json` строит стандартный Basic output;
* JSONSchex не предоставляет отдельного fail-fast API и собирает список
  ошибок. Поэтому на invalid data он сравнивается с `valid_json` в режиме
  `basic`. Его список внутренних error structs также не равен стандартному
  Basic output по форме и цене построения.

Перед каждым измерением self-check выполняет все участвующие реализации и
требует одинакового valid/invalid verdict. Для `valid_json` он проверяет все
четыре формата: `flag`, `basic`, `detailed`, `verbose`.

# Сценарии

Draft 6 и Draft 2020-12 используют одинаковые по смыслу schema с
соответствующим `$schema` и отдельным `$id`. В снимок входят семь сценариев:

* строка с `minLength`, `maxLength` и `pattern`;
* вложенный объект с `properties`, `required`, `additionalProperties`, массивом
  и простыми assertions;
* массив из 10 объектов;
* массив из 100 объектов с ошибкой в первом элементе;
* массив из 100 объектов с ошибкой в последнем элементе;
* композиция с `allOf`, `oneOf`, `not` и `contains`;
* рекурсивное дерево с локальной ссылкой `$ref: "#"`.

У каждого сценария есть valid и invalid instance. Раздельные ошибки в первом и
последнем элементах большого массива показывают влияние short-circuit.

# Окружение снимка

* Intel Core i7-12700H, VM видит 4 schedulers;
* OTP 28, ERTS 16.4, Elixir 1.19.5, JIT включён;
* `valid_json` — commit `c598350`;
* Jesse — commit `d06868f`;
* JSONSchex — commit `4ba3c8c`.

Полный smoke-run измерял каждую точку одну секунду. Контрольный прогон ниже
использовал одну секунду warmup, три секунды измерения времени, одну секунду
измерения памяти и одну секунду измерения reductions на точку. Allocated —
выделенная за вызов память по данным Benchee, а не пиковый resident set.

# Контрольный сценарий: вложенный объект

## Draft 6, verdict-oriented

| Instance | Реализация | Average | Allocated | Reductions |
| --- | --- | ---: | ---: | ---: |
| valid | Jesse cold/default | 17.37 μs | 42 592 B | 3 001 |
| valid | `valid_json` hot/flag | 9.19 μs | 17 568 B | 2 053 |
| valid | `valid_json` cold/flag | 1.111 ms | 638 008 B | 71 445 |
| invalid | Jesse cold/default | 3.35 μs | 8 040 B | 778 |
| invalid | `valid_json` hot/flag | 4.05 μs | 6 760 B | 859 |
| invalid | `valid_json` cold/flag | 1.110 ms | 627 200 B | 70 272 |

На valid object горячий `valid_json` оказался в 1.89 раза быстрее Jesse, при
меньших allocations и reductions. На этом invalid object Jesse остановился
раньше и оказался в 1.21 раза быстрее. Холодный `valid_json` на valid object
примерно в 64 раза медленнее Jesse из-за проверки и компиляции schema на каждом
вызове.

## Draft 6, сбор всех ошибок

| Instance | Реализация | Average | Allocated | Reductions |
| --- | --- | ---: | ---: | ---: |
| invalid | Jesse cold/all-errors | 18.83 μs | 47 176 B | 3 300 |
| invalid | `valid_json` hot/basic | 124.22 μs | 107 840 B | 10 514 |
| invalid | `valid_json` cold/basic | 1.199 ms | 728 256 B | 79 731 |

На этой schema Jesse all-errors в 6.6 раза быстрее горячего `valid_json` Basic.
Кроме собственно validation это сравнение включает различную цену результата:
список внутренних tuples Jesse против стандартного JSON Schema output.

## Draft 2020-12

| Instance | Реализация | Average | Allocated | Reductions |
| --- | --- | ---: | ---: | ---: |
| valid | JSONSchex cold | 19.79 μs | 20 840 B | 4 058 |
| valid | `valid_json` cold/flag | 1.720 ms | 1 039 624 B | 104 427 |
| valid | JSONSchex hot | 2.51 μs | 3 000 B | 345 |
| valid | `valid_json` hot/flag | 10.46 μs | 17 568 B | 2 038 |
| invalid | JSONSchex cold | 19.82 μs | 22 592 B | 4 205 |
| invalid | `valid_json` cold/basic | 1.870 ms | 1 129 872 B | 112 606 |
| invalid | JSONSchex hot | 3.06 μs | 4 752 B | 616 |
| invalid | `valid_json` hot/basic | 121.21 μs | 107 840 B | 10 348 |

На valid object JSONSchex оказался в 4.17 раза быстрее в hot-режиме. На invalid
object разница составила 39.6 раза, но эта строка включает различную работу по
построению диагностики. В cold-режиме JSONSchex оказался примерно в 87–94 раза
быстрее; `valid_json:run_schema/3` выполняет meta-schema validation и полную
компиляцию.

# Стоимость output formats valid_json

Форматы измерены на заранее зарегистрированной Draft 2020-12 schema. External
output size — размер только возвращаемого output value в Erlang external term
format; он отделён от всех allocations внутри вызова.

| Instance | Format | Average | Allocated | Reductions | External output size |
| --- | --- | ---: | ---: | ---: | ---: |
| valid | `flag` | 9.82 μs | 17 608 B | 2 036 | 22 B |
| valid | `basic` | 86.00 μs | 63 536 B | 6 326 | 1 375 B |
| valid | `detailed` | 88.00 μs | 68 816 B | 6 648 | 1 618 B |
| valid | `verbose` | 177.04 μs | 153 632 B | 14 660 | 7 315 B |
| invalid | `flag` | 4.35 μs | 6 800 B | 793 | 23 B |
| invalid | `basic` | 125.50 μs | 107 880 B | 10 346 | 4 220 B |
| invalid | `detailed` | 129.24 μs | 107 848 B | 10 146 | 3 959 B |
| invalid | `verbose` | 195.34 μs | 166 896 B | 15 854 | 8 356 B |

На этой schema `basic` и `detailed` стоят почти одинаково. Относительно
`flag` они медленнее примерно в 8.8–9.0 раза на valid data и в 28.9–29.7 раза
на invalid data. `verbose` медленнее примерно в 18 и 45 раз соответственно.

Разница зависит от schema, instance и позиции ошибки. Наибольший `verbose`
output в этом наборе получен для массива из 100 объектов: около 273 KB против
22–23 B у `flag`.

# Наблюдения полного smoke-run

* Горячий `valid_json` Flag обычно в 1.5–3.2 раза быстрее Jesse/default на valid
  data и поздних ошибках Draft 6. Если ошибочен первый элемент массива из 100
  значений, Jesse благодаря раннему short-circuit примерно в 5.1 раза быстрее.
* Jesse all-errors в 1.3–6.8 раза быстрее горячего `valid_json` Basic на
  diagnostic-safe invalid scenarios.
* Cold compile-and-validate JSONSchex примерно в 15–113 раз быстрее
  `valid_json:run_schema/3` в зависимости от schema и instance.
* На valid hot data Draft 2020-12 JSONSchex примерно в 1.7–6.0 раза быстрее
  `valid_json` Flag.
* На invalid hot data Draft 2020-12 JSONSchex примерно в 6.6–132 раза быстрее
  `valid_json` Basic. Разброс определяется количеством и формой стандартных
  output units, которые создаёт `valid_json`.

# Особенность Jesse all-errors

Self-check обнаружил, что `{allowed_errors, infinity}` меняет verdict валидного
composition scenario. Ошибка из подсхемы, которую `not` должен отвергнуть,
попадает в итоговый список, хотя обычный Jesse/default возвращает `{ok, Data}`.

Поэтому composition scenario исключён только из all-errors сравнения Jesse и
`valid_json` Basic. Он остаётся в основном сравнении Jesse/default и
`valid_json` Flag. Это ограничение относится к выбору корректного режима
benchmark, а не к результату `valid_json`.

# Воспроизведение

Benchmark выбирает установленную совместимую пару OTP 28 / Elixir через свой
`.tool-versions`:

```sh
cd _checkouts/valid_json_bench
mix deps.get
mix run bench/verify.exs
mix run bench/compare.exs
mix run bench/output_sizes.exs
```

Отдельные срезы и компактный TSV-вывод:

```sh
BENCH_SUITE=jesse mix run bench/compare.exs
BENCH_SUITE=jsonschex BENCH_CASE=nested mix run bench/compare.exs
BENCH_SUITE=output BENCH_CASE=array_100 mix run bench/compare.exs
BENCH_FORMAT=compact mix run bench/compare.exs
```

Время каждого этапа настраивается целыми секундами:

```sh
BENCH_WARMUP=1 BENCH_TIME=3 BENCH_MEMORY_TIME=1 BENCH_REDUCTION_TIME=1 \
  mix run bench/compare.exs
```

Для устойчивого сравнения выбранный срез нужно повторить не менее трёх раз на
незагруженной машине. Runner печатает версии OTP, ERTS, Elixir, число
schedulers и commit каждого checkout вместе с результатом.

# Проверка

При подготовке снимка выполнены:

* benchmark self-check всех valid/invalid verdicts;
* EUnit: 7015 tests, 0 failures;
* conformance: 5327 tests, 0 failures.

EUnit и conformance запускались через обязательную обёртку `silent_rebar3`.
