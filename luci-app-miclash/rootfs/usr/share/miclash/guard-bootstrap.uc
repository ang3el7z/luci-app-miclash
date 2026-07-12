#!/usr/bin/ucode

import * as guard from 'miclash.guard';
import * as runtime_module from 'miclash.runtime';
import * as settings_module from 'miclash.settings';
import { atomic_write } from 'miclash.storage';

const STATE_PATH = '/etc/miclash/guard-bootstrap.json';
const STATUS_PATH = '/var/run/miclash/guard-bootstrap.json';
const BATCH_PATH = '/tmp/miclash/guard-bootstrap.nft';
const TABLES = [ 'miclash_guard_bootstrap_v1', 'miclash_guard_emergency_v1' ];

function nft_binary(runtime) {
	for (let path in [ '/usr/sbin/nft', '/sbin/nft', '/usr/bin/nft' ])
		if (runtime.fs.lstat(path)?.type == 'file')
			return path;
	return '/usr/sbin/nft';
};

function run(runtime, command, args) {
	return runtime.process.run({ command, args }).code === 0;
};

function ensure_directories(runtime) {
	for (let path in [ runtime.paths.etc, runtime.paths.run, runtime.paths.tmp ])
		if (!run(runtime, '/bin/mkdir', [ '-p', path ]))
			return false;
	return true;
};

function table_installed(runtime, table) {
	let inspect = nft_binary(runtime) + ' list chain inet ' + table + ' protected_direct_drop_v1';
	return run(runtime, '/bin/sh', [ '-c',
		inspect + " 2>/dev/null | grep -Fq 'meta nfproto ipv4 drop' && " +
		inspect + " 2>/dev/null | grep -Fq 'meta nfproto ipv6 drop'"
	]);
};

function installed(runtime) {
	for (let table in TABLES)
		if (table_installed(runtime, table))
			return true;
	return false;
};

function ruleset(table) {
	return join('\n', [
		'add table inet ' + table,
		'add chain inet ' + table + ' protected_direct_drop_v1 { type filter hook forward priority -310; policy accept; }',
		'add rule inet ' + table + ' protected_direct_drop_v1 iifname "clash-tun" accept',
		'add rule inet ' + table + ' protected_direct_drop_v1 oifname "clash-tun" accept',
		'add rule inet ' + table + ' protected_direct_drop_v1 ct status dnat accept',
		'add rule inet ' + table + ' protected_direct_drop_v1 udp sport 67 udp dport 68 accept',
		'add rule inet ' + table + ' protected_direct_drop_v1 udp sport 68 udp dport 67 accept',
		'add rule inet ' + table + ' protected_direct_drop_v1 ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 } accept',
		'add rule inet ' + table + ' protected_direct_drop_v1 ip6 daddr { ::/128, ::1/128, fc00::/7, fe80::/10, ff00::/8 } accept',
		'add rule inet ' + table + ' protected_direct_drop_v1 meta nfproto ipv4 drop comment "miclash-guard-bootstrap"',
		'add rule inet ' + table + ' protected_direct_drop_v1 meta nfproto ipv6 drop comment "miclash-guard-bootstrap"',
		''
	]);
};

function install_rules(runtime) {
	if (installed(runtime))
		return true;
	if (!ensure_directories(runtime))
		return false;

	for (let table in TABLES) {
		atomic_write(runtime, BATCH_PATH, ruleset(table), 0o600);
		if (run(runtime, nft_binary(runtime), [ '-f', BATCH_PATH ]) && table_installed(runtime, table))
			return true;
	}
	return false;
};

function remove_rules(runtime) {
	let nft = nft_binary(runtime);
	for (let table in TABLES)
		if (table_installed(runtime, table) &&
		    !run(runtime, nft, [ 'delete', 'table', 'inet', table ]))
			return false;
	return !installed(runtime);
};

function write_json(runtime, path, value, mode) {
	if (!ensure_directories(runtime))
		return false;
	atomic_write(runtime, path, sprintf('%J\n', value), mode);
	return true;
};

function persisted(runtime) {
	let content = runtime.fs.readfile(STATE_PATH);
	if (content == null)
		return null;
	try { return json(content); }
	catch (error) { return null; }
};

function legacy_enabled(runtime) {
	let content = runtime.fs.readfile('/opt/clash/settings');
	if (content == null)
		return null;
	let found = null;
	for (let raw in split(content, '\n')) {
		let line = trim(raw);
		if (line != 'INTERNET_ONLY_MICLASH=true' && line != 'INTERNET_ONLY_MICLASH=false')
			continue;
		let value = line == 'INTERNET_ONLY_MICLASH=true';
		if (found != null && found != value)
			return null;
		found = value;
	}
	return found;
};

function observations(runtime) {
	return {
		persisted: persisted(runtime),
		installed: { verified: installed(runtime), enabled: true },
		legacy_enabled: legacy_enabled(runtime)
	};
};

function production_adapter(runtime) {
	return {
		verify: (wanted) => wanted.enabled ? installed(runtime) : !installed(runtime),
		install: () => install_rules(runtime),
		remove: () => remove_rules(runtime),
		persist: (wanted) => write_json(runtime, STATE_PATH, {
			schema_version: 1,
			enabled: wanted.enabled
		}, 0o600),
		record_status: (status) => write_json(runtime, STATUS_PATH, {
			...status,
			verified_at_ms: runtime.clock.now()
		}, 0o600)
	};
};

function main() {
	if (length(ARGV) != 1 || (ARGV[0] != 'install' && ARGV[0] != 'disable' && ARGV[0] != 'remove'))
		die('usage: guard-bootstrap.uc {install|disable|remove}\n');

	let runtime = runtime_module.create();
	runtime.observers.guard = production_adapter(runtime);
	let wanted;
	if (ARGV[0] == 'disable' || ARGV[0] == 'remove')
		wanted = {
			enabled: false,
			source: ARGV[0] == 'disable' ? 'explicit_disable' : 'package_removal',
			explicit_disable: true
		};
	else {
		let settings = null;
		try { settings = settings_module.load(runtime); }
		catch (error) {}
		wanted = guard.desired(settings, observations(runtime));
	}

	guard.install_bootstrap(runtime, wanted);
};

main();
