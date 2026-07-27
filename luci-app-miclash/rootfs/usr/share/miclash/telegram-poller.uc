import * as errors from 'miclash.errors';

const MAX_BACKOFF_MS = 60000;

export function retry_delay_ms(failures) {
	if (type(failures) != 'int' || failures < 1)
		errors.fail('INVALID_ARGUMENT');
	return min(MAX_BACKOFF_MS, 1000 * (1 << min(failures - 1, 6)));
};

export function poll_timeout_seconds(settings) {
	let timeout = settings?.poll_timeout_seconds ?? 25;
	if (type(timeout) != 'int' || timeout < 5 || timeout > 50)
		errors.fail('INVALID_ARGUMENT');
	return timeout;
};
