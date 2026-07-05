# MiClash Router OUTPUT Decoupling Design

Date: 2026-07-05
Branch: `refactoring-redesign`

## Context

The previous client guard redesign removed the active fail-closed OUTPUT guard and made the protection guard apply only to forwarded client/device traffic.

One router-originated behavior still remains coupled to `INTERNET_ONLY_MICLASH`: when the service is running, the setting changes OUTPUT routing so router-side TCP can be redirected to MiClash and root/router traffic stops using the normal bypass path.

This is not a fail-closed guard, but it still changes router downloads and updates when the user only expects client devices to be protected.

## Decision

`INTERNET_ONLY_MICLASH` must control only client/device guard behavior.

Router-originated OUTPUT routing must follow the normal MiClash routing behavior regardless of this setting.

## Required Behavior

- Client/device protection remains FORWARD-only.
- Router-originated OUTPUT traffic is not blocked by the guard.
- Router-originated OUTPUT traffic is not specially redirected or de-bypassed because `INTERNET_ONLY_MICLASH=true`.
- Root/router OUTPUT bypass behavior remains the normal default.
- OUTPUT interface exclusions are applied normally and are not skipped because client guard is enabled.
- Existing ordinary OUTPUT handling that is independent of client guard remains intact.
- Legacy cleanup for stale `MICLASH_GUARD_OUTPUT` remains allowed because it only removes old rules.

## Out Of Scope

- No new setting for "router traffic through MiClash".
- No UI changes beyond removing stale log wording if needed.
- No changes to `repair_forward_rules`, TUN/MIXED forwarding rules, or client guard FORWARD enforcement.

## Acceptance Criteria

- No executable code uses `INTERNET_ONLY_MICLASH` inside OUTPUT routing helpers except unrelated global setting reads.
- `apply_nft_output_redirect_rules` and `apply_iptables_output_redirect_rules` are removed if they only exist for client guard OUTPUT redirect behavior.
- No active `output_redir` or `CLASH_OUTPUT_REDIRECT` routing rules remain.
- Removal-only cleanup for stale `CLASH_OUTPUT_REDIRECT` rules remains allowed for upgrades from intermediate builds.
- No OUTPUT log/comment says `client guard policy enabled`.
- FORWARD guard rules and legacy `MICLASH_GUARD_OUTPUT` cleanup remain.
- Shell syntax checks pass for `clash-rules` and `init.d/clash`.
- `node --check` passes for the LuCI config view.
