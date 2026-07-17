import { readFileSync } from 'node:fs';

const read = path => readFileSync(path, 'utf8');
const makefile = read('luci-app-miclash/Makefile');
const remove = read('luci-app-miclash/rootfs/usr/share/miclash/package-remove');
const release = read('luci-app-miclash/rootfs/usr/share/miclash/package-release');
const runtime = read('luci-app-miclash/rootfs/usr/share/miclash/runtime.uc');

function check(value, message) { if (!value) throw new Error(message); }

check(remove.includes('/usr/share/miclash/mutation-lock.sh') &&
	remove.includes('miclash_mutation_lock_enter_package_owner 30000'),
	'package removal must own the canonical package mutation lease');
check(remove.indexOf('establish_barrier ||') <
	remove.indexOf('miclash_mutation_lock_enter_package_owner 30000'),
	'package barrier must precede the package lease');
check(remove.includes('guard-runtime.uc protect') &&
	remove.includes('guard-runtime.uc verify-protected'),
	'package removal must establish and verify native Guard protection');
check(remove.includes('stop_disable miclashd') &&
	remove.includes('/etc/init.d/clash stop') && remove.includes('/etc/init.d/clash disable'),
	'package removal must quiesce the only production services');
check(remove.includes('routing-cleanup.uc') && remove.includes('dns-cleanup.uc') &&
	remove.includes('firewall-cleanup.uc'),
	'package removal must use native typed ownership cleanup');
check(!remove.includes('/etc/init.d/clash package_cleanup') &&
	!remove.includes('clash-rules"') && !remove.includes("clash-rules'"),
	'package removal must not depend on a legacy backend');
check(remove.includes('prepare_release_state') && remove.includes('commit_release_state') &&
	release.includes('barrier-complete.hold'),
	'removal must retain a retryable completion proof');
check(makefile.includes('/usr/share/miclash/package-remove') &&
	makefile.includes('/var/run/miclash/package-removal'),
	'package lifecycle must invoke the removal authority');
check(!runtime.includes('/opt/clash/bin/clash-rules'),
	'production runtime must have no legacy Guard dependency');

console.log('package removal native-backend contract passed');
