# Keyword and feature coverage

Keyword by keyword, plus the parts of the specification that are not keywords:
`format`, the content vocabulary, regular expressions, and numbers. Revisions
and dates are recorded in the [overview](index.md).

A caveat about jesse throughout: it implements draft 03, draft 04, and draft 06,
so most of the "no" entries below are keywords that did not exist in those
drafts rather than gaps in what jesse set out to do. They are still absent, and
if your schemas use them the outcome is the same either way.

## Core and references

| Keyword | valid_json | jesse | jsonschex |
| --- | --- | --- | --- |
| `$schema` | yes, selects the dialect; a default can be configured | read to pick a draft, defaults to draft 03 when absent | yes, 2020-12 is built in, others need a loader |
| `$id` | yes, including plain-name fragment identifiers (`"$id": "#name"`) in Draft 6/7 | draft 04 `id` is skipped; the README states id-based references are unsupported | yes |
| `$ref` | yes, resolved at compile time; in Draft 6/7 sibling keywords of a `$ref` object are ignored | yes, resolved while validating | yes |
| `$defs` / `definitions` | both: `$defs` in 2019-09/2020-12, `definitions` as the real keyword of Draft 6/7 and a compatibility alias in modern drafts | neither as a keyword; `#/definitions/...` pointers still resolve | `$defs` |
| `$anchor` | yes, 2019-09/2020-12; Draft 6/7 use `$id` plain-name fragments instead | no | yes |
| `$dynamicRef` / `$dynamicAnchor` | yes | no | yes |
| `$recursiveRef` / `$recursiveAnchor` | yes, Draft 2019-09 | no | no |
| `$vocabulary` | yes, including user meta-schemas taken from the store | no | yes, the meta-schema comes from your loader |
| `$comment` | ignored; unknown keyword in Draft 6 | ignored | ignored |
| Cross-draft references | yes, all four dialects in one closure | not applicable | excluded from the test suite run |

## Assertions

| Keyword | valid_json | jesse | jsonschex |
| --- | --- | --- | --- |
| `type` | yes | yes | yes |
| `enum`, `const` | yes | yes | yes |
| `multipleOf` | yes | yes | yes |
| `maximum`, `minimum`, `exclusiveMaximum`, `exclusiveMinimum` | yes | yes | yes |
| `maxLength`, `minLength` | yes, counted in code points | yes | yes |
| `pattern` | yes | yes | yes |
| `maxItems`, `minItems`, `uniqueItems` | yes | yes | yes |
| `maxProperties`, `minProperties` | yes | yes | yes |
| `required` | yes | yes | yes |
| `dependentRequired` | yes, 2019-09/2020-12 | no, `dependencies` covers the draft-04 form | yes |

## Applicators

| Keyword | valid_json | jesse | jsonschex |
| --- | --- | --- | --- |
| `allOf`, `anyOf`, `oneOf`, `not` | yes | yes | yes |
| `if` / `then` / `else` | yes, Draft 7 and later | no | yes |
| `dependentSchemas` | yes, 2019-09/2020-12 | no, `dependencies` covers the draft-04 form | yes |
| `dependencies` (classic form) | yes, Draft 6/7, in both property and schema forms | yes | yes, as a compatibility keyword |
| `properties`, `patternProperties`, `additionalProperties` | yes | yes | yes |
| `propertyNames` | yes | yes | yes |
| `items`, schema form | yes, both dialects | yes | yes |
| `items` array form and `additionalItems` | yes, Draft 6/7/2019-09 | yes | not applicable |
| `prefixItems` and trailing `items` | yes, Draft 2020-12 | no | yes |
| `contains` | yes | yes | yes |
| `minContains`, `maxContains` | yes | no | yes |
| `unevaluatedProperties`, `unevaluatedItems` | yes | no | yes |
| Boolean schemas | yes | yes | yes |

## Output, annotations, and errors

| | valid_json | jesse | jsonschex |
| --- | --- | --- | --- |
| Standard output formats | `flag`, `basic`, `detailed`, `verbose` | no | no |
| Annotation keywords collected | `title`, `description`, `default`, `deprecated`, `readOnly`, `writeOnly`, `examples` | no, `examples` is accepted and ignored | no |
| Error shape | output units with keyword location, absolute location, and instance location | `data_invalid` / `schema_invalid` tuples with a path of names and indices | structs with `path`, `rule`, `context`, `value` |
| Human-readable messages | `format_error/1`, wording is not a contract | built into the error tuple | `format_error/1` |
| Stopping early | `flag` short-circuits where annotations allow it | first error by default, `allowed_errors` to collect more | errors are collected |
| Schema validated against its meta-schema | yes, whenever it is compiled — at registration or inside `run_schema/3` — and the failure carries the output of that check | no, malformed schemas surface as `schema_invalid` during validation | no |

## format

`format` is an annotation by default in `valid_json` and in jsonschex, and both
turn it into an assertion with an option — `assert_format` on a store, and
`format_assertion` on a compile. jesse has no such switch: the formats it knows
are always checked.

| Format | valid_json | jesse | jsonschex |
| --- | --- | --- | --- |
| `date`, `time`, `date-time` | yes | `date-time` only | yes |
| `duration` | yes | no | yes |
| `email` | yes | a `^[^@]+@[^@]+$` match | yes |
| `idn-email` | annotation only | no | yes, with `idna` |
| `hostname` | yes, but an `xn--` label is treated as an ordinary label | yes | yes |
| `idn-hostname` | annotation only | no | yes, with `idna` |
| `ipv4`, `ipv6` | yes | yes | yes |
| `uri`, `uri-reference` | yes | yes | yes |
| `iri`, `iri-reference` | annotation only | no | yes |
| `uri-template` | yes | no | yes |
| `uuid` | yes | no | yes |
| `json-pointer`, `relative-json-pointer` | yes | no | yes |
| `regex` | yes | no | yes |
| Format-Assertion vocabulary | a meta-schema requiring it is rejected | not applicable | listed among the supported vocabularies |

## Content vocabulary

| | valid_json | jesse | jsonschex |
| --- | --- | --- | --- |
| `contentEncoding` | annotation only | not implemented | `base64` and `base64url` when `content_assertion` is set |
| `contentMediaType` | annotation only | not implemented | `application/json` and any `+json` type when `content_assertion` is set |
| `contentSchema` | annotation only, the subschema is not applied | not implemented | applied to the decoded content |

## Regular expressions and numbers

The specification asks for ECMA-262 regular expressions. `valid_json` and jesse
both hand the pattern to Erlang's `re`, which is PCRE. For `valid_json` this is
a deliberate, documented decision: a pattern outside the subset the two dialects
share — `\p{Letter}`, for instance — fails to compile and the schema is
rejected, rather than being accepted and matching something subtly different.
jesse passes patterns through as well, with `re_options` configurable in the
application environment. jsonschex is the only one of the three that adapts
ECMA-262 patterns before compiling them.

`multipleOf` and the numeric comparisons are computed on doubles in `valid_json`
and in jesse, so a decimal fraction with no exact binary representation can
disagree with decimal arithmetic. jsonschex uses `decimal` for `multipleOf` when
that optional dependency is present.

## Conformance testing

`valid_json` runs every mandatory file of the official JSON Schema Test Suite
for both Draft 2020-12 and Draft 2019-09, plus the official output tests; the
deviations it knows about are listed in the "Not supported" section of the
[README](../../README.md).

jsonschex reports passing 100% of the Draft 2020-12 suite with
`optional/cross-draft` excluded, and ships the suite as a submodule.

jesse runs the official suite too, as a submodule, with a Common Test suite per
draft and a short skip list. In the draft 06 suite that list is location-
independent identifiers, three `refRemote` base-URI-change groups, a root ref in
a remote ref, and two `$id`-in-an-unexpected-place cases — which is the same
limitation its README states in prose.
