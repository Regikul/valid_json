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
            {root, "priv/schemas"}
        ]}}
    ]}
].
```

The `root` path is resolved relative to the current working directory, so the
relative path above works when `rebar3 shell` is started from the project root.
Use an absolute path if the application can be started from another directory.

Then start the shell from the project root and wait for the initial load to
finish:

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
