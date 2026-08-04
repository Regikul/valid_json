---
type: Specification
title: ECMA-262 regular expression dialect
description: Разделы ECMA-262 11-го издания, задающие диалект регулярных выражений keyword'ов pattern и patternProperties, с указанием того, что именно из них нормативно для валидатора.
tags: [ecma-262, specification, regex, pattern, unicode]
status: stable
sources:
  - id: ecma262-11
    resource: https://262.ecma-international.org/11.0/
    title: ECMA-262, 11th edition, ECMAScript 2020 Language Specification
---

# Documents

* [ECMA-262 11th edition, regexp sections](ecma262-11-regexp.txt) - Локальная выборка разделов 11.2, 11.3, 21.2 и B.1.4.

Издание выбрано не по свежести, а по ссылке: JSON Schema Core 2020-12 называет нормативным именно 11-е издание и внутри него раздел 21.2.1 ([core.txt:3456](../json-schema/draft-2020-12/core.txt), [core.txt:682](../json-schema/draft-2020-12/core.txt)). Draft 2019-09 ссылается на ECMA-262 без издания и указывает раздел 15.10.1 ([core.txt:626](../json-schema/draft-2019-09/core.txt)) — нумерацию времён 5-го издания; диалект имеется в виду тот же самый, поэтому отдельного зеркала для него нет.

Опубликованное издание ECMA-262 существует в HTML и PDF, а не в тексте, поэтому этот файл — не побайтовое зеркало, а механическое текстовое представление четырёх поддеревьев документа. Правила преобразования и их потери названы в шапке самого файла. Издание опубликовано и больше не меняется, поэтому происхождение не нуждается в закреплении коммитом, и директория не подчиняется [playbook обновления upstream](../../playbooks/update-json-schema-upstreams.md).

# Sections used by the validator

| Тема | Раздел |
| --- | --- |
| Грамматика паттерна целиком | 21.2.1 ([ecma262-11-regexp.txt:111](ecma262-11-regexp.txt)) |
| Семантика паттерна | 21.2.2 ([ecma262-11-regexp.txt:562](ecma262-11-regexp.txt)) |
| Границы слова `\b`, `\B` и состав WordCharacters | 21.2.2.6 ([ecma262-11-regexp.txt:861](ecma262-11-regexp.txt)), 21.2.2.6.1 ([ecma262-11-regexp.txt:1005](ecma262-11-regexp.txt)) |
| Точка и множество LineTerminator | 21.2.2.8 ([ecma262-11-regexp.txt:1108](ecma262-11-regexp.txt)) |
| Имена и значения Unicode-свойств | 21.2.2.8.3 ([ecma262-11-regexp.txt:1271](ecma262-11-regexp.txt)), 21.2.2.8.4 ([ecma262-11-regexp.txt:1439](ecma262-11-regexp.txt)) |
| Escape-последовательности | 21.2.2.9 ([ecma262-11-regexp.txt:2042](ecma262-11-regexp.txt)), 21.2.2.10 ([ecma262-11-regexp.txt:2117](ecma262-11-regexp.txt)) |
| Краткие классы `\d`, `\s`, `\w` и их дополнения | 21.2.2.12 ([ecma262-11-regexp.txt:2149](ecma262-11-regexp.txt)) |
| Классы символов и диапазоны | 21.2.2.13 ([ecma262-11-regexp.txt:2255](ecma262-11-regexp.txt)) |
| Состав `\s`: WhiteSpace и LineTerminator | 11.2 ([ecma262-11-regexp.txt:28](ecma262-11-regexp.txt)), 11.3 ([ecma262-11-regexp.txt:64](ecma262-11-regexp.txt)) |
| Расширения, недоступные под флагом `u` | B.1.4 ([ecma262-11-regexp.txt:3220](ecma262-11-regexp.txt)) |

Эталоном служит грамматика под флагом `u`: Unicode-режим требует сама JSON Schema ([core.txt:684](../json-schema/draft-2020-12/core.txt)), а под этим флагом расширения Annex B отключены, и часть выражений, принимаемых обычным движком JavaScript, становится синтаксической ошибкой. Приложение B оставлено в выборке ровно затем, чтобы эту границу было видно.

Спецификация не обязывает реализацию совпадать с этим диалектом: соответствие ему заявлено как SHOULD, а MUST относится только к запрету неявного якорения ([core.txt:710](../json-schema/draft-2020-12/core.txt)). Фактическое расхождение движка `re` с текстом этих разделов измерено в [«Адаптации ECMA-262 к PCRE»](../../architecture/ecma-to-pcre-adaptation.md).
