# DNS and Guard Second Review Design

## Scope

This change closes the six findings from the second Task 6 review without weakening the existing transactional DNS proof, exact-plan, same-cursor, legacy-provability, duplicate-target, or postrm `.done` guarantees.

## DNS recovery and ownership

Committed active recovery will use a fresh production observation before returning. The observation must have the manifest's exact section identity, no pending UCI deltas, a trusted unchanged authority document, unambiguous target ownership, and exact active scalar values. Any conflict returns `CORRUPT_STATE`; the fixed `dns-control apply` adapter may only create ownership after `NOT_FOUND`, so it cannot repair or re-add a drifted foreign target.

For a preexisting target, ownership remains foreign: the current target count must equal the original target count and the complete original server list must remain an ordered subsequence of the current list. This rejects missing or reordered authority while allowing inserted foreign non-target servers. For a MiClash-added target, the existing exactly-one and append-after-original invariant remains.

A single manifest-absent clean-proof helper will be called by both `cleanup()` and `recover('clean')`. It freshly observes UCI and rejects conflicts, missing section identity, target presence, `cachesize=0`, or `noresolv=1`.

## Fail-closed Guard finalization

The forced Guard remains installed through service startup and ordinary cleanup. A new fixed `guard_finalize` command loads final policy only after core/firewall/DNS completion:

- Enabled policy is verification-only. It must not delete, rebuild, or otherwise mutate an already proven Guard.
- Disabled policy performs strict removal only after the transition is complete, then proves absence.
- If disabled removal or final proof fails, it immediately re-establishes and freshly verifies Guard, then returns failure. Thus a finalization error returns with proven fail-closed protection.

The init script calls `guard_finalize` after procd registration on start and after DNS cleanup on stop. Its failure is fatal. Stateful lifecycle tests inspect Guard state during and after the post-procd failure path.

## Package Guard authority

Two fixed clash-rules entrypoints are added:

- `package_guard_start` establishes and freshly proves Guard.
- `package_guard_verify` is non-mutating and proves Guard remains installed.

Both require a root-owned, mode-0700, non-symlink package-removal barrier at its canonical path and successful participation in the live inherited package-owner mutation lease. An environment flag alone is insufficient because the shared lock join validates the inherited owner token and live process identity. Ordinary public Guard commands remain barrier-rejected.

`package-remove` invokes `package_guard_start` immediately after acquiring the package-owner lease and before quiescence, routing cleanup, DNS cleanup, or firewall cleanup. Later shipped init package cleanup invokes only `package_guard_verify` and preserves Guard while removing firewall state.

## Tests and failure handling

TDD RED coverage will include:

- public `recover()` active drift, pending changes, section identity, and preexisting target missing/reordering;
- fixed adapter refusal for committed-active drift, pending changes, and section identity;
- shared manifest-absent clean refusal through both public cleanup paths;
- post-procd enabled finalization failure retaining proven Guard, verification-only enabled success, and disabled removal failure restoring proven Guard;
- unauthorized package Guard entrypoint refusal;
- actual shipped package init/package cleanup under a trusted barrier and inherited package lease;
- an ordering sentinel that fails if quiescence, routing, DNS, or firewall cleanup occurs before `package_guard_start` proof.

Focused tests run RED before production changes, then GREEN. Final verification includes the full ucode suite, actual DNS/init lifecycle, actual package removal, package cleanup/release, mutation-lock, routing namespace, all Node gates, shell syntax, and whitespace checks.
