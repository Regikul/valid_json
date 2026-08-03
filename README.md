# valid_json

`valid_json` — OTP-библиотека для валидации JSON с помощью JSON Schema.

## Область поддержки

Проект сосредоточен на:

- JSON Schema Draft 2020-12;
- JSON Schema Draft 2019-09;
- cross-draft ссылках между этими диалектами;
- форматах результата валидации `flag`, `basic`, `detailed` и `verbose`.

Валидатор находится на этапе реализации. Нормативные документы, runtime-схемы и официальный набор conformance-тестов уже закреплены в репозитории. Текущее состояние работ и порядок фаз — в [roadmap](ROADMAP.md).

На сегодня закрыты фазы P0–P5, идёт P6. Оба диалекта поддержаны в части assertion keywords, applicators, составных constraints, annotation-only keywords, resources и обычных ссылок (`$id`, `$anchor`, `$defs`, `$ref` на локальные и удалённые документы), а также `unevaluatedProperties` и `unevaluatedItems`. Работает `$vocabulary`: набор активных keywords берётся из метасхемы диалекта. В Draft 2020-12 поддержаны динамические ссылки — `$dynamicAnchor` вместе с `$dynamicRef`; в Draft 2019-09 — recursive keywords `$recursiveAnchor` и `$recursiveRef` вместе с array-form `items` и `additionalItems`. `format` собирается как аннотация и ничего не проверяет. Схемы компилируются из реестра документов, который ничего не загружает по сети: всё, до чего дотягиваются ссылки, должно быть зарегистрировано заранее. Результат подтверждён соответствующими файлами официального сьюта в формате `flag`. Ещё не поддержаны cross-draft переходы, форматы результата `basic`, `detailed` и `verbose`, assertion-ветвь `format` и content keywords. Проверка схем метасхемой пока не включена.

## Сборка

```shell
rebar3 compile
```

## База знаний

Архитектура, правила conformance-тестирования, процедуры обновления и локальные копии спецификаций собраны в [OKF bundle](okf/).
