# valid_json

[![CI](https://github.com/Regikul/valid_json/actions/workflows/ci.yml/badge.svg)](https://github.com/Regikul/valid_json/actions/workflows/ci.yml)

`valid_json` is an Erlang/OTP library for validating JSON instances against
[JSON Schema](https://json-schema.org/).

The implementation is under active development. See the
[roadmap](ROADMAP.md) for the current conformance and feature status.

## Supported features

- JSON Schema Draft 2020-12 and Draft 2019-09.
- Cross-draft schema resources and references.
- Schema compilation from inline documents or a pre-populated document store.
- URI resolution and schema resources using `$id`, `$anchor`, `$defs`, and
  `$ref`, including references to other registered documents.
- Draft 2020-12 dynamic references (`$dynamicAnchor` and `$dynamicRef`) and
  Draft 2019-09 recursive references (`$recursiveAnchor` and `$recursiveRef`).
- Assertions and applicators for scalar, array, and object values, including
  conditionals, dependent schemas, `contains`, and `unevaluated*` keywords.
- `$vocabulary`, built-in metaschemas, and user-provided metaschemas from the
  document store.
- Standard validation output formats: `flag`, `basic`, `detailed`, and
  `verbose`.

The registry is deliberately offline: documents reachable through `$ref` must
be registered before compilation or validation. No network requests are made
at runtime.

`format` is collected as an annotation by default. Opt-in format assertions are
available for the implemented built-in formats; IDN and IRI formats remain
annotations. `contentEncoding`, `contentMediaType`, and `contentSchema` are
annotations and do not decode or validate string content.

## Not supported

Every mandatory file of the JSON Schema Test Suite is run for both dialects.
The list below is what both Draft 2020-12 and Draft 2019-09 ask for and the
library does not do.

| Area | What is not supported |
| --- | --- |
| Regular expression dialect | `pattern`, `patternProperties`, and `format: regex` are compiled with the `re` module, which is PCRE rather than ECMA-262. A pattern outside the subset shared by both dialects — `\p{Letter}`, for example — fails to compile and the whole schema is rejected |
| Format-Assertion vocabulary | Not all format names of the specification are checked, so a metaschema that requires this vocabulary is rejected. Format assertions are enabled with the `assert_format` compile option instead |
| `idn-email`, `idn-hostname`, `iri`, `iri-reference` | Always annotations, even with assertions enabled: the string itself is not checked |
| `hostname` | An `xn--…` label is treated as an ordinary label: A-labels are not decoded and IDNA2008 rules are not applied to their contents |
| Numeric precision | `multipleOf` and numeric comparisons are computed on doubles, so a decimal fraction with no exact binary representation can disagree with decimal arithmetic |

## Comparison

`valid_json` is new. To help you decide whether it fits, here is how it lines up
against the two closest alternatives — [jesse](https://github.com/for-GET/jesse)
for Erlang and [jsonschex](https://github.com/xinz/jsonschex) for Elixir.

| | valid_json | jesse | jsonschex |
| --- | --- | --- | --- |
| Dialects | 2020-12, 2019-09 | draft 03, 04, 06 | 2020-12 |
| Output | standard `flag`, `basic`, `detailed`, `verbose` | own error tuples | own error structs |
| Registry | offline, pre-populated, in ETS under supervision | global ETS, may fetch over HTTP | inside the compiled struct, filled by your loader |

The full comparison lives in [docs/comparison](docs/comparison/index.md), split
into [API](docs/comparison/api.md),
[architecture](docs/comparison/architecture.md), and
[keyword and feature coverage](docs/comparison/keywords.md). It was measured
against jesse 1.8.2 and jsonschex 0.9.0 on 2026-08-05.

## Requirements

- Erlang/OTP 27 or later — the library decodes JSON with the `json` module
  from stdlib, which first appeared in OTP 27.
- [rebar3](https://rebar3.org/)

## Build and test

Compile the project with:

```shell
rebar3 compile
```

Run the EUnit and conformance test suite with:

```shell
rebar3 eunit
```

Run the conformance profiles alone — the JSON Schema Test Suite and the
official output tests, without the remaining unit tests:

```shell
rebar3 conformance
```

Start an interactive Erlang shell with the application loaded:

```shell
rebar3 shell
```

## Usage

### Validate against a schema value

`run_schema/3` takes the schema itself instead of its name: it compiles the
schema in the calling process and validates right away, without a store or a
started application. Such a schema has to stand on its own — the documents of a
store are not visible to it.

```erlang
{ok, #{<<"valid">> := true}} =
    valid_json:run_schema(
        #{<<"type">> => <<"integer">>, <<"minimum">> => 0},
        5,
        [{output, flag}]).
```

### Register a schema and validate by name

A schema used more than once belongs in a store: it is compiled once, and every
validation after that is a lookup by name. A schema names itself with `$id`.
Register it, then validate instances against that name:

```erlang
{ok, _} = application:ensure_all_started(valid_json),

Name = <<"https://example.com/schemas/user">>,
Schema = #{
    <<"$id">> => Name,
    <<"type">> => <<"object">>,
    <<"properties">> => #{
        <<"name">> => #{<<"type">> => <<"string">>}
    },
    <<"required">> => [<<"name">>]
},
{ok, [CanonicalUri]} = valid_json:add(Schema),

{ok, #{<<"valid">> := true}} =
    valid_json:validate(
        CanonicalUri,
        #{<<"name">> => <<"Ada">>},
        [{output, flag}]).
```

Schemas that reference one another must go in one call, because references are
resolved eagerly: `valid_json:add([SchemaA, SchemaB])`. See
[Schema names](#schema-names) for schemas that do not declare `$id`.

The default output format is `flag`. Select `basic`, `detailed`, or `verbose`
with the same `[{output, Format}]` option:

```erlang
{ok, Result} = valid_json:validate(
    CanonicalUri,
    #{<<"name">> => 42},
    [{output, detailed}]).
```

### Report a rejected schema

`add/1` and `remove/1` report failures as pairs of a document name and a schema
error. The error is a machine-readable record; `format_error/1` turns one into
human-readable text. A schema rejected before it got a name is reported under
the atom `anonymous`:

```erlang
case valid_json:add(Schema) of
    {ok, Names} ->
        Names;
    {error, {compilation, Errors}} ->
        [io:format("~ts: ~ts~n", [DocName, valid_json:format_error(Error)])
         || {DocName, Error} <- Errors]
end.
```

The wording is an implementation detail and may change; the record's `reason`
and `location` are the stable contract.

### Load schemas from a directory

The built-in directory loader recursively reads `.json` files into the standard
store when the application starts. For example, create
`priv/schemas/weight.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "integer",
  "minimum": 0
}
```

Configure the loader in `config/sys.config`:

```erlang
[
    {valid_json, [
        {loader, {valid_json_loader_dir, [
            {priv_dir, valid_json, "schemas"}
        ]}}
    ]}
].
```

The path is resolved inside the `priv` directory of the named application, which
is where a release keeps it — unlike a path relative to the current working
directory, it does not depend on where the node was started from. In your own
application, name that application instead. The loader stays inside the
directory it was given: it does not follow symbolic links but reports them as an
error.

Then start the shell and wait for the initial load to finish:

```shell
rebar3 shell
```

```erlang
{ok, _} = valid_json:wait(5000),
{ok, #{<<"valid">> := true}} =
    valid_json:validate(<<"weight.json">>, 5, [{output, flag}]).
```

The schema above declares no `$id`, so it is named by the path it was loaded
from — `weight.json`, with `.json` as the default extension. See
[Schema names](#schema-names) for the full rule.

### References and custom stores

For schemas with `$ref` links, register every document needed by the reference
closure in one call — `valid_json:add([SchemaA, SchemaB])`, or
`valid_json:add_at([{UriA, SchemaA}, {UriB, SchemaB}])` when the names come
from outside. References are resolved eagerly, and a document whose target is
not in the store yet is rejected. The store is pre-populated only; it never
fetches referenced documents over the network.

For a custom store, add `valid_json:store_child_spec/2` to your
application's supervision tree, then use the `valid_json` facade's `store_*`
functions, such as `valid_json:store_add/2` and `valid_json:store_validate/4`.
A store requires a `base_uri`: it is how the store claims its schemas for a
service, and two stores over the same directory under
`https://shop.service/schemas/` and `https://internal.service/schemas/` name
their documents apart.

## Schema names

A document is addressed by its `$id`. Nothing else is an address: a schema
registered under a path that also declares `$id` answers to the `$id` only, and
the path stays behind as the base against which its relative `$ref` resolve.

A relative `$id` is resolved against the `base_uri` of the store. The standard
store uses `https://valid_json.internal/schemas/`, so a schema with
`"$id": "weight"` is addressable as
`https://valid_json.internal/schemas/weight` and, in the short form resolved
against that `base_uri`, as `weight`. The `.internal` top-level domain is
reserved by ICANN for private use, so such a name never collides with an
address that something answers at. This is the implementation-defined default
base URI that RFC 3986 Section 5.1.4 permits and JSON Schema Section 9.1.1 asks
implementations to document.

A schema that declares no `$id` has to be named from the outside, and that is
what `add_at` is for. It takes one document, or a batch of them when they
reference each other:

```erlang
{ok, [Name]}  = valid_json:add_at(<<"allow">>, true),
{ok, [A, B]}  = valid_json:add_at([{<<"a">>, SchemaA}, {<<"b">>, SchemaB}]).
```

The loader does the same for a whole directory, naming each document by its
path relative to the root. Both kinds of path are relative, and the store's
`base_uri` makes them absolute — which is why the same set of files suits any
store.

The two doors do not overlap: `add/1` takes schemas and nothing else, `add_at`
takes named entries and nothing else. Which function you call is what decides
where the name comes from — never the shape of the argument.

A schema passed to `valid_json:add/1` without an `$id` is rejected with
`unnamed_schema`: the root of a document is always a schema resource and needs
an absolute name, and there is nothing to build one from. That includes the
boolean schemas `true` and `false`, which carry no keywords and therefore no
`$id` — they can only be registered by the loader or by `add_at`.

## License

Licensed under the [Apache License 2.0](LICENSE.md).
