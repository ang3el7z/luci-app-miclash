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
let appVersionBadge = null;
let kernelBadge = null;
let themeToggleButton = null;
let pageRoot = null;
let subscriptionInput = null;
let servicePollTimer = null;
let currentUiTheme = 'light';

const UI_THEME_KEY = 'UI_THEME';

const callServiceList = rpc.declare({
    object: 'service',
    method: 'list',
    params: ['name'],
    expect: { '': {} }
});

function notify(type, message) {
    ui.addNotification(null, E('p', message), type);
}

function normalizeTheme(theme) {
    return theme === 'dark' ? 'dark' : 'light';
}

function applyEditorTheme() {
    if (!editor) return;
    const preferredTheme = currentUiTheme === 'dark' ? 'ace/theme/tomorrow_night_bright' : 'ace/theme/textmate';
    try {
        editor.setTheme(preferredTheme);
    } catch (e) {
        editor.setTheme('ace/theme/tomorrow_night_bright');
    }
}

function parseSettingsToMap(raw) {
    const map = {};
    String(raw || '').split('\n').forEach((line) => {
        const trimmed = line.trim();
        if (!trimmed || trimmed.charAt(0) === '#') return;
        const equalIndex = trimmed.indexOf('=');
        if (equalIndex <= 0) return;
        const key = trimmed.slice(0, equalIndex).trim();
        const value = trimmed.slice(equalIndex + 1).trim();
        if (key) map[key] = value;
    });
    return map;
}

function mapToSettingsContent(map) {
    const lines = Object.keys(map).map((key) => key + '=' + map[key]);
    return lines.length ? lines.join('\n') + '\n' : '';
}

async function readSettingsMap() {
    try {
        return parseSettingsToMap(await fs.read(SETTINGS_PATH));
    } catch (e) {
        return {};
    }
}

async function writeSettingsMap(map) {
    await fs.write(SETTINGS_PATH, mapToSettingsContent(map));
}

async function readThemePreference() {
    const settings = await readSettingsMap();
    return normalizeTheme(settings[UI_THEME_KEY] || 'light');
}

async function saveThemePreference(theme) {
    const settings = await readSettingsMap();
    settings[UI_THEME_KEY] = normalizeTheme(theme);
    await writeSettingsMap(settings);
}

function applyUiTheme(theme) {
    currentUiTheme = normalizeTheme(theme);

    if (pageRoot) {
        pageRoot.classList.toggle('miclash-theme-dark', currentUiTheme === 'dark');
        pageRoot.classList.toggle('miclash-theme-light', currentUiTheme === 'light');
    }

    if (themeToggleButton) {
        themeToggleButton.textContent = currentUiTheme === 'dark' ? _('Theme: Dark') : _('Theme: Light');
    }

    applyEditorTheme();
}

function isValidUrl(url) {
    try {
        const parsed = new URL(url);
        return parsed.protocol === 'http:' || parsed.protocol === 'https:';
    } catch (e) {
        return false;
    }
}

function looksLikeBase64Text(value) {
    const cleaned = String(value || '').replace(/\s+/g, '');
    if (cleaned.length < 64 || cleaned.length % 4 !== 0) return false;
    return /^[A-Za-z0-9+/=]+$/.test(cleaned);
}

function tryDecodeBase64(value) {
    try {
        if (typeof atob !== 'function') return null;
        const cleaned = String(value || '').replace(/\s+/g, '');
        return atob(cleaned);
    } catch (e) {
        return null;
    }
}

function looksLikeUriSubscription(value) {
    const content = String(value || '');
    return /(?:^|\n)\s*(vmess|vless|trojan|ss|ssr|hysteria|hysteria2|tuic):\/\/[^\s]+/i.test(content);
}

function normalizeSubscriptionContent(raw) {
    let content = String(raw || '').trim();
    let decodedFromBase64 = false;

    if (content && looksLikeBase64Text(content) && content.indexOf(':') === -1) {
        const decoded = tryDecodeBase64(content);
        if (decoded && decoded.trim()) {
            content = decoded.trim();
            decodedFromBase64 = true;
        }
    }

    return {
        content: content ? content + '\n' : '',
        decodedFromBase64: decodedFromBase64
    };
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

function sanitizeAppVersion(version) {
    return String(version || '').replace(/-r\d+$/i, '');
}

async function getVersions() {
    const info = {
        app: 'unknown',
        clash: 'unknown'
    };

    try {
        const opkgMiclash = await fs.exec('/bin/sh', ['-c', 'opkg list-installed luci-app-miclash 2>/dev/null']);
        const opkgSsc = await fs.exec('/bin/sh', ['-c', 'opkg list-installed luci-app-ssclash 2>/dev/null']);
        const apkMiclash = await fs.exec('/bin/sh', ['-c', 'apk info -v luci-app-miclash 2>/dev/null']);
        const raw = String(opkgMiclash.stdout || opkgSsc.stdout || apkMiclash.stdout || '').trim();
        if (raw) {
            info.app = sanitizeAppVersion(parseVersion(raw, 'installed'));
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

    return info;
}

async function detectSystemArchitecture() {
    try {
        const releaseInfo = await L.resolveDefault(fs.read('/etc/openwrt_release'), null);
        const match = String(releaseInfo || '').match(/^DISTRIB_ARCH=['"]?([^'"\n]+)['"]?/m);
        const distribArch = match ? match[1] : '';

        if (!distribArch) return 'amd64';
        if (distribArch.startsWith('aarch64_')) return 'arm64';
        if (distribArch === 'x86_64') return 'amd64';
        if (distribArch.startsWith('i386_')) return '386';
        if (distribArch.startsWith('riscv64_')) return 'riscv64';
        if (distribArch.startsWith('loongarch64_')) return 'loong64';
        if (distribArch.includes('_neon-vfp')) return 'armv7';
        if (distribArch.includes('_neon') || distribArch.includes('_vfp')) return 'armv6';
        if (distribArch.startsWith('arm_')) return 'armv5';
        if (distribArch.startsWith('mips64el_')) return 'mips64le';
        if (distribArch.startsWith('mips64_')) return 'mips64';
        if (distribArch.startsWith('mipsel_')) return distribArch.includes('hardfloat') ? 'mipsle-hardfloat' : 'mipsle-softfloat';
        if (distribArch.startsWith('mips_')) return distribArch.includes('hardfloat') ? 'mips-hardfloat' : 'mips-softfloat';
    } catch (e) {}

    return 'amd64';
}

function normalizeVersion(str) {
    if (!str) return '';
    const match = String(str).match(/v?(\d+\.\d+\.\d+)/i);
    return match ? match[1] : String(str).trim();
}

async function getMihomoStatus() {
    const binPath = '/opt/clash/bin/clash';

    try {
        const stat = await L.resolveDefault(fs.stat(binPath), null);
        if (!stat) {
            return { installed: false, version: null };
        }
    } catch (e) {
        return { installed: false, version: null };
    }

    try {
        const result = await fs.exec(binPath, ['-v']);
        const output = String(result?.stdout || result?.stderr || '').trim();
        if (output) {
            return { installed: true, version: parseVersion(output, _('Installed')) };
        }
    } catch (e) {}

    try {
        const result = await fs.exec(binPath, ['version']);
        const output = String(result?.stdout || result?.stderr || '').trim();
        if (output) {
            return { installed: true, version: parseVersion(output, _('Installed')) };
        }
    } catch (e) {}

    return { installed: true, version: _('Installed') };
}

async function getLatestMihomoRelease() {
    try {
        const response = await fetch('https://api.github.com/repos/MetaCubeX/mihomo/releases/latest');
        if (!response.ok) return null;

        const data = await response.json();
        if (!data || data.prerelease || !data.tag_name || !Array.isArray(data.assets)) {
            return null;
        }

        return {
            version: data.tag_name,
            assets: data.assets
        };
    } catch (e) {
        return null;
    }
}

function findKernelAsset(release, arch) {
    if (!release || !Array.isArray(release.assets)) return null;

    const tag = String(release.version || '');
    const cleanTag = tag.replace(/^v/i, '');
    const exactNames = [
        'mihomo-linux-' + arch + '-' + tag + '.gz',
        'mihomo-linux-' + arch + '-' + cleanTag + '.gz'
    ];

    for (let i = 0; i < exactNames.length; i++) {
        const asset = release.assets.find((item) => item.name === exactNames[i]);
        if (asset) return asset;
    }

    return release.assets.find((item) => item.name && item.name.indexOf('mihomo-linux-' + arch + '-') === 0 && item.name.endsWith('.gz')) || null;
}

async function downloadMihomoKernel(downloadUrl, version, arch) {
    const safeVersion = String(version || '').replace(/[^\w.-]/g, '');
    const fileName = 'mihomo-linux-' + arch + '-' + safeVersion + '.gz';
    const downloadPath = '/tmp/' + fileName;
    const extractedFile = downloadPath.replace(/\.gz$/, '');
    const targetFile = '/opt/clash/bin/clash';

    try {
        notify('info', _('Downloading Mihomo kernel...'));
        const curlResult = await fs.exec('/usr/bin/curl', ['-L', '-fsS', downloadUrl, '-o', downloadPath]);
        if (curlResult.code !== 0) {
            throw new Error(String(curlResult.stderr || curlResult.stdout || _('Download failed')).trim());
        }

        const extractResult = await fs.exec('/bin/gzip', ['-df', downloadPath]);
        if (extractResult.code !== 0) {
            throw new Error(String(extractResult.stderr || extractResult.stdout || _('Extraction failed')).trim());
        }

        await fs.exec('/bin/mv', [extractedFile, targetFile]);
        await fs.exec('/bin/chmod', ['+x', targetFile]);

        notify('info', _('Mihomo kernel downloaded and installed.'));
        return true;
    } catch (e) {
        notify('error', _('Kernel download failed: %s').format(e.message));
        return false;
    } finally {
        try { await fs.remove(downloadPath); } catch (removeErr) {}
    }
}

function showModal(options) {
    const overlay = E('div', { 'class': 'miclash-modal-overlay' });
    const modal = E('div', { 'class': 'miclash-modal' });
    const titleNode = E('div', { 'class': 'miclash-modal-title' }, String(options.title || ''));
    const bodyNode = options.body && options.body.nodeType
        ? options.body
        : E('div', { 'class': 'miclash-modal-body' }, String(options.body || ''));
    const actionsNode = E('div', { 'class': 'miclash-modal-actions' });

    function closeModal() {
        overlay.remove();
    }

    (options.buttons || []).forEach((item) => {
        const button = E('button', { 'class': item.className || 'btn' }, String(item.label || ''));
        button.addEventListener('click', async function(ev) {
            ev.preventDefault();
            if (item.onClick) {
                const prevText = button.textContent;
                button.disabled = true;
                try {
                    await item.onClick({ closeModal: closeModal, button: button });
                } finally {
                    if (button.isConnected) {
                        button.disabled = false;
                        button.textContent = prevText;
                    }
                }
            } else {
                closeModal();
            }
        });
        actionsNode.appendChild(button);
    });

    modal.appendChild(titleNode);
    modal.appendChild(bodyNode);
    modal.appendChild(actionsNode);
    overlay.appendChild(modal);

    overlay.addEventListener('click', function(ev) {
        if (ev.target === overlay) closeModal();
    });

    document.body.appendChild(overlay);
    return closeModal;
}

async function openKernelModal() {
    try {
        const [status, arch, release] = await Promise.all([
            getMihomoStatus(),
            detectSystemArchitecture(),
            getLatestMihomoRelease()
        ]);

        const asset = findKernelAsset(release, arch);
        const localVersion = normalizeVersion(status.version);
        const latestVersion = normalizeVersion(release ? release.version : '');

        let downloadLabel = _('Download Kernel');
        if (status.installed && release && localVersion && latestVersion && localVersion === latestVersion) {
            downloadLabel = _('Reinstall Kernel');
        } else if (status.installed && release) {
            downloadLabel = _('Download Update');
        }

        const info = E('div', { 'class': 'miclash-modal-body miclash-kernel-info' }, [
            E('div', {}, _('Status: %s').format(status.installed ? _('Installed') : _('Not installed'))),
            E('div', {}, _('Installed version: %s').format(status.installed ? status.version : _('Not installed'))),
            E('div', {}, _('Architecture: %s').format(arch)),
            E('div', {}, _('Latest release: %s').format(release ? release.version : _('Unavailable')))
        ]);

        const buttons = [];

        if (release && asset) {
            buttons.push({
                label: downloadLabel,
                className: 'btn cbi-button-apply',
                onClick: async function(ctx) {
                    ctx.button.textContent = _('Downloading...');
                    const ok = await downloadMihomoKernel(asset.browser_download_url, release.version, arch);
                    if (ok) {
                        await refreshHeaderState();
                        ctx.closeModal();
                    }
                }
            });
        }

        buttons.push({
            label: _('Restart Service'),
            className: 'btn',
            onClick: async function(ctx) {
                ctx.button.textContent = _('Restarting...');
                try {
                    await execService('restart');
                    notify('info', _('Clash service restarted successfully.'));
                    await refreshHeaderState();
                    ctx.closeModal();
                } catch (e) {
                    notify('error', _('Failed to restart Clash service: %s').format(e.message));
                }
            }
        });

        buttons.push({
            label: _('Close'),
            className: 'btn'
        });

        showModal({
            title: _('Mihomo Kernel'),
            body: info,
            buttons: buttons
        });
    } catch (e) {
        notify('error', _('Failed to load kernel information: %s').format(e.message));
    }
}

async function readSubscriptionUrl() {
    const settings = await readSettingsMap();
    return String(settings.SUBSCRIPTION_URL || '').trim();
}

async function saveSubscriptionUrl(url) {
    const clean = String(url || '').trim();
    const value = clean.replace(/\r?\n/g, '');
    const settings = await readSettingsMap();
    settings.SUBSCRIPTION_URL = value;
    await writeSettingsMap(settings);
}

function looksLikeBase64Blob(text) {
    const compact = String(text || '').replace(/\s+/g, '');
    if (compact.length < 48) return false;
    if (String(text || '').indexOf(':') !== -1) return false;
    return /^[A-Za-z0-9+/=]+$/.test(compact);
}

const REMNAWAVE_CLIENT_TYPES = {
    mihomo: true,
    clash: true,
    singbox: true,
    stash: true,
    json: true,
    'v2ray-json': true
};

async function getOpenWrtReleaseVersion() {
    try {
        const release = await fs.read('/etc/openwrt_release');
        const line = String(release || '').split('\n').find((item) => item.indexOf('DISTRIB_RELEASE=') === 0);
        return line ? line.split('=')[1].replace(/['"]/g, '').trim() : '';
    } catch (e) {
        return '';
    }
}

async function getSystemModel() {
    try {
        return String(await fs.read('/tmp/sysinfo/model') || '').trim();
    } catch (e) {
        return '';
    }
}

async function getHwidHash() {
    const probes = [
        "cat /sys/class/net/eth0/address 2>/dev/null | tr -d ':' | md5sum | cut -c1-14",
        "for i in /sys/class/net/*/address; do n=\"${i%/address}\"; n=\"${n##*/}\"; [ \"$n\" = \"lo\" ] && continue; cat \"$i\" 2>/dev/null | tr -d ':' | md5sum | cut -c1-14 && break; done"
    ];

    for (let i = 0; i < probes.length; i++) {
        try {
            const r = await fs.exec('/bin/sh', ['-c', probes[i]]);
            if (r.code === 0) {
                const hwid = String(r.stdout || '').trim();
                if (hwid && hwid !== 'unknown') return hwid;
            }
        } catch (e) {}
    }

    return '';
}

function buildSubscriptionClientProfile(settings, appVersion) {
    const safeVersion = /^\d+\.\d+\.\d+/.test(String(appVersion || '')) ? String(appVersion) : '1.0.0';
    const settingsUa = String(settings.HWID_USER_AGENT || '').trim();
    const userAgent = settingsUa || ('MiClash/' + safeVersion);

    return {
        ua: userAgent
    };
}

function normalizeSubscriptionDownloadUrl(rawUrl) {
    let parsed = null;
    try {
        parsed = new URL(rawUrl);
    } catch (e) {
        return {
            url: rawUrl,
            mode: 'direct',
            remnawaveCandidateUrl: null
        };
    }

    const segments = parsed.pathname.split('/').filter(Boolean);
    const subIndex = segments.indexOf('sub');
    if (subIndex < 0 || !segments[subIndex + 1]) {
        return {
            url: parsed.toString(),
            mode: 'direct',
            remnawaveCandidateUrl: null
        };
    }

    const clientType = String(segments[subIndex + 2] || '').toLowerCase();

    if (clientType && REMNAWAVE_CLIENT_TYPES[clientType]) {
        return {
            url: parsed.toString(),
            mode: 'remnawave-client-path',
            remnawaveCandidateUrl: null
        };
    }

    if (clientType && clientType !== 'info') {
        return {
            url: parsed.toString(),
            mode: 'direct',
            remnawaveCandidateUrl: null
        };
    }

    const candidateSegments = segments.slice();
    if (clientType === 'info') {
        candidateSegments[subIndex + 2] = 'mihomo';
    } else {
        candidateSegments.push('mihomo');
    }

    const candidate = new URL(parsed.toString());
    candidate.pathname = '/' + candidateSegments.join('/');

    parsed.pathname = '/' + segments.join('/');

    return {
        url: parsed.toString(),
        mode: 'direct',
        remnawaveCandidateUrl: candidate.toString()
    };
}

async function buildSubscriptionDeviceHeaders(settings) {
    const headers = {};
    const deviceOs = String(settings.HWID_DEVICE_OS || 'OpenWrt').trim() || 'OpenWrt';
    headers['x-device-os'] = deviceOs;

    const release = await getOpenWrtReleaseVersion();
    if (release) headers['x-ver-os'] = release;

    const model = await getSystemModel();
    if (model) headers['x-device-model'] = model;

    if (String(settings.ENABLE_HWID || '').toLowerCase() === 'true') {
        const hwid = await getHwidHash();
        if (hwid) headers['x-hwid'] = hwid;
    }

    return headers;
}

async function downloadSubscriptionWithProfile(url, profile, deviceHeaders, mode) {
    const args = [
        '-L', '-fsS',
        '-A', profile.ua,
        '-H', 'Accept: application/yaml, text/yaml, text/plain, */*',
        '-H', 'Cache-Control: no-cache',
        '-H', 'Pragma: no-cache'
    ];

    Object.keys(deviceHeaders || {}).forEach((key) => {
        const value = String(deviceHeaders[key] || '').trim();
        if (!value) return;
        args.push('-H');
        args.push(key + ': ' + value);
    });

    args.push(url);
    args.push('-o');
    args.push(TMP_SUBSCRIPTION_PATH);

    const dl = await fs.exec('/usr/bin/curl', args);
    if (dl.code !== 0) {
        const msg = String(dl.stderr || dl.stdout || _('Download failed')).trim();
        if (mode === 'remnawave-client-path' && /403/.test(msg)) {
            throw new Error(_('Remnawave blocked /mihomo path (HTTP 403). Disable "Disable Subscription Access by Path" in Remnawave response-rules settings.'));
        }
        throw new Error(msg);
    }

    const catResult = await fs.exec('/bin/cat', [TMP_SUBSCRIPTION_PATH]);
    if (catResult.code !== 0) {
        throw new Error(String(catResult.stderr || catResult.stdout || _('Unable to read downloaded file')).trim());
    }

    return String(catResult.stdout || '');
}

async function fetchSubscriptionAsYaml(url) {
    const settings = await readSettingsMap();
    const versions = await getVersions();
    const profile = buildSubscriptionClientProfile(settings, versions.app);
    const deviceHeaders = await buildSubscriptionDeviceHeaders(settings);
    const resolved = normalizeSubscriptionDownloadUrl(url);
    let mode = resolved.mode;

    let payload = await downloadSubscriptionWithProfile(resolved.url, profile, deviceHeaders, resolved.mode);
    if (!payload.trim()) {
        throw new Error(_('Downloaded file is empty.'));
    }

    if (looksLikeBase64Blob(payload) && resolved.remnawaveCandidateUrl) {
        payload = await downloadSubscriptionWithProfile(
            resolved.remnawaveCandidateUrl,
            profile,
            deviceHeaders,
            'remnawave-client-path'
        );
        mode = 'remnawave-client-path';
    }

    if (looksLikeBase64Blob(payload)) {
        throw new Error(_('The subscription server returned non-YAML data (likely base64 links). Ask your provider for Clash/Mihomo YAML output.'));
    }

    const tested = await testConfigContent(payload, false);
    if (!tested.ok) {
        throw new Error(tested.message || _('YAML validation failed.'));
    }

    return {
        content: payload,
        mode: mode
    };
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
    const [running, versions, kernelStatus] = await Promise.all([
        getServiceStatus(),
        getVersions(),
        getMihomoStatus()
    ]);

    if (startStopButton) {
        startStopButton.textContent = running ? _('Stop') : _('Start');
    }

    if (statusBadge) {
        statusBadge.classList.toggle('miclash-status-on', running);
        statusBadge.classList.toggle('miclash-status-off', !running);
        statusBadge.textContent = running ? _('Service running') : _('Service stopped');
    }

    if (appVersionBadge) {
        appVersionBadge.textContent = _('MiClash %s').format(versions.app);
    }

    if (kernelBadge) {
        if (kernelStatus.installed) {
            kernelBadge.textContent = _('Kernel %s').format(kernelStatus.version || versions.clash);
            kernelBadge.classList.remove('miclash-pill-warn');
        } else {
            kernelBadge.textContent = _('Kernel not installed');
            kernelBadge.classList.add('miclash-pill-warn');
        }
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
#tabmenu, .cbi-tabmenu { display: none !important; }
.miclash-page {
    width: 100%;
    box-sizing: border-box;
    --miclash-bg: #f4f7fb;
    --miclash-card-bg: #ffffff;
    --miclash-border: #d7e0ea;
    --miclash-text: #17202a;
    --miclash-muted: #5f6f82;
    --miclash-pill-bg: #f2f5ff;
    --miclash-pill-border: #cfd8ff;
    --miclash-pill-text: #2c3c56;
}
.miclash-page.miclash-theme-dark {
    --miclash-bg: #101722;
    --miclash-card-bg: #141e2b;
    --miclash-border: #273447;
    --miclash-text: #e7eef9;
    --miclash-muted: #94a6bf;
    --miclash-pill-bg: #1a2738;
    --miclash-pill-border: #344a67;
    --miclash-pill-text: #d4e0f2;
}
.miclash-page.miclash-theme-light {
    --miclash-bg: #f4f7fb;
    --miclash-card-bg: #ffffff;
    --miclash-border: #d7e0ea;
    --miclash-text: #17202a;
    --miclash-muted: #5f6f82;
    --miclash-pill-bg: #f2f5ff;
    --miclash-pill-border: #cfd8ff;
    --miclash-pill-text: #2c3c56;
}
.miclash-card {
    background: var(--miclash-card-bg);
    border: 1px solid var(--miclash-border);
    border-radius: 10px;
    padding: 16px;
    margin-bottom: 12px;
    box-sizing: border-box;
    color: var(--miclash-text);
}
.miclash-topbar {
    display: grid;
    grid-template-columns: 1fr auto 1fr;
    align-items: center;
    gap: 10px;
    margin-bottom: 8px;
}
.miclash-topbar-right {
    justify-self: end;
}
.miclash-version-center {
    display: flex;
    align-items: center;
    justify-content: center;
    flex-wrap: wrap;
    gap: 8px;
}
.miclash-pill {
    display: inline-flex;
    align-items: center;
    border: 1px solid var(--miclash-pill-border);
    background: var(--miclash-pill-bg);
    color: var(--miclash-pill-text);
    border-radius: 999px;
    padding: 4px 10px;
    font-size: 12px;
    font-weight: 600;
    line-height: 1.3;
}
.miclash-pill-btn {
    cursor: pointer;
    transition: border-color 0.15s ease, transform 0.15s ease;
}
.miclash-pill-btn:hover {
    border-color: #4f8cff;
    transform: translateY(-1px);
}
.miclash-pill-warn {
    border-color: #f59e0b;
    color: #b45309;
    background: rgba(245, 158, 11, 0.12);
}
.miclash-theme-btn {
    min-width: 115px;
}
.miclash-title {
    margin: 0 0 8px;
    font-size: 15px;
    font-weight: 700;
}
.miclash-meta {
    font-size: 12px;
    color: var(--miclash-muted);
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
    border: 1px solid var(--miclash-border);
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
.miclash-modal-overlay {
    position: fixed;
    inset: 0;
    background: rgba(4, 10, 18, 0.7);
    z-index: 10000;
    display: flex;
    align-items: center;
    justify-content: center;
}
.miclash-modal {
    width: min(92vw, 420px);
    border-radius: 10px;
    border: 1px solid var(--miclash-border);
    background: var(--miclash-card-bg);
    color: var(--miclash-text);
    padding: 16px;
    box-sizing: border-box;
}
.miclash-modal-title {
    font-size: 14px;
    font-weight: 700;
    margin-bottom: 8px;
}
.miclash-modal-body {
    font-size: 12px;
    color: var(--miclash-muted);
    line-height: 1.5;
}
.miclash-kernel-info {
    display: grid;
    gap: 6px;
}
.miclash-modal-actions {
    margin-top: 14px;
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

        appVersionBadge = E('span', { 'class': 'miclash-pill' }, _('MiClash ...'));
        kernelBadge = E('button', {
            'class': 'miclash-pill miclash-pill-btn',
            'click': openKernelModal
        }, _('Kernel ...'));
        themeToggleButton = E('button', {
            'class': 'btn miclash-theme-btn',
            'click': async function() {
                const nextTheme = currentUiTheme === 'dark' ? 'light' : 'dark';
                applyUiTheme(nextTheme);
                try {
                    await saveThemePreference(nextTheme);
                } catch (e) {
                    notify('error', _('Failed to save theme preference: %s').format(e.message));
                }
            }
        }, _('Theme: Light'));
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
                    const downloadedInfo = await fetchSubscriptionAsYaml(url);
                    const downloaded = downloadedInfo.content;

                    const tested = await testConfigContent(downloaded, true);
                    if (!tested.ok) {
                        throw new Error(_('YAML validation failed: %s').format(tested.message));
                    }

                    if (editor) {
                        editor.setValue(String(downloaded || '').trimEnd() + '\n', -1);
                        editor.clearSelection();
                    }

                    await execService('reload');
                    if (downloadedInfo.mode === 'remnawave-client-path') {
                        notify('info', _('Subscription downloaded, validated and applied (Remnawave /mihomo mode).'));
                    } else {
                        notify('info', _('Subscription downloaded, validated and applied.'));
                    }
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
                E('div', { 'class': 'miclash-topbar' }, [
                    E('div'),
                    E('div', { 'class': 'miclash-version-center' }, [
                        appVersionBadge,
                        kernelBadge
                    ]),
                    E('div', { 'class': 'miclash-topbar-right' }, [themeToggleButton])
                ]),
                E('h2', { 'class': 'miclash-title' }, _('MiClash Control Center')),
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

        pageRoot = page;

        setTimeout(async () => {
            try {
                applyUiTheme(await readThemePreference());
                await initializeAceEditor(configContent);
                await refreshHeaderState();

                if (servicePollTimer) clearInterval(servicePollTimer);
                servicePollTimer = setInterval(() => {
                    refreshHeaderState().catch(() => {});
                }, 5000);
            } catch (e) {
                notify('error', _('Failed to initialize editor: %s').format(e.message));
            }
        }, 30);

        return page;
    }
});
