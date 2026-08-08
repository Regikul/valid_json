---
type: Benchmark Report
title: Прогресс оптимизации горячей валидации
description: Кумулятивный эффект оптимизаций evaluator и новый профиль array_100_last_error для всех output formats.
tags: [benchmark, performance, profiling, validation, evaluator, output, allocations]
---

# Прогресс оптимизации горячей валидации

Отчёт фиксирует состояние после серии оптимизаций evaluator: дешёвого coverage,
линейного накопления diagnostic units, canonical empty results, fast paths
слияния результатов и передачи координат ветви без промежуточного копирования
`#eval_context{}`. Для `flag` keyword- и instance-location больше не
материализуются: cycle guard сохраняет только глубину instance.

Главный контрольный сценарий — Draft 2020-12
`array_100_last_error`: массив из 100 объектов, ошибка находится в последнем
элементе. Он заставляет evaluator пройти весь массив и хорошо показывает
накопительную стоимость каждого schema node.

# Состояние кода

Benchmark запускался на parent commit `349eea6` и незакоммиченном на момент
измерения change set из пяти файлов:

* `src/valid_json_eval.erl`;
* `src/valid_json_apply.erl`;
* `src/valid_json_array.erl`;
* `src/valid_json_object.erl`;
* `src/valid_json_unevaluated.erl`.

Этот change set включён в тот же commit, что и настоящий отчёт. Поэтому
metadata benchmark показывает `349eea6`, хотя фактически измерялось итоговое
состояние commit с отчётом.

# Окружение и методика

* Intel Core i7-12700H, VM видит 4 schedulers;
* OTP 28, ERTS 16.4, Elixir 1.19.5, JIT включён;
* Draft 2020-12, schema заранее зарегистрирована и скомпилирована;
* публичная граница Benchee — горячий `valid_json:validate/3`;
* Benchee: 1 s warmup, 2 s latency, 1 s memory и 1 s reductions на точку;
* каждый output benchmark повторён три раза последовательно;
* latency ниже — медиана трёх значений Benchee `Average`, без исключения
  outliers;
* allocations и reductions совпали во всех трёх прогонах;
* `tprof` отдельно измерял полный публичный путь и evaluator.

# Текущее состояние output formats

| Instance | Format | Average | Allocated | Reductions |
| --- | --- | ---: | ---: | ---: |
| invalid | `flag` | 196.99 us | 213 896 B | 31 281 |
| invalid | `detailed` | 354.99 us | 491 960 B | 52 187 |
| invalid | `basic` | 377.00 us | 510 824 B | 66 795 |
| invalid | `verbose` | 5.045 ms | 1 201 832 B | 161 826 |
| valid | `flag` | 198.54 us | 214 704 B | 31 389 |
| valid | `basic` | 907.55 us | 634 280 B | 81 489 |
| valid | `detailed` | 1.103 ms | 779 912 B | 89 388 |
| valid | `verbose` | 4.925 ms | 1 201 024 B | 162 447 |

Третий прогон `valid/flag` попал под фоновую нагрузку: его Average составил
241.90 us против 198.54 и 195.27 us в первых двух. Медиана сохраняет первый
результат и не превращает этот единичный выброс в эффект оптимизации.

# Эффект последнего change set

Таблица сравнивает новый benchmark с непосредственной контрольной точкой перед
устранением промежуточных context copies и ненаблюдаемых locations. Отрицательное
значение означает снижение стоимости.

| Instance | Format | Average | Allocated | Reductions |
| --- | --- | ---: | ---: | ---: |
| invalid | `flag` | -8.0% | -18.9% | -3.8% |
| invalid | `detailed` | -5.4% | -6.1% | -1.3% |
| invalid | `basic` | -6.6% | -5.9% | -1.7% |
| invalid | `verbose` | +1.0% | -2.6% | +0.3% |
| valid | `flag` | -6.8% | -19.0% | -4.0% |
| valid | `basic` | -15.3% | -4.8% | -2.8% |
| valid | `detailed` | -3.7% | -4.0% | -5.1% |
| valid | `verbose` | -0.8% | -2.6% | -2.7% |

Большой latency-сдвиг `valid/basic` следует считать верхней оценкой: его
предыдущая контрольная точка была шумной. У `verbose` устойчиво уменьшились
allocation, но latency не изменился: этот формат обязан материализовать почти
всё diagnostic tree, и context/location fast path составляет небольшую долю
его полной работы.

# Кумулятивный результат

Для `array_100_last_error / invalid / flag` относительно контрольной точки
перед оптимизацией coverage:

| Метрика | До | После | Изменение |
| --- | ---: | ---: | ---: |
| Average | 335.69 us | 196.99 us | -41.3%, ускорение 1.70x |
| Allocated | 693 392 B | 213 896 B | -69.2% |
| Reductions | 75 314 | 31 281 | -58.5% |

Полный `tprof` подтверждает изменение allocation независимо от Benchee:
693 352 B/op в исходном [профиле validate](02-validate-profile.md) против
213 904 B/op сейчас, то есть `-69.1%`.

Структурный `basic` выиграл ещё больше. Полный публичный профиль того же
invalid instance изменился так:

| Метрика `tprof` | До | После | Изменение |
| --- | ---: | ---: | ---: |
| Traced calls/op | 44 984 | 32 252 | -28.3% |
| Heap words/op | 258 403 | 63 858 | -75.3% |
| Heap bytes/op | 2 067 221 | 510 864 | -75.3% |

Таким образом, первоначальная проблема от половины до двух мегабайт allocations
на большом instance в основном устранена. На худшем `flag`-пути осталось около
31 тысячи reductions вместо 75 тысяч, но это всё ещё заметная абсолютная
стоимость для ста элементов.

# Новый профиль и следующая граница

Evaluator `invalid/flag` сейчас выделяет 26 358 words/op, или 210 864 B/op, и
выполняет 17 462 traced calls/op. Крупнейшие источники allocation:

| Функция | Calls/op | Words/op | Доля evaluator |
| --- | ---: | ---: | ---: |
| `valid_json_eval:eval_at/6` | 399 | 9 371 | 35.5% |
| named-property comprehension | 400 | 2 400 | 9.1% |
| `valid_json_object:check/3` | 100 | 2 100 | 8.0% |
| `valid_json_assert:holds/2` | 699 | 2 094 | 7.9% |
| `valid_json_object:apply_all/5` | 496 | 1 787 | 6.8% |
| `valid_json_evaluated:properties/1` | 198 | 1 782 | 6.8% |
| `valid_json_value:is_unique/1` | 1 | 1 098 | 4.2% |

`eval_at/6` теперь включает cycle guard и единственное создание context для
узла; дальнейшее уменьшение этой позиции затронет общую модель evaluator.
Более локальный следующий шаг — убрать capturing funs из
`valid_json_assert:holds/2`: они дают 2 094 words/op и дополнительные вызовы
анонимных функций. После этого следует повторно измерить `eval_at/6`, object
property traversal и подготовку array applications.

# Воспроизведение

```sh
cd bench

PROFILE_CASE=array_100_last_error PROFILE_VALIDITY=invalid \
PROFILE_FORMAT=flag PROFILE_LAYER=eval PROFILE_TYPE=all \
PROFILE_ITERATIONS=1000 PROFILE_WARMUP=200 \
mix run bench/profile.exs

PROFILE_CASE=array_100_last_error PROFILE_VALIDITY=invalid \
PROFILE_FORMAT=basic PROFILE_LAYER=full PROFILE_TYPE=all \
PROFILE_ITERATIONS=500 PROFILE_WARMUP=100 \
mix run bench/profile.exs

BENCH_SUITE=output BENCH_CASE=array_100_last_error BENCH_FORMAT=compact \
BENCH_WARMUP=1 BENCH_TIME=2 BENCH_MEMORY_TIME=1 \
BENCH_REDUCTION_TIME=1 mix run bench/compare.exs
```
