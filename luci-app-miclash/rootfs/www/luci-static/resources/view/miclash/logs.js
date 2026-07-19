'use strict';
'require view.miclash.api';
'require view.miclash.utils';

const ANSI_RE = /\x1b\[[0-9;]*m/g;
const SYSLOG_APP_RE = /\w+\.(\w+)\s+((?:clash(?:-rules|-hotplug)?)|miclash|mihomo)(?:\[\d+\])?:\s*(.*)$/;
const LOG_FILTER_RE = /\b(?:clash(?:-rules|-hotplug)?|miclash|mihomo)(?:\[\d+\])?:/i;

async function readRaw() {
	const api = view_miclash_api.create();
	const lines = [];
	let generation = '', cursor = 0, restarts = 0;
	try {
		for (let page = 0; page < 8 && lines.length < 1000; page++) {
			const reply = await api.logs_read(generation, cursor, 200);
			if (reply?.stale === true && restarts++ < 1) {
				generation = ''; cursor = 0; lines.length = 0; page = -1; continue;
			}
			if (!reply || reply.cursor !== cursor || !Array.isArray(reply.lines)) break;
			if (generation !== '' && reply.generation !== generation) break;
			if (generation === '' && typeof reply.generation === 'string') generation = reply.generation;
			reply.lines.slice(0, 200).forEach((line) => lines.push(String(line || '')));
			if (!reply.has_more) break;
			if (!Number.isInteger(reply.next_cursor) || reply.next_cursor <= cursor) break;
			cursor = reply.next_cursor;
		}
		return lines.join('\n').trim();
	} catch (e) {
		return '';
	} finally {
		api.destroy();
	}
}

function extractLogTime(line) {
	const bracket = String(line || '').match(/\[(\d{4}-\d{2}-\d{2}\s+([\d:]+))\]/);
	if (bracket) return bracket[2] || bracket[1];
	const classic = String(line || '').match(/\b(\d{2}:\d{2}:\d{2})\b/);
	return classic ? classic[1] : '--:--:--';
}

function normalizeLevel(level) {
	const clean = String(level || '').toUpperCase();
	if (/^(ERR|ERRO|ERROR)$/.test(clean)) return 'ERROR';
	if (/^(WARN|WARNING)$/.test(clean)) return 'WARN';
	if (/^DEBUG$/.test(clean)) return 'DEBUG';
	if (/^TRACE$/.test(clean)) return 'TRACE';
	if (/^INFO$/.test(clean)) return 'INFO';
	return clean || 'MUTED';
}

function levelClass(level) {
	const normalized = normalizeLevel(level).toLowerCase();
	return 'sbox-log-level-' + normalized;
}

function daemonClass(daemon) {
	return 'sbox-log-daemon-' + String(daemon || 'clash').replace(/[^a-z0-9_-]+/gi, '-').toLowerCase();
}

function buildLogItem(time, daemon, level, message, rawText) {
	const normalized = normalizeLevel(level);
	const text = '[' + time + '] [' + daemon + '] [' + normalized + '] ' + message;
	return {
		text: rawText || text,
		time: time,
		daemon: daemon || 'clash',
		level: normalized,
		message: message || '',
		levelClass: levelClass(normalized),
		daemonClass: daemonClass(daemon)
	};
}

function formatLine(line) {
	const raw = String(line || '').replace(ANSI_RE, '').trim();
	if (!raw) return null;

	const syslogMatch = raw.match(SYSLOG_APP_RE);
	if (syslogMatch) {
		const level = normalizeLevel(syslogMatch[1]);
		const daemon = syslogMatch[2];
		const message = view_miclash_utils.formatClashLogMessage(syslogMatch[3]);

		return buildLogItem(extractLogTime(raw), daemon, level, message);
	}

	const clashRawMatch = raw.match(/^time="([^"]+)"\s+level=(\w+)\s+msg="((?:\\.|[^"\\])*)"$/);
	if (clashRawMatch) {
		const isoTime = clashRawMatch[1];
		const level = normalizeLevel(clashRawMatch[2]);
		const message = view_miclash_utils.formatClashLogMessage('msg="' + clashRawMatch[3] + '"');
		const time = (isoTime.match(/(\d{2}:\d{2}:\d{2})/) || [null, '--:--:--'])[1];

		return buildLogItem(time, 'clash', level, message);
	}

	return null;
}

return L.Class.extend({
	readRaw: readRaw,
	formatLine: formatLine
});
