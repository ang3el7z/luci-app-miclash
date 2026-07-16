#!/usr/bin/ucode

import * as guard from 'miclash.guard';
import * as runtime_module from 'miclash.runtime';
import * as settings_module from 'miclash.settings';
import { atomic_write } from 'miclash.storage';

const STATE_PATH = '/etc/miclash/guard-bootstrap.json';
const STATUS_PATH = '/var/run/miclash/guard-bootstrap.json';
const BATCH_PATH = '/tmp/miclash/guard-bootstrap.nft';

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

function capture(command) {
	let pipe = require('fs').popen(command + ' 2>/dev/null', 'r');
	if (pipe == null)
		return null;
	let output = pipe.read('all');
	return pipe.close() == 0 ? output : null;
};

function nft_io(runtime) {
	let nft = nft_binary(runtime);
	return {
		list_tables: () => capture(nft + ' -j list tables'),
		list_table: (table) => capture(nft + ' -j list table inet ' + table),
		apply: (table, batch) => {
			if (!ensure_directories(runtime))
				return false;
			atomic_write(runtime, BATCH_PATH, batch, 0o600);
			return run(runtime, nft, [ '-f', BATCH_PATH ]);
		},
		remove: (tables, batch) => {
			if (!ensure_directories(runtime))
				return false;
			atomic_write(runtime, BATCH_PATH, batch, 0o600);
			return run(runtime, nft, [ '-f', BATCH_PATH ]);
		}
	};
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

function observations(runtime, backend) {
	return {
		persisted: persisted(runtime),
		installed: {
			verified: backend.installed(),
			enabled: true,
			occupied: backend.occupied()
		}
	};
};

function production_adapter(runtime, backend) {
	return {
		verify: (wanted) => wanted.enabled ? backend.installed() : backend.absent(),
		install: () => backend.install(),
		remove: () => backend.remove(),
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
	let backend = guard.create_nft_backend(nft_io(runtime));
	runtime.observers.guard = production_adapter(runtime, backend);
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
		wanted = guard.desired(settings, observations(runtime, backend));
	}

	guard.install_bootstrap(runtime, wanted);
};

main();
