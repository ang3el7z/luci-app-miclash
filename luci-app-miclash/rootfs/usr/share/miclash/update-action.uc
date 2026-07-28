import * as errors from 'miclash.errors';

function parsed(value) {
	if (type(value) != 'string')
		return null;
	value = trim(value);
	value = replace(value, /^v/, '');
	value = replace(value, /-r[0-9]+$/, '');
	let stable = match(value, /^([0-9]+\.[0-9]+\.[0-9]+)$/);
	let rc = stable == null ?
		match(value, /^([0-9]+\.[0-9]+\.[0-9]+)_rc([0-9]+)$/) : null;
	let tagged = stable == null && rc == null ?
		match(value, /^([0-9]+\.[0-9]+\.[0-9]+)[.-]([0-9A-Za-z][0-9A-Za-z.-]*)$/) :
		null;
	let base = stable?.[1] ?? rc?.[1] ?? tagged?.[1];
	if (base == null)
		return null;
	let numeric = [];
	for (let item in split(base, '.'))
		push(numeric, int(item));
	let suffix = null;
	if (rc != null)
		suffix = [ 'rc', int(rc[2]) ];
	else if (tagged != null) {
		suffix = [];
		for (let item in split(tagged[2], /[.-]/))
			push(suffix, match(item, /^[0-9]+$/) ? int(item) : lc(item));
	}
	return { numeric, suffix };
};

export function compare(left, right) {
	let a = parsed(left), b = parsed(right);
	if (a == null || b == null)
		return null;
	let total = max(length(a.numeric), length(b.numeric));
	for (let index = 0; index < total; index++) {
		let x = a.numeric[index] ?? 0, y = b.numeric[index] ?? 0;
		if (x < y) return -1;
		if (x > y) return 1;
	}
	if (a.suffix == null || b.suffix == null) {
		if (a.suffix == null && b.suffix == null) return 0;
		return a.suffix == null ? 1 : -1;
	}
	total = max(length(a.suffix), length(b.suffix));
	for (let index = 0; index < total; index++) {
		if (index >= length(a.suffix)) return -1;
		if (index >= length(b.suffix)) return 1;
		let x = a.suffix[index], y = b.suffix[index];
		if (x === y) continue;
		if (type(x) == 'int' && type(y) != 'int') return -1;
		if (type(x) != 'int' && type(y) == 'int') return 1;
		return x < y ? -1 : 1;
	}
	return 0;
};

export function classify(installed, target) {
	if (parsed(target) == null)
		return 'unknown';
	if (installed == null || installed == '')
		return 'install';
	let compared = compare(installed, target);
	if (compared == null)
		return 'unknown';
	if (compared < 0)
		return 'update';
	if (compared > 0)
		return 'downgrade';
	return 'reinstall';
};

export function validate(action, installed, target) {
	if (action != 'install' && action != 'update' &&
	    action != 'reinstall' && action != 'downgrade')
		errors.fail('INVALID_ARGUMENT');
	if (classify(installed, target) != action)
		errors.fail('INVALID_ARGUMENT');
	return true;
};
