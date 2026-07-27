import { atomic_write } from 'miclash.storage';

const PATH = '/etc/miclash/guard-safety-latch';
const CONTENT = 'miclash-guard-safety-latch-v1\n';

export function is_set(runtime) {
	// Presence is intentionally fail-closed. A corrupt or replaced latch is not
	// interpreted as OFF and therefore cannot silently authorize Guard removal.
	return runtime.fs.lstat(PATH) != null;
};

export function set(runtime) {
	return atomic_write(runtime, PATH, CONTENT, 0o600) === true && is_set(runtime);
};

export function clear(runtime) {
	let stat = runtime.fs.lstat(PATH);
	if (stat == null) return true;
	if (stat.type != 'file' || stat.uid != 0 || stat.mode != 0o600 ||
	    runtime.fs.readfile(PATH) != CONTENT)
		return false;
	return runtime.fs.unlink(PATH) === true && !is_set(runtime);
};
