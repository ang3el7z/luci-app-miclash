'use strict';
'require baseclass';

const MAX_RECORDS = 200;
const listeners = new Set();
const records = [];
const active = new Map();
let sequence = 0;

function clock() {
	if (typeof performance === 'object' && typeof performance.now === 'function')
		return performance.now();
	return Date.now();
}

function round(value) {
	return Math.round(Math.max(0, Number(value) || 0) * 10) / 10;
}

function name(value) {
	const clean = String(value || '').replace(/[^A-Za-z0-9._:-]/g, '_').slice(0, 64);
	return clean || 'unknown';
}

function notify() {
	for (const listener of listeners) {
		try { listener(); } catch (error) {}
	}
}

function append(kind, metricName, startedAt, succeeded, finishedAt) {
	const finished = Number.isFinite(Number(finishedAt)) ? Number(finishedAt) : clock();
	const started = Number.isFinite(Number(startedAt)) ? Number(startedAt) : finished;
	records.push({
		kind,
		name: name(metricName),
		duration_ms: round(finished - started),
		success: succeeded !== false,
		at_ms: Date.now()
	});
	if (records.length > MAX_RECORDS) records.splice(0, records.length - MAX_RECORDS);
	notify();
}

function aggregate(kind) {
	const result = {};
	for (const record of records) {
		if (record.kind !== kind) continue;
		const current = result[record.name] || {
			count: 0, failures: 0, total_ms: 0, average_ms: 0, maximum_ms: 0
		};
		current.count++;
		if (!record.success) current.failures++;
		current.total_ms = round(current.total_ms + record.duration_ms);
		current.maximum_ms = Math.max(current.maximum_ms, record.duration_ms);
		current.average_ms = round(current.total_ms / current.count);
		result[record.name] = current;
	}
	return result;
}

return baseclass.extend({
	now: clock,

	recordRpc(method, startedAt, succeeded, finishedAt) {
		append('rpc', method, startedAt, succeeded, finishedAt);
	},

	begin(metricName) {
		const token = { id: ++sequence, name: name(metricName), started_at: clock() };
		active.set(token.id, token);
		return token;
	},

	end(token, succeeded) {
		if (!token || active.get(token.id) !== token) return false;
		active.delete(token.id);
		append('timing', token.name, token.started_at, succeeded !== false);
		return true;
	},

	snapshot() {
		return {
			methods: aggregate('rpc'),
			timings: aggregate('timing'),
			records: records.map((record) => ({ ...record }))
		};
	},

	clear() {
		records.splice(0);
		active.clear();
		notify();
	},

	subscribe(callback) {
		if (typeof callback !== 'function') return () => {};
		listeners.add(callback);
		return () => listeners.delete(callback);
	}
});
