'use strict';
'require fs';
'require view.miclash.utils';

const ANSI_RE = /\x1b\[[0-9;]*m/g;
const SYSLOG_CLASH_RE = /\w+\.(\w+)\s+(clash(?:-rules|-hotplug)?)(?:\[\d+\])?:\s*(.*)$/;

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

function extractLogTime(line) {
	const bracket = String(line || '').match(/\[(\d{4}-\d{2}-\d{2}\s+([\d:]+))\]/);
	if (bracket) return bracket[2] || bracket[1];
	const classic = String(line || '').match(/\b(\d{2}:\d{2}:\d{2})\b/);
	return classic ? classic[1] : '--:--:--';
}

function formatLine(line) {
	const raw = String(line || '').replace(ANSI_RE, '').trim();
	if (!raw) return null;

	const syslogMatch = raw.match(SYSLOG_CLASH_RE);
	if (syslogMatch) {
		const level = String(syslogMatch[1] || '').toUpperCase();
		const daemon = syslogMatch[2];
		const message = view_miclash_utils.formatClashLogMessage(syslogMatch[3]);

		return {
			text: '[' + extractLogTime(raw) + '] [' + daemon + '] [' + level + '] ' + message,
			level: level
		};
	}

	const clashRawMatch = raw.match(/^time="([^"]+)"\s+level=(\w+)\s+msg="((?:\\.|[^"\\])*)"$/);
	if (clashRawMatch) {
		const isoTime = clashRawMatch[1];
		const level = String(clashRawMatch[2] || '').toUpperCase();
		const message = view_miclash_utils.formatClashLogMessage('msg="' + clashRawMatch[3] + '"');
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
