# Repository Guidelines

## Project Structure

MiClash is a LuCI package for OpenWrt 24.10+. Sources are under `luci-app-miclash/`: services and configuration in `rootfs/etc`, ucode backend in `rootfs/usr/share/miclash`, and LuCI JavaScript/CSS in `rootfs/www/luci-static/resources/view/miclash`. Translations are in `rootfs/po/{ru,zh-cn}`, tests in `tests/`, and repository checks in `tools/`.

## Development Commands

- `tools/run-ucode-tests.sh` runs host ucode tests; pass a test path for a focused run.
- `for check in tools/check-*.mjs; do node "$check"; done` runs JavaScript contracts.
- `sh -n install-miclash*.sh tools/*.sh` checks shell syntax.
- In an OpenWrt SDK, use `make package/luci-app-miclash/compile V=s`.

## Code and Architecture

Preserve tab indentation. Use `snake_case` for ucode and `camelCase` for browser JavaScript. Keep backend operations bounded, schema-validated, atomic, and recoverable. Prefer `miclashd` domain operations over new shell backends. Support both opkg/OpenWrt 24 and apk/OpenWrt 25.

## Proportional Verification

Use the smallest verification that proves the change:

- Text, CSS, docs, or an obvious one-line configuration change: run `git diff --check` and a relevant syntax check; no new test is required.
- Local behavior change or clear bug fix: run a focused affected test; add a regression test when it protects meaningful logic.
- Routing, DNS, firewall, Guard, updates, migrations, concurrency, or package lifecycle: add regression coverage and run the relevant suite, privileged gate, or router smoke test.

Avoid unrelated full suites, lengthy plans, or brainstorming/TDD for mechanical low-risk work. Use systematic debugging and stronger tests when the cause is uncertain or networking is at risk.

## Model and Agent Budget

Use the lowest-cost reliable setting. Default to Terra Medium for implementation, focused exploration, tests, and approved plans. Use Terra Low for mechanical edits and Terra High for broad bounded analysis. Use Sol Medium for architecture, ambiguous bugs, risky networking, major plans, and independent review. Use Sol High only after lower settings or repeated fixes fail, or for a critical migration. Extra High, Max, Ultra, and subagents require clear justification or an explicit request. Escalate one step at a time, then return implementation to Terra Medium.

## Git, PR, and Security

Use Conventional Commit prefixes such as `feat:`, `fix:`, `docs:`, and `ci:`. Never put agent or AI-tool names (`codex`, `chatgpt`, `ai`) in branches, commits, or PR titles; use the task name. Keep commits scoped. Never force-add or commit ignored `docs/`. Never commit tokens, subscription URLs, router credentials, generated reports, or live UCI state. PRs should state impact, safety, verification, and include LuCI screenshots.

@RTK.md
