# Task 2 Report — Runtime contracts

Status: DONE_WITH_CONCERNS

## Scope

- Added stable error objects and normalization in `errors.uc`.
- Added primitive, enum, length, object, profile, URL, MAC, operation ID, and archive validation in `schema.uc`.
- Added an overrideable runtime with lazy production adapters for `fs`, `ubus`, `uci`, and `uloop`, plus an argv-only process runner.
- Added deterministic filesystem, clock/timer, process, UCI, and event fakes.
- Added focused schema/error and runtime/fake tests.

## TDD evidence

### RED

1. Focused contract test on pinned ucode revision `3f64c8089bf3ea4847c96b91df09fbfcaec19e1d`:

   `UCODE_BIN=/tmp/ucode-build/ucode tools/run-ucode-tests.sh tests/ucode/test-errors-schema.uc`

   Exit 1: `Unable to resolve path for module 'miclash.errors'` and `miclash.schema`.

2. Focused-runner regression before the infrastructure fix:

   The same positional invocation ran all three globbed tests (`test-errors-schema`, `test-runtime`, and `test-testlib`) and reported `2 of 3 ucode tests failed`.

3. Pinned-type regression:

   Adding a valid boolean schema assertion failed with `INVALID_ARGUMENT`, demonstrating that pinned ucode reports booleans as `bool`, not `boolean`.

4. Deterministic timer regression:

   Adding `fake_clock.set_timeout()` failed with `Type error: left-hand side is not a function` before the fake and lazy uloop adapter were implemented.

### GREEN

- Focused errors/schema: `1 ucode tests passed`.
- Focused runtime/fakes: `1 ucode tests passed`.
- Full pinned ucode suite: `3 ucode tests passed`.

## Infrastructure deviation

`tools/run-ucode-tests.sh` required a minimal compatibility correction because the brief documents a positional focused-test command but the runner ignored all positional arguments. It now:

- runs the supplied files when positional paths are present;
- preserves the existing full glob and aggregation when no files are supplied;
- defaults `UCODE_PATH` to both `tests/ucode` and the package `usr/share` directory so dotted `miclash.*` imports resolve.

The brief's sample `'x'.repeat(4097)` is not supported by the pinned ucode revision. The test uses `sprintf('%04097d', 0)` to create the same 4097-byte oversized string without relying on a nonexistent string method.

## Verification commands and results

- `UCODE_BIN=/tmp/ucode-build/ucode tools/run-ucode-tests.sh` — PASS, 3/3.
- `node tools/check-*.mjs` — PASS, 16/16.
- Parse every tracked `*.json` with Node — PASS, 2/2.
- `sh -n` for every tracked `*.sh` — PASS, 2/2.
- `actionlint -shellcheck=` — PASS.
- `git diff --check` — PASS.
- LF scan for all Task 2 files and the adjusted runner — PASS.

## Concerns

- Pinned core `system(commandArray, timeout)` supports argv and timeout but not captured stdout/stderr, an explicit environment object, or injected stdin. The production sync runner therefore uses only argv arrays, represents validated environment entries through `/usr/bin/env KEY=value ...`, and explicitly rejects non-empty `stdin` with `INVALID_ARGUMENT`. It does not silently ignore unsupported fields and never uses `popen`, a shell string, or nonexistent `throw` syntax. A future dedicated native/helper adapter is required before production callers need stdin or captured output.
- Running actionlint with its bundled external shellcheck integration reports pre-existing `SC2086` at `.github/workflows/makefile.yml:196`. Workflow-only actionlint (`-shellcheck=`) passes. The unrelated release/legacy workflow was not modified.
