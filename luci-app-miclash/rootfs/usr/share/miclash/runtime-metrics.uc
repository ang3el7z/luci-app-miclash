import { fail } from 'miclash.errors';

const MAX_VALUE = 9007199254740991;

function nonnegative(value) {
	if ((type(value) != 'int' && type(value) != 'double') || value < 0 || value > MAX_VALUE)
		return null;
	return value;
};

function unavailable(running) {
	return { running, available: false };
};

export function create(dependencies) {
	if (type(dependencies?.service_state) != 'function' || type(dependencies?.request) != 'function')
		fail('INVALID_ARGUMENT');

	function status() {
		let service;
		try { service = dependencies.service_state(); }
		catch (error) { return unavailable(false); }
		if (service?.running !== true) return unavailable(false);

		let traffic, connections;
		try {
			traffic = dependencies.request('/traffic');
			connections = dependencies.request('/connections');
		}
		catch (error) { return unavailable(true); }
		if (traffic?.ok !== true || connections?.ok !== true ||
			type(traffic.data) != 'object' || type(connections.data) != 'object' ||
			type(connections.data.connections) != 'array')
			return unavailable(true);

		let upload_rate = nonnegative(traffic.data.up);
		let download_rate = nonnegative(traffic.data.down);
		let upload_total = nonnegative(connections.data.uploadTotal);
		let download_total = nonnegative(connections.data.downloadTotal);
		let memory_bytes = nonnegative(connections.data.memory);
		if (upload_rate == null || download_rate == null || upload_total == null ||
			download_total == null || memory_bytes == null)
			return unavailable(true);

		return {
			running: true,
			available: true,
			upload_rate,
			download_rate,
			upload_total,
			download_total,
			connections: length(connections.data.connections),
			memory_bytes
		};
	};

	return { status };
};
