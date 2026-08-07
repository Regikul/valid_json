# Benchmarking

* [Сравнение производительности valid_json, Jesse и JSONSchex](00-validator-comparison.md) - Методика и локальные результаты cold/hot-валидации для Draft 6 и Draft 2020-12, а также стоимость стандартных output formats valid_json.
* [Влияние trust_schema на холодную компиляцию](01-trust-schema.md) - Стоимость meta-schema validation и производительность trusted cold-path valid_json на Draft 6 и Draft 2020-12.
* [Профиль горячей валидации](02-validate-profile.md) - Распределение вызовов, heap allocations и времени внутри valid_json:validate/3 на Draft 2020-12.
