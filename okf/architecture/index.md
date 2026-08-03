# Architecture

## Нормативные документы

* [JSON Schema assets](json-schema-assets.md) - Назначение runtime-ресурсов в `priv/` и conformance fixtures в `test/`.
* [Validator design overview](validator-design.md) - Инварианты, классификация keywords, границы core/resources/runtime, план реализации и единый список открытых вопросов.
* [Validator computational core](validator-core.md) - Модель JSON-значения, constraint IR, evaluator, аннотации, output formats и публичный контракт валидации.
* [Validator resources and runtime](validator-resources-runtime.md) - Schema resources, URI и dialect, registry, компиляция, ETS ownership, reload и invalidation.
* [Format attributes](format-attributes.md) - Девятнадцать имён `format`: роль, алгоритм, нормативный источник, ограничения и отложенное решение по IDN и IRI.

## Supporting notes

Эти документы сохраняют измерения и развёрнутые примеры, но не являются обязательным чтением для реализации.

* [ECMA-262 to PCRE adaptation](ecma-to-pcre-adaptation.md) - Расхождения `re` с диалектом ECMA-262, замер на снапшоте сьюта и две ступени переписывания паттерна.
* [Validator value model notes](validator-value-model-notes.md) - Измерения OTP, Unicode-примеры и доказательство границ `multipleOf`.
* [Validator compiled examples](validator-compiled-examples.md) - Полные Erlang-термы и fixture evidence для ресурсов, ссылок и dialect inheritance.
