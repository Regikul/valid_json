---
type: Benchmark Report
title: Влияние trust_schema на холодную компиляцию
description: Стоимость meta-schema validation и производительность trusted cold-path valid_json на Draft 6 и Draft 2020-12.
tags: [benchmark, performance, json-schema, trust-schema, compilation]
---

# Влияние `trust_schema` на холодную компиляцию

Этот отчёт дополняет [исходное сравнение](00-validator-comparison.md) отдельным измерением
production-опции `{trust_schema, true}`. Опция появилась в `valid_json` commit
`d7961f9` и отключает только проверку schema resources их meta-schemas. Resource
discovery, определение dialect и vocabularies, разрешение ссылок, compiler
safety checks, emission IR и validation instance остаются внутри измеряемого
вызова.

Результаты являются локальным снимком, а не переносимой характеристикой любого
оборудования. Для capacity planning их следует повторить на целевой машине.

# Что сравнивается

Обе строки вызывают `valid_json:run_schema/3`, то есть компилируют schema и
проверяют instance заново при каждом вызове:

```erlang
valid_json:run_schema(Schema, Instance, OutputOptions).
valid_json:run_schema(Schema, Instance,
                      [{trust_schema, true} | OutputOptions]).
```

У них одинаковые schema, instance и output format. Разница ограничена
meta-schema validation:

| Строка | Meta-schema validation | Остальная компиляция | Instance validation |
| --- | --- | --- | --- |
| default | да, `basic` по умолчанию | да | да |
| trusted | нет | да | да |

Поэтому разность default и trusted показывает стоимость meta-schema pass, а
trusted остаётся end-to-end cold-path, не compile-only микротестом.

Draft 6 verdict-oriented использует `flag` на valid и invalid data. Для
диагностического сравнения Draft 6 invalid использует `basic`. Draft 2020-12,
как и исходный отчёт, использует `flag` на valid data и `basic` на invalid data,
поскольку JSONSchex всегда собирает ошибки.

# Окружение и методика

* Intel Core i7-12700H, VM видит 4 schedulers;
* OTP 28, ERTS 16.4, Elixir 1.19.5, JIT включён;
* `valid_json` — commit `d7961f9`;
* Jesse — commit `d06868f`;
* JSONSchex — commit `4ba3c8c`.

Контрольный nested-object прогон использовал одну секунду warmup, три секунды
измерения времени, одну секунду измерения памяти и одну секунду измерения
reductions на каждую точку. `Average` — среднее время Benchee. `Allocated` —
суммарные выделения за вызов по данным Benchee, а не peak resident memory.

Полный корпус использует те же семь сценариев, что исходный отчёт. Для него
время усреднено по 100 последовательным вызовам после прогрева, а allocation и
reductions сняты коллекторами Benchee. Этот короткий срез нужен для диапазонов;
основными контрольными числами остаются таблицы nested object.

# Проверка реализации

Перед benchmark выполнены:

* self-check одинакового valid/invalid verdict всех сценариев;
* EUnit: 7021 tests, 0 failures;
* conformance: 5327 tests, 0 failures.

EUnit и conformance запускались через `./silent_rebar3`.

Review commit подтвердил следующие свойства:

* `trust_schema` доступен как compile option для `run_schema/3` и как
  store-wide policy;
* `schema_validation` снова содержит только `flag`, `basic`, `detailed` и
  `verbose`;
* trusted-path не отключает reference и compiler safety checks;
* custom meta-schema и её `$schema`-цепочка остаются profile dependencies в
  `sources`;
* `$ref`-closure custom meta-schema, нужный только для meta-validation, в
  trusted artifact не добавляется;
* store использует одну политику для loader, последующих добавлений, rebuild и
  восстановления artifact table.

# Контрольный сценарий: Draft 6

## Verdict-oriented, `flag`

| Instance | Реализация | Average | Allocated | Reductions |
| --- | --- | ---: | ---: | ---: |
| valid | `valid_json` hot | 9.69 μs | 17 568 B | 2 053 |
| valid | Jesse cold/default | 18.35 μs | 42 592 B | 3 001 |
| valid | `valid_json` cold/trusted | 258.81 μs | 256 008 B | 34 326 |
| valid | `valid_json` cold/default | 1.185 ms | 637 928 B | 70 679 |
| invalid | Jesse cold/default | 3.72 μs | 8 040 B | 778 |
| invalid | `valid_json` hot | 4.48 μs | 6 760 B | 859 |
| invalid | `valid_json` cold/trusted | 264.34 μs | 245 240 B | 33 125 |
| invalid | `valid_json` cold/default | 1.227 ms | 627 120 B | 69 506 |

На valid data trusted относительно default:

* быстрее в 4.58 раза;
* выделяет в 2.49 раза меньше памяти;
* выполняет в 2.06 раза меньше reductions.

На invalid data коэффициенты составляют 4.64, 2.56 и 2.10 соответственно.
Trusted cold остаётся примерно в 14 раз медленнее Jesse на valid data. На
invalid data разница больше из-за очень короткого fail-fast пути Jesse.

## Invalid diagnostics, `basic`

| Реализация | Average | Allocated | Reductions |
| --- | ---: | ---: | ---: |
| Jesse cold/all-errors | 20.12 μs | 47 176 B | 3 300 |
| `valid_json` hot | 145.08 μs | 107 840 B | 10 514 |
| `valid_json` cold/trusted | 465.78 μs | 346 208 B | 42 700 |
| `valid_json` cold/default | 1.457 ms | 728 176 B | 78 825 |

Здесь trusted быстрее default в 3.13 раза, allocation ниже в 2.10 раза, а
reductions — в 1.85 раза. Доля meta-validation меньше, чем в `flag`, потому что
построение Basic output для invalid instance одинаково выполняется в обеих
строках.

# Контрольный сценарий: Draft 2020-12

| Instance | Реализация | Average | Allocated | Reductions |
| --- | --- | ---: | ---: | ---: |
| valid | JSONSchex cold | 20.78 μs | 20 840 B | 4 058 |
| valid | `valid_json` cold/trusted | 270.62 μs | 260 240 B | 33 841 |
| valid | `valid_json` cold/default | 1.693 ms | 1 039 760 B | 104 428 |
| invalid | JSONSchex cold | 21.07 μs | 22 592 B | 4 205 |
| invalid | `valid_json` cold/trusted | 439.67 μs | 350 312 B | 42 391 |
| invalid | `valid_json` cold/default | 1.888 ms | 1 130 008 B | 112 607 |

На valid data trusted относительно default:

* быстрее в 6.25 раза;
* выделяет почти в 4 раза меньше памяти;
* выполняет в 3.09 раза меньше reductions.

На invalid data trusted быстрее в 4.29 раза, allocation ниже в 3.23 раза, а
reductions — в 2.66 раза. JSONSchex всё ещё быстрее trusted cold примерно в 13
раз на valid и в 21 раз на invalid data: после снятия meta-validation остаётся
заметная стоимость discovery и emission IR.

# Диапазоны полного корпуса

Коэффициент больше единицы означает преимущество trusted над default.

| Срез | Ускорение | Снижение allocation | Снижение reductions |
| --- | ---: | ---: | ---: |
| Draft 6, `flag`, valid и invalid | 2.06–5.74× | 1.25–2.53× | 1.19–2.12× |
| Draft 6, invalid `basic` | 1.15–4.17× | 1.10–2.09× | 1.07–1.86× |
| Draft 2020-12, valid `flag`, invalid `basic` | 1.27–6.47× | 1.21–3.98× | 1.18–3.07× |

Нижняя граница приходится на большие массивы с `basic` либо на рекурсивный
instance. Там обход instance и построение output уже доминируют над проверкой
schema. Верхняя граница наблюдается на небольших и средних schemas, где
meta-schema pass был основной частью cold-вызова.

Характерные точки полного среза:

| Scenario | Output | Default | Trusted | Speedup |
| --- | --- | ---: | ---: | ---: |
| Draft 6 scalar valid | `flag` | 314.65 μs | 54.80 μs | 5.74× |
| Draft 6 nested valid | `flag` | 1.102 ms | 263.42 μs | 4.18× |
| Draft 6 array-100 valid | `flag` | 1.101–1.196 ms | 505.60–546.54 μs | 2.18–2.19× |
| Draft 2020-12 scalar valid | `flag` | 260.97 μs | 46.09 μs | 5.66× |
| Draft 2020-12 nested valid | `flag` | 1.566 ms | 242.14 μs | 6.47× |
| Draft 2020-12 composition valid | `flag` | 2.106 ms | 442.26 μs | 4.76× |
| Draft 2020-12 array-100 invalid | `basic` | 3.68–3.72 ms | 2.90 ms | 1.27–1.28× |

# Выводы

`trust_schema` снимает первый и крупнейший слой cold-cost. На типичном nested
Draft 2020-12 вызове он устраняет около 780 KB allocations и 70.6 тысячи
reductions, которые не нужны приложению с заранее проверенной schema.

Режим также даёт чистую границу для дальнейшего профилирования:

```text
default cold − trusted cold = meta-schema validation
trusted cold − hot          = discovery + references + emission
hot                         = evaluator + output
```

Trusted не заменяет оптимизацию checked-path и не делает cold-компиляцию равной
по цене конкурентам. После отключения meta-validation следующий крупный бюджет
находится в emitter/discovery: nested Draft 2020-12 trusted всё ещё аллоцирует
около 260 KB ради артефакта размером порядка нескольких килобайт.

Для схем из внешнего или смешанного источника default остаётся обязательным.
Trusted store должен быть отдельным trust domain: loader и все последующие
`add`/`add_at` в нём считаются заранее проверенными.
