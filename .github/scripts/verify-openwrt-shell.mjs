import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const scripts = [
	'install-miclash.sh',
	'luci-app-miclash/rootfs/etc/init.d/clash',
	'luci-app-miclash/rootfs/etc/hotplug.d/iface/40-clash',
	'luci-app-miclash/rootfs/etc/hotplug.d/net/99-clash-tun',
	'luci-app-miclash/rootfs/opt/clash/bin/clash-rules'
];

const shell = process.env.SHELL_CHECK_BIN || '/bin/sh';
const missing = [];
let failed = false;

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

if (failed) process.exit(1);

console.log(`OpenWrt shell verified: ${scripts.length} files`);
