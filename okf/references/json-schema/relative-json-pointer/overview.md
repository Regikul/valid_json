---
type: Specification
title: Relative JSON Pointers
description: Internet-Draft behind the relative-json-pointer format attribute, normative for both dialects, mirrored locally.
tags: [json-schema, specification, json-pointer, format]
status: stable
sources:
  - id: relative-json-pointer
    resource: https://www.ietf.org/archive/id/draft-handrews-relative-json-pointer-01.txt
    title: Relative JSON Pointers, draft-handrews-relative-json-pointer-01
---

# Documents

* [Relative JSON Pointers](relative-json-pointer.txt) - Local mirror of the draft defining the syntax.[^relative-json-pointer]

Черновик задаёт format attribute `relative-json-pointer` и назван нормативной ссылкой обоих диалектов: Draft 2020-12 ([validation.txt:1381](../draft-2020-12/validation.txt)) и Draft 2019-09 ([validation.txt:1293](../draft-2019-09/validation.txt)). Оба ссылаются на одну и ту же ревизию `-01`, поэтому зеркало здесь одно и лежит рядом с диалектами, а не внутри одного из них.

Документ лежит в bundle JSON Schema, а не среди [IETF RFCs](../../rfc/): статуса RFC у него нет и не будет. Работу над ним ведёт организация JSON Schema, черновик числится за IETF как work in progress и по правилам IETF цитировать его иначе нельзя.

# Sections used by the validator

| Тема | Секция |
| --- | --- |
| Синтаксис и ABNF | 3 ([relative-json-pointer.txt:93](relative-json-pointer.txt)); само правило — [relative-json-pointer.txt:120](relative-json-pointer.txt) |
| Порядок вычисления | 4 ([relative-json-pointer.txt:129](relative-json-pointer.txt)) |
| Представление в JSON string | 5 ([relative-json-pointer.txt:176](relative-json-pointer.txt)) |
| Запрет в URI fragment | 6 ([relative-json-pointer.txt:229](relative-json-pointer.txt)) |
| Обработка ошибок | 7 ([relative-json-pointer.txt:236](relative-json-pointer.txt)) |

Валидатору нужен раздел 3: format attribute проверяет только синтаксис строки, а не то, разрешается ли указатель в реальном документе. Остальные разделы названы, чтобы граница была видна: неразрешимый указатель остаётся синтаксически верным и assertion не нарушает.

Правило раздела 3 — неотрицательное целое без ведущего нуля, за которым идёт либо `#`, либо JSON Pointer по разделу 3 RFC 6901 ([rfc6901.txt:95](../../rfc/rfc6901.txt)). Ревизия `-01` отличается от `-00` ровно этим: начальное число неотрицательное, а не положительное, поэтому `0` и `0#` допустимы.

# Notes on the mirror

В строке 120 стоит `&lt;json-pointer&gt;` вместо угловых скобок. Это дефект самого опубликованного черновика: копии с datatracker и из архива IETF совпадают побайтово. В строке 126 та же ссылка набрана правильно, так что смысл правила восстанавливается однозначно.

Даты в двух диалектах названы разные — ноябрь 2017 в Draft 2019-09 и декабрь 2020 в Draft 2020-12, — хотя ревизия в обеих ссылках одна. Даты относятся к публикации самих спецификаций JSON Schema; шапка черновика датирована январём 2018 года.

Срок действия черновика истёк в июле 2018 года. Для зеркала это ничего не меняет: текст ревизии `-01` неизменен, а спецификации ссылаются именно на него.

[^relative-json-pointer]: Luff, G. and H. Andrews, Ed., "Relative JSON Pointers", Work in Progress, Internet-Draft, draft-handrews-relative-json-pointer-01, January 2018.
