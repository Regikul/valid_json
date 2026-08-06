# Third-party code

This project vendors the following third-party files:

| File | Upstream source | License |
| --- | --- | --- |
| `vendor/json/json.erl` | `lib/stdlib/src/json.erl` (Erlang/OTP 28.1.1) | Apache License 2.0 |
| `vendor/json/json.hrl` | `lib/stdlib/src/json.hrl` (Erlang/OTP 28.1.1) | Apache License 2.0 |
| `vendor/uri_string/uri_string.erl` | `lib/stdlib/src/uri_string.erl` (Erlang/OTP 28.1.1) | Apache License 2.0 |
| `test/valid_json_eunit_progress.erl` | `vendor/eunit_formatters/src/eunit_progress.erl` (rebar3 3.27.0) | Apache License 2.0 |

## Erlang/OTP

The two module directories are selected by `rebar.config.script`: OTP20 uses
both copies, OTP21–26 use only the `json` copy, and OTP27+ use neither. The
URI backend supplies `resolve/2` on OTP 20–21 when the system API is absent.

The original Ericsson copyright and license notices remain in each file.
The copies are marked as modified. Changes remove OTP 27 documentation
attributes and replace APIs unavailable on the supported older OTP releases;
the URI copy also retains the upstream implementation unchanged apart from
the documentation attributes.

Erlang/OTP is distributed under the Apache License 2.0. The complete license
text is included in [`LICENSE.txt`](LICENSE.txt).

## rebar3

`test/valid_json_eunit_progress.erl` is a modified copy of
`eunit_progress.erl` from rebar3 3.27.0, originally written by Sean Cribbs
and distributed under the Apache License 2.0. The original copyright and
license notices remain in the file header. Changes replace `dict` with `map`,
remove the `binomial_heap` dependency, add aggregated dot output for
successful tests (`success_interval` option), and drop the `?NOTEST` guard
so the module's own unit tests run under `eunit`.
