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

### Validate an inline schema with the standard store

Register an inline schema under a URI, then validate instances against it:

```erlang
{ok, _} = application:ensure_all_started(valid_json),

Uri = <<"https://example.com/schemas/user">>,
Schema = #{
    <<"type">> => <<"object">>,
    <<"properties">> => #{
        <<"name">> => #{<<"type">> => <<"string">>}
    },
    <<"required">> => [<<"name">>]
},
{ok, [Uri]} = valid_json:add(Uri, Schema),

{ok, #{<<"valid">> := true}} =
    valid_json:validate(
        Uri,
        #{<<"name">> => <<"Ada">>},
        [{output, flag}]).
```

The default output format is `flag`. Select `basic`, `detailed`, or `verbose`
with the same `[{output, Format}]` option:

```erlang
{ok, Result} = valid_json:validate(
    Uri,
    #{<<"name">> => 42},
    [{output, detailed}]).
```

### Report a rejected schema

`add/2` and `remove/1` report failures as pairs of a document name and a schema
error. The error is a machine-readable record; `format_error/1` turns one into
human-readable text:

```erlang
case valid_json:add(Uri, Schema) of
    {ok, Names} ->
        Names;
    {error, {compilation, Errors}} ->
        [io:format("~ts: ~ts~n", [Name, valid_json:format_error(Error)])
         || {Name, Error} <- Errors]
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

The loader derives a `file://` base URI from the directory. File names are
therefore available as relative document names, and `.json` is the default
extension.

### References and custom stores

For schemas with `$ref` links, register every document needed by the reference
closure before registering the root schema. The store is pre-populated only;
it never fetches referenced documents over the network.

For a custom store, add `valid_json_store_sup:child_spec/2` to your
application's supervision tree, then use the `valid_json` facade's `store_*`
functions, such as `valid_json:store_add/2` and `valid_json:store_validate/4`.

## License

Licensed under the [Apache License 2.0](LICENSE.md).
