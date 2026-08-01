---
type: Specification
title: IETF RFCs referenced by JSON Schema
description: Normative IETF documents behind URI resolution and JSON Pointer, mirrored locally.
tags: [rfc, specification, uri, json-pointer]
status: stable
sources:
  - id: rfc3986
    resource: https://www.rfc-editor.org/rfc/rfc3986.txt
    title: 'Uniform Resource Identifier (URI): Generic Syntax, STD 66, RFC 3986'
  - id: rfc6901
    resource: https://www.rfc-editor.org/rfc/rfc6901.txt
    title: JavaScript Object Notation (JSON) Pointer, RFC 6901
---

# Documents

* [RFC 3986](rfc3986.txt) - Local mirror of the URI generic syntax standard.[^rfc3986]
* [RFC 6901](rfc6901.txt) - Local mirror of the JSON Pointer specification.[^rfc6901]

Both documents are normative references of JSON Schema Core in Draft 2020-12 and Draft 2019-09. Published RFCs are immutable, so provenance needs no commit pinning and this directory is outside the [upstream update playbook](../../playbooks/update-json-schema-upstreams.md).

# Sections used by the validator

| Тема | Секция RFC 3986 |
| --- | --- |
| Percent-encoding и unreserved characters | 2.1 ([rfc3986.txt:634](rfc3986.txt)), 2.3 ([rfc3986.txt:718](rfc3986.txt)), 2.4 ([rfc3986.txt:745](rfc3986.txt)) |
| Разбор на компоненты | 3 ([rfc3986.txt:861](rfc3986.txt)) |
| Fragment | 3.5 ([rfc3986.txt:1308](rfc3986.txt)) |
| Классификация ссылок | 4.1-4.3 ([rfc3986.txt:1393](rfc3986.txt)) |
| Same-document reference | 4.4 ([rfc3986.txt:1482](rfc3986.txt)) |
| Выбор base URI | 5.1 ([rfc3986.txt:1553](rfc3986.txt)) |
| Алгоритм разрешения относительной ссылки | 5.2 ([rfc3986.txt:1661](rfc3986.txt)) |
| Remove dot segments | 5.2.4 ([rfc3986.txt:1805](rfc3986.txt)) |
| Recomposition | 5.3 ([rfc3986.txt:1911](rfc3986.txt)) |
| Эквивалентность и лестница сравнения | 6.1 ([rfc3986.txt:2098](rfc3986.txt)), 6.2 ([rfc3986.txt:2135](rfc3986.txt)) |
| Syntax-based и scheme-based normalization | 6.2.2 ([rfc3986.txt:2197](rfc3986.txt)), 6.2.3 ([rfc3986.txt:2259](rfc3986.txt)) |
| Collected ABNF | Appendix A ([rfc3986.txt:2695](rfc3986.txt)) |

| Тема | Секция RFC 6901 |
| --- | --- |
| Синтаксис указателя и escaping `~0`/`~1` | 3 ([rfc6901.txt:95](rfc6901.txt)) |
| Порядок вычисления по документу | 4 ([rfc6901.txt:133](rfc6901.txt)) |
| Представление в JSON string | 5 ([rfc6901.txt:207](rfc6901.txt)) |
| URI fragment identifier form | 6 ([rfc6901.txt:261](rfc6901.txt)) |
| Обработка ошибок | 7 ([rfc6901.txt:303](rfc6901.txt)) |

Раздел 6 RFC 6901 относится к расхождению Draft 2019-09 по `instanceLocation`: prose требует fragment-encoded форму, а закреплённые output fixtures — обычный JSON Pointer.

# Documents deliberately not mirrored

RFC 3987 (IRI) не упоминается ни в одном из локальных Core-документов и валидатору не нужен. RFC 8141 (URN) не является нормативной ссылкой JSON Schema: `urn:` в обязательном `ref.json` разбирается как обычный URI по RFC 3986, без знания структуры namespace. RFC 8259 нормативен для JSON Schema, но модель значения валидатора уже зафиксирована в [validator-core](../../architecture/validator-core.md) и в тексте RFC не нуждается.

[^rfc3986]: Berners-Lee, T., Fielding, R., and L. Masinter, "Uniform Resource Identifier (URI): Generic Syntax", STD 66, RFC 3986, January 2005.
[^rfc6901]: Bryan, P., Ed., Zyp, K., and M. Nottingham, Ed., "JavaScript Object Notation (JSON) Pointer", RFC 6901, April 2013.
