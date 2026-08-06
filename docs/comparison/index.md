# Comparison with jesse and jsonschex

`valid_json` is new, so a claim that it is good is worth little on its own. This
comparison is meant as a checklist instead: it puts the library next to the two
closest alternatives and states, feature by feature, what each of them does.

The alternatives are [jesse](https://github.com/for-GET/jesse), the established
JSON Schema validator for Erlang, and
[jsonschex](https://github.com/xinz/jsonschex), a Draft 2020-12 implementation
for Elixir. Everything below was read from the sources of the exact revisions
listed here.

## What was measured

| Library | Version | Commit | Commit date |
| --- | --- | --- | --- |
| `valid_json` | 0.2.2, not published on hex | `838e3a8` | 2026-08-06 |
| jesse | 1.8.2 (the tag points at `master`) | `d06868f` | 2025-09-28 |
| jsonschex | 0.9.0 (the release commit) | `3572664` | 2026-07-23 |

Checked on 2026-08-06, and on that date only the `valid_json` column was read
again: jesse and jsonschex are still described from the revisions listed above.
Later releases of either project may have moved on; the version and commit are
recorded so that you can tell how stale this page is.

## The three libraries in a sentence each

**jesse** is the incumbent. It has been around long enough to be a dependency of
other packages, it is written in plain Erlang with no dependencies, and it also
ships as a command-line tool and a Docker image. It implements draft 03, draft
04, and draft 06, and it has not followed the specification past that point.

**jsonschex** implements Draft 2020-12 in full and reports passing 100% of the
official test suite for that dialect, with `optional/cross-draft` excluded. It
is an Elixir library: usable from Erlang, but it brings the Elixir toolchain and
a struct-shaped API with it.

**valid_json** implements Draft 2020-12 and Draft 2019-09, including references
across the two, and reports results in the four output formats of the
specification. It is built as an OTP application: schemas are compiled once when
they are registered, artifacts live in ETS under supervision, and the registry
never touches the network. A schema needed just once does not have to be
registered at all — `run_schema/3` compiles and evaluates it in the calling
process.

## Checklist

| | valid_json | jesse | jsonschex |
| --- | --- | --- | --- |
| Language | Erlang/OTP 20+ | Erlang | Elixir ~> 1.14 |
| License | Apache 2.0 | Apache 2.0 | MIT |
| Dialects | 2020-12, 2019-09, cross-draft | draft 03, 04, 06 | 2020-12 |
| Runtime dependencies | none | none | optional `jason`, `decimal`, `idna` |
| Result of a validation | standard `flag`, `basic`, `detailed`, `verbose` output | own error tuples | own error structs |
| Annotations | collected | not collected | not collected |
| Where the schema lives | compiled into an ETS artifact when registered | raw in a global ETS table, walked on every validation | in a struct held by the caller |
| Validating with an unregistered schema | `run_schema/3`, compiling anew on every call; the schema has to stand on its own | `validate_with_schema/2,3` | the compiled struct is the normal case |
| Naming a document | its own `$id` via `add/1`, or a name from outside via `add_at/1,2` | the key given to `add_schema/2` | the compiled struct has no name |
| Network at runtime | never | possible: unknown `$ref` may be fetched over `http:` | whatever your loader does |
| `unevaluatedProperties` / `unevaluatedItems` | yes | no | yes |
| `$dynamicRef` / `$dynamicAnchor` | yes | no | yes |
| `$recursiveRef` / `$recursiveAnchor` | yes | no | no |
| `$vocabulary` and custom meta-schemas | yes, meta-schemas come from the store | no | yes, the meta-schema comes from your loader |
| Schema checked against its meta-schema on registration | yes | no | no |
| `format` as an assertion | opt-in per store, 15 formats | always on, 7 formats | opt-in per compile, full set |
| `contentEncoding` / `contentMediaType` / `contentSchema` | annotations only | not implemented | checked when enabled |
| Regular expression dialect | PCRE as-is | PCRE as-is | ECMA-262 patterns are adapted |
| `multipleOf` arithmetic | doubles | doubles | `decimal` when the dependency is present |
| Command-line tool | no | yes, escript and Docker | no |

## Which one to reach for

Take **jesse** if draft 04 or draft 06 is what your schemas are written against,
if you want a validator that a lot of production Erlang already runs, or if you
need to validate files from a shell script.

Take **jsonschex** if you are writing Elixir and want Draft 2020-12 with the
sharp edges filed down: ECMA-262 regular expressions, decimal `multipleOf`,
internationalized formats, content assertions, and an entry point into a
fragment of a larger document such as an OpenAPI file.

Take **valid_json** if you are writing Erlang and need Draft 2020-12 or Draft
2019-09, if you want the standard output formats rather than a bespoke error
shape, or if your schemas should be a supervised, offline part of a release
rather than something fetched at validation time. A schema that arrives with the
request is not shut out — `run_schema/3` takes it — but it pays for compilation
every time, so the store is still where a schema used more than once belongs.

## The details

- [API](api.md) — the functions each library exposes, the options they take, and
  the shape of what they return.
- [Architecture](architecture.md) — where the schema lives, when it is compiled,
  and what that means for running the thing.
- [Keyword and feature coverage](keywords.md) — keyword by keyword, plus
  `format`, `content*`, regular expressions, and numbers.
