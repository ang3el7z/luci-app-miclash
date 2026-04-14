'use strict';
'require view';
'require fs';
'require ui';
'require rpc';

const CONFIG_PATH = '/opt/clash/config.yaml';
const SETTINGS_PATH = '/opt/clash/settings';
const ACE_BASE = '/luci-static/resources/view/miclash/ace/';
const TMP_SUBSCRIPTION_PATH = '/tmp/miclash-subscription.yaml';

let editor = null;
let startStopButton = null;
let statusBadge = null;
let versionBar = null;
let subscriptionInput = null;
let servicePollTimer = null;

const callServiceList = rpc.declare({
    object: 'service',
    method: 'list',
    params: ['name'],
    expect: { '': {} }
});

function notify(type, message) {
    ui.addNotification(null, E('p', message), type);
}

function isDarkTheme() {
    try {
        const bg = getComputedStyle(document.body).backgroundColor || '';
        const match = bg.match(/(\d+),\s*(\d+),\s*(\d+)/);
        if (!match) return true;
        const r = Number(match[1]);
        const g = Number(match[2]);
        const b = Number(match[3]);
        const brightness = (r * 299 + g * 587 + b * 114) / 1000;
        return brightness < 140;
    } catch (e) {
        return true;
    }
}

function applyEditorTheme() {
    if (!editor) return;
    const preferredTheme = isDarkTheme() ? 'ace/theme/tomorrow_night_bright' : 'ace/theme/textmate';
    try {
        editor.setTheme(preferredTheme);
    } catch (e) {
        editor.setTheme('ace/theme/tomorrow_night_bright');
    }
}

function isValidUrl(url) {
    try {
        const parsed = new URL(url);
        return parsed.protocol === 'http:' || parsed.protocol === 'https:';
    } catch (e) {
        return false;
    }
}

async function loadScript(src) {
    return new Promise((resolve, reject) => {
        if (document.querySelector('script[src="' + src + '"]')) {
            resolve();
            return;
        }
        const script = document.createElement('script');
        script.src = src;
        script.onload = resolve;
        script.onerror = reject;
        document.head.appendChild(script);
    });
}

function parseYamlValue(yaml, key) {
    const escapedKey = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const re = new RegExp('^\\s*' + escapedKey + '\\s*:\\s*(["\\\']?)([^#\\r\\n]+?)\\1\\s*(?:#.*)?$', 'm');
    const m = yaml.match(re);
    return m ? m[2].trim() : null;
}

function normalizeHostPortFromAddr(addr, fallbackHost, fallbackPort) {
    if (!addr) return { host: fallbackHost, port: fallbackPort };
    const cleaned = addr.replace(/["']/g, '').trim();
    const hostPort = cleaned.replace(/^\[|\]$/g, '');
    const lastColon = hostPort.lastIndexOf(':');
    let host = fallbackHost;
    let port = fallbackPort;
    if (lastColon !== -1) {
        host = hostPort.slice(0, lastColon);
        port = hostPort.slice(lastColon + 1);
    }
    if (host === '0.0.0.0' || host === '::' || host === '') {
        host = fallbackHost;
    }
    return { host, port };
}

function computeUiPath(externalUiName, externalUi) {
    if (externalUiName) {
        const name = externalUiName.replace(/(^\/+|\/+$)/g, '');
        return '/' + name + '/';
    }
    if (externalUi && !/[\/\\\.]/.test(externalUi)) {
        const name = externalUi.trim();
        return '/' + name + '/';
    }
    return '/ui/';
}

async function getServiceStatus() {
    try {
        const instances = (await callServiceList('clash'))['clash']?.instances;
        return Object.values(instances || {})[0]?.running || false;
    } catch (e) {
        return false;
    }
}

async function execService(action) {
    return fs.exec('/etc/init.d/clash', [action]);
}

function parseVersion(raw, fallback) {
    const str = String(raw || '').trim();
    if (!str) return fallback;
    const matched = str.match(/(\d+\.\d+\.\d+(?:[-+][\w.-]+)?)/);
    return matched ? matched[1] : str.split('\n')[0];
}

async function getVersions() {
    const info = {
        app: 'unknown',
        clash: 'unknown',
        openwrt: 'unknown'
    };

    try {
        const opkgMiclash = await fs.exec('/bin/sh', ['-c', 'opkg list-installed luci-app-miclash 2>/dev/null']);
        const opkgSsc = await fs.exec('/bin/sh', ['-c', 'opkg list-installed luci-app-ssclash 2>/dev/null']);
        const apkMiclash = await fs.exec('/bin/sh', ['-c', 'apk info -e luci-app-miclash 2>/dev/null']);
        const raw = String(opkgMiclash.stdout || opkgSsc.stdout || apkMiclash.stdout || '').trim();
        if (raw) {
            info.app = parseVersion(raw, 'installed');
        }
    } catch (e) {}

    try {
        const clashV = await fs.exec('/opt/clash/bin/clash', ['-v']);
        const clashVersion = String(clashV.stdout || clashV.stderr || '');
        if (clashVersion) {
            info.clash = parseVersion(clashVersion, 'installed');
        } else {
            const clashVersionAlt = await fs.exec('/opt/clash/bin/clash', ['version']);
            info.clash = parseVersion(clashVersionAlt.stdout || clashVersionAlt.stderr, 'installed');
        }
    } catch (e) {}

    try {
        const release = await fs.read('/etc/openwrt_release');
        const line = String(release || '').split('\n').find((x) => x.indexOf('DISTRIB_RELEASE=') === 0);
        if (line) {
            info.openwrt = line.split('=')[1].replace(/['"]/g, '').trim();
        }
    } catch (e) {}

    return info;
}

async function readSubscriptionUrl() {
    try {
        const raw = await fs.read(SETTINGS_PATH);
        const lines = String(raw || '').split('\n');
        const line = lines.find((item) => item.indexOf('SUBSCRIPTION_URL=') === 0);
        return line ? line.slice('SUBSCRIPTION_URL='.length).trim() : '';
    } catch (e) {
        return '';
    }
}

async function saveSubscriptionUrl(url) {
    const clean = String(url || '').trim();
    const value = clean.replace(/\r?\n/g, '');

    let raw = '';
    try {
        raw = await fs.read(SETTINGS_PATH);
    } catch (e) {
        raw = '';
    }

    const lines = String(raw || '').split('\n').filter((line) => line !== '');
    let replaced = false;
    const out = lines.map((line) => {
        if (line.indexOf('SUBSCRIPTION_URL=') === 0) {
            replaced = true;
            return 'SUBSCRIPTION_URL=' + value;
        }
        return line;
    });

    if (!replaced) {
        out.push('SUBSCRIPTION_URL=' + value);
    }

    await fs.write(SETTINGS_PATH, out.join('\n') + '\n');
}

function extractTestError(testResult) {
    const rawDetail = String(testResult?.stderr || testResult?.stdout || '').trim();
    if (!rawDetail) return 'unknown error';

    const lines = rawDetail.split('\n').filter((l) => l.trim().length > 0);
    for (let i = 0; i < lines.length; i++) {
        const msgMatch = lines[i].match(/msg="([^"]+)"/);
        if (msgMatch) return msgMatch[1].trim();
    }
    return lines[lines.length - 1].trim();
}

async function testConfigContent(content, keepOnSuccess) {
    const normalized = String(content || '').trimEnd() + '\n';
    let original = '';

    try {
        original = await fs.read(CONFIG_PATH);
    } catch (e) {
        original = '';
    }

    try {
        await fs.write(CONFIG_PATH, normalized);
        const testResult = await fs.exec('/opt/clash/bin/clash', ['-d', '/opt/clash', '-t']);

        if (testResult.code !== 0) {
            await fs.write(CONFIG_PATH, original);
            return {
                ok: false,
                message: extractTestError(testResult)
            };
        }

        if (!keepOnSuccess) {
            await fs.write(CONFIG_PATH, original);
        }

        return { ok: true, message: '' };
    } catch (e) {
        try {
            await fs.write(CONFIG_PATH, original);
        } catch (restoreError) {}
        return {
            ok: false,
            message: e.message || 'test failed'
        };
    }
}

async function refreshHeaderState() {
    const [running, versions] = await Promise.all([
        getServiceStatus(),
        getVersions()
    ]);

    if (startStopButton) {
        startStopButton.textContent = running ? _('Stop') : _('Start');
    }

    if (statusBadge) {
        statusBadge.classList.toggle('miclash-status-on', running);
        statusBadge.classList.toggle('miclash-status-off', !running);
        statusBadge.textContent = running ? _('Service running') : _('Service stopped');
    }

    if (versionBar) {
        versionBar.textContent = _('MiClash: %s  |  Mihomo: %s  |  OpenWrt: %s')
            .format(versions.app, versions.clash, versions.openwrt);
    }
}

async function openDashboard() {
    try {
        if (!(await getServiceStatus())) {
            notify('error', _('Service is not running.'));
            return;
        }

        const config = await fs.read(CONFIG_PATH);
        const ec = parseYamlValue(config, 'external-controller');
        const ecTls = parseYamlValue(config, 'external-controller-tls');
        const secret = parseYamlValue(config, 'secret');
        const externalUi = parseYamlValue(config, 'external-ui');
        const externalUiName = parseYamlValue(config, 'external-ui-name');

        const baseHost = window.location.hostname;
        const basePort = '9090';
        const useTls = !!ecTls;

        const hostPort = normalizeHostPortFromAddr(useTls ? ecTls : ec, baseHost, basePort);
        const scheme = useTls ? 'https:' : 'http:';
        const uiPath = computeUiPath(externalUiName, externalUi);

        const qp = new URLSearchParams();
        if (secret) qp.set('secret', secret);
        qp.set('hostname', hostPort.host);
        qp.set('port', hostPort.port);
        const url = scheme + '//' + hostPort.host + ':' + hostPort.port + uiPath + '?' + qp.toString();

        const newWindow = window.open(url, '_blank');
        if (!newWindow) {
            notify('warning', _('Popup was blocked. Please allow popups for this site.'));
        }
    } catch (e) {
        notify('error', _('Failed to open dashboard: %s').format(e.message));
    }
}

async function initializeAceEditor(content) {
    await loadScript(ACE_BASE + 'ace.js');
    ace.config.set('basePath', ACE_BASE);
    editor = ace.edit('miclash-editor');
    applyEditorTheme();
    editor.session.setMode('ace/mode/yaml');
    editor.setValue(String(content || ''), -1);
    editor.clearSelection();
    editor.setOptions({
        fontSize: '12px',
        showPrintMargin: false,
        wrap: true
    });
}

const PAGE_CSS = `
.miclash-page { width: 100%; box-sizing: border-box; }
.miclash-card {
    background: var(--card-bg-color, var(--background-color, #fff));
    border: 1px solid var(--border-color-medium, var(--border-color, #ddd));
    border-radius: 10px;
    padding: 16px;
    margin-bottom: 12px;
    box-sizing: border-box;
}
.miclash-title {
    margin: 0 0 8px;
    font-size: 15px;
    font-weight: 700;
}
.miclash-meta {
    font-size: 12px;
    color: var(--text-color-high, #666);
}
.miclash-actions {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    margin-top: 10px;
}
.miclash-status {
    display: inline-flex;
    align-items: center;
    font-size: 12px;
    font-weight: 600;
    border-radius: 999px;
    padding: 4px 10px;
    border: 1px solid transparent;
}
.miclash-status-on {
    background: rgba(46, 204, 113, 0.15);
    color: #1f8b4c;
    border-color: rgba(46, 204, 113, 0.45);
}
.miclash-status-off {
    background: rgba(231, 76, 60, 0.15);
    color: #b83b30;
    border-color: rgba(231, 76, 60, 0.45);
}
.miclash-editor {
    width: 100%;
    height: 620px;
    border: 1px solid var(--border-color-medium, var(--border-color, #ddd));
    border-radius: 8px;
    margin-top: 10px;
}
.miclash-grid {
    display: grid;
    grid-template-columns: 1fr;
    gap: 12px;
}
@media (min-width: 960px) {
    .miclash-grid {
        grid-template-columns: 1fr 1fr;
    }
}
.miclash-url {
    width: 100%;
    box-sizing: border-box;
}
.miclash-links {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
}
`;

return view.extend({
    handleSave: null,
    handleSaveApply: null,
    handleReset: null,

    load: function() {
        return Promise.all([
            L.resolveDefault(fs.read(CONFIG_PATH), ''),
            readSubscriptionUrl()
        ]);
    },

    render: function(data) {
        const configContent = data[0] || '';
        const subscriptionUrl = data[1] || '';

        const styleNode = E('style', {}, PAGE_CSS);

        versionBar = E('div', { 'class': 'miclash-meta' }, _('Loading versions...'));
        statusBadge = E('span', { 'class': 'miclash-status miclash-status-off' }, _('Checking service...'));

        startStopButton = E('button', {
            'class': 'btn',
            'click': async function() {
                this.disabled = true;
                try {
                    const running = await getServiceStatus();
                    if (running) {
                        await execService('stop');
                        await execService('disable');
                    } else {
                        await execService('enable');
                        await execService('start');
                    }
                    await refreshHeaderState();
                } catch (e) {
                    notify('error', _('Unable to toggle service: %s').format(e.message));
                } finally {
                    this.disabled = false;
                }
            }
        }, _('Start'));

        const restartButton = E('button', {
            'class': 'btn',
            'click': async function() {
                this.disabled = true;
                try {
                    await execService('restart');
                    notify('info', _('Clash service restarted successfully.'));
                    await refreshHeaderState();
                } catch (e) {
                    notify('error', _('Failed to restart Clash service: %s').format(e.message));
                } finally {
                    this.disabled = false;
                }
            }
        }, _('Restart'));

        const dashboardButton = E('button', {
            'class': 'btn',
            'click': openDashboard
        }, _('Open Dashboard'));

        subscriptionInput = E('input', {
            'class': 'cbi-input-text miclash-url',
            'type': 'text',
            'placeholder': 'https://example.com/subscription.yaml',
            'value': subscriptionUrl
        });

        const saveSubscriptionUrlButton = E('button', {
            'class': 'btn',
            'click': async function() {
                const url = String(subscriptionInput.value || '').trim();
                if (!url) {
                    notify('error', _('Subscription URL is empty.'));
                    return;
                }
                if (!isValidUrl(url)) {
                    notify('error', _('Invalid subscription URL.'));
                    return;
                }

                this.disabled = true;
                try {
                    await saveSubscriptionUrl(url);
                    notify('info', _('Subscription URL saved.'));
                } catch (e) {
                    notify('error', _('Failed to save URL: %s').format(e.message));
                } finally {
                    this.disabled = false;
                }
            }
        }, _('Save URL'));

        const downloadSubscriptionButton = E('button', {
            'class': 'btn',
            'click': async function() {
                const url = String(subscriptionInput.value || '').trim();
                if (!url) {
                    notify('error', _('Subscription URL is empty.'));
                    return;
                }
                if (!isValidUrl(url)) {
                    notify('error', _('Invalid subscription URL.'));
                    return;
                }

                this.disabled = true;
                try {
                    await saveSubscriptionUrl(url);

                    const dl = await fs.exec('/usr/bin/curl', ['-L', '-fsS', url, '-o', TMP_SUBSCRIPTION_PATH]);
                    if (dl.code !== 0) {
                        throw new Error(String(dl.stderr || dl.stdout || _('Download failed')).trim());
                    }

                    const downloaded = await fs.read(TMP_SUBSCRIPTION_PATH);
                    if (!String(downloaded || '').trim()) {
                        throw new Error(_('Downloaded file is empty.'));
                    }

                    const tested = await testConfigContent(downloaded, true);
                    if (!tested.ok) {
                        throw new Error(_('YAML validation failed: %s').format(tested.message));
                    }

                    if (editor) {
                        editor.setValue(String(downloaded || '').trimEnd() + '\n', -1);
                        editor.clearSelection();
                    }

                    await execService('reload');
                    notify('info', _('Subscription downloaded, validated and applied.'));
                } catch (e) {
                    notify('error', _('Failed to apply subscription: %s').format(e.message));
                } finally {
                    try {
                        await fs.remove(TMP_SUBSCRIPTION_PATH);
                    } catch (removeErr) {}
                    this.disabled = false;
                }
            }
        }, _('Download Subscription'));

        const validateButton = E('button', {
            'class': 'btn',
            'click': async function() {
                if (!editor) return;
                this.disabled = true;
                try {
                    const tested = await testConfigContent(editor.getValue(), false);
                    if (!tested.ok) {
                        throw new Error(tested.message);
                    }
                    notify('info', _('YAML validation passed.'));
                } catch (e) {
                    notify('error', _('YAML validation failed: %s').format(e.message));
                } finally {
                    this.disabled = false;
                }
            }
        }, _('Validate YAML'));

        const saveButton = E('button', {
            'class': 'btn',
            'click': async function() {
                if (!editor) return;
                this.disabled = true;
                try {
                    const tested = await testConfigContent(editor.getValue(), true);
                    if (!tested.ok) {
                        throw new Error(tested.message);
                    }
                    notify('info', _('Configuration saved.'));
                } catch (e) {
                    notify('error', _('Failed to save configuration: %s').format(e.message));
                } finally {
                    this.disabled = false;
                }
            }
        }, _('Save'));

        const saveApplyButton = E('button', {
            'class': 'btn cbi-button-apply',
            'click': async function() {
                if (!editor) return;
                this.disabled = true;
                try {
                    const tested = await testConfigContent(editor.getValue(), true);
                    if (!tested.ok) {
                        throw new Error(tested.message);
                    }

                    await execService('reload');
                    notify('info', _('Configuration applied and service reloaded.'));
                    await refreshHeaderState();
                } catch (e) {
                    notify('error', _('Failed to apply configuration: %s').format(e.message));
                } finally {
                    this.disabled = false;
                }
            }
        }, _('Save & Apply'));

        const openSettings = () => { window.location.href = L.url('admin/services/miclash/settings'); };
        const openRulesets = () => { window.location.href = L.url('admin/services/miclash/rulesets'); };
        const openLog = () => { window.location.href = L.url('admin/services/miclash/log'); };

        const page = E('div', { 'class': 'miclash-page' }, [
            styleNode,

            E('div', { 'class': 'miclash-card' }, [
                E('h2', { 'class': 'miclash-title' }, _('MiClash Control Center')),
                versionBar,
                E('div', { 'style': 'margin-top: 10px;' }, [statusBadge]),
                E('div', { 'class': 'miclash-actions' }, [
                    startStopButton,
                    restartButton,
                    dashboardButton
                ])
            ]),

            E('div', { 'class': 'miclash-grid' }, [
                E('div', { 'class': 'miclash-card' }, [
                    E('h3', { 'class': 'miclash-title' }, _('Subscription URL')),
                    E('p', { 'class': 'miclash-meta' }, _('Save your subscription URL and download config directly to /opt/clash/config.yaml with automatic YAML validation.')),
                    subscriptionInput,
                    E('div', { 'class': 'miclash-actions' }, [
                        saveSubscriptionUrlButton,
                        downloadSubscriptionButton
                    ])
                ]),
                E('div', { 'class': 'miclash-card' }, [
                    E('h3', { 'class': 'miclash-title' }, _('Quick Navigation')),
                    E('p', { 'class': 'miclash-meta' }, _('Open the remaining MiClash sections.')),
                    E('div', { 'class': 'miclash-links' }, [
                        E('button', { 'class': 'btn', 'click': openSettings }, _('Settings')),
                        E('button', { 'class': 'btn', 'click': openRulesets }, _('Rulesets')),
                        E('button', { 'class': 'btn', 'click': openLog }, _('Log'))
                    ])
                ])
            ]),

            E('div', { 'class': 'miclash-card' }, [
                E('h3', { 'class': 'miclash-title' }, _('YAML Configuration')),
                E('p', { 'class': 'miclash-meta' }, _('Editor with safe YAML validation: invalid changes are automatically rolled back.')),
                E('div', { 'id': 'miclash-editor', 'class': 'miclash-editor' }),
                E('div', { 'class': 'miclash-actions' }, [
                    validateButton,
                    saveButton,
                    saveApplyButton
                ])
            ])
        ]);

        setTimeout(async () => {
            try {
                await initializeAceEditor(configContent);
                applyEditorTheme();
                await refreshHeaderState();

                try {
                    const media = window.matchMedia('(prefers-color-scheme: dark)');
                    const listener = function() { applyEditorTheme(); };
                    if (typeof media.addEventListener === 'function') {
                        media.addEventListener('change', listener);
                    } else if (typeof media.addListener === 'function') {
                        media.addListener(listener);
                    }
                } catch (e) {}

                if (servicePollTimer) clearInterval(servicePollTimer);
                servicePollTimer = setInterval(() => {
                    applyEditorTheme();
                    refreshHeaderState().catch(() => {});
                }, 5000);
            } catch (e) {
                notify('error', _('Failed to initialize editor: %s').format(e.message));
            }
        }, 30);

        return page;
    }
});
