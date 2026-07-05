# MiClash Client-Only Guard Design

Date: 2026-07-05
Branch: refactoring-redesign

## Summary

Change the "Internet only through MiClash" feature so it protects client device traffic only. The guard should prevent LAN clients from reaching WAN directly when MiClash protection is enabled, while router-originated traffic remains available for LuCI, subscription downloads, MiClash package updates, Mihomo kernel updates, DNS/package-manager operations, and other router maintenance.

This restores the no-repair assumption from `main` for the service-running flow, and intentionally changes the service-stopped flow by removing router-originated traffic from the guard scope.

## Product Semantics

The guard means:

- Client devices behind the router must not bypass MiClash to reach the internet.
- Devices must still be able to reach the router for local services such as LuCI, DHCP, DNS, and local network access.
- Router-originated traffic is outside the guard scope.
- If MiClash is running and client traffic does not pass through it correctly, that is a firewall/routing bug to fix at the source, not a reason to run repair before every UI network operation.

Expected flows:

- Service running, guard enabled: client traffic goes through MiClash; UI update/download operations work.
- Service stopped, guard enabled: client internet is fail-closed; router update/download operations still work.
- Guard disabled: normal router and client traffic behavior.

## Firewall Design

The guard should apply only to transit traffic in `FORWARD`.

Keep:

- nftables `miclash_guard` forward chain.
- iptables `MICLASH_GUARD_FORWARD`.
- Guard allow rules for established/related traffic, `clash-tun`, DNAT/local networks, DHCP, and other required local client-router behavior.
- WAN-facing drop rules in `FORWARD` so client devices cannot exit directly.

Remove:

- nftables guard `output` chain.
- iptables `MICLASH_GUARD_OUTPUT`.
- Any hook from the guard into `OUTPUT`.
- Output-level WAN drop behavior from the internet-only guard.

The normal MiClash redirect/marking tables may still contain OUTPUT rules for proxying router-originated traffic when the service is running. Those are traffic-routing rules, not fail-closed guard rules.

## UI And Update Flow

Update/download flows should no longer run a network repair step before doing work.

Remove or stop using:

- `repair_network_path` as a `clash-rules` entry point.
- `traffic_rules_exist`, if it is only used by `repair_network_path`.
- `prepareNetworkUpdate` logic that executes `repair_network_path`.
- `isNetworkUpdateBlocked`, `shouldSkipSubscriptionDownload`, `skippedSubscriptionMessage`, and `assertNetworkUpdateAllowed` if they only model the old "router traffic blocked while service stopped" behavior.
- UI messages that say subscription download was skipped because the guard is enabled while the service is stopped.

Update text should clarify that the guard protects devices/client traffic, not all traffic originating from the router itself.

## Error Handling

The UI should not silently continue after a failed repair because repair is no longer part of the normal flow.

If a network operation fails, show the underlying operation error:

- package update failure
- kernel download failure
- subscription download failure
- release metadata failure

If client forwarding is broken while the service is running, treat it as a service/firewall bug and fix the start/reload/hotplug path separately.

## Testing And Verification

Implementation should verify:

- `clash-rules` shell syntax is valid.
- init script shell syntax is valid.
- No references remain to `repair_network_path`.
- No references remain to `MICLASH_GUARD_OUTPUT`.
- No references remain to `shouldSkipSubscriptionDownload` or the skipped subscription message.
- nftables guard code no longer creates a guard `output` hook.
- iptables guard code no longer creates or hooks a guard chain into `OUTPUT`.
- Update package, update kernel, release checks, and subscription downloads no longer check for `service stopped + guard enabled` before running.
- `guard_start`, `guard_stop`, and `guard_refresh` still work, but only manage client forwarding protection.

## Out Of Scope

- Adding a strict mode that also protects router-originated traffic.
- Adding temporary allowlists for router update/download operations.
- Adding automatic repair before every update/download operation.
- Redesigning normal MiClash proxy modes beyond the guard scope change.
