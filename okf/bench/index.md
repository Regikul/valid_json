# Benchmarking

* [Протокол измерения производительности](performance-measurement.md) - Воспроизводимые smoke-, контрольные и межверсионные замеры без закреплённого численного baseline.
* [Сравнение производительности valid_json, Jesse и JSONSchex](00-validator-comparison.md) - Методика и локальные результаты cold/hot-валидации для Draft 6 и Draft 2020-12, а также стоимость стандартных output formats valid_json.
* [Влияние trust_schema на холодную компиляцию](01-trust-schema.md) - Стоимость meta-schema validation и производительность trusted cold-path valid_json на Draft 6 и Draft 2020-12.
* [Профиль горячей валидации](02-validate-profile.md) - Распределение вызовов, heap allocations и времени внутри valid_json:validate/3 на Draft 2020-12.
* [Результаты оптимизации output locations](03-location-output-optimization.md) - Повторный benchmark после ленивого построения absoluteKeywordLocation и fast paths сериализации locations.
* [Прогресс оптимизации горячей валидации](04-validation-optimization-progress.md) - Кумулятивный эффект оптимизаций evaluator и новый профиль большого массива для всех output formats.
* [Сравнение с Jesse и JSONSchex после оптимизации evaluator](05-validator-comparison-after-optimization.md) - Текущее положение hot, cold и trusted cold valid_json относительно Jesse и JSONSchex.
* [Format-specific diagnostics и плоский Basic collector](06-format-specific-diagnostics.md) - Эффект прямого сбора Basic output и отказа от гарантированного порядка sibling units.
* [Cycle guard в пределах позиции instance](07-position-scoped-cycle-guard.md) - Эффект разделения consuming и in-place входов evaluator и устранения guard-работы при структурном спуске.
