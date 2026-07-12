# Task 3 report: Transactional nftables backend

## Status

DONE

## Scope delivered

- Added deterministic `miclash.firewall.common` validation/helpers.
- Added `miclash.firewall.nft` with `compile(desired)`, `observe(runtime)`, `apply(runtime, compiled)`, and `cleanup(runtime, mode)`.
- Added exact semantic-golden, validation, generation topology, observation, apply failure, temp-file, and Guard-ownership coverage in `tests/ucode/test-firewall-nft.uc`.
- Did not implement iptables, routing, or DNS backends.

The accepted Task 1 nft goldens remain unchanged. They are the full network contract, including the historical `inet miclash_guard` semantic section. Task 3 exact-compares an explicit compiler-owned projection of each full golden, filtering only that section. The executable batch never contains `miclash_guard_bootstrap_v1`, `miclash_guard_emergency_v1`, or legacy `miclash_guard` ownership commands. The independent Task 2 Guard therefore remains continuously installed across compile, apply, rollback, verification failure, and cleanup.

## RED evidence

Primary RED, after adding the complete test harness before production files:

```text
==> tests/ucode/test-firewall-nft.uc
Syntax error: Unable to resolve path for module 'miclash.firewall.nft'
1 of 1 ucode tests failed
```

Review-driven RED/GREEN cycles were also test-first:

1. Missing generation entry-chain creation:

```text
tproxy-explicit-guard-ipv4-quic: generation entry chains exist before anchor links
1 of 1 ucode tests failed
```

2. Structured observation initially trusted a stale table comment instead of the switched stable anchor:

```text
structured anchor observation identifies switched generation without stale table comments
1 of 1 ucode tests failed
```

3. Caller-controlled nft set names were initially ignored:

```text
expected function to throw
1 of 1 ucode tests failed
```

4. The normal runtime process adapter reports status but not stdout, so production observation initially could not consume real nft JSON:

```text
production observation captures nft output when process adapter returns status only
1 of 1 ucode tests failed
```

Each RED failed for the intended missing behavior and was followed by a focused GREEN.

## Compiler and transaction design

- Generation IDs are deterministic 12-hex SHA-256 prefixes unless the reconciler supplies a validated ID.
- Stable base chains are `prerouting`, `output`, `tun_input`, and `tun_forward`.
- Every generation has a fixed inventory of entry/proxy chains and IPv4/IPv6 local, provider, and fake-IP sets. Optional sets are present but empty, making old-generation removal deterministic.
- A single nft batch creates/populates the new generation, flushes and relinks stable anchors, and deletes every prior-generation owned object. nft transaction rollback prevents a partial switch.
- The compiled semantic model preserves accepted family parity, interface-selection semantics, device block/direct/proxy/inherit precedence, QUIC family scope, proxy-server bypass ordering, fake-IP behavior, TPROXY/TUN/MIXED marks, exact `0x0002` and upper-bit loop prevention, and mark-zero OUTPUT matching.
- Guard-on client provider bypass remains omitted while router OUTPUT bypass remains before marking.

## Observation, apply, cleanup, and failure safety

- JSON observation identifies the active generation from the structured `prerouting` anchor jump. It accepts the table schema comment only as a compatibility fallback. Normalized text observation uses the same anchor first.
- Apply creates an exclusive entropy-named batch under the runtime temp directory with mode `0600`, writes/flushes/closes it, invokes exactly `nft -f <path>`, verifies the active generation through observation, and removes the owned temp on success or failure.
- Failure simulation covers before `nft -f` (open failure), inside `nft -f` (nonzero exit), and after `nft -f` (generation verification mismatch). Every path asserts no owned batch remains.
- Cleanup requires `{ preserve_guard: true }`, deletes only `table inet miclash`, re-observes absence, and never names either Guard table.
- Invalid interfaces, IPs, CIDRs, generation identifiers, and caller-controlled set names are rejected before command generation.

## Real nft evidence

An isolated Ubuntu nft namespace with `CAP_NET_ADMIN` consumed production-generated batches. Generation A used the IPv4-only TPROXY/Guard/QUIC scenario. Generation B used the dual-stack MIXED/Guard/device-policy/QUIC scenario. The A-to-B transaction linked generation `222222222222` and removed generation `111111111111`. Fresh `nft -j list table inet miclash` showed stable anchors jumping only to `*_g_222222222222`, IPv4 and IPv6 MIXED rules, TUN anchors, all new generation sets/chains, and no old-generation object names. Production `observe(create())` returned:

```text
{ "installed": true, "generation": "222222222222", "source": "json-anchor" }
nft-tproxy-ipv4-to-mixed-dualstack-switch-and-observe-ok
```

The same real parser accepted the production batch with `nft -c -f -`.

No Guard table was created, deleted, flushed, or weakened during the experiment.

## GREEN and final verification

Focused:

```text
==> tests/ucode/test-firewall-nft.uc
1 ucode tests passed
```

Fresh full pinned-CI ucode suite:

```text
14 ucode tests passed
```

Repository checks:

```text
16 repository checks passed
translation check passed (224 localized strings)
ucode layout check passed
```

`git diff --check` exited zero.

## Self-review

- Confirmed all 12 representative scenarios exact-match their compiler-owned golden projection.
- Confirmed Task 1 goldens and `test-network-contract.uc` are unchanged and GREEN.
- Confirmed production files contain no Guard table name or Guard deletion primitive.
- Confirmed base anchors are flushed only inside the same transaction that creates/populates and links the next generation.
- Confirmed fixed generation topology makes removal independent of optional desired data.
- Confirmed structured observation follows the active anchor rather than a table comment that nft may retain across `add table` updates.
- Confirmed apply verification is not inferred from process exit alone.
- Confirmed batch paths are unique, exclusive, `0600`, and removed on tested success/failure paths.
- Confirmed no iptables, routing, DNS, Guard bootstrap, or accepted-golden production scope was changed.

## Concerns

None known.
