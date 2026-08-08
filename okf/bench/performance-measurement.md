---
type: Playbook
title: Протокол измерения производительности
description: Воспроизводимая процедура smoke-, контрольных и межверсионных замеров valid_json, Jesse и JSONSchex без закрепления численного baseline.
tags: [benchmark, performance, measurement, regression, jesse, jsonschex]
status: stable
---

# Протокол измерения производительности

Документ задаёт один способ измерять производительность валидатора. Он не
содержит эталонных значений и не устанавливает порог регрессии. Результат
каждого запуска остаётся runtime artifact: его можно сопоставить с другим
запуском, но сам этот документ из-за очередного измерения не меняется.

Исполняемая часть протокола находится в отслеживаемом Git каталоге
[`bench/`](../../bench/). Сценарии, параметры вызовов и compact formatter
версионируются вместе с исходным кодом. Jesse и JSONSchex закреплены полными
commit SHA в [`bench/mix.exs`](../../bench/mix.exs) и
[`bench/mix.lock`](../../bench/mix.lock).

# Измеряемые границы

Слова `cold` и `hot` относятся к состоянию schema, а не VM. Applications и
модули уже загружены, одноразовая публикация встроенных meta-schemas завершена,
а JSON представлен готовыми BEAM terms. Запуск VM, application startup и JSON
decoding в измеряемую функцию не входят.

| Dialect и задача | Реализация | Измеряемая граница |
| --- | --- | --- |
| Draft 6, verdict | Jesse cold | `jesse:validate_with_schema/3`, default |
| Draft 6, verdict | `valid_json` cold | `valid_json:run_schema/3`, `flag` |
| Draft 6, verdict | `valid_json` hot | `valid_json:validate/3`, `flag` |
| Draft 6, все ошибки | Jesse cold | `jesse:validate_with_schema/3`, `{allowed_errors, infinity}` |
| Draft 6, все ошибки | `valid_json` cold | `valid_json:run_schema/3`, `basic` |
| Draft 6, все ошибки | `valid_json` hot | `valid_json:validate/3`, `basic` |
| Draft 2020-12, cold | JSONSchex и `valid_json` | `compile/1` + `validate/2` и `run_schema/3` |
| Draft 2020-12, hot | JSONSchex и `valid_json` | готовый artifact и зарегистрированная schema |

На valid input JSONSchex сравнивается с `valid_json` Flag. На invalid input
JSONSchex возвращает список ошибок, поэтому `valid_json` использует Basic.
Payload этих ошибок неодинаков, и результат показывает стоимость публичных
контрактов библиотек, а не одной и той же структуры данных.

Jesse cold следует всегда показывать рядом с обеими строками `valid_json`:
cold и hot. Cold/cold отвечает на вопрос о полном вызове от raw schema, а
cold/hot отдельно показывает эффект предварительной компиляции `valid_json`.
Одна строка не заменяет другую.

# Метрики

Каждая точка содержит:

- Benchee `Average` и `Median` latency;
- allocations в bytes/op;
- reductions/op;
- для output-size запуска — размер возвращённого значения в Erlang external
  term format.

Allocations означают суммарные выделения process heap за вызов, а не пиковую
resident memory. Время из `tprof` используется только для ранжирования функций:
instrumentation меняет абсолютную latency.

# Условия сопоставимости

Два запуска можно сравнивать между собой, только если совпадают:

- revision benchmark runner без суффикса `-dirty`;
- revisions Jesse и JSONSchex;
- сценарий, valid/invalid input, dialect, output format и cold/hot boundary;
- CPU, число online schedulers, OTP, ERTS и Elixir;
- warmup, latency, memory и reduction intervals;
- число повторов и способ агрегации.

Замер выполняется на простаивающей машине без параллельных benchmark и
профилировщиков. Переход между версиями OTP, VM flags или числом schedulers
начинает новую несопоставимую серию.

# Подготовка и self-check

Из корня репозитория:

```sh
cd bench
mix deps.get
mix format --check-formatted
mix run bench/verify.exs
```

Self-check обязателен перед latency-измерением. Он требует одинакового
valid/invalid verdict у участвующих библиотек и проверяет все четыре output
formats `valid_json`.

# Smoke-замер

Smoke нужен для быстрой проверки крупного сдвига, но не служит доказательством
небольшой регрессии. Он выполняется один раз с короткими интервалами:

```sh
BENCH_FORMAT=compact BENCH_WARMUP=1 BENCH_TIME=1 \
BENCH_MEMORY_TIME=1 BENCH_REDUCTION_TIME=1 \
mix run bench/compare.exs
```

# Контрольный замер

Контрольный запуск использует 2 s warmup, 5 s latency, 2 s memory и 2 s
reductions на каждую точку. Каждый выбранный срез запускается три раза
последовательно. Для latency сравнивается медиана трёх значений `Average`; для
allocations и reductions также берётся медиана, а несовпадающие значения
рассматриваются вместе с их диапазоном.

Основные canary scenarios покрывают разные формы работы evaluator:

| Scenario | Нагрузка |
| --- | --- |
| `scalar_string` | чистые assertions без структурного обхода |
| `nested_object` | смешанные object, array и assertions |
| `array_100_last_error` | длинный consuming-обход и поздняя ошибка |
| `object_properties_100` | именованные свойства объекта |
| `object_patterns_100` | `patternProperties` и несколько совпадений имени |
| `object_unevaluated_100` | coverage через `allOf` и `unevaluatedProperties` |
| `composition` | `allOf`, `oneOf`, `not` и `contains` |
| `recursive_ref` | рекурсивный переход по `$ref` |

Все output formats измеряются на контрольной ширине:

```sh
for run in 1 2 3; do
  for case_name in scalar_string nested_object array_100_last_error \
    object_properties_100 object_patterns_100 object_unevaluated_100 \
    composition recursive_ref; do
    BENCH_SUITE=output BENCH_CASE="exact:${case_name}" \
    BENCH_FORMAT=compact BENCH_WARMUP=2 BENCH_TIME=5 \
    BENCH_MEMORY_TIME=2 BENCH_REDUCTION_TIME=2 \
    mix run bench/compare.exs
  done
done
```

Линейность object paths проверяется отдельно на ширинах 10, 100 и 1 000. Для
этого sweep достаточно Flag и Basic:

```sh
for run in 1 2 3; do
  for family in object_properties_ object_additional_ object_patterns_ \
    object_unevaluated_; do
    BENCH_SUITE=output BENCH_CASE="$family" \
    BENCH_OUTPUT_FORMATS=flag,basic BENCH_FORMAT=compact \
    BENCH_WARMUP=2 BENCH_TIME=5 BENCH_MEMORY_TIME=2 \
    BENCH_REDUCTION_TIME=2 mix run bench/compare.exs
  done
done
```

Конкурентные границы измеряются отдельными suite. Runner печатает обе
validity и все соответствующие cold/hot строки:

```sh
for run in 1 2 3; do
  for case_name in nested_object array_100_last_error object_properties_100; do
    BENCH_SUITE=jesse BENCH_CASE="exact:${case_name}" \
    BENCH_FORMAT=compact BENCH_WARMUP=2 BENCH_TIME=5 \
    BENCH_MEMORY_TIME=2 BENCH_REDUCTION_TIME=2 \
    mix run bench/compare.exs

    BENCH_SUITE=jsonschex BENCH_CASE="exact:${case_name}" \
    BENCH_FORMAT=compact BENCH_WARMUP=2 BENCH_TIME=5 \
    BENCH_MEMORY_TIME=2 BENCH_REDUCTION_TIME=2 \
    mix run bench/compare.exs
  done
done
```

# Сравнение двух версий valid_json

Обе версии измеряются одним checkout benchmark runner. Целевая версия
выбирается абсолютным `VALID_JSON_PATH`, а отдельный `MIX_BUILD_PATH` не даёт
артефактам двух исходных деревьев смешаться:

```sh
VALID_JSON_PATH=/absolute/path/to/version-a \
MIX_BUILD_PATH=_build/version-a mix run bench/verify.exs

VALID_JSON_PATH=/absolute/path/to/version-b \
MIX_BUILD_PATH=_build/version-b mix run bench/verify.exs
```

После self-check для обоих путей повторяется один и тот же контрольный command
с теми же значениями `VALID_JSON_PATH` и `MIX_BUILD_PATH`. Compact output
начинает каждую серию runtime metadata и выдаёт строки `BENCH_RESULT`, поэтому
граница, scenario и revision остаются видимыми рядом с измерением.

# Профилирование отклонения

Профиль снимается после того, как Benchee воспроизвёл отклонение. Он не
заменяет контрольный замер:

```sh
PROFILE_CASE=object_properties_100 PROFILE_VALIDITY=valid \
PROFILE_FORMAT=flag PROFILE_LAYER=full PROFILE_TYPE=all \
PROFILE_ITERATIONS=1000 PROFILE_WARMUP=200 \
mix run bench/profile.exs
```

Слои `lookup`, `core`, `eval` и `output` отделяют получение artifact,
валидацию с уже полученным artifact, evaluator и проекцию результата. Вывод о
регрессии основывается на публичной границе Benchee; профиль объясняет, где
изменилась работа.
