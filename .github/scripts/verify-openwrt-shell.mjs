import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const scripts = [
	'install-miclash.sh',
	'luci-app-miclash/rootfs/etc/init.d/clash',
	'luci-app-miclash/rootfs/etc/hotplug.d/iface/40-clash',
	'luci-app-miclash/rootfs/etc/hotplug.d/net/99-clash-tun',
	'luci-app-miclash/rootfs/opt/clash/bin/clash-rules',
	'luci-app-miclash/rootfs/opt/clash/bin/miclash-update'
];

const shell = process.env.SHELL_CHECK_BIN || '/bin/sh';
const missing = [];
let failed = false;
const clashRulesPath = path.join(process.cwd(), 'luci-app-miclash/rootfs/opt/clash/bin/clash-rules');

for (const rel of scripts) {
	const file = path.join(process.cwd(), rel);
	if (!fs.existsSync(file)) {
		missing.push(rel);
		continue;
	}

	const result = spawnSync(shell, ['-n', file], { encoding: 'utf8' });
	if (result.status !== 0) {
		failed = true;
		process.stderr.write(result.stderr || result.stdout || `Shell syntax check failed: ${rel}\n`);
	}
}

if (missing.length) {
	failed = true;
	process.stderr.write('Missing OpenWrt shell scripts:\n');
	for (const rel of missing) process.stderr.write(`- ${rel}\n`);
}

if (fs.existsSync(clashRulesPath)) {
	const clashRules = fs.readFileSync(clashRulesPath, 'utf8');
	if (!/repair_network_path\(\)\s*{[\s\S]+traffic_rules_exist[\s\S]+repair_policy_routing_state[\s\S]+repair_forward_rules[\s\S]+apply_guard_rules/.test(clashRules)) {
		failed = true;
		process.stderr.write('clash-rules: repair_network_path must rebuild rules, repair policy/forward state, and refresh guard\n');
	}
	if (!/\brepair_network_path\)[\s\S]+repair_network_path/.test(clashRules)) {
		failed = true;
		process.stderr.write('clash-rules: missing repair_network_path CLI case\n');
	}
}

if (failed) process.exit(1);

console.log(`OpenWrt shell verified: ${scripts.length} files`);
