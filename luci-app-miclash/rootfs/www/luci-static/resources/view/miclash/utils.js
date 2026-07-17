'use strict';
'require view.miclash.api';

const RPC_TIMEOUT_SEC = 360;
const SERVICE_POLL_TIMEOUT_MS = 60000;
const SERVICE_POLL_INTERVAL_MS = 500;
const MAX_CLASH_TEST_ERROR_LEN = 8000;

function unescapeLogString(s) {
    return String(s)
        .replace(/\\n/g, '\n')
        .replace(/\\r/g, '\r')
        .replace(/\\t/g, '\t')
        .replace(/\\"/g, '"')
        .replace(/\\\\/g, '\\');
}

function stripClashLogPrefix(line) {
    return String(line)
        .replace(/^time="[^"]+"\s+level=\w+\s+/, '')
        .replace(/^ERRO\[[^\]]+\]\s*/, '')
        .replace(/^WARN\[[^\]]+\]\s*/, '')
        .trim();
}

function formatClashTestError(stdout, stderr) {
    const raw = [stderr, stdout]
        .filter(function(s) { return s && String(s).trim(); })
        .join('\n')
        .trim();
    if (!raw) return '';

    const lines = [];
    const seen = new Set();

    function addLine(line) {
        if (line == null) return;
        line = String(line).replace(/\r/g, '').trim();
        if (!line || seen.has(line)) return;
        seen.add(line);
        lines.push(line);
    }

    function addBlock(text) {
        unescapeLogString(text).split('\n').forEach(function(l) {
            l = l.trim();
            if (l) addLine(l);
        });
    }

    let m;
    const msgRe = /msg="((?:\\.|[^"\\])*)"/g;
    while ((m = msgRe.exec(raw)) !== null) {
        addBlock(m[1]);
    }

    raw.split('\n').forEach(function(line) {
        const t = line.trim();
        if (!t || /level=(info|debug)\b/i.test(t)) return;

        const erro = t.match(/^ERRO\[[^\]]+\]\s*(.+)$/);
        if (erro) {
            addLine(erro[1]);
            return;
        }

        if (/^time="[^"]+"\s+level=(fatal|error)\b/i.test(t) && !/msg="/.test(t)) {
            addLine(stripClashLogPrefix(t));
            return;
        }

        if (/^(Error:|Parse config error:|panic:)/i.test(t)) {
            addLine(t);
            return;
        }
        if (/^Profile Check Failed/i.test(t)) {
            addLine(t);
            return;
        }
        if (/^yaml:/i.test(t) || /^line \d+:/i.test(t)) {
            addLine(t);
            return;
        }
        if (/configuration file .+ test failed/i.test(t)) {
            addLine(t);
            return;
        }
    });

    let out = lines.join('\n');
    if (!out) {
        out = raw.split('\n')
            .map(stripClashLogPrefix)
            .filter(function(l) { return l && !/level=(info|debug)\b/i.test(l); })
            .join('\n');
    }

    if (out.length > MAX_CLASH_TEST_ERROR_LEN) {
        out = out.slice(0, MAX_CLASH_TEST_ERROR_LEN) + '\n…';
    }
    return out;
}

function formatClashLogMessage(raw) {
    if (raw == null) return '';
    const m = String(raw).trim();
    if (!m) return '';

    const nested = m.match(/^time="[^"]+"\s+level=\w+\s+msg="((?:\\.|[^"\\])*)"$/);
    if (nested) {
        return unescapeLogString(nested[1]);
    }

    const msgOnly = m.match(/^msg="((?:\\.|[^"\\])*)"$/);
    if (msgOnly) {
        return unescapeLogString(msgOnly[1]);
    }

    return m;
}

function bumpRpcTimeout() {
    try {
        if (typeof L !== 'undefined' && L.env &&
            (!(L.env.rpctimeout > 0) || L.env.rpctimeout < RPC_TIMEOUT_SEC)) {
            L.env.rpctimeout = RPC_TIMEOUT_SEC;
        }
    } catch (e) {}
}

async function getClashRunning() {
    const api = view_miclash_api.create();
    try {
        const state = await api.status();
        return state?.observed?.service?.running === true || state?.observed?.service?.state === 'running';
    } catch (e) {
        return false;
    } finally { api.destroy(); }
}

async function waitForServiceStatus(getStatusFn, targetStatus, timeoutMs) {
    const deadline = Date.now() + (timeoutMs || SERVICE_POLL_TIMEOUT_MS);
    while (Date.now() < deadline) {
        if (await getStatusFn() === targetStatus) {
            return true;
        }
        await new Promise(function(resolve) {
            setTimeout(resolve, SERVICE_POLL_INTERVAL_MS);
        });
    }
    return false;
}

return L.Class.extend({
    bumpRpcTimeout: bumpRpcTimeout,
    formatClashTestError: formatClashTestError,
    formatClashLogMessage: formatClashLogMessage,
    getClashRunning: getClashRunning,
    waitForServiceStatus: waitForServiceStatus,
    SERVICE_POLL_TIMEOUT_MS: SERVICE_POLL_TIMEOUT_MS,

    isLightTheme: function() {
        if (document.documentElement.dataset.bsTheme === 'dark') return false;
        if (document.documentElement.dataset.bsTheme === 'light') return true;
        const bg = window.getComputedStyle(document.body).backgroundColor;
        const m = bg.match(/\d+/g);
        if (m && m.length >= 3)
            return (0.299 * +m[0] + 0.587 * +m[1] + 0.114 * +m[2]) / 255 > 0.5;
        return true;
    }
});
