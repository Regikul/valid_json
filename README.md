# valid_json

`valid_json` — OTP-библиотека для валидации JSON с помощью JSON Schema.

## Область поддержки

Проект сосредоточен на:

- JSON Schema Draft 2020-12;
- JSON Schema Draft 2019-09;
- cross-draft ссылках между этими диалектами;
- форматах результата валидации `flag`, `basic`, `detailed` и `verbose`.

Валидатор находится на этапе реализации. Нормативные документы, runtime-схемы и официальный набор conformance-тестов уже закреплены в репозитории. Текущее состояние работ и порядок фаз — в [roadmap](ROADMAP.md).

На сегодня закрыты фазы P0–P2. Оба диалекта поддержаны в части assertion keywords, applicators, составных constraints и annotation-only keywords; результат подтверждён соответствующими файлами официального сьюта в формате `flag`. Ещё не поддержаны resources и ссылки (`$id`, `$anchor`, `$ref`, remotes), `unevaluatedProperties` с `unevaluatedItems`, `$dynamicRef`, `$vocabulary` вместе с array-form `items` и `additionalItems` Draft 2019-09, форматы результата `basic`, `detailed` и `verbose`, а также `format` и content keywords.

## Сборка

```shell
rebar3 compile
```

## База знаний

Архитектура, правила conformance-тестирования, процедуры обновления и локальные копии спецификаций собраны в [OKF bundle](okf/).
