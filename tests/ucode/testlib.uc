export function assert_true(value, message) {
	if (!value)
		die(message || 'expected truthy value');
};

export function assert_equal(actual, expected, message) {
	if (actual != expected)
		die(message || sprintf('expected %J, got %J', expected, actual));
};

export function assert_match(value, pattern, message) {
	if (!match(value, pattern))
		die(message || sprintf('%J does not match %s', value, pattern));
};

export function assert_throws(fn, code) {
	let thrown = null;
	try { fn(); } catch (e) { thrown = e; }
	assert_true(thrown != null, 'expected function to throw');
	// Current ucode catch objects expose { type, message, stacktrace }.
	// Retain .code support for forward-compatible structured errors.
	assert_equal(thrown.code ?? thrown.message, code, 'unexpected error code');
};
