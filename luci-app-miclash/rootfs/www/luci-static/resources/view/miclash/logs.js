'use strict';
'require fs';

const ANSI_RE = /\x1b\[[0-9;]*m/g;
const SYSLOG_CLASH_RE = /^.*? ([\d:]{8}) .*?daemon\.(\w+)\s+(clash(?:-rules|-hotplug)?)\b(?:\[\d+\])?:\s*(.*)$/;

async function readRaw() {
	try {
		const direct = await fs.exec('/sbin/logread', ['-e', 'clash']);
		if (direct.code === 0) return String(direct.stdout || '').trim();
	} catch (e) {}

	try {
		const all = await fs.exec('/sbin/logread', []);
		if (all.code === 0) {
			return String(all.stdout || '')
				.split('\n')
				.filter((line) => /clash/i.test(line))
				.join('\n')
				.trim();
		}
	} catch (e) {}

	return '';
}

function normalizeMessage(message) {
	let text = String(message || '').trim();
	if (!text) return '';

	const msgOnly = text.match(/^msg="(.*)"$/);
	if (msgOnly) text = msgOnly[1];

	const clashCore = text.match(/^time="[^"]+"\s+level=\w+\s+msg="(.*)"$/);
	if (clashCore) text = clashCore[1];

	return text.replace(/\\"/g, '"').trim();
}

function formatLine(line) {
	const raw = String(line || '').replace(ANSI_RE, '').trim();
	if (!raw) return null;

	const syslogMatch = raw.match(SYSLOG_CLASH_RE);
	if (syslogMatch) {
		const time = syslogMatch[1];
		const level = String(syslogMatch[2] || '').toUpperCase();
		const daemon = syslogMatch[3];
		const message = normalizeMessage(syslogMatch[4]);

		return {
			text: '[' + time + '] [' + daemon + '] [' + level + '] ' + message,
			level: level
		};
	}

	const clashRawMatch = raw.match(/^time="([^"]+)"\s+level=(\w+)\s+msg="(.*)"$/);
	if (clashRawMatch) {
		const isoTime = clashRawMatch[1];
		const level = String(clashRawMatch[2] || '').toUpperCase();
		const message = normalizeMessage(clashRawMatch[3]);
		const time = (isoTime.match(/(\d{2}:\d{2}:\d{2})/) || [null, '--:--:--'])[1];

		return {
			text: '[' + time + '] [clash] [' + level + '] ' + message,
			level: level
		};
	}

	if (!/clash/i.test(raw)) return null;

	const fallbackLevel =
		/\b(FATAL|PANIC|ERRO|ERROR)\b/i.test(raw) ? 'ERROR' :
		/\b(WARN|WARNING)\b/i.test(raw) ? 'WARN' :
		/\b(INFO)\b/i.test(raw) ? 'INFO' : 'MUTED';

	return { text: raw, level: fallbackLevel };
}

return L.Class.extend({
	readRaw: readRaw,
	formatLine: formatLine
});
