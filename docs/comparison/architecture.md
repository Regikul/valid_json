# Architecture

Where a schema lives, when it is turned into something executable, and what
that implies for running a system. Revisions and dates are recorded in the
[overview](index.md).

## valid_json: compiled artifacts in a supervised store

`valid_json` is an OTP application. Its root supervisor runs one store subtree
per set of schemas, `one_for_one`, so a store that fails does not disturb the
others. The standard store is always started; an application that needs its own
adds `valid_json_store_sup:child_spec/2` to its own supervision tree.

A store is a manager process and two ETS tables, one for compiled artifacts and
one for the registry of documents. The tables are not owned by the manager. Each
belongs to a keeper process that does nothing but create the table, name itself
its heir, and hand ownership over on request. The keeper carries no logic that
can fail, which is what lets the tables — and their contents — survive a restart
of the manager.

Compilation happens once, when a document is registered. `add` parses the
document, resolves its references, builds the intermediate representation, and
recompiles every already-registered artifact the change affects. Only if all of
that succeeds are the results committed to the tables; a failure leaves the
store exactly as it was, and reports which document failed and why. `remove` is
symmetrical: a document that other documents still refer to is not removed, and
the refusal names the documents that hold the references.

Validation does not go through the manager. `validate/3` reads the compiled
artifact from ETS in the caller's own process and evaluates it there, so
validations run concurrently and no single process is on the hot path. The read
tolerates the window in which a keeper is restarting: it reports `unavailable`
rather than failing.

The registry is offline by design. Every document reachable through `$ref` must
be registered before the document that refers to it — mutually referencing
documents in one call — and nothing is fetched over the network at any point.
The initial population of a store is the job of a loader, a behaviour with one
callback, `load/1`, which returns the whole set of documents at once under
relative names; the `base_uri` of the store turns those names into addresses.

**What follows from this.** Schemas are part of a release and are validated when
the release starts, not when a request arrives. A bad schema is a startup or
registration error, not a runtime surprise. There is no way to validate against
a schema that has not been registered, and no way to fetch one that is missing.

## jesse: a raw schema in a global table, walked each time

jesse has no application callback module and no supervision tree. Its store is a
single named public ETS table, created lazily by whichever process first touches
`jesse_database` — which is also the process that owns it, and with which the
table disappears. Entries are keyed by string: the source key, an id, an mtime,
and the schema as it was parsed.

Nothing is compiled. A validation walks the raw schema term keyword by keyword,
carrying a state record with the error allowance, the error handler, and the
external validator. A regular expression is handed to `re` as the walk reaches
it. The same schema validated a thousand times is traversed a thousand times.

Resolution happens during that walk too. `load_uri` looks the key up and, if it
is not there, fetches it — `file:`, `http:`, or `https:` — adds it to the table,
and continues. That makes remote references work with no setup at all, and it
also means a validation can perform network I/O and can fail for reasons that
have nothing to do with the data.

**What follows from this.** Getting started is very cheap, and there is nothing
to wire into a supervision tree. In exchange, the schema store is process-owned
global state with no restart story, and the cost of a validation scales with the
size of the schema every time.

## jsonschex: a compiled struct you hold yourself

jsonschex splits compile from validate and hands the result back to you.
`compile/2` parses the schema, registers ids and anchors, resolves references,
compiles keywords into rules, resolves vocabularies, and calls your loader for
anything remote. The result is a struct. `validate/2` runs its rules, collecting
errors and tracking which properties and items were evaluated so that
`unevaluated*` can be decided.

There are no processes and no ETS. Where the compiled struct lives is your
problem, and so is its lifetime: a module attribute, a persistent term, an
Agent, whatever suits. For schemas known at build time the library goes one step
further and compiles them while your module compiles, via `Schema.compile!/2` or
the `~X` sigil.

Remote resolution is entirely yours as well. The loader is a function from URI
to schema; it is called on a miss, and the guide is explicit that caching,
timeouts, and recursion are your responsibility.

**What follows from this.** The library imposes nothing on the shape of your
application, which is the Elixir convention, and the compile-time path is the
fastest of the three for static schemas. In exchange, there is no answer to
"where do the schemas live and who reloads them" — that is your design.

## Side by side

| | valid_json | jesse | jsonschex |
| --- | --- | --- | --- |
| Compiled ahead of validation | yes, on registration | no | yes, on `compile/2` |
| Where the schema lives | ETS tables under supervision | one global public ETS table | wherever the caller puts the struct |
| Survives a process restart | yes, tables outlive the manager | no, the table dies with its owner | as designed by the caller |
| Cost of the hot path | ETS read plus evaluation, in the caller | full walk of the raw schema | rule execution on the struct |
| Reloading the set of schemas | `add` and `remove`, all-or-nothing, affected artifacts rebuilt | `add_schema` and `del_schema`, one key at a time | recompile and replace the struct |
| Broken schema is detected | at registration, against the meta-schema | at validation, as `schema_invalid` | at compile time |
| Network | never | possible during validation | inside your loader |
