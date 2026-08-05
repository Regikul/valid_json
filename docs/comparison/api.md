# API

What each library asks you to call, what it lets you configure, and what comes
back. Revisions and dates are recorded in the [overview](index.md).

## valid_json

Every schema goes through a store. Registering a document compiles it; a
validation names the document by its URI.

```erlang
{ok, [CanonicalUri]} = valid_json:add(Name, Schema),
{ok, #{<<"valid">> := true}} = valid_json:validate(CanonicalUri, Instance, [{output, flag}]).
```

The facade is small:

| Function | Purpose |
| --- | --- |
| `add/2`, `add/1` | register one document or a whole set in the standard store |
| `remove/1` | drop documents, refusing to break documents that refer to them |
| `wait/1` | wait for the initial load, and get a monitor for later changes |
| `validate/3` | validate an instance against a registered document |
| `store_add/2,3`, `store_remove/2`, `store_wait/2`, `store_validate/4` | the same operations against a named store |
| `format_error/1` | turn a schema error record into human-readable text |

A set of documents that refer to one another must be registered in a single
call, because a document whose references cannot be resolved is rejected.

**Options of a validation call.** Exactly one: `{output, flag | basic | detailed
| verbose}`. The result is the standard output document of the specification,
so `{ok, Output}` may well describe a failed validation — `valid` is a field in
`Output`, not the shape of the return. `{error, Reason}` is reserved for not
getting as far as evaluating: `not_found`, `unavailable`, or an evaluation error.

**Options of a store**, given to `valid_json:store_child_spec/2`:
`base_uri`, `default_dialect`, `assert_format`, and `loader`; the last three
also read from the application environment. `base_uri` is required — it is how a
store claims its schemas for a service, and relative document names become
addresses against it. `assert_format` belongs to the store rather than to a call
because it changes the compiled artifact.

**The loader** is a behaviour with one callback, `load/1`, returning the whole
set of documents at once under relative names. Where the schemas live is the
loader's business; what they are called is the store's.
`valid_json_loader_dir` ships with the library and reads a directory tree of
`.json` files.

**Errors of registration** are records: a reason, the location of the offending
keyword or schema position, and, when a schema failed its meta-schema, the
standard output of that check. `format_error/1` renders one; the record itself
is the stable contract.

## jesse

Two ways to work, and you may mix them.

```erlang
ok = jesse:add_schema(Key, Schema),
{ok, Value} = jesse:validate(Key, Data),
{ok, Value} = jesse:validate_with_schema(Schema, Data).
```

| Function | Purpose |
| --- | --- |
| `add_schema/2,3`, `del_schema/1` | put a schema into the global table, take it out |
| `load_schemas/2,3` | load a directory of schemas through a parser function |
| `validate/2,3` | validate against a stored schema, named by key |
| `validate_with_schema/2,3` | validate against a schema passed in the call |
| `main/1` | the entry point of the command-line tool |

**Options** are the customisation surface, and it is wider than `valid_json`'s:

- `allowed_errors` — keep going after a failure, up to a count or `infinity`.
  The default is to stop at the first error.
- `error_handler` — your own function, called with each error, the errors so
  far, and the allowance; it may raise instead of accumulating.
- `external_validator` — your own validation step, run alongside the schema.
- `parser_fun` — how to turn a binary into a term, which is also how jesse
  supports mochijson2, jiffy, jsx, and maps rather than one representation.
- `schema_loader_fun` — how to obtain a schema that is referenced but not
  stored.
- `default_schema_ver`, `meta_schema_ver` — which draft to assume. When a schema
  carries no `$schema`, jesse assumes draft 03 unless you say otherwise.

**Results.** `{ok, Value}` on success, `{error, Errors}` otherwise, where each
error is a `data_invalid` tuple (schema, error kind, offending value, path) or a
`schema_invalid` tuple. A path is a list of property names and zero-based array
indices. There are no annotations and no standard output formats.

**As a program.** `bin/jesse schema.json -- instance.json`, with `--json` for
machine-readable output, and the same thing as a Docker image.

## jsonschex

Compilation produces a value that you keep; validation takes it and the data.

```elixir
{:ok, compiled} = JSONSchex.compile(%{"type" => "array", "items" => %{"type" => "integer"}})
:ok = JSONSchex.validate(compiled, [1, 2, 3])
```

| Function | Purpose |
| --- | --- |
| `compile/1,2` | compile a schema into a reusable struct |
| `validate/2` | validate data against a compiled schema |
| `compile_fragment/2` | compile a fragment of a larger document, addressed by JSON Pointer or URI reference |
| `bundle_fragment/2` | rewrite a fragment into a standalone schema, pulling external references into `$defs` |
| `format_error/1` | render one error as a sentence |
| `~X` sigil, `Schema.compile!/2` | compile a literal schema while the module itself is being compiled |

**Options of `compile/2`:** `loader`, a function from a URI to a decoded schema,
used for remote `$ref` and for a meta-schema that is not the canonical
2020-12 one; `base_uri`; `format_assertion`; `content_assertion`. The two
assertion flags default to false, which leaves `format` and `content*` as
annotations.

**Results.** `:ok`, or `{:error, errors}` where each error carries `path` as a
list of segments, `rule` as the keyword that failed, `context`, and `value`.
Errors are built lazily, and there are no standard output formats.

## Where the three differ most

**Validating a schema you have not registered.** jesse has
`validate_with_schema/2,3`. jsonschex hands you the compiled struct, so this is
the normal case rather than a special one. `valid_json` has no such path: a
schema must be registered in a store before anything can be validated against
it. If your schemas arrive with the request rather than with the release, this
is the difference that will decide the matter.

**Entering a fragment.** `compile_fragment/2` and `bundle_fragment/2` let
jsonschex take an OpenAPI document and treat one subschema of it as the root.
Neither jesse nor `valid_json` has an equivalent.

**Reporting.** `valid_json` is the only one of the three that produces the
output documents defined by the specification, which is what makes its results
portable between implementations and tooling. The other two define their own
error shapes, which are easier to pattern-match against in place.

**Hooks.** jesse lets you replace the error handler and add an external
validator, and lets you choose how JSON is represented. `valid_json` fixes the
representation to the one `json:decode/1` produces and offers no per-call hooks.
