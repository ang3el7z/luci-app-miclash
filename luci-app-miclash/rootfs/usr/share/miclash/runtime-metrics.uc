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
	if (type(dependencies?.service_state) != 'function' || type(dependencies?.now) != 'function' ||
		type(dependencies?.request) != 'function')
		fail('INVALID_ARGUMENT');
	let previous = null;

	function read_connections() {
		let connections;
		try {
			connections = dependencies.request('/connections');
		}
		catch (error) { return null; }
		if (connections?.ok !== true || type(connections.data) != 'object' ||
			type(connections.data.connections) != 'array')
			return null;
		let upload_total = nonnegative(connections.data.uploadTotal);
		let download_total = nonnegative(connections.data.downloadTotal);
		let memory_bytes = nonnegative(connections.data.memory);
		let observed_at;
		try { observed_at = nonnegative(dependencies.now()); }
		catch (error) { observed_at = null; }
		if (upload_total == null || download_total == null || memory_bytes == null || observed_at == null)
			return null;
		return { upload_total, download_total, memory_bytes, observed_at,
			connections: length(connections.data.connections) };
	};

	function status() {
		let service;
		try { service = dependencies.service_state(); }
		catch (error) {
			previous = null;
			return unavailable(false);
		}
		if (service?.running !== true) {
			previous = null;
			return unavailable(false);
		}

		let current = null;
		for (let attempt = 0; attempt < 2 && current == null; attempt++)
			current = read_connections();
		if (current == null) {
			previous = null;
			return unavailable(true);
		}

		let upload_rate = 0, download_rate = 0;
		if (previous != null && current.observed_at > previous.observed_at &&
			current.upload_total >= previous.upload_total && current.download_total >= previous.download_total) {
			let elapsed = current.observed_at - previous.observed_at;
			upload_rate = nonnegative((current.upload_total - previous.upload_total) * 1000 / elapsed);
			download_rate = nonnegative((current.download_total - previous.download_total) * 1000 / elapsed);
			if (upload_rate == null || download_rate == null) {
				upload_rate = 0;
				download_rate = 0;
			}
		}
		previous = current;

		return {
			running: true,
			available: true,
			upload_rate,
			download_rate,
			upload_total: current.upload_total,
			download_total: current.download_total,
			connections: current.connections,
			memory_bytes: current.memory_bytes
		};
	};

	return { status };
};
