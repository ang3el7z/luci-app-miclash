'use strict';
'require fs';
'require view.miclash.utils';
'require view.miclash.logs';

const SERVICE_ACTION_SETTLE_MS = 300;
const DIAGNOSTIC_LOG_LINES = 12;
const DIAGNOSTIC_TEST_LINES = 40;
const START_SERVICE_TIMEOUT_MS = 180000;
const STOP_SERVICE_TIMEOUT_MS = 60000;
const RESTART_SERVICE_TIMEOUT_MS = 180000;
const READY_POLL_INTERVAL_MS = 1000;
const CONFIG_PATH = '/opt/clash/config.yaml';
const SETTINGS_PATH = '/opt/clash/settings';

function delay(ms) {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

function shellQuote(s) {
	return '\'' + String(s).replace(/'/g, "'\\''") + '\'';
}

function parseSettings(raw) {
	const out = {};
	String(raw || '').split('\n').forEach((line) => {
		const trimmed = line.trim();
		if (!trimmed || trimmed.charAt(0) === '#') return;
		const idx = trimmed.indexOf('=');
		if (idx <= 0) return;
		out[trimmed.slice(0, idx).trim()] = trimmed.slice(idx + 1).trim();
	});
	return out;
}

function parseYamlValue(yaml, key) {
	const escapedKey = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
	const re = new RegExp('^\\s*' + escapedKey + '\\s*:\\s*(["\\\']?)([^#\\r\\n]+?)\\1\\s*(?:#.*)?$', 'm');
	const m = String(yaml || '').match(re);
	return m ? m[2].trim() : null;
}

function normalizeHostPort(value, fallbackPort) {
	const cleaned = String(value || '').replace(/["']/g, '').trim();
	const hostPort = cleaned.replace(/^\[|\]$/g, '');
	const lastColon = hostPort.lastIndexOf(':');
	let port = fallbackPort;

	if (lastColon !== -1) {
		port = hostPort.slice(lastColon + 1);
	}

	return {
		host: '127.0.0.1',
		port: String(port || fallbackPort)
	};
}

function stageMessage(key) {
	const labels = {
		process: _('Checking Clash service process...'),
		api: _('Checking Clash API...'),
		dns: _('Checking DNS...'),
		tun: _('Checking TUN interface...'),
		policy: _('Checking routing policy...'),
		forward: _('Checking forwarding rules...')
	};
	return labels[key] || key;
}

function stageErrorMessage(key, detail) {
	const labels = {
		process: _('Clash service did not enter running state.'),
		api: _('Clash API is not responding.'),
		dns: _('DNS listener is not ready.'),
		tun: _('TUN interface did not appear.'),
		policy: _('Routing policy check failed.'),
		forward: _('Forwarding rules check failed.')
	};
	const base = labels[key] || _('Service readiness check failed.');
	return detail ? base + ' ' + detail : base;
}

function normalizeExecError(result) {
	return String(result?.stderr || result?.stdout || '').trim();
}

async function getStatus() {
	return view_miclash_utils.getClashRunning();
}

async function waitForStatus(targetStatus, timeoutMs) {
	return view_miclash_utils.waitForServiceStatus(
		getStatus,
		!!targetStatus,
		timeoutMs || view_miclash_utils.SERVICE_POLL_TIMEOUT_MS
	);
}

async function dispatchActions(actions) {
	const script = (Array.isArray(actions) ? actions : [actions])
		.filter((action) => !!action)
		.map((action) => '/etc/init.d/clash ' + action)
		.join('; ');
	return view_miclash_utils.execDetached(script);
}

async function dispatchActionsAndWait(actions, targetStatus, timeoutMs) {
	await dispatchActions(actions);
	await delay(SERVICE_ACTION_SETTLE_MS);
	return waitForStatus(!!targetStatus, timeoutMs);
}

async function restartOrReload(action) {
	return dispatchActionsAndWait([action], true, RESTART_SERVICE_TIMEOUT_MS);
}

async function loadReadinessContext() {
	const [config, settingsRaw] = await Promise.all([
		L.resolveDefault(fs.read(CONFIG_PATH), ''),
		L.resolveDefault(fs.read(SETTINGS_PATH), '')
	]);
	const settings = parseSettings(settingsRaw);
	const proxyMode = String(settings.PROXY_MODE || '').trim() || 'tproxy';
	const externalController = parseYamlValue(config, 'external-controller');
	const externalControllerTls = parseYamlValue(config, 'external-controller-tls');
	const secret = parseYamlValue(config, 'secret');
	const dnsListen = parseYamlValue(config, 'listen') || '0.0.0.0:7874';
	const api = normalizeHostPort(externalControllerTls || externalController || '127.0.0.1:9090', '9090');
	const dns = normalizeHostPort(dnsListen, '7874');

	return {
		proxyMode: proxyMode,
		apiScheme: externalControllerTls ? 'https' : 'http',
		apiHost: api.host,
		apiPort: api.port,
		secret: secret,
		dnsPort: dns.port
	};
}

async function checkClashApi(ctx) {
	const url = ctx.apiScheme + '://' + ctx.apiHost + ':' + ctx.apiPort + '/version';
	const args = ['-fsS', '--connect-timeout', '2', '--max-time', '3'];
	if (ctx.apiScheme === 'https') args.push('-k');
	if (ctx.secret) {
		args.push('-H');
		args.push('Authorization: Bearer ' + ctx.secret);
	}
	args.push(url);
	const result = await L.resolveDefault(fs.exec('/usr/bin/curl', args), { code: 1, stderr: 'curl failed' });
	return result.code === 0 ? { ok: true } : { ok: false, detail: normalizeExecError(result) };
}

async function waitForClashApi(ctx) {
	return checkClashApi(ctx);
}

async function checkDnsReady(ctx) {
	const port = String(ctx.dnsPort || '7874').replace(/[^0-9]/g, '') || '7874';
	const script = 'if command -v ss >/dev/null 2>&1; then ss -ln 2>/dev/null; else netstat -ln 2>/dev/null; fi | grep -Eq ' +
		shellQuote('[:.]' + port + '([[:space:]]|$)');
	const result = await L.resolveDefault(fs.exec('/bin/sh', ['-c', script]), { code: 1, stderr: 'DNS port not listening' });
	return result.code === 0 ? { ok: true } : { ok: false, detail: _('port %s is not listening').format(port) };
}

async function waitForDnsReady(ctx) {
	return checkDnsReady(ctx);
}

async function checkTunReady(ctx) {
	if (!/^(tun|mixed)$/.test(String(ctx.proxyMode || ''))) return { ok: true, skipped: true };
	const result = await L.resolveDefault(fs.exec('/bin/sh', ['-c', '[ -d /sys/class/net/clash-tun ]']), { code: 1 });
	return result.code === 0 ? { ok: true } : { ok: false, detail: _('clash-tun is missing') };
}

async function waitForTunReady(ctx) {
	return checkTunReady(ctx);
}

async function checkRulesCommand(action, fallback) {
	const result = await L.resolveDefault(fs.exec('/opt/clash/bin/clash-rules', [action]), { code: 1, stderr: fallback });
	return result.code === 0 ? { ok: true } : { ok: false, detail: normalizeExecError(result) || fallback };
}

async function waitForPolicyReady() {
	return checkRulesCommand('validate_policy', _('policy validation failed'));
}

async function waitForForwardReady(ctx) {
	if (!/^(tun|mixed)$/.test(String(ctx.proxyMode || ''))) return { ok: true, skipped: true };
	return checkRulesCommand('validate_forward', _('forward validation failed'));
}

async function waitForStage(key, tester, deadline, onStage) {
	let lastDetail = '';
	if (onStage) onStage(stageMessage(key));

	while (Date.now() < deadline) {
		const result = await tester();
		if (result && result.ok) return true;
		if (result && result.detail) lastDetail = result.detail;
		await delay(READY_POLL_INTERVAL_MS);
	}

	throw new Error(stageErrorMessage(key, lastDetail));
}

async function waitForReadyStatus(options) {
	const opts = options || {};
	const timeoutMs = opts.timeoutMs || RESTART_SERVICE_TIMEOUT_MS;
	const deadline = Date.now() + timeoutMs;
	const onStage = opts.onStage;

	await waitForStage('process', async () => {
		return await getStatus() ? { ok: true } : { ok: false };
	}, deadline, onStage);

	const ctx = await loadReadinessContext();
	await waitForStage('api', () => waitForClashApi(ctx), deadline, onStage);
	await waitForStage('dns', () => waitForDnsReady(ctx), deadline, onStage);
	await waitForStage('tun', () => waitForTunReady(ctx), deadline, onStage);
	await waitForStage('policy', () => waitForPolicyReady(ctx), deadline, onStage);
	await waitForStage('forward', () => waitForForwardReady(ctx), deadline, onStage);

	return true;
}

function formatActionList(actions) {
	return (Array.isArray(actions) ? actions : [actions]).filter(Boolean).join(', ');
}

function getActionTimeout(actions, targetStatus, timeoutMs) {
	if (timeoutMs) return timeoutMs;
	if (!targetStatus) return STOP_SERVICE_TIMEOUT_MS;
	const list = (Array.isArray(actions) ? actions : [actions]).filter(Boolean);
	if (list.some((action) => /^(restart|reload)$/.test(action))) {
		return RESTART_SERVICE_TIMEOUT_MS;
	}
	return START_SERVICE_TIMEOUT_MS;
}

async function readConfigTestDiagnostics() {
	try {
		const result = await fs.exec('/opt/clash/bin/clash', ['-d', '/opt/clash', '-t']);
		const formatted = view_miclash_utils.formatClashTestError(result.stdout, result.stderr);
		const lines = String(formatted || '')
			.split(/\r?\n/)
			.map((line) => line.trim())
			.filter(Boolean)
			.slice(-DIAGNOSTIC_TEST_LINES)
			.join('\n');
		return lines ? 'clash -t:\n' + lines : '';
	} catch (e) {
		return 'clash -t: ' + (e.message || e);
	}
}

async function readDiagnostics(includeConfigTest) {
	const parts = [];
	if (includeConfigTest) {
		const test = await readConfigTestDiagnostics();
		if (test) parts.push(test);
	}

	const raw = await view_miclash_logs.readRaw();
	const logs = String(raw || '')
		.split(/\r?\n/)
		.map((line) => line.trim())
		.filter(Boolean)
		.slice(-DIAGNOSTIC_LOG_LINES)
		.join('\n');
	if (logs) parts.push('logread:\n' + logs);

	return parts.join('\n\n');
}

async function describeTimeout(actions, targetStatus, timeoutMs) {
	const actionText = formatActionList(actions) || 'service action';
	const timeoutSec = Math.round(getActionTimeout(actions, targetStatus, timeoutMs) / 1000);
	let message = targetStatus
		? _('Service did not enter running state within %ss after: %s').format(timeoutSec, actionText)
		: _('Service did not stop within %ss after: %s').format(timeoutSec, actionText);

	const logs = await readDiagnostics(!!targetStatus);
	if (logs) message += '\n\n' + logs;
	return message;
}

async function dispatchActionsAndWaitOrThrow(actions, targetStatus, timeoutMs) {
	const effectiveTimeout = getActionTimeout(actions, !!targetStatus, timeoutMs);
	const ok = await dispatchActionsAndWait(actions, targetStatus, effectiveTimeout);
	if (ok) return true;
	throw new Error(await describeTimeout(actions, !!targetStatus, effectiveTimeout));
}

async function dispatchActionsAndWaitReadyOrThrow(actions, targetStatus, options) {
	const opts = options || {};
	const effectiveTimeout = getActionTimeout(actions, !!targetStatus, opts.timeoutMs);

	await dispatchActions(actions);
	await delay(SERVICE_ACTION_SETTLE_MS);

	if (!targetStatus) {
		const stopped = await waitForStatus(false, effectiveTimeout);
		if (stopped) return true;
		throw new Error(await describeTimeout(actions, false, effectiveTimeout));
	}

	try {
		await waitForReadyStatus({
			timeoutMs: effectiveTimeout,
			onStage: opts.onStage
		});
		return true;
	} catch (e) {
		const logs = await readDiagnostics(true);
		let message = e.message || String(e);
		if (logs) message += '\n\n' + logs;
		throw new Error(message);
	}
}

async function restartOrReloadOrThrow(action) {
	return dispatchActionsAndWaitReadyOrThrow([action], true, { timeoutMs: RESTART_SERVICE_TIMEOUT_MS });
}

return L.Class.extend({
	getStatus: getStatus,
	waitForStatus: waitForStatus,
	dispatchActions: dispatchActions,
	dispatchActionsAndWait: dispatchActionsAndWait,
	dispatchActionsAndWaitOrThrow: dispatchActionsAndWaitOrThrow,
	dispatchActionsAndWaitReadyOrThrow: dispatchActionsAndWaitReadyOrThrow,
	restartOrReload: restartOrReload,
	restartOrReloadOrThrow: restartOrReloadOrThrow,
	waitForReadyStatus: waitForReadyStatus,
	describeTimeout: describeTimeout,
	START_SERVICE_TIMEOUT_MS: START_SERVICE_TIMEOUT_MS,
	STOP_SERVICE_TIMEOUT_MS: STOP_SERVICE_TIMEOUT_MS,
	RESTART_SERVICE_TIMEOUT_MS: RESTART_SERVICE_TIMEOUT_MS
});
