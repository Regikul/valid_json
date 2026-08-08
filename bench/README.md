# valid_json comparison benchmark

Pairwise BEAM benchmarks for:

- Jesse and `valid_json` on JSON Schema Draft 6;
- JSONSchex and `valid_json` on JSON Schema Draft 2020-12;
- the `flag`, `basic`, `detailed`, and `verbose` output modes of `valid_json`.

The project uses the parent `valid_json` checkout and Git-pinned Jesse and
JSONSchex revisions. Its `.tool-versions` selects an installed compatible OTP
28 / Elixir combination.

## Comparison matrix

| Dialect | Comparison | Calls inside the timed function |
| --- | --- | --- |
| Draft 6 | cold/cold | `jesse:validate_with_schema/3` vs `valid_json:run_schema/3` |
| Draft 6 | cold/hot | `jesse:validate_with_schema/3` vs registered `valid_json:validate/3` |
| 2020-12 | cold/cold | `JSONSchex.compile/1` + `validate/2` vs `valid_json:run_schema/3` |
| 2020-12 | hot/hot | `JSONSchex.validate/2` on a compiled schema vs registered `valid_json:validate/3` |

Jesse is never benchmarked through `add_schema/2`: registration does not
compile its schema and would only add storage lookup overhead.

On valid inputs and in verdict-oriented Jesse comparisons, `valid_json` uses
`flag`. For invalid all-error comparisons, Jesse uses
`{allowed_errors, infinity}` and `valid_json` uses `basic`. JSONSchex always
collects validation errors, so the 2020-12 comparison uses `flag` for valid
inputs and `basic` for invalid inputs.

Jesse's `{allowed_errors, infinity}` does not preserve its normal verdict for
the composition scenario: errors from a deliberately rejected `not` branch
escape into the final result. The all-errors comparison therefore excludes
that scenario. The ordinary Jesse/default versus `valid_json`/`flag`
comparison still includes it.

"Cold" means a raw, uncompiled schema on an already started VM. JSON decoding,
VM startup, application startup, module loading, and one-time meta-schema
publication are outside the timed functions. Cold work is end-to-end schema
preparation plus validation, not a claim that the libraries perform identical
compilation work.

Every invocation first checks that all participating validators agree on every
valid/invalid verdict. Benchmark inputs are already-decoded, identical BEAM
terms.

## Run

```sh
cd bench
mix deps.get
mix run bench/verify.exs
mix run bench/compare.exs
mix run bench/output_sizes.exs
mix run bench/profile.exs
```

The full run uses 2 seconds of warmup, 5 seconds of timing, 2 seconds of memory
measurement, and 2 seconds of reductions measurement per job and input.

Filter the suite or cases when iterating:

```sh
BENCH_SUITE=jesse mix run bench/compare.exs
BENCH_SUITE=jsonschex BENCH_CASE=nested mix run bench/compare.exs
BENCH_SUITE=output BENCH_CASE=array_100 mix run bench/compare.exs
```

`BENCH_CASE` is applied before schema compilation, registration, and verdict
verification. This keeps a targeted run from preparing the full corpus. The
same filter is accepted by `bench/verify.exs` and `bench/output_sizes.exs`.
Filters are substring matches by default; prefix a complete scenario name with
`exact:` when a width such as 100 would otherwise also match 1,000.

The object corpus contains width sweeps at 10, 100, and 1,000 properties:

- `object_properties_*` for named properties;
- `object_additional_*` for additional properties;
- `object_patterns_*` with a mix of zero, one, and two matching patterns;
- `object_unevaluated_*` for Draft 2020-12 coverage crossing `allOf`;
- `object_property_names_100`, `object_required_100`,
  `object_dependent_required_100`, and `object_dependent_schemas_100` for
  individual object keywords.

Run only Flag and Basic across a width sweep, then all formats at the control
size:

```sh
BENCH_SUITE=output BENCH_CASE=object_properties_ \
  BENCH_OUTPUT_FORMATS=flag,basic mix run bench/compare.exs

BENCH_SUITE=output BENCH_CASE=exact:object_properties_100 \
  mix run bench/compare.exs
```

`BENCH_OUTPUT_FORMATS` accepts a comma-separated subset of `flag`, `basic`,
`detailed`, and `verbose`. It affects only the output suite.

For a compact tab-separated result stream suitable for collecting a full run:

```sh
BENCH_FORMAT=compact mix run bench/compare.exs
```

Timing controls are environment variables containing whole seconds:

```sh
BENCH_WARMUP=1 BENCH_TIME=2 BENCH_MEMORY_TIME=1 BENCH_REDUCTION_TIME=1 \
  mix run bench/compare.exs
```

For stable latency comparisons, leave the machine otherwise idle and repeat
the selected run at least three times. The script prints OTP, ERTS, Elixir,
scheduler count, the benchmark revision, and all three implementation
revisions with every result. A dirty worktree is marked with `-dirty`.

To apply this exact benchmark revision to another `valid_json` worktree, set
an absolute target path and use a separate Mix build directory:

```sh
VALID_JSON_PATH=/absolute/path/to/valid_json-version-a \
MIX_BUILD_PATH=_build/version-a mix run bench/verify.exs
```

`output_sizes.exs` reports the portable Erlang external-term size of each
`valid_json` output value. This is the returned payload size, separate from the
per-call allocation measured by Benchee.

## Profile hot validation

`profile.exs` profiles only hot `valid_json` validation. Schema registration,
compilation, application startup, module loading, and warmup stay outside the
profile. OTP `tprof` attributes call count, process-heap allocation, and self
time to functions in loaded `valid_json*` modules.

The measurement contract and interpretation rules are recorded in
[`../okf/bench/performance-measurement.md`](../okf/bench/performance-measurement.md).

The default profiles the complete public `validate/3` path for a valid nested
object in `flag` format:

```sh
mix run bench/profile.exs
```

Select a scenario, validity, output format, measured layer, and profiler type:

```sh
PROFILE_CASE=array_100_last_error PROFILE_VALIDITY=invalid \
PROFILE_FORMAT=basic PROFILE_LAYER=full PROFILE_TYPE=memory \
PROFILE_ITERATIONS=1000 mix run bench/profile.exs
```

Supported layers are:

- `full`: public `valid_json:validate/3`, including artifact lookup;
- `lookup`: only the store artifact lookup;
- `core`: validation with an already fetched compiled artifact;
- `eval`: evaluator without output projection;
- `output`: projection of one already computed evaluation result.

`PROFILE_TYPE` accepts `all`, `count`, `memory`, or `time`. Other controls are
`PROFILE_DIALECT` (`draft6` or `draft202012`), `PROFILE_WARMUP`, and
`PROFILE_TOP`. Profiled time is instrumentation-heavy and is useful for ranking
functions, not as absolute latency; use the Benchee comparison for the latter.
