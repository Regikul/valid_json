# Third-party code

This project vendors the following files from Erlang/OTP 28.1.1:

| File | Upstream source | License |
| --- | --- | --- |
| `vendor/json/json.erl` | `lib/stdlib/src/json.erl` | Apache License 2.0 |
| `vendor/json/json.hrl` | `lib/stdlib/src/json.hrl` | Apache License 2.0 |
| `vendor/uri_string/uri_string.erl` | `lib/stdlib/src/uri_string.erl` | Apache License 2.0 |

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
