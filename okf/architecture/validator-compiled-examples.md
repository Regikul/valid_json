---
type: Architecture Note
title: Validator compiled examples
description: Полные Erlang-термы compiled schema и fixture evidence для resources, refs, aliases и dialect inheritance.
tags: [json-schema, erlang, compiled-schema, examples, evidence]
status: draft
---

# Роль документа

Это supporting note к нормативным [validator-core](validator-core.md) и [resources/runtime](validator-resources-runtime.md). Здесь можно расширять примеры и измерения, не раздувая контракт реализации. Определения records и types находятся только в validator-core.

Во всех примерах:

```erlang
D = <<"https://json-schema.org/draft/2020-12/schema">>.
```

# Boolean schema

Для inline `true` полный артефакт имеет один anonymous resource:

```erlang
#{root => anonymous,
  sources => [],
  resources => #{
    anonymous =>
      #resource{id = undefined,
                dialect = D,
                anchors = #{},
                dynamic_anchors = #{},
                recursive_anchor = false,
                nodes = #{<<>> => true}}}}.
```

Boolean node не имеет keywords и не производит annotations. Локации строятся из `addr()` и eval context.

# Составное object constraint

Исходная схема:

```json
{
  "type": "object",
  "required": ["a"],
  "properties": {"a": {"type": "integer"}},
  "patternProperties": {"^x-": true},
  "additionalProperties": false
}
```

Терм после `Re = {<<"^x-">>, MP}`:

```erlang
#{root => anonymous,
  sources => [],
  resources => #{anonymous =>
    #resource{id = undefined,
      dialect = D,
      anchors = #{},
      dynamic_anchors = #{},
      recursive_anchor = false,
      nodes = #{
        <<>> => #node{unevaluated = [], constraints = [
          {type, [object]},
          {required, [<<"a">>]},
          {properties,
            #{<<"a">> => {anonymous, <<"/properties/a">>}},
            [{Re, {anonymous, <<"/patternProperties/^x-">>}}],
            {anonymous, <<"/additionalProperties">>}}]},
        <<"/properties/a">> =>
          #node{constraints = [{type, [integer]}], unevaluated = []},
        <<"/patternProperties/^x-">> => true,
        <<"/additionalProperties">> => false}}}}.
```

Три object keywords свёрнуты в один constraint, но каждая подсхема остаётся самостоятельным node. Поэтому evaluator строит фактические keyword locations, включая `/additionalProperties` и `/patternProperties/^x-`.

# Рекурсия через `$defs`

```json
{
  "$id": "https://example.com/tree",
  "$defs": {
    "node": {
      "type": "object",
      "properties": {
        "children": {
          "type": "array",
          "items": {"$ref": "#/$defs/node"}
        }
      }
    }
  },
  "$ref": "#/$defs/node"
}
```

```erlang
T = <<"https://example.com/tree">>,
#{root => T,
  sources => [],
  resources => #{T =>
    #resource{id = T,
      dialect = D,
      anchors = #{},
      dynamic_anchors = #{},
      recursive_anchor = false,
      nodes = #{
        <<>> => #node{constraints = [
          {ref, {T, <<"/$defs/node">>}}], unevaluated = []},

        <<"/$defs/node">> => #node{unevaluated = [], constraints = [
          {type, [object]},
          {properties,
            #{<<"children">> =>
                {T, <<"/$defs/node/properties/children">>}},
            undefined,
            undefined}]},

        <<"/$defs/node/properties/children">> =>
          #node{unevaluated = [], constraints = [
            {type, [array]},
            {items,
              {T, <<"/$defs/node/properties/children/items">>}}]},

        <<"/$defs/node/properties/children/items">> =>
          #node{constraints = [
            {ref, {T, <<"/$defs/node">>}}], unevaluated = []}}}}}.
```

`$defs` не производит constraint, но резервирует schema locations. Цикл замкнут адресами, поэтому артефакт конечен; бесконечный обход предотвращает active-frame guard, не форма IR.

# Embedded resource

```json
{
  "$id": "https://example.com/foo",
  "items": {
    "$id": "https://example.com/bar",
    "additionalProperties": {}
  }
}
```

```erlang
Foo = <<"https://example.com/foo">>,
Bar = <<"https://example.com/bar">>,
#{root => Foo,
  sources => [],
  resources => #{
    Foo => #resource{id = Foo,
      dialect = D,
      anchors = #{},
      dynamic_anchors = #{},
      recursive_anchor = false,
      nodes = #{
        <<>> => #node{unevaluated = [], constraints = [
          {items, {Bar, <<>>}}]}}},

    Bar => #resource{id = Bar,
      dialect = D,
      anchors = #{},
      dynamic_anchors = #{},
      recursive_anchor = false,
      nodes = #{
        <<>> => #node{unevaluated = [], constraints = [
          {properties, undefined, undefined,
            {Bar, <<"/additionalProperties">>}}]},
        <<"/additionalProperties">> =>
          #node{constraints = [], unevaluated = []}}}}}.
```

Pointer в `Bar` — `/additionalProperties`, не `/items/additionalProperties`. Синтаксическая вложенность документа заканчивается на resource boundary.

# Unknown keyword

```json
{"myCustom": {"sub": {"type": "string"}}}
```

Draft 2020-12:

```erlang
#node{unevaluated = [], constraints = [
  {annotation, <<"myCustom">>,
    #{<<"sub">> => #{<<"type">> => <<"string">>}}}]}.
```

`/myCustom/sub` не становится node: позиция не признана schema. В Draft 2019-09 unknown keyword игнорируется и `constraints = []`.

# Присутствие и defaults

Следующие формы намеренно различаются в IR:

```erlang
%% keyword отсутствует
#node{constraints = [], unevaluated = []}.

%% keyword написан и производит пустую annotation
#node{constraints = [
  {properties, #{}, undefined, undefined}], unevaluated = []}.

%% no-op assertion всё равно присутствует в verbose hierarchy
#node{constraints = [{min_length, 0}], unevaluated = []}.
```

В составных constraints `undefined` означает отсутствие keyword, а не его default. Например, у `{contains, Addr, undefined, undefined, true}` обработчик применяет default `minContains = 1`; если schema написала `minContains: 1`, в IR лежит integer `1` и присутствие не теряется.

# Fixture evidence: resources и dialects

Числа относятся к закреплённому snapshot JSON Schema Test Suite и нужны для оценки покрытия решений, а не для production-кода.

## Embedded resources

- В обоих обязательных наборах найдено 99 embedded resources без `$schema` в 17 files. Они требуют не отказывать в компиляции, но не различают inheritance от compile default: enclosing dialect всегда совпадает с entry dialect.
- Embedded `$schema` встречается один раз — группа `$ref` with `$recursiveAnchor` в `draft2019-09/ref.json`; он совпадает с enclosing dialect.
- Embedded resource с другим dialect в snapshot отсутствует. Возможность смены dialect держится на спецификации, не fixture.

## Anonymous roots

В обязательных и optional directories обоих dialects 807 schemas без корневого `$id`. Fragment-only refs внутри них допустимы: в основном наборе каждого dialect 24 groups используют `$ref: "#..."` без root `$id` — 25 с dynamic/recursive ref. Ссылок с относительным path и относительных embedded `$id` там нет.

В 14 anonymous documents есть absolute embedded `$id`; такой resource именован и доступен внутренней absolute reference. Пример находится в `anchor.json`, группа «Location-independent identifier with absolute URI».

## Remotes

В `remotes/` 41 file:

- 21 имеют root `$id`;
- у 4 `$id` отличается от retrieval path (`different-id-ref-string.json` и `urn-ref-string.json` в обоих dialects);
- 2 содержат embedded `$id`;
- у 6 нет `$schema` (`nested-absolute-ref-to-string`, `urn-ref-string`, `different-id-ref-string` в обоих dialects).

Все refs из tests используют retrieval URI. Cases с отличающимся `$id` проверяют, что retrieval alias не потерян. Embedded `$id` чужого, ещё не достигнутого document снаружи не адресуется; чтобы его обнаружить, compiler сначала должен иметь причину загрузить сам document.

## Vocabularies

Первая группа `draft2020-12/vocabulary.json` ссылается на registered metaschema без validation vocabulary. Applicator остаётся активным, поэтому `badProperty: false` под `properties` валит instance; `minimum: 10` становится unknown annotation; Core keywords продолжают работать. Вторая группа объявляет неизвестный vocabulary `false` и потому должна компилироваться.

## Meta-schema validation

Проверка snapshot показала 939 schemas без нарушений собственных meta-schemas:

- 755 groups обязательного набора обоих dialects;
- 143 optional groups;
- 41 remote document.

Это подтверждает возможность обязательной проверки schema resources, но не заменяет собственные negative compiler tests: официальный suite исходит из валидных schemas и не покрывает каталог `schema_error()`.
