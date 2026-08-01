---
type: Architecture Note
title: Validator value model notes
description: Измерения OTP и fixture evidence для JSON equality, Unicode length, numeric precision и multipleOf.
tags: [json-schema, erlang, otp, unicode, floating-point, evidence]
status: draft
---

# Роль документа

Это supporting note к [validator-core](validator-core.md), а не дополнительный нормативный контракт. Здесь сохранены эксперименты и длинные доказательства, из которых выведены решения value model. При смене OTP или декодера измерения нужно повторить; форма IR от этого автоматически не меняется.

# Отображение и равенство

`json:decode/1` OTP 27 возвращает integer для целого литерала, double для дробного, binary для строки, list для массива и map с binary keys для объекта. Отображение инъективно вне чисел: `<<"null">> =/= null`, `<<>> =/= []`, `<<"true">> =/= true`.

Erlang `==` даёт нужное рекурсивное JSON equality:

```erlang
1 == 1.0                                     % true
#{<<"a">> => [1, #{}]} ==
  #{<<"a">> => [1.0, #{}]}                 % true
true == 1                                    % false
null == <<"null">>                          % false
[] == <<>>                                   % false
9007199254740993 == 9007199254740992.0       % false
```

Последний случай подтверждает, что сравнение bignum с float не сводит оба значения к неточному double. Поэтому cases «float and integers are equal up to 64-bit representation limits» из `const.json` не требуют своей арифметики.

Потеря порядка и duplicate object keys не наблюдаема keywords: порядок объектов семантически незначим, а поведение на duplicates RFC 8259 оставляет неопределённым.

# Границы double

| Литерал | Поведение OTP 27 | Влияние |
| --- | --- | --- |
| integer любой величины | точный bignum | integer block `optional/bignum` проходит |
| `1e400` | decoder exception | suite не требует такого JSON value |
| больше 17 значащих цифр | nearest double | два high-precision cases вне профиля |

Точный decimal можно получить через `json:decode/3` с `#{float => Fun}`: callback видит исходный token, например `<<"0.1">>`. Цена не локальна в `multipleOf`: новый терм занимает место каждого `float()` в schema и instance. Тогда вручную переписываются equality (`const`, `enum`, `uniqueItems`), numeric comparisons, annotation serialization и поведение overflow literals. Точная schema-side дробь отдельно не помогает, потому что instance-side `0.3` уже округлён.

# Доказательство границы multipleOf

Обязательные и overflow fixtures зажимают реализацию тремя cases:

| Schema | Data | Expected |
| --- | --- | --- |
| `multipleOf: 0.0001` | `0.0075` | true |
| `type: integer`, `multipleOf: 0.5` | `1e308` | true |
| `type: integer`, `multipleOf: 0.123456789` | `1e308` | false |

Обычное деление переполняется на последних двух. Гибрид core делает `rem` для integers, проверяет целочисленность представимого quotient и при overflow раскладывает double в точную двоичную дробь. В частности:

```text
0.5         = 1 / 2^1
0.123456789 = 8895999182988127 / 2^56
```

Так оба overflow cases получают правильный ответ на bignum, а `0.0075 / 0.0001` в OTP даёт ровно `75.0`.

Граница не устраняется точной обработкой уже декодированных doubles:

```text
nearest(0.1) = 7205759403792794 / 2^56
nearest(0.3) = 5404319552844595 / 2^54
0.3 / 0.1    = 2.9999999999999996
```

Вторая дробь не делится на первую нацело даже в точной bignum arithmetic. Поэтому schema `multipleOf: 0.1` может отвергнуть JSON literal `0.3`, хотя десятичное определение keyword требует принять его. Потеря произошла в decoder, не в выбранной ветви алгоритма.

В обязательном suite каждого dialect одиннадцать scenarios `multipleOf`; используются `2`, `1.5`, `0.0001`, `0.123456789` и `1e-8`. Контрпримера `0.3 / 0.1` нет, поэтому ограничение объявлено словами в [conformance policy](../testing/conformance-policy.md), а не красным fixture.

# Unicode length

JSON Schema считает string length в Unicode code points. `string:length/1` считает grapheme clusters и отвечает иначе:

| Значение | Code points | `string:length/1` |
| --- | ---: | ---: |
| ASCII CR, LF между `a` и `b` | 4 | 3 |
| `e` и следующий U+0301 | 2 | 1 |
| U+1100 U+1161 | 2 | 1 |
| 👨‍👩‍👧 | 5 | 1 |
| 💩 | 1 | 1 |

Пара CR/LF уже показывает расхождение на ASCII: Unicode grapheme segmentation считает её одним cluster. Decoder не нормализует combining sequence: `e` и U+0301 остаются binary `<<101, 204, 129>>`, то есть нормативный `cp_length/1` возвращает 2.

Обязательные `maxLength.json` и `minLength.json` обоих dialects различают bytes/UTF-16 units от characters через 💩, но не различают code points от clusters: там обе нужные метрики равны 1. Combining sequences встречаются только в optional `format/idn-*`, не в length tests.

# Валидность UTF-8 и стоимость прохода

OTP 27 decoder отвергает:

- битый байт `255` как `{invalid_byte, 255}`;
- overlong start byte `192` как `{invalid_byte, 192}`;
- одиночный surrogate U+D83D как `unexpected_end`.

Поэтому pattern `<<_/utf8, Rest/binary>>` тотален на каждом `json()` string. На произвольном binary он таким не является, но arbitrary binary не входит в value model.

Для валидного UTF-8 каждый code point занимает 1–4 bytes:

```text
byte_size(B) div 4 =< code_points(B) =< byte_size(B)
```

Отсюда быстрые ответы:

- `maxLength: M`: `byte_size(B) =< M` — true, `byte_size(B) > 4*M` — false;
- `minLength: M`: `byte_size(B) < M` — false, `byte_size(B) >= 4*M` — true.

Сканирование нужно только в промежутке и тогда ограничено `4*M`, а не полным размером враждебного instance. `length(unicode:characters_to_list(B))` отвергнут: он всегда строит список cons cells и не использует эти O(1) границы.

# Что перепроверять при смене среды

1. Термы `json:decode/1` для integer, float, invalid UTF-8 и surrogate.
2. Точное сравнение bignum/float через `==`.
3. Quotients и IEEE-754 decompositions из раздела `multipleOf`.
4. `string:length/1` на таблице Unicode examples.
5. Обязательные/optional fixture counts, если обновился snapshot suite.
