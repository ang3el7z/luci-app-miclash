import { fail } from 'miclash.errors';
import * as storage from 'miclash.storage';

const DEFAULT_PATH = '/tmp/miclash/daemon-ready.json';

export function create(runtime, options) {
	if (type(runtime?.fs?.lstat) != 'function' || type(runtime?.fs?.unlink) != 'function' ||
	    type(runtime?.clock?.now) != 'function')
		fail('INVALID_ARGUMENT');
	let path = options?.path ?? DEFAULT_PATH;
	let writer = options?.storage ?? storage;
	if (type(path) != 'string' || path != DEFAULT_PATH || type(writer?.atomic_write) != 'function')
		fail('INVALID_ARGUMENT');

	function clear() {
		if (runtime.fs.lstat(path) != null && runtime.fs.unlink(path) !== true)
			fail('INTERNAL');
		return true;
	};

	function activate(reconcile, source) {
		if (type(reconcile?.startup) != 'function' || type(source) != 'string')
			fail('INVALID_ARGUMENT');
		let failure = null;
		try {
			if (reconcile.startup(source) !== true)
				fail('HEALTH_FAILED');
			if (writer.atomic_write(runtime, path, sprintf('%J\n', {
				schema_version: 1, startup_reconciled: true,
				ready_at_ms: runtime.clock.now()
			}), 0o600) !== true)
				fail('INTERNAL');
			return true;
		}
		catch (error) { failure = error?.code ?? error?.message ?? 'INTERNAL'; }
		try { clear(); }
		catch (error) { fail('INTERNAL'); }
		fail(failure);
	};

	return { clear, activate, revoke: clear };
};
