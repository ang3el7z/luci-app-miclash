# MiClash Guard Proxy Server Overlap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent client guard mode from treating proxy server IPs as LAN-client bypass destinations.

**Architecture:** Keep `proxy_servers` loop-prevention for router OUTPUT, but make LAN-client PREROUTING/mangle server exclusions conditional on `INTERNET_ONLY_MICLASH`. Add a static regression test that checks both nftables and iptables rule builders by parsing `clash-rules`.

**Tech Stack:** POSIX shell for OpenWrt runtime rules, Node.js static checks for repository tests.

---

### Task 1: Add Regression Test

**Files:**
- Create: `tools/check-guard-proxy-overlap.mjs`

- [ ] **Step 1: Write the failing test**

Create `tools/check-guard-proxy-overlap.mjs` with these checks:

```js
import { readFileSync } from 'node:fs';

const rules = readFileSync('luci-app-miclash/rootfs/opt/clash/bin/clash-rules', 'utf8');
let failed = false;

function check(condition, message) {
	if (!condition) {
		console.error(message);
		failed = true;
	}
}

function functionBody(name) {
	const start = rules.indexOf(`${name}() {`);
	if (start < 0) return '';
	let depth = 0;
	for (let i = rules.indexOf('{', start); i < rules.length; i++) {
		const char = rules[i];
		if (char === '{') depth++;
		if (char === '}') {
			depth--;
			if (depth === 0) return rules.slice(start, i + 1);
		}
	}
	return '';
}

const nftClient = functionBody('apply_nft_server_exclusions_mangle');
const iptablesClient = functionBody('apply_iptables_server_exclusions');
const nftOutput = functionBody('apply_nft_output_rules');
const iptablesOutput = functionBody('apply_iptables_output_rules');

check(nftClient.includes('INTERNET_ONLY_MICLASH'),
	'nft client proxy-server exclusions must branch on INTERNET_ONLY_MICLASH.');
check(nftClient.includes('Client guard enabled') && nftClient.includes('return 0'),
	'nft client proxy-server exclusions must skip the bypass when client guard is enabled.');
check(nftClient.includes('nft add rule inet clash CLASH_MARK ip daddr @proxy_servers return'),
	'nft client proxy-server exclusion must remain available when client guard is disabled.');

check(iptablesClient.includes('INTERNET_ONLY_MICLASH'),
	'iptables client proxy-server exclusions must branch on INTERNET_ONLY_MICLASH.');
check(iptablesClient.includes('Client guard enabled') && iptablesClient.includes('return 0'),
	'iptables client proxy-server exclusions must skip the bypass when client guard is enabled.');
check(iptablesClient.includes('iptables -t mangle -A CLASH_PROCESS -d "$ip/32" -j RETURN'),
	'iptables destination proxy-server exclusion must remain available when client guard is disabled.');

check(nftOutput.includes('nft add rule inet clash output ip daddr @proxy_servers return'),
	'nft OUTPUT proxy-server loop-prevention must remain present.');
check(iptablesOutput.includes('CLASH_LOCAL') && iptablesOutput.includes('iptables -t mangle -A CLASH_LOCAL -d "$ip/32" -j RETURN'),
	'iptables OUTPUT proxy-server loop-prevention must remain present.');

if (failed) process.exit(1);
console.log('guard proxy overlap check passed');
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node tools/check-guard-proxy-overlap.mjs`

Expected: FAIL because `apply_nft_server_exclusions_mangle` and `apply_iptables_server_exclusions` do not branch on `INTERNET_ONLY_MICLASH`.

### Task 2: Implement Conditional Client Exclusions

**Files:**
- Modify: `luci-app-miclash/rootfs/opt/clash/bin/clash-rules`

- [ ] **Step 1: Skip nft client server exclusions when guard is enabled**

Update `apply_nft_server_exclusions_mangle()` so it begins with:

```sh
    if [ "$INTERNET_ONLY_MICLASH" = "true" ]; then
        msg "Client guard enabled; proxy server IPs are not excluded from client mangle"
        return 0
    fi
```

Then leave the existing `nft add rule inet clash CLASH_MARK ip daddr @proxy_servers return` rule unchanged for guard-disabled compatibility.

- [ ] **Step 2: Skip iptables client server exclusions when guard is enabled**

Update `apply_iptables_server_exclusions()` so it begins with:

```sh
    if [ "$INTERNET_ONLY_MICLASH" = "true" ]; then
        msg "Client guard enabled; proxy server IPs are not excluded from client processing"
        return 0
    fi
```

Then leave the existing per-IP `CLASH_PROCESS` destination/source returns unchanged for guard-disabled compatibility.

- [ ] **Step 3: Run the focused regression test**

Run: `node tools/check-guard-proxy-overlap.mjs`

Expected: PASS with `guard proxy overlap check passed`.

### Task 3: Verify Existing Checks

**Files:**
- No additional files.

- [ ] **Step 1: Run shell syntax checks**

Run:

```powershell
& 'C:\Program Files\Git\bin\sh.exe' -n luci-app-miclash/rootfs/opt/clash/bin/clash-rules
& 'C:\Program Files\Git\bin\sh.exe' -n luci-app-miclash/rootfs/etc/init.d/clash
```

Expected: both commands exit 0.

- [ ] **Step 2: Run static JavaScript checks**

Run:

```powershell
node --check luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js
node tools/check-service-readiness-update-flow.mjs
node tools/check-settings-restart-feedback.mjs
node tools/check-release-channel-columns.mjs
node tools/check-translations.mjs
node tools/check-guard-proxy-overlap.mjs
```

Expected: all commands exit 0.

- [ ] **Step 3: Commit only this change set**

Stage only:

```powershell
git add -- docs/superpowers/plans/2026-07-06-miclash-guard-proxy-server-overlap.md tools/check-guard-proxy-overlap.mjs luci-app-miclash/rootfs/opt/clash/bin/clash-rules
git diff --cached --name-only
git commit -m "fix: keep guard from bypassing proxy server overlaps"
```

Expected staged paths are exactly the plan, the new test, and `clash-rules`.
