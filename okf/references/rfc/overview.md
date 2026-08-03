---
type: Specification
title: IETF RFCs referenced by JSON Schema
description: Normative IETF documents behind URI resolution, JSON Pointer and format attributes, mirrored locally.
tags: [rfc, specification, uri, json-pointer, format]
status: stable
sources:
  - id: rfc1123
    resource: https://www.rfc-editor.org/rfc/rfc1123.txt
    title: Requirements for Internet Hosts -- Application and Support, STD 3, RFC 1123
  - id: rfc2673
    resource: https://www.rfc-editor.org/rfc/rfc2673.txt
    title: Binary Labels in the Domain Name System, RFC 2673
  - id: rfc3339
    resource: https://www.rfc-editor.org/rfc/rfc3339.txt
    title: 'Date and Time on the Internet: Timestamps, RFC 3339'
  - id: rfc3986
    resource: https://www.rfc-editor.org/rfc/rfc3986.txt
    title: 'Uniform Resource Identifier (URI): Generic Syntax, STD 66, RFC 3986'
  - id: rfc4122
    resource: https://www.rfc-editor.org/rfc/rfc4122.txt
    title: A Universally Unique IDentifier (UUID) URN Namespace, RFC 4122
  - id: rfc4291
    resource: https://www.rfc-editor.org/rfc/rfc4291.txt
    title: IP Version 6 Addressing Architecture, RFC 4291
  - id: rfc5321
    resource: https://www.rfc-editor.org/rfc/rfc5321.txt
    title: Simple Mail Transfer Protocol, RFC 5321
  - id: rfc6570
    resource: https://www.rfc-editor.org/rfc/rfc6570.txt
    title: URI Template, RFC 6570
  - id: rfc6901
    resource: https://www.rfc-editor.org/rfc/rfc6901.txt
    title: JavaScript Object Notation (JSON) Pointer, RFC 6901
---

# Documents

* [RFC 1123](rfc1123.txt) - Local mirror of the Internet host requirements, source of the hostname syntax.[^rfc1123]
* [RFC 2673](rfc2673.txt) - Local mirror of the DNS binary labels document, source of the dotted-quad syntax.[^rfc2673]
* [RFC 3339](rfc3339.txt) - Local mirror of the Internet timestamp format and the ISO 8601 collected ABNF.[^rfc3339]
* [RFC 3986](rfc3986.txt) - Local mirror of the URI generic syntax standard.[^rfc3986]
* [RFC 4122](rfc4122.txt) - Local mirror of the UUID URN namespace specification.[^rfc4122]
* [RFC 4291](rfc4291.txt) - Local mirror of the IPv6 addressing architecture.[^rfc4291]
* [RFC 5321](rfc5321.txt) - Local mirror of SMTP, source of the Mailbox grammar.[^rfc5321]
* [RFC 6570](rfc6570.txt) - Local mirror of the URI Template specification.[^rfc6570]
* [RFC 6901](rfc6901.txt) - Local mirror of the JSON Pointer specification.[^rfc6901]

RFC 3986 и RFC 6901 нормативны для JSON Schema Core в обоих диалектах: на них держатся разрешение ссылок и адресация внутри документа. Остальные семь документов нормативны для отдельных format attributes и названы разделом 7.3 части Validation ([validation.txt:723](../json-schema/draft-2020-12/validation.txt)).

Опубликованный RFC неизменен, поэтому происхождение не нуждается в закреплении коммитом, и эта директория не подчиняется [playbook обновления upstream](../../playbooks/update-json-schema-upstreams.md).

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

# Sections behind format attributes

Секция названа для каждого attribute, который валидатор проверяет сам. Имена с документированным исключением и имена вне IETF перечислены ниже отдельно.

| Format | Нормативная секция |
| --- | --- |
| `date-time` | RFC 3339, 5.6 ([rfc3339.txt:399](rfc3339.txt)) вместе с ограничениями 5.7 ([rfc3339.txt:455](rfc3339.txt)) |
| `date` | RFC 3339, правило `full-date` в 5.6 ([rfc3339.txt:399](rfc3339.txt)) |
| `time` | RFC 3339, правило `full-time` в 5.6 ([rfc3339.txt:399](rfc3339.txt)) и leap second в 5.7 ([rfc3339.txt:455](rfc3339.txt)) |
| `duration` | RFC 3339, Appendix A ([rfc3339.txt:623](rfc3339.txt)); само правило — [rfc3339.txt:726](rfc3339.txt) |
| `email` | RFC 5321, `Mailbox` в 4.1.2 ([rfc5321.txt:2314](rfc5321.txt)), address literal 4.1.3 ([rfc5321.txt:2380](rfc5321.txt)), пределы длины 4.5.3.1 ([rfc5321.txt:3460](rfc5321.txt)) |
| `hostname` | RFC 1123, 2.1 ([rfc1123.txt:720](rfc1123.txt)) |
| `ipv4` | RFC 2673, 3.2 ([rfc2673.txt:105](rfc2673.txt)) |
| `ipv6` | RFC 4291, 2.2 ([rfc4291.txt:179](rfc4291.txt)); встроенный IPv4 — 2.5.5 ([rfc4291.txt:523](rfc4291.txt)) |
| `uri`, `uri-reference` | RFC 3986, Appendix A ([rfc3986.txt:2695](rfc3986.txt)) и классификация ссылок 4.1-4.3 ([rfc3986.txt:1393](rfc3986.txt)) |
| `uuid` | RFC 4122, 3 ([rfc4122.txt:139](rfc4122.txt)); ABNF строковой формы — [rfc4122.txt:178](rfc4122.txt) |
| `uri-template` | RFC 6570, 2 ([rfc6570.txt:679](rfc6570.txt)); грамматика — [rfc6570.txt:685](rfc6570.txt) |
| `json-pointer` | RFC 6901, 5 ([rfc6901.txt:207](rfc6901.txt)) |

Для `hostname` спецификация называет RFC 1123 и добавляет упоминание punycode со ссылкой на RFC 5891. Отдельного текста последний не требует: punycode-метка остаётся обычной LDH-меткой, и правила раздела 2.1 покрывают её целиком.

Официальный сьют требует от `hostname` большего: отдельная группа `hostname.json` декодирует метку `xn--…` и проверяет её содержимое правилами IDNA2008. Это выходит за нормативный текст, поэтому группа объявлена расхождением в [conformance-policy](../../testing/conformance-policy.md#известные-расхождения). Это же документированное исключение покрывает четыре IDN/IRI-имени; зеркало RFC 5891 в текущий профиль не входит.

RFC 5321 обновляет RFC 1123, поэтому расхождения по синтаксису домена между двумя зеркалами нет: SMTP берёт имя хоста в том же виде.

RFC 9562 заменил RFC 4122 в 2024 году, но спецификация ссылается именно на 4122, а строковая форма UUID в обоих документах одна и та же.

# Documents deliberately not mirrored

RFC 3987 (IRI), RFC 5890 и RFC 5891 (IDNA), RFC 6531 (SMTPUTF8) нормативны для четырёх format attributes — `iri`, `iri-reference`, `idn-hostname` и `idn-email`, — которые являются документированным исключением профиля. Пока эти имена остаются чистой annotation, тексты валидатору не нужны.

Relative JSON Pointer, задающий `relative-json-pointer`, статуса RFC не имеет и остаётся Internet-Draft организации JSON Schema. Зеркало лежит рядом с диалектами, в [bundle JSON Schema](../json-schema/relative-json-pointer/).

ECMA-262, задающий `regex`, документом IETF не является. Подмножество, которое валидатор обязан принимать, названо в самой спецификации, а разница движков измерена в [«Адаптациях ECMA-262 к PCRE»](../../architecture/ecma-to-pcre-adaptation.md).

RFC 8141 (URN) не является нормативной ссылкой JSON Schema: `urn:` в обязательном `ref.json` разбирается как обычный URI по RFC 3986, без знания структуры namespace. RFC 8259 нормативен для JSON Schema, но модель значения валидатора уже зафиксирована в [validator-core](../../architecture/validator-core.md) и в тексте RFC не нуждается.

[^rfc1123]: Braden, R., Ed., "Requirements for Internet Hosts - Application and Support", STD 3, RFC 1123, October 1989.
[^rfc2673]: Crawford, M., "Binary Labels in the Domain Name System", RFC 2673, August 1999.
[^rfc3339]: Klyne, G. and C. Newman, "Date and Time on the Internet: Timestamps", RFC 3339, July 2002.
[^rfc3986]: Berners-Lee, T., Fielding, R., and L. Masinter, "Uniform Resource Identifier (URI): Generic Syntax", STD 66, RFC 3986, January 2005.
[^rfc4122]: Leach, P., Mealling, M., and R. Salz, "A Universally Unique IDentifier (UUID) URN Namespace", RFC 4122, July 2005.
[^rfc4291]: Hinden, R. and S. Deering, "IP Version 6 Addressing Architecture", RFC 4291, February 2006.
[^rfc5321]: Klensin, J., "Simple Mail Transfer Protocol", RFC 5321, October 2008.
[^rfc6570]: Gregorio, J., Fielding, R., Hadley, M., Nottingham, M., and D. Orchard, "URI Template", RFC 6570, March 2012.
[^rfc6901]: Bryan, P., Ed., Zyp, K., and M. Nottingham, Ed., "JavaScript Object Notation (JSON) Pointer", RFC 6901, April 2013.
