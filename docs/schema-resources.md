# Schema resources and identifiers

This page is the detailed companion to the README: how documents are named in
`valid_json`, how the registry and the loader work, and how to plug in a custom
store. The normative contract lives in
[okf/architecture/validator-resources-runtime.md](../okf/architecture/validator-resources-runtime.md);
this page is user-facing prose.

## Two doors, not one argument shape

A document is addressed by its canonical name. Where the name comes from is
decided by the function you call — never by the shape of the argument.

- `valid_json:add/1` takes schemas and nothing else. Each schema names itself
  with its `$id`. A schema without an `$id` is rejected with `unnamed_schema`
  under the key `anonymous`: the root of a document is always a schema resource
  and needs an absolute name, and there is nothing to build one from. That
  includes the boolean schemas `true` and `false`, which carry no keywords and
  therefore no `$id` — they can only be registered by the loader or by
  `add_at`.
- `valid_json:add_at/1,2` takes name-and-schema pairs. The name comes from
  outside: the address a document was found at, or the path a file was read
  from.

```erlang
{ok, [Name]} = valid_json:add_at(<<"allow">>, true),
{ok, [A, B]} = valid_json:add_at([{<<"a">>, SchemaA}, {<<"b">>, SchemaB}]).
```

A schema registered under a path that also declares `$id` answers to the `$id`
only; the path stays behind as the base against which its relative `$ref`
resolve.

## References are resolved eagerly

References are resolved at compile time, not lazily at validation time. A
document whose `$ref` target is not in the registry is rejected. This is why a
set of documents that reference one another must be registered in one call:

```erlang
{ok, _} = valid_json:add([SchemaA, SchemaB]).
```

Once a document is registered, validation is a lookup by canonical name; the
compiled artifact is self-contained and needs no registry access.

The dialect is a property of each schema resource, not of the whole document:
an embedded resource chooses its own dialect with `$schema`, and a `$ref`
target is compiled according to the dialect of the target resource while the
`$ref` object itself keeps the semantics of its source dialect. This holds
across all four supported dialects — Draft 2020-12, Draft 2019-09, Draft 7 and
Draft 6 — including classic plain-name `$id` fragments (`"$id": "#name"`) in
Draft 6/7 and modern `$anchor` targets, so references may cross dialects in any
direction and over multi-hop chains.

## Registry policy: offline, no network

The registry is deliberately offline. Documents reachable through `$ref` must
be registered before compilation or validation, and the library never fetches a
referenced document over the network. Validation is therefore deterministic,
has no latency from fetching, and exposes no fetching surface to untrusted
schemas.

## Base URI and relative names

A relative `$id` is resolved against the `base_uri` of the store. The standard
store uses `https://valid_json.internal/schemas/`, so a schema with
`"$id": "weight"` is addressable as
`https://valid_json.internal/schemas/weight` and, in the short form, as
`weight`. The `.internal` top-level domain is reserved by ICANN for private use,
so such a name never collides with an address that something answers at. This
is the implementation-defined default base URI that RFC 3986 Section 5.1.4
permits and JSON Schema Section 9.1.1 asks implementations to document.

A schema that declares no `$id` has to be named from the outside — that is what
`add_at` is for. Both kinds of path are relative, and the store's `base_uri`
makes them absolute, which is why the same set of files suits any store.

## The directory loader

The built-in loader, `valid_json_loader_dir`, recursively reads `.json` files
into the standard store when the application starts, naming each document by
its path relative to the root. Path segments are percent-encoded and a colon in
the first segment is escaped, so a name like `product/banana.json` survives
unchanged while a space, a percent sign, or a slash inside a file name is
escaping. The loader stays inside the directory it was given: it does not
follow symbolic links but reports them as an error.

For example, create `priv/schemas/weight.json`:

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

The path is resolved inside the `priv` directory of the named application,
which is where a release keeps it — unlike a path relative to the current
working directory, it does not depend on where the node was started from. In
your own application, name that application instead.

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
from — `weight.json`, with `.json` as the default extension. `wait/2` waits
for the initial load and returns a monitor that fires if the registry changes
later.

## Custom stores

A store claims its schemas for a service: it has a `base_uri`, and two stores
over the same files under `https://shop.service/schemas/` and
`https://internal.service/schemas/` name their documents apart.

For a custom store, add `valid_json:store_child_spec/2` to your application's
supervision tree, then use the `store_*` facade functions, such as
`valid_json:store_add/2` and `valid_json:store_validate/4`. The standard store
is started by the library itself, so it has no `store_child_spec` counterpart —
embedding is only for your own stores.

A store's options are `base_uri` (required), `default_dialect`,
`assert_format`, and `loader`. `assert_format` belongs to the store rather than
to a single call, because it changes the compiled artifact.

## The loader behaviour

The loader is a behaviour with one callback, `load/1`, returning the whole set
of documents at once under relative names. The set is registered with one
`add`, so mutual references inside it resolve by themselves. Where the schemas
live is the loader's business; what they are called is the store's.

## Removal and reload

`remove/1` refuses to drop a document that other documents reference. Each error
pairs the caller's spelling of the entry with the canonical name of the
referenced document and the names of the documents that reference it:

```erlang
{error, [{Entry, #schema_error{reason = {referenced_by, Name, Refs}}}]}
```

Reloading is transactional and all-or-nothing: an `add` recompiles the existing
documents whose reference closure intersects the changed names, and only
commits when every compilation succeeds. On failure both the registry and the
artifact table keep their previous contents.

## Errors

Registration failures come back as pairs of a document name and a schema error.
The error is a machine-readable record; `valid_json:format_error/1` turns one
into human-readable text. The record's `reason` and `location` fields are the
stable contract; the wording is an implementation detail and may change.

```erlang
case valid_json:add(Schema) of
    {ok, Names} ->
        Names;
    {error, {compilation, Errors}} ->
        [io:format("~ts: ~ts~n", [DocName, valid_json:format_error(Error)])
         || {DocName, Error} <- Errors]
end.
```

A schema rejected before it got a name is reported under the atom `anonymous`.
