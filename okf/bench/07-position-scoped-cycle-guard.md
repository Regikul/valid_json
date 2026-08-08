---
type: Benchmark Report
title: Cycle guard в пределах позиции instance
description: "Эффект разделения consuming и in-place входов evaluator и отказа от кадров {Addr, Depth} на каждом schema node."
tags: [benchmark, performance, profiling, validation, evaluator, cycle-guard, allocations]
---

# Cycle guard в пределах позиции instance

Отчёт фиксирует переход от одного guard для всей активной ветви к guard,
ограниченному текущей позицией JSON instance.

До изменения каждый вход в schema node создавал `{Addr, Depth}`, искал его в
`sets:set()` и добавлял в множество. Это происходило и для in-place
applicators, и при заведомом продвижении в элемент массива либо свойство
объекта.

После изменения evaluator различает два входа:

* consuming applicator применяет подсхему к другому JSON value и начинает с
  пустого guard;
* in-place applicator сохраняет JSON value, сравнивает target с текущим node и
  map его предков, затем добавляет текущий node перед переходом;
* sibling-ветви получают исходный immutable context и не видят посещения друг
  друга.

Guard теперь имеет форму `#{addr() => true}` и содержит только предков
текущего node на той же позиции instance. Повтор schema address после
consuming-перехода остаётся разрешённой рекурсией с прогрессом.

# Состояние кода

Контрольная точка «до» — чистый commit `c736ce1`. Benchmark «после» выполнялся
на незакоммиченном change set поверх него: metadata runner поэтому также
показывает `c736ce1`. Change set включает новый guard, явные consuming/in-place
входы и регрессионные тесты циклов и прогрессирующей рекурсии.

# Окружение и методика

* Intel Core i7-12700H, VM видит 4 schedulers;
* OTP 28, ERTS 16.4, Elixir 1.19.5, JIT включён;
* Draft 2020-12, schema заранее зарегистрирована и скомпилирована;
* публичная граница Benchee — горячий `valid_json:validate/3`;
* сценарий `array_100_last_error`: сто объектов, ошибка находится в последнем;
* 1 s warmup, 2 s latency, 1 s memory и 1 s reductions на точку;
* output suite выполнен три раза последовательно;
* latency — медиана трёх Benchee `Average`; memory и reductions совпали во всех
  повторах;
* `tprof` измерял полный публичный путь, 1 000 итераций после 200 warmup.

Сценарий намеренно consuming-heavy: один вход в schema массива, сто входов в
item schema и до трёх входов в schema свойств каждого объекта. Поэтому он
изолирует стоимость guard на структурном спуске. Семантика in-place циклов
проверяется тестами, но отдельный benchmark длинной reference-цепочки в этот
отчёт не входит.

# Результат output suite

Итоговое состояние после изменения:

| Instance | Format | Average | Allocated | Reductions |
| --- | --- | ---: | ---: | ---: |
| invalid | `flag` | 100.56 us | 109 552 B | 26 328 |
| invalid | `basic` | 159.41 us | 210 320 B | 34 225 |
| invalid | `detailed` | 161.22 us | 283 640 B | 39 710 |
| invalid | `verbose` | 4.675 ms | 1 127 304 B | 161 537 |
| valid | `flag` | 100.67 us | 109 864 B | 26 460 |
| valid | `basic` | 694.50 us | 324 456 B | 48 683 |
| valid | `detailed` | 934.20 us | 509 440 B | 65 969 |
| valid | `verbose` | 4.881 ms | 1 126 680 B | 161 560 |

Изменение относительно непосредственной контрольной точки `c736ce1`:

| Instance | Format | Average | Allocated | Reductions |
| --- | --- | ---: | ---: | ---: |
| invalid | `flag` | −36.7% | −28.2% | −4.5% |
| invalid | `basic` | −29.7% | −17.1% | −5.2% |
| invalid | `detailed` | −39.1% | −13.2% | −1.3% |
| invalid | `verbose` | −8.7% | −3.7% | +0.3% |
| valid | `flag` | −36.7% | −28.2% | −4.3% |
| valid | `basic` | −9.9% | −11.8% | −0.2% |
| valid | `detailed` | −7.0% | −7.9% | −2.2% |
| valid | `verbose` | +3.2% | −3.7% | −1.3% |

Allocations уменьшились во всех восьми точках. Наиболее сильный относительный
эффект ожидаемо получил `flag`, где diagnostic units не заслоняют стоимость
входа evaluator. У `verbose` guard составляет малую долю полной hierarchy;
колебание valid latency на +3.2% не сопровождается ростом allocations или
reductions и не доказывает регрессию.

# Подтверждение профилем

Полный `tprof call_memory` для invalid instance:

| Format | Heap words/op до | Heap words/op после | Изменение |
| --- | ---: | ---: | ---: |
| `flag` | 18 690 | 13 689 | −26.8% |
| `basic` | 31 709 | 26 300 | −17.1% |

Стоимость общего входа node снизилась отдельно от остальных handlers:

| Format | Функция до | Words/op до | Функция после | Calls/op после | Words/op после |
| --- | --- | ---: | --- | ---: | ---: |
| `flag` | `valid_json_eval:eval_at/6` | 9 371 | `valid_json_eval:eval_entered/7` | 399 | 3 990 |
| `basic` | `valid_json_eval:eval_at/6` | 9 419 | `valid_json_eval:eval_entered/7` | 401 | 4 010 |

Новый общий helper выделяет ровно 10 words на вход — один обновлённый
`#eval_context{}`. Consuming wrapper не создаёт frame, не выполняет lookup и
передаёт literal empty map. Экономия полного профиля составила 5 001 words/op
для Flag и 5 409 words/op для Basic, что совпадает с ожидаемым порядком
стоимости удалённых frame и set operations.

# Семантическая приёмка

Регрессионные тесты отдельно закрепляют:

* прямой self-reference и косвенный in-place цикл возвращают `no_progress`;
* повтор target в sibling-ветвях разрешён;
* повтор того же schema address после спуска в дочернее свойство считается
  прогрессом;
* существующие `$dynamicRef` и `$recursiveRef` сохраняют прежний verdict,
  locations и termination.

После изменения выполнены обязательные наборы:

* `./silent_rebar3 as ci eunit` — 7 050 tests, 0 failures;
* `./silent_rebar3 as ci conformance` — 5 327 tests, 0 failures.

# Воспроизведение

```sh
cd _checkouts/valid_json_bench

BENCH_SUITE=output BENCH_CASE=array_100_last_error BENCH_FORMAT=compact \
BENCH_WARMUP=1 BENCH_TIME=2 BENCH_MEMORY_TIME=1 \
BENCH_REDUCTION_TIME=1 mix run bench/compare.exs

PROFILE_CASE=array_100_last_error PROFILE_VALIDITY=invalid \
PROFILE_FORMAT=basic PROFILE_LAYER=full PROFILE_TYPE=memory \
PROFILE_ITERATIONS=1000 PROFILE_WARMUP=200 PROFILE_TOP=15 \
mix run bench/profile.exs

PROFILE_CASE=array_100_last_error PROFILE_VALIDITY=invalid \
PROFILE_FORMAT=flag PROFILE_LAYER=full PROFILE_TYPE=memory \
PROFILE_ITERATIONS=1000 PROFILE_WARMUP=200 PROFILE_TOP=15 \
mix run bench/profile.exs
```
