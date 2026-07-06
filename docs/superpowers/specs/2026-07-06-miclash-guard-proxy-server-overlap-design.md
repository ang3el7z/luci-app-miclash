# MiClash Guard Proxy Server Overlap Design

Date: 2026-07-06
Branch: `fix-guard`

## Context

The client-only guard protects devices behind the router by blocking direct WAN forwarding when `INTERNET_ONLY_MICLASH=true`.

Current client marking also excludes IP addresses from the generated `proxy_servers` set. This is needed for router/Mihomo-originated outbound connections so the proxy core can reach its upstream servers without routing loops.

The same exclusion is unsafe for LAN client traffic while the guard is enabled. If a normal destination resolves to the same IP as one of the proxy servers, client traffic is excluded from MiClash, then the guard blocks the direct WAN path.

Observed example:

- `akira.click` resolved to `138.124.254.75`.
- `138.124.254.75` was present in `@proxy_servers`.
- LAN client traffic to `akira.click` was skipped by client marking.
- The guard then dropped the packet on WAN.
- Router-originated curl worked because router traffic is outside the client guard path.

This is a general product issue, not a one-site allowlist issue. Users can open arbitrary sites, APIs, and VPN endpoints. MiClash should not require users to know which public IPs overlap with proxy server IPs.

## Decision

When the client guard is enabled, LAN client traffic must not use `proxy_servers` as a bypass exclusion.

The `proxy_servers` exclusion remains valid for router/Mihomo-originated traffic where it prevents loops. It must not be treated as a client-side direct-access allowlist while the guard is enforcing "devices only through MiClash".

## Product Semantics

Guard disabled:

- MiClash routes client traffic according to its normal mode, rules, and exclusions.
- This is routing/proxy behavior, not a fail-closed guarantee.
- Some traffic may intentionally bypass MiClash through technical exclusions, unsupported paths, or direct rules.

Guard enabled:

- Client devices must not reach WAN directly.
- Client traffic to public destinations should be marked and sent to MiClash unless it is a local/router technical exception.
- A proxy server IP is not a client bypass exception.
- If client traffic cannot be sent through MiClash, it should fail closed instead of leaking directly.

## Firewall Design

Keep `proxy_servers` bypass behavior only in scopes that protect Mihomo from routing loops:

- router-originated OUTPUT handling
- Mihomo/root outbound connection handling
- cleanup or loop-prevention rules that do not affect LAN client PREROUTING

For LAN client PREROUTING/mangle handling:

- when `INTERNET_ONLY_MICLASH=true`, do not add `ip daddr @proxy_servers return` before client mark/TPROXY rules;
- client traffic to a proxy server IP should be marked like ordinary internet traffic;
- the existing FORWARD guard continues to block only traffic that still tries to leave WAN directly.

The preferred implementation is conditional:

- with guard disabled, preserve current client `proxy_servers` exclusion for compatibility;
- with guard enabled, skip that client exclusion.

This minimizes behavior changes for existing users while fixing strict guard mode.

## Alternatives Considered

Always remove the client `proxy_servers` exclusion. This is simpler and makes behavior more consistent, but it changes non-guard behavior for all users.

Allow `@proxy_servers` through the guard directly. This would make the observed site work, but it weakens the meaning of guard by creating known direct internet bypasses for every proxy endpoint IP.

The selected design is the conditional client-side skip because it preserves compatibility when guard is off and enforces the product promise when guard is on.

## Testing And Verification

Implementation should verify:

- nftables client mangle rules do not contain `ip daddr @proxy_servers return` before mark/TPROXY rules when `INTERNET_ONLY_MICLASH=true`;
- iptables client marking follows the same behavior;
- router OUTPUT loop-prevention for proxy server IPs remains present;
- FORWARD guard remains client-only and still blocks direct WAN forwarding;
- shell syntax checks pass for `clash-rules` and `init.d/clash`;
- existing LuCI/static test scripts still pass;
- a router-side smoke test confirms LAN client traffic to a proxy-server-overlap IP is no longer dropped before MiClash.

## Out Of Scope

- Adding user-managed domain/IP allowlists for this bug.
- Guessing or hardcoding specific domains such as `akira.click`.
- Changing subscription parsing or proxy provider semantics.
- Redesigning MiClash rule mode, fake-ip mode, or global proxy mode.
