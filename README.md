# valid_json

Modern JSON Schema validation for Erlang/OTP.

`valid_json` is an Erlang/OTP library that validates JSON instances against
JSON Schema Draft 2020-12 and Draft 2019-09, including references across the
two dialects. Schemas are compiled once when they are registered and are then
validated against in one of the four standard output formats. The registry is
offline — no network requests are made during validation.

[![CI](https://github.com/Regikul/valid_json/actions/workflows/ci.yml/badge.svg)](https://github.com/Regikul/valid_json/actions/workflows/ci.yml)

## Why valid_json?

`valid_json` fills the niche of a modern JSON Schema validator for Erlang.
[jesse](https://github.com/for-GET/jesse), the incumbent Erlang validator, has
not followed the specification past draft 06. [jsonschex](https://github.com/xinz/jsonschex)
implements Draft 2020-12 in full, but it is an Elixir library: using it from
Erlang brings the Elixir toolchain and a struct-shaped API into your build.

If you are writing Erlang and need Draft 2019-09 or Draft 2020-12, `valid_json`
provides modern JSON Schema support without requiring an Elixir-based
validation stack.

| Feature | valid_json | jesse | jsonschex |
| --- | --- | --- | --- |
| Erlang-native | yes | yes | no (Elixir) |
| Draft 2020-12 | yes | no (drafts 03, 04, 06) | yes |
| Draft 2019-09 | yes | no | no |
| Cross-draft references | yes | no | no |
| `$dynamicRef` / `$recursiveRef` | yes | no | `$dynamicRef` only |
| `unevaluatedProperties` / `unevaluatedItems` | yes | no | yes |
| Standard output formats | `flag`, `basic`, `detailed`, `verbose` | own error tuples | own error structs |
| Runtime dependencies | none | none | optional `jason`, `decimal`, `idna` |
| Network at validation time | never | possible for unknown `$ref` | whatever your loader does |

See the full comparison in [docs/comparison](docs/comparison/index.md) — API,
architecture, and keyword-by-keyword coverage, measured against jesse 1.8.2 and
jsonschex 0.9.0.

## Installation

The package is not published on [Hex](https://hex.pm) yet; add it as a Git
dependency, pinned to the latest tag:

```erlang
{deps, [
    {valid_json, {git, "https://github.com/Regikul/valid_json.git", {tag, "v0.2.2"}}}
]}.
```

## Quick start

Start the application so that the built-in meta-schemas are published, then
validate.

### Validate a schema once

`run_schema/3` compiles the schema in the calling process and validates the
instance right away — nothing is kept:

```erlang
{ok, _} = application:ensure_all_started(valid_json),

Schema = #{<<"type">> => <<"integer">>, <<"minimum">> => 0},
{ok, #{<<"valid">> := true}} =
    valid_json:run_schema(Schema, 5, [{output, flag}]).
```

### Compile once, validate many times

Register the schema under its `$id`, then validate by name. Registration
compiles the schema; every validation after that is a lookup:

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

Registered schemas are compiled once and reused. Artifacts are stored in a
supervised ETS table, so a schema used more than once belongs in a store; a
schema that arrives with a single request can use `run_schema/3`, at the price
of compiling it on every call.

## Features

### Supported dialects

- JSON Schema Draft 2020-12
- JSON Schema Draft 2019-09
- Cross-draft references between the two

### References and schema resources

- `$id`, `$anchor`, `$defs`, `$ref`
- `$dynamicRef` / `$dynamicAnchor` (Draft 2020-12)
- `$recursiveRef` / `$recursiveAnchor` (Draft 2019-09)
- `$vocabulary`, built-in meta-schemas, and user-provided meta-schemas from the
  store
- References are resolved eagerly at compile time, so a reference closure is a
  finite, comparable value — cyclic schemas are not a problem

### Validation

- All standard assertion keywords: `type`, `enum`, `const`, numeric bounds,
  `pattern`, length and collection-size keywords, `uniqueItems`, `required`,
  `dependentRequired`
- Applicators: `allOf`, `anyOf`, `oneOf`, `not`, `if` / `then` / `else`,
  `dependentSchemas`
- Object applicators: `properties`, `patternProperties`,
  `additionalProperties`, `propertyNames`
- Array applicators: `prefixItems`, `items`, `contains`, `minContains`,
  `maxContains`, plus the Draft 2019-09 array form of `items` and
  `additionalItems`
- `unevaluatedProperties` and `unevaluatedItems`

### Output

- The four standard output formats of the specification: `flag`, `basic`,
  `detailed`, and `verbose`

### Registry and storage

- Schemas are compiled once on registration; artifacts live in a supervised
  ETS table
- Transactional reload and removal with dependency checking — a document that
  others reference cannot be removed
- A directory loader reads `.json` files recursively at startup
- `run_schema/3` for schemas that are used once

## Schema references and the registry

The registry is deliberately offline: documents reachable through `$ref` must
be registered before compilation. No network requests are made at runtime, so
validation is deterministic, has no latency from fetching, and exposes no
fetching surface for untrusted schemas.

A document is addressed by its `$id`; a schema that declares none can be named
from the outside with `add_at/1,2` or by the loader. Sets of documents that
reference one another are registered in one call, because references are
resolved eagerly:

```erlang
{ok, [CanonicalUriA, CanonicalUriB]} = valid_json:add([SchemaA, SchemaB]).
```

The full identifier model — `$id`, `base_uri`, relative names, embedded
resources, and the directory loader — is described in
[Schema resources and identifiers](docs/schema-resources.md).

## Output formats

Validation returns the standard output document of the specification, so `{ok,
Output}` may well describe a failed validation — `valid` is a field inside
`Output`, not the shape of the return. The address itself may be a relative,
short name: on a miss it is resolved against the store's `base_uri` before
reporting `not_found`.

```erlang
{ok, #{<<"valid">> := false, <<"errors">> := [_ | _]}} =
    valid_json:validate(RelativelUri, #{<<"name">> => 42}, [{output, detailed}]).
```

`{error, Reason}` is reserved for not getting as far as evaluating:
`not_found`, `unavailable`, or an evaluation error.

## Specification compliance

`valid_json` runs the official
[JSON Schema Test Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite)
for both dialects. The pinned conformance run executes **792 test groups and
3547 test cases** — the whole validation suite, including the declared
capability profiles, minus the declared exclusions — plus the **8 official
output test cases** and 41 remote documents used by `refRemote` tests. Remote
documents are registered in advance; the validation run itself makes no network
requests.

The declared capability profiles are:

- `optional/` files whose schemas compile within the supported dialects,
  including `optional/id`, `optional/unknownKeyword`, and `optional/cross-draft`;
- a `format` profile — the `optional/format/` files, compiled with
  `{assert_format, true}` — covering 16 files per dialect (the four IDN/IRI
  files are declared exclusions);
- the official output tests, which pin the `basic` format; `flag`, `detailed`,
  and `verbose` are covered by the project's own golden tests, because the
  official suite does not exercise them.

Every schema resource is checked against its own meta-schema when it is
compiled; a schema that fails its meta-schema is rejected at registration.
The conformance policy, including the exact list of files, excluded groups, and
the pinned census, lives in [okf/testing/conformance-policy.md](okf/testing/conformance-policy.md).

### Format

`format` is collected as an **annotation** by default in both dialects.
Format assertions are opt-in: compiling with `{assert_format, true}` enables
string checking for the implemented formats. An annotation is still collected
for a passing value, and a value of a non-string type always passes.

```erlang
Schema = #{<<"format">> => <<"ipv4">>},

%% Annotation only: the string passes, whatever it contains.
{ok, #{<<"valid">> := true}} =
    valid_json:run_schema(Schema, <<"999.1.1.1">>, []),

%% With assertions enabled, the value is checked.
{ok, #{<<"valid">> := false}} =
    valid_json:run_schema(Schema, <<"999.1.1.1">>,
                          [{assert_format, true}]).
```

| | Formats |
| --- | --- |
| Assertion (with `assert_format`) | `date`, `time`, `date-time`, `duration`, `ipv4`, `ipv6`, `hostname`, `email`, `uri`, `uri-reference`, `uri-template`, `json-pointer`, `relative-json-pointer`, `uuid`, `regex` — 15 formats |
| Annotation only, by declaration | `idn-email`, `idn-hostname`, `iri`, `iri-reference` |

Unknown format names always pass and still produce an annotation. The
Format-Assertion vocabulary is not claimed: a meta-schema that declares it
`true` is rejected, as the specification requires of an implementation that
does not check every format name. `contentEncoding`, `contentMediaType`, and
`contentSchema` are annotations and do not decode or validate string content.

The per-format algorithms and their exact boundaries are documented in
[okf/architecture/format-attributes.md](okf/architecture/format-attributes.md).

## Known limitations

- **Regular expression dialect.** `pattern`, `patternProperties`, and
  `format: regex` are compiled with Erlang's `re` module, which is PCRE rather
  than ECMA-262. A pattern outside the subset shared by both dialects — for
  example `\p{Letter}` — fails to compile and the whole schema is rejected.
  The ECMA-262/PCRE differences are measured in
  [okf/architecture/ecma-to-pcre-adaptation.md](okf/architecture/ecma-to-pcre-adaptation.md).
- **IDN and IRI formats.** `idn-email`, `idn-hostname`, `iri`, and
  `iri-reference` are always annotations: the string itself is not checked.
  This is a declared exclusion of the profile, not a temporary gap.
- **`hostname` and A-labels.** An `xn--…` label is treated as an ordinary LDH
  label: A-labels are not decoded and IDNA2008 rules are not applied to their
  contents.
- **Numeric precision.** `multipleOf` and numeric comparisons are computed on
  doubles, so a decimal fraction with no exact binary representation can
  disagree with decimal arithmetic.
- **Content keywords.** `contentEncoding`, `contentMediaType`, and
  `contentSchema` are annotations only; string content is not decoded.

## Documentation

- [Comparison with jesse and jsonschex](docs/comparison/index.md) — the full
  checklist, split into [API](docs/comparison/api.md),
  [architecture](docs/comparison/architecture.md), and
  [keyword coverage](docs/comparison/keywords.md)
- [Schema resources and identifiers](docs/schema-resources.md) — naming,
  the registry, the loader, and custom stores
- [okf/](okf/index.md) — normative documents: architecture, core contract,
  conformance policy, and format attributes
- [ROADMAP.md](ROADMAP.md) — the implementation checklist, phase by phase

## Requirements

- Erlang/OTP **20 or later**. CI runs the full suite (compile, conformance,
  EUnit) on OTP 20 through 29.
- [rebar3](https://rebar3.org/)

OTP releases before 27 use vendored copies of the stdlib `json` and `uri_string`
modules, taken from OTP 28.1.1 and compiled only on the old releases. This is
what keeps `{deps, []}` empty — the library has no third-party dependencies, on
any OTP version. See [THIRD_PARTY.md](THIRD_PARTY.md).

## Development

```shell
rebar3 compile
rebar3 eunit
rebar3 conformance
```

`conformance` is an alias that runs the conformance profiles alone — the JSON
Schema Test Suite and the official output tests — without the remaining unit
tests. In CI, the `ci` profile turns compiler warnings into errors and runs
`rebar3 as ci compile`, `rebar3 as ci conformance`, and `rebar3 as ci eunit`.

## Project status

`valid_json` is version 0.2.2 and is under active development. Draft 2020-12
and Draft 2019-09 are supported within the conformance profile declared above;
the remaining work is tracked in [ROADMAP.md](ROADMAP.md) — the `format`
profiles and optional capability profiles of phase P8, the HTTP loader, and
the cross-cutting items.

The records' `reason` and `location` fields are the stable error contract; the
wording produced by `format_error/1` is an implementation detail and may change.
The public API may have breaking changes before 1.0.

## License

Licensed under the [Apache License 2.0](LICENSE.md).