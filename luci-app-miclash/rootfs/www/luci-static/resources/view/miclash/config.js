'use strict';
'require view';
'require fs';
'require ui';
'require view.miclash.utils';
'require view.miclash.route';
'require view.miclash.service';
'require view.miclash.store';
'require view.miclash.release';
'require view.miclash.package';
'require view.miclash.logs';
'require view.miclash.settings-model';
'require view.miclash.rulesets-model';
'require view.miclash.ui-shell';
'require view.miclash.subscription';
'require view.miclash.guard';

const CONFIG_PATH = view_miclash_store.CONFIG_PATH;
const MAIN_CONFIG_NAME = view_miclash_store.MAIN_CONFIG_NAME;
const CONFIG_PROFILES = view_miclash_store.CONFIG_PROFILES;
const RULESET_PATH = view_miclash_rulesets_model.RULESET_PATH;
const FAKEIP_WHITELIST_FILENAME = view_miclash_rulesets_model.FAKEIP_WHITELIST_FILENAME;
const ACE_BASE = '/luci-static/resources/view/miclash/ace/';
const UPDATE_CHECK_MS = 10 * 60 * 1000;
const LOG_POLL_MS = 5000;
const STATUS_POLL_MS = 5000;

let editor = null;
let pageRoot = null;
let controlPollTimer = null;
let logPollTimer = null;
let updatePollTimer = null;
let rulesetMainEditor = null;
let rulesetWhitelistEditor = null;

view_miclash_utils.bumpRpcTimeout();

const appState = {
	versions: { app: 'unknown', clash: 'unknown' },
	kernelStatus: { installed: false, version: null },
	serviceRunning: false,
	proxyMode: 'tproxy',
	configContent: '',
	subscriptionUrl: '',
	selectedConfigName: MAIN_CONFIG_NAME,
	configProfiles: CONFIG_PROFILES.slice(),
	settings: null,
	interfaces: [],
	selectedInterfaces: [],
	detectedLan: '',
	detectedWan: '',
	activeCtrlTab: 'control',
	activeCfgTab: 'config',
	logsRaw: '',
	logsUpdatedAt: 0,
	releaseMeta: {
		appVersion: '',
		kernelVersion: '',
		checkedAt: 0
	},
	serviceActionBusy: false
};

function notify(type, message) {
	const node = ui.addNotification(null, E('p', String(message || '')), type);
	// "Auto-hide notifications" defaults to true; the toast disappears after a
	// short timeout (longer for errors so the user has time to read them).
	// When the user turns the option off, the toast stays until they close it
	// manually Р Р†Р вЂљРІР‚Сњ useful for diagnosing rare issues without losing the message.
	const autoHide = !appState.settings || appState.settings.autoHideNotifications !== false;
	if (node && autoHide) {
		const timeout = type === 'error' ? 10000 : 6000;
		setTimeout(() => {
			try {
				node.remove();
			} catch (e) {}
		}, timeout);
	}
}

function safeText(value) {
	return String(value == null ? '' : value)
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;');
}

function isValidUrl(url) {
	try {
		const parsed = new URL(url);
		return parsed.protocol === 'http:' || parsed.protocol === 'https:';
	} catch (e) {
		return false;
	}
}

const normalizeConfigProfileName = view_miclash_store.normalizeConfigProfileName;
const getConfigLabel = view_miclash_store.getConfigLabel;
const getConfigPathByName = view_miclash_store.getConfigPathByName;
const readConfigFileByName = view_miclash_store.readConfigFileByName;
const writeConfigFileByName = view_miclash_store.writeConfigFileByName;
const ensureConfigProfilesReady = view_miclash_store.ensureConfigProfilesReady;
const readSubscriptionUrl = view_miclash_store.readSubscriptionUrl;
const saveSubscriptionUrl = view_miclash_store.saveSubscriptionUrl;
const readSettingsMap = view_miclash_store.readSettingsMap;
const writeSettingsMap = view_miclash_store.writeSettingsMap;
const parseVersion = view_miclash_release.parseVersion;
const parsePackageVersion = view_miclash_release.parsePackageVersion;
const parseVersionFromOpkgStatus = view_miclash_release.parseVersionFromOpkgStatus;
const normalizeAppVersion = view_miclash_release.normalizeAppVersion;
const normalizeVersion = view_miclash_release.normalizeVersion;
const normalizeReleaseChannel = view_miclash_release.normalizeReleaseChannel;
const compareNumericVersions = view_miclash_release.compareNumericVersions;
const findKernelAsset = view_miclash_release.findKernelAsset;
const findMiClashAsset = view_miclash_release.findMiClashAsset;
const detectPackageManager = view_miclash_package.detectPackageManager;
const execOrThrow = view_miclash_package.execOrThrow;
const installMiClashDependencies = view_miclash_package.installMiClashDependencies;
const ensureCurlAvailable = view_miclash_package.ensureCurlAvailable;
const getNetworkInterfaces = view_miclash_settings_model.getNetworkInterfaces;
const transformProxyMode = view_miclash_settings_model.transformProxyMode;
const detectCurrentProxyMode = view_miclash_settings_model.detectCurrentProxyMode;
const loadOperationalSettings = view_miclash_settings_model.loadOperationalSettings;
const loadInterfacesByMode = view_miclash_settings_model.loadInterfacesByMode;
const detectLanBridge = view_miclash_settings_model.detectLanBridge;
const detectWanInterface = view_miclash_settings_model.detectWanInterface;
const normalizeProxyMode = view_miclash_settings_model.normalizeProxyMode;
const normalizeRulesetName = view_miclash_rulesets_model.normalizeName;
const readRulesetsData = () => view_miclash_rulesets_model.readData(CONFIG_PATH);
const createRulesetFile = view_miclash_rulesets_model.createFile;
const saveRulesetFile = view_miclash_rulesets_model.saveFile;
const deleteRulesetFile = view_miclash_rulesets_model.deleteFile;
const saveRulesetWhitelist = view_miclash_rulesets_model.saveWhitelist;
const looksLikeBase64Text = view_miclash_subscription.looksLikeBase64Text;
const tryDecodeBase64 = view_miclash_subscription.tryDecodeBase64;
const looksLikeUriSubscription = view_miclash_subscription.looksLikeUriSubscription;
const looksLikeBase64Blob = view_miclash_subscription.looksLikeBase64Blob;
const looksLikeYamlConfig = view_miclash_subscription.looksLikeYamlConfig;

function applyThemeToEditor(editorInstance) {
	view_miclash_ui_shell.applyThemeToEditor(editorInstance);
}

function applyEditorTheme() {
	view_miclash_ui_shell.applyThemeToEditors([
		editor,
		rulesetMainEditor,
		rulesetWhitelistEditor
	]);
}

async function getVersions() {
	const info = { app: 'unknown', clash: 'unknown' };
	const packageName = 'luci-app-miclash';

	try {
		const clashV = await fs.exec('/opt/clash/bin/clash', ['-v']);
		const clashVersion = String(clashV.stdout || clashV.stderr || '');
		if (clashVersion) {
			info.clash = parseVersion(clashVersion, 'installed');
		} else {
			const alt = await fs.exec('/opt/clash/bin/clash', ['version']);
			info.clash = parseVersion(alt.stdout || alt.stderr, 'installed');
		}
	} catch (e) {}

	try {
		const result = await fs.exec('/bin/opkg', ['list-installed', packageName]);
		const raw = String(result.stdout || '') + '\n' + String(result.stderr || '');
		const parsed = parsePackageVersion(raw, packageName);
		if (parsed) info.app = normalizeAppVersion(parsed);
	} catch (_) {
		try {
			const result = await fs.exec('/usr/bin/apk', ['info', '-v', packageName]);
			const raw = String(result.stdout || '') + '\n' + String(result.stderr || '');
			const parsed = parsePackageVersion(raw, packageName);
			if (parsed) info.app = normalizeAppVersion(parsed);
		} catch (_) {}
	}

	if (info.app === 'unknown') {
		try {
			const opkgStatusRaw = await fs.read('/usr/lib/opkg/status');
			const parsed = parseVersionFromOpkgStatus(opkgStatusRaw, [packageName]);
			if (parsed) info.app = normalizeAppVersion(parsed);
		} catch (_) {}
	}

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

async function getMihomoStatus() {
	const binPath = '/opt/clash/bin/clash';

	try {
		const stat = await L.resolveDefault(fs.stat(binPath), null);
		if (!stat) return { installed: false, version: null };
	} catch (e) {
		return { installed: false, version: null };
	}

	try {
		const result = await fs.exec(binPath, ['-v']);
		const output = String(result.stdout || result.stderr || '').trim();
		if (output) return { installed: true, version: parseVersion(output, _('Installed')) };
	} catch (e) {}

	try {
		const result = await fs.exec(binPath, ['version']);
		const output = String(result.stdout || result.stderr || '').trim();
		if (output) return { installed: true, version: parseVersion(output, _('Installed')) };
	} catch (e) {}

	return { installed: true, version: _('Installed') };
}

async function ensureMihomoKernelInstalled() {
	const status = await getMihomoStatus();
	appState.kernelStatus = status;

	if (!status || !status.installed) {
		updateHeaderAndControlDom();
		throw new Error(_('Mihomo kernel is not installed.'));
	}

	return status;
}

function includePrereleases() {
	return normalizeReleaseChannel(appState.settings && appState.settings.releaseChannel) === 'prerelease';
}

async function getLatestMihomoRelease() {
	return view_miclash_release.getLatestMihomoRelease(includePrereleases());
}

async function getLatestMiClashRelease() {
	return view_miclash_release.getLatestMiClashRelease(includePrereleases());
}

function resolveAppActionState() {
	const local = normalizeAppVersion(appState.versions?.app || '');
	const latest = normalizeAppVersion(appState.releaseMeta?.appVersion || '');
	const hasLocal = !!local && local !== 'unknown';
	const cmp = compareNumericVersions(local, latest);
	const hasUpdate = !!latest && (!hasLocal || cmp === -1 || (cmp === null && local !== latest));

	if (!hasLocal) {
		return {
			kind: 'install',
			icon: '\u2b07',
			className: 'sbox-version-action-install',
			title: _('Install MiClash')
		};
	}

	if (hasUpdate) {
		return {
			kind: 'update',
			icon: '\u2b07',
			className: 'sbox-version-action-install',
			title: _('Update MiClash')
		};
	}

	return {
		kind: 'reinstall',
		icon: '\u21bb',
		className: 'sbox-version-action-reinstall',
		title: _('Reinstall MiClash')
	};
}

function resolveKernelActionState() {
	const installed = !!(appState.kernelStatus && appState.kernelStatus.installed);
	const local = normalizeVersion(
		(appState.kernelStatus && appState.kernelStatus.version) ||
		appState.versions?.clash ||
		''
	);
	const latest = normalizeVersion(appState.releaseMeta?.kernelVersion || '');
	const cmp = compareNumericVersions(local, latest);
	const hasUpdate = installed && !!latest && (!local || cmp === -1 || (cmp === null && local !== latest));

	if (!installed) {
		return {
			kind: 'install',
			icon: '\u2b07',
			className: 'sbox-version-action-install',
			title: _('Install Kernel')
		};
	}

	if (hasUpdate) {
		return {
			kind: 'update',
			icon: '\u2b07',
			className: 'sbox-version-action-install',
			title: _('Update Kernel')
		};
	}

	return {
		kind: 'reinstall',
		icon: '\u21bb',
		className: 'sbox-version-action-reinstall',
		title: _('Reinstall Kernel')
	};
}

function shouldCheckAppRelease(force) {
	return !!force || resolveAppActionState().kind !== 'update';
}

function shouldCheckKernelRelease(force) {
	return !!force || resolveKernelActionState().kind !== 'update';
}

async function refreshReleaseMeta(options) {
	const opts = options || {};
	const force = !!opts.force;
	const checkApp = shouldCheckAppRelease(force);
	const checkKernel = shouldCheckKernelRelease(force);

	if (!checkApp && !checkKernel) return false;

	const [appRelease, kernelRelease] = await Promise.all([
		checkApp ? getLatestMiClashRelease() : Promise.resolve(null),
		checkKernel ? getLatestMihomoRelease() : Promise.resolve(null)
	]);

	if (checkApp) {
		appState.releaseMeta.appVersion = appRelease ? normalizeAppVersion(appRelease.version || '') : '';
	}
	if (checkKernel) {
		appState.releaseMeta.kernelVersion = kernelRelease ? normalizeVersion(kernelRelease.version || '') : '';
	}
	appState.releaseMeta.checkedAt = Date.now();
	updateHeaderAndControlDom();
	return true;
}

function isRpcReconnectLikeError(message) {
	const text = String(message || '').toLowerCase();
	if (!text) return false;
	if (text.indexOf('xhr') !== -1 && text.indexOf('timeout') !== -1) return true;
	if (text.indexOf('request timed out') !== -1) return true;
	if (text.indexOf('networkerror') !== -1) return true;
	if (text.indexOf('failed to fetch') !== -1) return true;
	if (text.indexOf('connection') !== -1 && (text.indexOf('closed') !== -1 || text.indexOf('reset') !== -1 || text.indexOf('refused') !== -1)) return true;
	return false;
}

async function installMiClashFromSettings(actionKind) {
	assertNetworkUpdateAllowed();

	const manager = await detectPackageManager();
	if (!manager) throw new Error(_('No supported package manager found (apk/opkg).'));

	const release = await getLatestMiClashRelease();
	if (!release) throw new Error(_('Failed to load MiClash release information: %s').format(_('Unavailable')));

	const asset = findMiClashAsset(release, manager.type);
	if (!asset || !asset.browser_download_url) {
		throw new Error(_('Failed to load MiClash release information: %s').format(_('Download failed')));
	}

	const tmpPath = manager.type === 'apk' ? '/tmp/miclash-update.apk' : '/tmp/miclash-update.ipk';
	const mode = String(actionKind || 'update');
	const forceReinstall = mode === 'reinstall';

	try {
		notify('info', _('Downloading MiClash package...'));
		await installMiClashDependencies(manager);
		await execOrThrow('/usr/bin/curl', ['-L', '-fsS', asset.browser_download_url, '-o', tmpPath], _('Download failed'));

		try {
			if (manager.type === 'apk') {
				await execOrThrow(
					manager.bin,
					forceReinstall
						? ['add', '--force-reinstall', '--allow-untrusted', tmpPath]
						: ['add', tmpPath, '--allow-untrusted'],
					_('Failed to install MiClash package.')
				);
			} else {
				await execOrThrow(
					manager.bin,
					forceReinstall
						? ['--force-reinstall', 'install', tmpPath]
						: ['install', tmpPath],
					_('Failed to install MiClash package.')
				);
			}
		} catch (e) {
			if (!isRpcReconnectLikeError(e.message)) throw e;
			notify('info', _('Connection interrupted while finalizing MiClash update. Reloading interface...'));
			setTimeout(() => {
				window.location.reload();
			}, 3000);
			return true;
		}

		notify('info', _('MiClash package downloaded and installed.'));
		notify('info', _('MiClash package installed. Reloading interface...'));
		setTimeout(() => {
			window.location.reload();
		}, 1500);
		return true;
	} finally {
		try { await fs.remove(tmpPath); } catch (e) {}
	}
}

async function downloadMihomoKernel(downloadUrl, version, arch) {
	const safeVersion = String(version || '').replace(/[^\w.-]/g, '');
	const fileName = 'mihomo-linux-' + arch + '-' + safeVersion + '.gz';
	const downloadPath = '/tmp/' + fileName;
	const extractedFile = downloadPath.replace(/\.gz$/, '');
	const targetFile = '/opt/clash/bin/clash';

	try {
		notify('info', _('Downloading mihomo kernel...'));

		await ensureCurlAvailable();
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

async function installKernelFromSettings() {
	assertNetworkUpdateAllowed();

	const arch = await detectSystemArchitecture();
	const release = await getLatestMihomoRelease();
	const asset = findKernelAsset(release, arch);

	if (!release) throw new Error(_('Failed to load kernel information: %s').format(_('Unavailable')));
	if (!asset || !asset.browser_download_url) throw new Error(_('Failed to load kernel information: %s').format(_('Download failed')));

	const ok = await downloadMihomoKernel(asset.browser_download_url, release.version, arch);
	if (!ok) return false;

	if (await getServiceStatus()) {
		try {
			if (!(await restartOrReloadService('restart'))) {
				throw new Error(_('Service did not enter running state in time.'));
			}
			notify('info', _('Kernel installed and service restarted.'));
		} catch (e) {
			notify('error', _('Kernel installed, but failed to restart service: %s').format(e.message));
		}
	}

	appState.kernelStatus = await getMihomoStatus();
	appState.versions.clash = (appState.kernelStatus && appState.kernelStatus.version) || appState.versions.clash;
	await refreshHeaderAndControl();
	await refreshReleaseMeta({ force: true });
	return true;
}

function showModal(options) {
	const opts = Object.assign({}, options || {}, { mountNode: pageRoot });
	return view_miclash_ui_shell.showModal(opts);
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

		const info = E('div', { 'class': 'sbox-modal-body' }, [
			E('div', {}, _('Status: %s').format(status.installed ? _('Installed') : _('Not installed'))),
			E('div', {}, _('Installed version: %s').format(status.installed ? status.version : _('Not installed'))),
			E('div', {}, _('Architecture: %s').format(arch)),
			E('div', {}, _('Latest release: %s').format(release ? release.version : _('Unavailable')))
		]);

		const buttons = [];
		if (release && asset) {
			buttons.push({
				label: downloadLabel,
				className: 'cbi-button cbi-button-apply',
				onClick: async function(ctx) {
					ctx.button.textContent = _('Downloading...');
					const ok = await downloadMihomoKernel(asset.browser_download_url, release.version, arch);
					if (ok) {
						if (await getServiceStatus()) {
							try {
								if (!(await restartOrReloadService('restart'))) {
									throw new Error(_('Service did not enter running state in time.'));
								}
								notify('info', _('Kernel installed and service restarted.'));
							} catch (e) {
								notify('error', _('Kernel installed, but failed to restart service: %s').format(e.message));
							}
						}
						await refreshHeaderAndControl();
						ctx.closeModal();
					}
				}
			});
		}

		buttons.push({
			label: _('Close'),
			className: 'cbi-button cbi-button-neutral'
		});

		showModal({
			title: _('Kernel Settings'),
			body: info,
			buttons: buttons
		});
	} catch (e) {
		notify('error', _('Failed to load kernel information: %s').format(e.message));
	}
}

async function withButtons(btns, fn) {
	return view_miclash_ui_shell.withButtons(btns, fn, safeText);
}

async function withServiceButtons(activeBtn, inactiveBtn, fn) {
	const activeHtml = activeBtn ? activeBtn.innerHTML : '';
	const inactiveDisabled = inactiveBtn ? inactiveBtn.disabled : false;

	appState.serviceActionBusy = true;

	if (activeBtn) {
		activeBtn.disabled = true;
		activeBtn.innerHTML = '<span class="sbox-spinner"></span> ' + safeText(activeBtn.textContent || '').trim();
	}
	if (inactiveBtn) inactiveBtn.disabled = true;
	updateHeaderAndControlDom();

	try {
		return await fn();
	} finally {
		appState.serviceActionBusy = false;

		if (activeBtn && activeBtn.isConnected) {
			activeBtn.disabled = false;
			activeBtn.innerHTML = activeHtml;
		}
		if (inactiveBtn && inactiveBtn.isConnected) inactiveBtn.disabled = inactiveDisabled;
	}
}

function parseYamlValue(yaml, key) {
	const escapedKey = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
	const re = new RegExp('^\\s*' + escapedKey + '\\s*:\\s*(["\\\']?)([^#\\r\\n]+?)\\1\\s*(?:#.*)?$', 'm');
	const m = String(yaml || '').match(re);
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
	if (host === '0.0.0.0' || host === '::' || host === '') host = fallbackHost;
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
	return view_miclash_service.getStatus();
}

async function waitForServiceStatus(targetStatus, timeoutMs) {
	return view_miclash_service.waitForStatus(!!targetStatus, timeoutMs);
}

async function dispatchServiceActions(actions) {
	return view_miclash_service.dispatchActions(actions);
}

async function restartOrReloadService(action) {
	return view_miclash_service.restartOrReload(action);
}

function notifyDetailedError(title, detail) {
	ui.addNotification(null, E('div', {}, [
		E('p', String(title || '')),
		E('pre', {
			'style': 'margin: 6px 0 0; padding: 0 0 0 10px; font-size: 11px; line-height: 1.45; font-family: monospace; white-space: pre-wrap; word-break: break-word; max-height: 280px; overflow: auto; background: none; border: 0; border-left: 2px solid var(--sbox-border, currentColor);'
		}, String(detail || _('unknown error')))
	]), 'error');
}

function buildSubscriptionClientProfile(settings, appVersion) {
	return view_miclash_subscription.buildClientProfile(settings, appVersion);
}

function normalizeSubscriptionDownloadUrl(rawUrl) {
	return view_miclash_subscription.normalizeDownloadUrl(rawUrl);
}

async function buildSubscriptionDeviceHeaders(settings) {
	return view_miclash_subscription.buildDeviceHeaders(settings);
}

async function downloadSubscriptionWithProfile(url, profile, deviceHeaders, mode) {
	return view_miclash_subscription.downloadWithProfile(url, profile, deviceHeaders, mode);
}

async function testConfigContent(content, keepOnSuccess, targetPath) {
	return view_miclash_subscription.testConfigContent(
		content,
		keepOnSuccess,
		targetPath,
		{ ensureKernelInstalled: ensureMihomoKernelInstalled }
	);
}

async function fetchSubscriptionAsYaml(url, targetPath) {
	assertNetworkUpdateAllowed();

	const settingsMap = await readSettingsMap();
	const versions = await getVersions();
	const profile = buildSubscriptionClientProfile(settingsMap, versions.app);
	const deviceHeaders = await buildSubscriptionDeviceHeaders(settingsMap);
	const resolved = normalizeSubscriptionDownloadUrl(url);
	let mode = resolved.mode;
	let payload = '';
	let primaryError = null;

	try {
		payload = await downloadSubscriptionWithProfile(resolved.url, profile, deviceHeaders, mode);
	} catch (e) {
		primaryError = e;
	}

	const needsFallbackByPayload = !primaryError &&
		(looksLikeBase64Blob(payload) || looksLikeUriSubscription(payload));
	const shouldTryFallback = !!resolved.remnawaveCandidateUrl &&
		(needsFallbackByPayload || (primaryError && resolved.fallbackOnError));

	if (shouldTryFallback) {
		try {
			payload = await downloadSubscriptionWithProfile(
				resolved.remnawaveCandidateUrl,
				profile,
				deviceHeaders,
				'remnawave-client-path'
			);
			mode = 'remnawave-client-path';
			primaryError = null;
		} catch (fallbackError) {
			if (primaryError) {
				throw new Error(_('Subscription download failed for both original URL and /mihomo fallback: %s').format(fallbackError.message));
			}
			throw new Error(_('Original URL returned links/base64 and /mihomo fallback failed: %s').format(fallbackError.message));
		}
	}

	if (primaryError) throw primaryError;
	if (!payload.trim()) throw new Error(_('Downloaded file is empty.'));

	if (looksLikeBase64Blob(payload)) {
		const decoded = tryDecodeBase64(payload);
		if (decoded && looksLikeYamlConfig(decoded)) {
			payload = decoded;
		}
	}

	if (looksLikeBase64Blob(payload) || looksLikeUriSubscription(payload)) {
		if (mode === 'remnawave-client-path') {
			throw new Error(_('Both original URL and /mihomo returned links/base64 instead of Clash YAML. Check provider export type.'));
		}
		throw new Error(_('The subscription server returned links/base64 instead of Clash YAML. For Remnawave use the /mihomo subscription path.'));
	}

	const tested = await testConfigContent(payload, false, targetPath || CONFIG_PATH);
	if (!tested.ok) throw new Error(tested.message || _('YAML validation failed.'));

	return { content: payload, mode: mode };
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
		const popup = window.open(url, '_blank');

		if (!popup) {
			notify('warning', _('Popup was blocked. Please allow popups for this site.'));
		}
	} catch (e) {
		notify('error', _('Failed to open dashboard: %s').format(e.message));
	}
}

async function saveOperationalSettings(mode, proxyMode, tunStack, autoDetectLan, autoDetectWan, blockQuic, internetOnlyMiclash, useTmpfsRules, interfaces, enableHwid, hwidUserAgent, hwidDeviceOS, autoHideNotifications, releaseChannel, options) {
	const opts = options || {};
	try {
		await view_miclash_settings_model.saveOperationalSettings(
			mode,
			proxyMode,
			tunStack,
			autoDetectLan,
			autoDetectWan,
			blockQuic,
			internetOnlyMiclash,
			useTmpfsRules,
			interfaces,
			enableHwid,
			hwidUserAgent,
			hwidDeviceOS,
			autoHideNotifications,
			releaseChannel
		);

		if (!opts.silent) {
			notify('info', _('Settings saved.'));
		}
		return true;
	} catch (e) {
		notify('error', _('Failed to save settings: %s').format(e.message));
		return false;
	}
}

async function switchProxyModeFromHeader(targetMode) {
	const nextMode = normalizeProxyMode(targetMode);
	if (nextMode === appState.proxyMode) return;

	const current = await loadOperationalSettings();
	const interfaces = (current.mode === 'explicit'
		? (current.includedInterfaces || [])
		: (current.excludedInterfaces || [])
	).slice();

	const ok = await saveOperationalSettings(
		current.mode || 'exclude',
		nextMode,
		current.tunStack || 'system',
		!!current.autoDetectLan,
		!!current.autoDetectWan,
		!!current.blockQuic,
		!!current.internetOnlyMiclash,
		!!current.useTmpfsRules,
		interfaces,
		!!current.enableHwid,
		current.hwidUserAgent || 'MiClash',
		current.hwidDeviceOS || 'OpenWrt',
		current.autoHideNotifications !== false,
		current.releaseChannel || 'release',
		{ silent: true }
	);

	if (!ok) throw new Error(_('Cannot save proxy mode.'));

	if (!(await restartOrReloadService('restart'))) {
		throw new Error(_('Service did not enter running state in time.'));
	}

	appState.settings = await loadOperationalSettings();
	appState.selectedInterfaces = await loadInterfacesByMode(appState.settings.mode || 'exclude');
	appState.detectedLan = appState.settings.detectedLan || (await detectLanBridge()) || '';
	appState.detectedWan = appState.settings.detectedWan || (await detectWanInterface()) || '';
	appState.proxyMode = normalizeProxyMode(appState.settings.proxyMode || nextMode);
	appState.serviceRunning = await getServiceStatus();

	const freshConfig = await L.resolveDefault(
		fs.read(getConfigPathByName(appState.selectedConfigName)),
		''
	);
	appState.configContent = freshConfig;
	if (editor) {
		editor.setValue(String(freshConfig || ''), -1);
		editor.clearSelection();
	}

	updateHeaderAndControlDom();
	if (appState.activeCtrlTab === 'settings') renderSettingsPane();
	notify('info', _('Proxy mode switched to %s. Service restarted.').format(appState.proxyMode));
}

async function loadClashLogs() {
	return view_miclash_logs.readRaw();
}

function colorizeLog(raw) {
	if (!raw) return '<span class="sbox-log-muted">No logs yet.</span>';

	const rows = String(raw || '').split('\n')
		.map((line) => view_miclash_logs.formatLine(line))
		.filter((item) => !!item && !!item.text);

	if (!rows.length) return '<span class="sbox-log-muted">No logs yet.</span>';

	return rows.map((item) => {
		const esc = safeText(item.text);
		if (/(FATAL|PANIC|ERRO|ERROR)/i.test(item.level)) return '<span class="sbox-log-error">' + esc + '</span>';
		if (/(WARN|WARNING)/i.test(item.level)) return '<span class="sbox-log-warn">' + esc + '</span>';
		if (/(INFO)/i.test(item.level)) return '<span class="sbox-log-info">' + esc + '</span>';
		return '<span class="sbox-log-muted">' + esc + '</span>';
	}).join('\n');
}

function loadScript(src) {
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

async function initializeAceEditor(content) {
	await loadScript(ACE_BASE + 'ace.js');
	await loadScript(ACE_BASE + 'mode-yaml.js');

	ace.config.set('basePath', ACE_BASE);
	const editorHost = (pageRoot && pageRoot.querySelector('#miclash-editor')) || document.getElementById('miclash-editor');
	if (!editorHost) throw new Error('editor container #miclash-editor not found');
	editor = ace.edit(editorHost);
	editor.session.setMode('ace/mode/yaml');
	editor.setValue(String(content || ''), -1);
	editor.clearSelection();
	editor.setOptions({
		fontSize: '12px',
		showPrintMargin: false,
		wrap: true,
		highlightActiveLine: true
	});
	applyEditorTheme();
}

function destroyRulesetEditors() {
	if (rulesetMainEditor) {
		try { rulesetMainEditor.destroy(); } catch (e) {}
		try { if (rulesetMainEditor.container) rulesetMainEditor.container.textContent = ''; } catch (e) {}
		rulesetMainEditor = null;
	}

	if (rulesetWhitelistEditor) {
		try { rulesetWhitelistEditor.destroy(); } catch (e) {}
		try { if (rulesetWhitelistEditor.container) rulesetWhitelistEditor.container.textContent = ''; } catch (e) {}
		rulesetWhitelistEditor = null;
	}
}

async function openRulesetsModal() {
	await loadScript(ACE_BASE + 'ace.js');
	await loadScript(ACE_BASE + 'mode-text.js');

	const data = await readRulesetsData();
	let rulesetNames = data.rulesetNames.slice();
	let currentRuleset = rulesetNames[0] || '';
	const rulesetCache = Object.assign({}, data.contentMap || {});

	const body = E('div', { 'class': 'sbox-modal-body sbox-rulesets-modal-body' });
	body.innerHTML = '' +
		'<div class="sbox-rulesets-layout">' +
			'<aside class="sbox-rulesets-sidebar">' +
				'<div class="sbox-rulesets-title">' + safeText(_('Local Rulesets')) + '</div>' +
				'<div class="sbox-muted">' + safeText(_('Manage local .txt lists for rule-providers.')) + '</div>' +
				'<div class="sbox-rulesets-create-row">' +
					'<input id="sbox-ruleset-new-name" class="cbi-input-text sbox-input" type="text" placeholder="' + safeText(_('new-list-name')) + '" />' +
					'<button id="sbox-ruleset-create" type="button" class="cbi-button cbi-button-positive">' + safeText(_('Create')) + '</button>' +
				'</div>' +
				'<div id="sbox-rulesets-list" class="sbox-rulesets-list"></div>' +
			'</aside>' +
			'<section class="sbox-rulesets-main">' +
				'<div class="sbox-rulesets-toolbar">' +
					'<span id="sbox-ruleset-current" class="sbox-ruleset-current"></span>' +
					'<div class="sbox-rulesets-toolbar-actions">' +
						'<button id="sbox-ruleset-save" type="button" class="cbi-button cbi-button-positive">' + safeText(_('Save')) + '</button>' +
						'<button id="sbox-ruleset-delete" type="button" class="cbi-button cbi-button-negative">' + safeText(_('Delete')) + '</button>' +
					'</div>' +
				'</div>' +
				'<div id="sbox-ruleset-empty" class="sbox-rulesets-empty">' + safeText(_('No ruleset selected. Create one to begin.')) + '</div>' +
				'<div id="sbox-ruleset-editor-wrap" class="sbox-ruleset-editor-wrap">' +
					'<div id="sbox-ruleset-editor" class="sbox-ruleset-editor"></div>' +
				'</div>' +
				'<div class="sbox-rulesets-example">' +
					'<div class="sbox-muted" style="margin-bottom:6px;">' + safeText(_('Example usage in config.yaml')) + '</div>' +
					'<pre>rule-providers:\n  your-list:\n    behavior: classical\n    type: file\n    format: text\n    path: ./lst/your-list.txt</pre>' +
				'</div>' +
				(data.whitelistMode ? '' +
					'<div class="sbox-rulesets-whitelist">' +
						'<div class="sbox-rulesets-whitelist-head">' + safeText(_('IP-CIDR List (fake-ip whitelist mode)')) + '</div>' +
						'<div class="sbox-muted" style="margin-bottom:8px;">' + safeText(_('One IPv4/CIDR per line. Save applies firewall update without restarting Mihomo.')) + '</div>' +
						'<div id="sbox-ruleset-whitelist-editor" class="sbox-ruleset-whitelist-editor"></div>' +
						'<div class="sbox-actions" style="margin-top:8px;">' +
							'<button id="sbox-ruleset-save-whitelist" type="button" class="cbi-button cbi-button-apply">' + safeText(_('Save IP-CIDR List')) + '</button>' +
						'</div>' +
					'</div>'
					: '') +
			'</section>' +
		'</div>';

	const listNode = body.querySelector('#sbox-rulesets-list');
	const currentNode = body.querySelector('#sbox-ruleset-current');
	const emptyNode = body.querySelector('#sbox-ruleset-empty');
	const editorWrap = body.querySelector('#sbox-ruleset-editor-wrap');
	const saveBtn = body.querySelector('#sbox-ruleset-save');
	const deleteBtn = body.querySelector('#sbox-ruleset-delete');
	const createBtn = body.querySelector('#sbox-ruleset-create');
	const createInput = body.querySelector('#sbox-ruleset-new-name');
	const saveWhitelistBtn = body.querySelector('#sbox-ruleset-save-whitelist');

	function ensureRulesetEditor() {
		if (rulesetMainEditor) return;
		rulesetMainEditor = ace.edit('sbox-ruleset-editor');
		rulesetMainEditor.session.setMode('ace/mode/text');
		rulesetMainEditor.setOptions({
			fontSize: '12px',
			showPrintMargin: false,
			wrap: true,
			highlightActiveLine: true
		});
		applyThemeToEditor(rulesetMainEditor);
	}

	function resizeAndFocusRulesetEditor(shouldFocus) {
		if (!rulesetMainEditor) return;
		setTimeout(() => {
			try { rulesetMainEditor.resize(); } catch (e) {}
			if (shouldFocus) {
				try { rulesetMainEditor.focus(); } catch (e) {}
			}
		}, 0);
	}

	function refreshToolbarState() {
		const hasCurrent = !!currentRuleset;
		if (currentNode) currentNode.textContent = hasCurrent ? ('./lst/' + currentRuleset) : _('No file selected');
		if (saveBtn) saveBtn.disabled = !hasCurrent;
		if (deleteBtn) deleteBtn.disabled = !hasCurrent;
		if (emptyNode) emptyNode.style.display = hasCurrent ? 'none' : '';
		if (editorWrap) editorWrap.style.display = hasCurrent ? 'block' : 'none';
		if (hasCurrent) resizeAndFocusRulesetEditor(false);
	}

	function renderRulesetList() {
		if (!listNode) return;
		listNode.innerHTML = '';

		if (!rulesetNames.length) {
			listNode.innerHTML = '<div class="sbox-muted">' + safeText(_('No rulesets yet.')) + '</div>';
			return;
		}

		rulesetNames.forEach((name) => {
			const button = E('button', {
				'type': 'button',
				'class': 'sbox-ruleset-list-item' + (name === currentRuleset ? ' active' : '')
			}, name);

			button.addEventListener('click', async () => {
				currentRuleset = name;
				renderRulesetList();
				refreshToolbarState();
				ensureRulesetEditor();
				const content = rulesetCache[currentRuleset] != null
					? rulesetCache[currentRuleset]
					: await L.resolveDefault(fs.read(RULESET_PATH + currentRuleset), '');
				rulesetCache[currentRuleset] = content;
				rulesetMainEditor.setValue(String(content || ''), -1);
				rulesetMainEditor.clearSelection();
				resizeAndFocusRulesetEditor(true);
			});

			listNode.appendChild(button);
		});
	}

	const closeModal = showModal({
		title: _('Rulesets'),
		body: body,
		modalClass: 'sbox-modal-wide',
		buttons: [
			{
				label: _('Close'),
				className: 'cbi-button cbi-button-neutral'
			}
		],
		onClose: destroyRulesetEditors
	});

	refreshToolbarState();
	renderRulesetList();

	if (currentRuleset) {
		ensureRulesetEditor();
		rulesetMainEditor.setValue(String(rulesetCache[currentRuleset] || ''), -1);
		rulesetMainEditor.clearSelection();
		resizeAndFocusRulesetEditor(false);
	}

	if (createInput && createBtn) {
		const createAction = () => withButtons(createBtn, async () => {
			const normalized = normalizeRulesetName(createInput.value);
			if (!normalized) {
				throw new Error(_('Invalid name. Use letters, numbers, "_" or "-".'));
			}

			const filename = normalized + '.txt';
			if (filename === FAKEIP_WHITELIST_FILENAME) {
				throw new Error(_('This name is reserved.'));
			}
			if (rulesetNames.includes(filename)) {
				throw new Error(_('A ruleset with this name already exists.'));
			}

			await createRulesetFile(filename);
			rulesetNames.push(filename);
			rulesetNames.sort((a, b) => a.localeCompare(b));
			rulesetCache[filename] = '';
			currentRuleset = filename;
			createInput.value = '';

			renderRulesetList();
			refreshToolbarState();
			ensureRulesetEditor();
			rulesetMainEditor.setValue('', -1);
			rulesetMainEditor.clearSelection();
			resizeAndFocusRulesetEditor(true);
			notify('info', _('Ruleset "%s" created.').format(filename));
		}).catch((e) => {
			notify('error', e.message || _('Failed to create ruleset.'));
		});

		createBtn.addEventListener('click', createAction);
		createInput.addEventListener('keydown', (ev) => {
			if (ev.key === 'Enter') {
				ev.preventDefault();
				createAction();
			}
		});
	}

	if (saveBtn) {
		saveBtn.addEventListener('click', () => withButtons(saveBtn, async () => {
			if (!currentRuleset || !rulesetMainEditor) return;
			const raw = String(rulesetMainEditor.getValue() || '').replace(/\r\n/g, '\n');
			const finalContent = raw.trim() ? raw.trimEnd() + '\n' : '';
			await saveRulesetFile(currentRuleset, finalContent);
			rulesetCache[currentRuleset] = finalContent;
			notify('info', _('Ruleset "%s" saved.').format(currentRuleset));
		}).catch((e) => {
			notify('error', _('Failed to save ruleset: %s').format(e.message));
		}));
	}

	if (deleteBtn) {
		deleteBtn.addEventListener('click', () => {
			if (!currentRuleset) return;
			const deletingName = currentRuleset;

			showModal({
				title: _('Delete Ruleset'),
				body: _('Are you sure you want to delete "%s"?').format(deletingName),
				buttons: [
					{
						label: _('Delete'),
						className: 'cbi-button cbi-button-negative',
						onClick: async function(ctx) {
							await deleteRulesetFile(deletingName);
							rulesetNames = rulesetNames.filter((name) => name !== deletingName);
							delete rulesetCache[deletingName];
							currentRuleset = rulesetNames[0] || '';
							renderRulesetList();
							refreshToolbarState();
							if (rulesetMainEditor) {
								rulesetMainEditor.setValue(currentRuleset ? String(rulesetCache[currentRuleset] || '') : '', -1);
								rulesetMainEditor.clearSelection();
							}
							notify('info', _('Ruleset "%s" deleted.').format(deletingName));
							ctx.closeModal();
						}
					},
					{
						label: _('Cancel'),
						className: 'cbi-button cbi-button-neutral'
					}
				]
			});
		});
	}

	if (data.whitelistMode && saveWhitelistBtn) {
		rulesetWhitelistEditor = ace.edit('sbox-ruleset-whitelist-editor');
		rulesetWhitelistEditor.session.setMode('ace/mode/text');
		rulesetWhitelistEditor.setOptions({
			fontSize: '12px',
			showPrintMargin: false,
			wrap: true,
			highlightActiveLine: true
		});
		rulesetWhitelistEditor.setValue(String(data.whitelistContent || ''), -1);
		rulesetWhitelistEditor.clearSelection();
		applyThemeToEditor(rulesetWhitelistEditor);

		saveWhitelistBtn.addEventListener('click', () => withButtons(saveWhitelistBtn, async () => {
			const raw = String(rulesetWhitelistEditor.getValue() || '').replace(/\r\n/g, '\n');
			const finalContent = raw.trim() ? raw.trimEnd() + '\n' : '';
			const update = await saveRulesetWhitelist(finalContent);
			if (update && update.code === 0) {
				notify('info', _('IP-CIDR list saved and firewall rules updated.'));
			} else {
				const errMsg = String(update?.stderr || update?.stdout || _('unknown error')).trim();
				notify('warning', _('IP-CIDR list saved, but firewall update failed: %s').format(errMsg));
			}
		}).catch((e) => {
			notify('error', _('Failed to save IP-CIDR list: %s').format(e.message));
		}));
	}

	return closeModal;
}

function modeLabel(mode) {
	if (mode === 'tun') return 'tun mode';
	if (mode === 'mixed') return 'mixed mode';
	return 'tproxy mode';
}

function buildSettingsSummary() {
	if (!appState.settings) return '';

	const s = appState.settings;
	const lines = [];

	if (s.mode === 'explicit') {
		lines.push(_('Mode: Explicit (proxy only selected interfaces)'));
		if (s.autoDetectLan && appState.detectedLan) lines.push(_('Auto LAN: %s').format(appState.detectedLan));
	} else {
		lines.push(_('Mode: Exclude (proxy all except selected interfaces)'));
		if (s.autoDetectWan && appState.detectedWan) lines.push(_('Auto WAN: %s').format(appState.detectedWan));
	}

	const manual = (s.mode === 'explicit' ? s.includedInterfaces : s.excludedInterfaces) || [];
	if (manual.length) {
		lines.push(_('Manual interfaces: %s').format(manual.join(', ')));
	}

	lines.push(_('Proxy mode: %s').format(s.proxyMode || appState.proxyMode || 'tproxy'));
	lines.push(_('Tun stack: %s').format(s.tunStack || 'system'));

	return lines.map((line) => '<div>' + safeText(line) + '</div>').join('');
}

function buildInterfaceListHtml() {
	const s = appState.settings || {};
	const selectedSet = new Set((appState.selectedInterfaces || []).concat(
		s.mode === 'explicit' && s.autoDetectLan && appState.detectedLan ? [appState.detectedLan] : [],
		s.mode === 'exclude' && s.autoDetectWan && appState.detectedWan ? [appState.detectedWan] : []
	));

	const autoInterface = s.mode === 'explicit'
		? (s.autoDetectLan ? appState.detectedLan : '')
		: (s.autoDetectWan ? appState.detectedWan : '');

	const groups = { wan: [], ethernet: [], wifi: [], vpn: [], virtual: [], other: [] };
	(appState.interfaces || []).forEach((iface) => {
		const cat = groups[iface.category] ? iface.category : 'other';
		groups[cat].push(iface);
	});

	const titles = {
		wan: _('WAN'),
		ethernet: _('Ethernet'),
		wifi: _('Wi-Fi'),
		vpn: _('VPN / Tunnel'),
		virtual: _('Virtual'),
		other: _('Other')
	};

	const order = ['wan', 'ethernet', 'wifi', 'vpn', 'virtual', 'other'];
	const chunks = [];

	order.forEach((cat) => {
		if (!groups[cat].length) return;

		const items = groups[cat].map((iface) => {
			const isChecked = selectedSet.has(iface.name);
			const isAuto = autoInterface && iface.name === autoInterface;

			return '' +
				'<label class="sbox-interface-item' + (isAuto ? ' sbox-interface-auto' : '') + '">' +
				'<input type="checkbox" class="sbox-interface-check" value="' + safeText(iface.name) + '"' + (isChecked ? ' checked' : '') + ' />' +
				'<span>' + safeText(iface.name) + (isAuto ? ' <em>(' + safeText(_('auto')) + ')</em>' : '') + '</span>' +
				'</label>';
		}).join('');

		chunks.push('' +
			'<div class="sbox-interface-group">' +
			'<div class="sbox-interface-group-title">' + safeText(titles[cat]) + '</div>' +
			'<div class="sbox-interface-grid">' + items + '</div>' +
			'</div>');
	});

	if (!chunks.length) {
		return '<div class="sbox-muted">' + safeText(_('No interfaces detected.')) + '</div>';
	}

	return chunks.join('');
}

function buildSettingsPaneHtml() {
	const s = appState.settings || {
		mode: 'exclude',
		proxyMode: appState.proxyMode || 'tproxy',
		tunStack: 'system',
		autoDetectLan: true,
		autoDetectWan: true,
		blockQuic: true,
		internetOnlyMiclash: false,
		useTmpfsRules: true,
		autoHideNotifications: true,
		releaseChannel: 'release',
		enableHwid: false,
		hwidUserAgent: 'MiClash',
		hwidDeviceOS: 'OpenWrt'
	};

	const currentProxyMode = appState.proxyMode || s.proxyMode || 'tproxy';
	const showTunStack = currentProxyMode === 'tun' || currentProxyMode === 'mixed';

	return '' +
		'<div id="sbox-settings-status" class="sbox-settings-status">' +
			buildSettingsSummary() +
		'</div>' +
		'<div class="sbox-settings-gap" aria-hidden="true"></div>' +
		'<div class="sbox-settings-grid">' +
			'<section class="sbox-settings-block">' +
				'<h4>' + safeText(_('Traffic Scope')) + '</h4>' +
				'<label class="sbox-radio-row">' +
					'<input type="radio" name="sbox-interface-mode" value="exclude"' + (s.mode !== 'explicit' ? ' checked' : '') + ' />' +
					'<span>' + safeText(_('Exclude mode: proxy all interfaces except selected ones')) + '</span>' +
				'</label>' +
					'<label class="sbox-radio-row">' +
						'<input type="radio" name="sbox-interface-mode" value="explicit"' + (s.mode === 'explicit' ? ' checked' : '') + ' />' +
						'<span>' + safeText(_('Explicit mode: proxy only selected interfaces')) + '</span>' +
					'</label>' +
				'</section>' +

				'<section class="sbox-settings-block">' +
					'<h4>' + safeText(_('Auto Detection')) + '</h4>' +
					'<label class="sbox-checkbox-row" id="sbox-auto-lan-row"' + (s.mode === 'explicit' ? '' : ' style="display:none"') + '>' +
					'<input type="checkbox" id="sbox-auto-lan"' + (s.autoDetectLan ? ' checked' : '') + ' />' +
					'<span>' + safeText(_('Auto detect LAN bridge')) + '</span>' +
				'</label>' +
				'<label class="sbox-checkbox-row" id="sbox-auto-wan-row"' + (s.mode !== 'explicit' ? '' : ' style="display:none"') + '>' +
					'<input type="checkbox" id="sbox-auto-wan"' + (s.autoDetectWan ? ' checked' : '') + ' />' +
					'<span>' + safeText(_('Auto detect WAN interface')) + '</span>' +
				'</label>' +
				'<div class="sbox-muted">' +
					safeText(_('Detected LAN: %s').format(appState.detectedLan || '-')) + '<br/>' +
					safeText(_('Detected WAN: %s').format(appState.detectedWan || '-')) +
				'</div>' +
			'</section>' +

			'<section class="sbox-settings-block sbox-settings-block-wide">' +
				'<h4>' + safeText(_('Interfaces')) + '</h4>' +
				'<div class="sbox-muted" style="margin-bottom:8px;">' +
					(s.mode === 'explicit'
						? safeText(_('Choose interfaces that should go through proxy.'))
						: safeText(_('Choose interfaces that should bypass proxy.'))
					) +
				'</div>' +
				buildInterfaceListHtml() +
				'</section>' +

				'<section class="sbox-settings-block sbox-settings-block-wide">' +
					'<h4>' + safeText(_('Additional')) + '</h4>' +
					'<div id="sbox-tun-stack-row" style="margin-bottom:10px;' + (showTunStack ? '' : 'display:none;') + '">' +
						'<label>' + safeText(_('Tun stack')) + '</label>' +
						'<select id="sbox-tun-stack" class="cbi-input-select sbox-select">' +
							'<option value="system"' + ((s.tunStack || 'system') === 'system' ? ' selected' : '') + '>system</option>' +
							'<option value="gvisor"' + ((s.tunStack || 'system') === 'gvisor' ? ' selected' : '') + '>gvisor</option>' +
							'<option value="mixed"' + ((s.tunStack || 'system') === 'mixed' ? ' selected' : '') + '>mixed</option>' +
						'</select>' +
					'</div>' +
					'<label class="sbox-checkbox-row">' +
						'<input type="checkbox" id="sbox-block-quic"' + (s.blockQuic ? ' checked' : '') + ' />' +
						'<span>' + safeText(_('Block QUIC (UDP/443)')) + '</span>' +
					'</label>' +
				'<label class="sbox-checkbox-row">' +
					'<input type="checkbox" id="sbox-internet-only-miclash"' + (s.internetOnlyMiclash ? ' checked' : '') + ' />' +
					'<span>' + safeText(_('Internet only through MiClash')) + '</span>' +
				'</label>' +
				'<label class="sbox-checkbox-row">' +
					'<input type="checkbox" id="sbox-tmpfs"' + (s.useTmpfsRules ? ' checked' : '') + ' />' +
					'<span>' + safeText(_('Store rules/providers on tmpfs')) + '</span>' +
				'</label>' +
				'<label class="sbox-checkbox-row">' +
					'<input type="checkbox" id="sbox-auto-hide-notifications"' + (s.autoHideNotifications !== false ? ' checked' : '') + ' />' +
					'<span>' + safeText(_('Auto-hide notifications')) + '</span>' +
				'</label>' +
				'<div style="margin-bottom:10px;">' +
					'<label>' + safeText(_('Release channel')) + '</label>' +
					'<select id="sbox-release-channel" class="cbi-input-select sbox-select">' +
						'<option value="release"' + (normalizeReleaseChannel(s.releaseChannel) === 'release' ? ' selected' : '') + '>' + safeText(_('Release only')) + '</option>' +
						'<option value="prerelease"' + (normalizeReleaseChannel(s.releaseChannel) === 'prerelease' ? ' selected' : '') + '>' + safeText(_('Release + pre-release')) + '</option>' +
					'</select>' +
				'</div>' +
				'<label class="sbox-checkbox-row">' +
					'<input type="checkbox" id="sbox-enable-hwid"' + (s.enableHwid ? ' checked' : '') + ' />' +
					'<span>' + safeText(_('Inject HWID headers into proxy-providers')) + '</span>' +
				'</label>' +
				'<div class="sbox-form-grid">' +
					'<div>' +
						'<label>' + safeText(_('User-Agent')) + '</label>' +
						'<input id="sbox-hwid-user-agent" class="cbi-input-text sbox-input" type="text" value="' + safeText(s.hwidUserAgent || 'MiClash') + '" />' +
					'</div>' +
					'<div>' +
						'<label>' + safeText(_('Device OS')) + '</label>' +
						'<input id="sbox-hwid-device-os" class="cbi-input-text sbox-input" type="text" value="' + safeText(s.hwidDeviceOS || 'OpenWrt') + '" />' +
					'</div>' +
				'</div>' +
			'</section>' +
			'</div>' +

			'<div class="sbox-settings-save-wrap">' +
				'<button id="sbox-settings-save" type="button" class="cbi-button cbi-button-apply sbox-settings-save-btn">' + safeText(_('Save Settings')) + '</button>' +
			'</div>' +
		'';
}

function buildConfigOptionsHtml() {
	return (appState.configProfiles || CONFIG_PROFILES).map((item) =>
		'<option value="' + safeText(item.name) + '"' +
		(item.name === appState.selectedConfigName ? ' selected' : '') +
		'>' + safeText(_(item.label)) + '</option>'
	).join('');
}

function buildPageHtml() {
	const versionApp = safeText(appState.versions.app || _('unknown'));
	const versionKernel = safeText(
		appState.kernelStatus && appState.kernelStatus.installed
			? (appState.kernelStatus.version || appState.versions.clash || _('Installed'))
			: _('Not installed')
	);

	return '' +
		'<div class="sbox-header">' +
			'MiClash <span class="sbox-version-inline">' +
				'<strong id="sbox-app-version">' + versionApp + '</strong>' +
				'<span id="sbox-app-action" class="sbox-version-action-icon" role="button" tabindex="0" title="' + safeText(_('Install MiClash')) + '" aria-label="' + safeText(_('Install MiClash')) + '"></span>' +
			'</span>' +
			'<span class="sbox-header-dot">|</span>' +
			'mihomo <span class="sbox-version-inline">' +
				'<strong id="sbox-kernel-version">' + versionKernel + '</strong>' +
				'<span id="sbox-kernel-action" class="sbox-version-action-icon" role="button" tabindex="0" title="' + safeText(_('Install Kernel')) + '" aria-label="' + safeText(_('Install Kernel')) + '"></span>' +
			'</span>' +
			'<span class="sbox-header-dot">|</span>' +
			'<span class="sbox-proxy-mode-inline">' + safeText(_('Mode')) + '</span>' +
			'<select id="sbox-mode-select" class="cbi-input-select sbox-mode-select">' +
				'<option value="tproxy"' + (appState.proxyMode === 'tproxy' ? ' selected' : '') + '>tproxy</option>' +
				'<option value="tun"' + (appState.proxyMode === 'tun' ? ' selected' : '') + '>tun</option>' +
				'<option value="mixed"' + (appState.proxyMode === 'mixed' ? ' selected' : '') + '>mixed</option>' +
			'</select>' +
			'<span class="sbox-header-dot">|</span>' +
			'<span id="sbox-guard" class="sbox-guard-pill ' + (isInternetOnlyEnabled() ? 'sbox-guard-on' : 'sbox-guard-off') + '" title="' + safeText(_('Internet only through MiClash')) + '">' +
				'<span class="sbox-guard-dot ' + (isInternetOnlyEnabled() ? 'sbox-dot-on' : 'sbox-dot-off') + '"></span>' +
				'<span class="sbox-guard-label">' + safeText(_('Guard')) + '</span>' +
				'<span id="sbox-guard-state" class="sbox-guard-state">' + safeText(isInternetOnlyEnabled() ? _('ON') : _('OFF')) + '</span>' +
			'</span>' +
			'<button id="sbox-dashboard" type="button" class="cbi-button sbox-header-button sbox-btn-dashboard ' + (appState.serviceRunning ? 'sbox-btn-dashboard-on' : 'sbox-btn-dashboard-off') + '"' +
				(appState.serviceRunning ? '' : ' disabled') +
			'>' + safeText(_('Dashboard')) + '</button>' +
		'</div>' +

		'<div class="sbox-card">' +
			'<div class="sbox-card-tabs">' +
				'<button type="button" class="sbox-tab sbox-tab-active" data-ctrl-tab="control">' + safeText(_('Control')) + '</button>' +
				'<button type="button" class="sbox-tab" data-ctrl-tab="settings">' + safeText(_('Settings')) + '</button>' +
			'</div>' +

				'<div id="sbox-pane-control">' +
					'<div class="sbox-row">' +
						'<span id="sbox-status" class="sbox-status ' + (appState.serviceRunning ? 'sbox-status-on' : 'sbox-status-off') + '">' +
							'<span class="sbox-dot ' + (appState.serviceRunning ? 'sbox-dot-on' : 'sbox-dot-off') + '"></span>' +
							'<span id="sbox-status-label">' + safeText(appState.serviceRunning ? _('Service running') : _('Service stopped')) + '</span>' +
						'</span>' +
						'<button id="sbox-start" type="button" class="cbi-button cbi-button-positive sbox-btn-start sbox-service-button"' +
							(appState.serviceRunning ? ' style="display:none"' : '') +
						'>' + safeText(_('Start')) + '</button>' +
						'<button id="sbox-stop" type="button" class="cbi-button cbi-button-negative sbox-btn-stop sbox-service-button"' +
							(appState.serviceRunning ? '' : ' style="display:none"') +
						'>' + safeText(_('Stop')) + '</button>' +
						'<button id="sbox-restart" type="button" class="cbi-button cbi-button-apply sbox-btn-restart"' +
							(appState.serviceRunning ? '' : ' style="display:none"') +
						'>' + safeText(_('Restart')) + '</button>' +
					'</div>' +
				'</div>' +

			'<div id="sbox-pane-settings" style="display:none"></div>' +
		'</div>' +

		'<div class="sbox-card">' +
			'<div class="sbox-card-tabs">' +
				'<button type="button" class="sbox-tab sbox-tab-active" data-cfg-tab="config">' + safeText(_('Config')) + '</button>' +
				'<button type="button" class="sbox-tab" data-cfg-tab="logs">' + safeText(_('Logs')) + '</button>' +
			'</div>' +

				'<div id="sbox-pane-config">' +
					'<div class="sbox-config-toolbar">' +
						'<select id="sbox-config-select" class="cbi-input-select sbox-select">' + buildConfigOptionsHtml() + '</select>' +
						'<input id="sbox-subscription-url" class="cbi-input-text sbox-input" type="text" placeholder="https://..." value="' + safeText(appState.subscriptionUrl || '') + '" />' +
						'<button id="sbox-save-update-sub" type="button" class="cbi-button cbi-button-positive sbox-save-update-sub">' + safeText(_('Save URL / Update Config')) + '</button>' +
					'</div>' +
				'<div id="miclash-editor" class="sbox-editor"></div>' +
				'<div class="sbox-actions">' +
						'<button id="sbox-validate" type="button" class="cbi-button cbi-button-apply">' + safeText(_('Validate YAML')) + '</button>' +
						'<button id="sbox-save" type="button" class="cbi-button cbi-button-positive">' + safeText(_('Save')) + '</button>' +
						'<button id="sbox-clear-editor" type="button" class="cbi-button cbi-button-negative">' + safeText(_('Clear Editor')) + '</button>' +
						'<button id="sbox-set-main-config" type="button" class="cbi-button cbi-button-apply sbox-action-right"' +
							(appState.selectedConfigName === MAIN_CONFIG_NAME ? ' style="display:none"' : '') +
						'>' + safeText(_('Set as Main')) + '</button>' +
					'</div>' +
					'<div class="sbox-config-footer">' +
						'<button id="sbox-open-rulesets" type="button" class="cbi-button cbi-button-neutral">' + safeText(_('Rulesets')) + '</button>' +
					'</div>' +
				'</div>' +

			'<div id="sbox-pane-logs" style="display:none">' +
				'<div class="sbox-log-toolbar">' +
					'<button id="sbox-log-refresh" type="button" class="cbi-button cbi-button-apply">' + safeText(_('Refresh')) + '</button>' +
					'<span id="sbox-log-updated" class="sbox-log-updated"></span>' +
				'</div>' +
				'<pre id="sbox-log-content" class="sbox-log-content"></pre>' +
			'</div>' +
		'</div>';
}

function updateHeaderAndControlDom() {
	if (!pageRoot) return;

	const status = pageRoot.querySelector('#sbox-status');
	const statusLabel = pageRoot.querySelector('#sbox-status-label');
	const dot = pageRoot.querySelector('#sbox-status .sbox-dot');
	const startBtn = pageRoot.querySelector('#sbox-start');
	const stopBtn = pageRoot.querySelector('#sbox-stop');
	const restartBtn = pageRoot.querySelector('#sbox-restart');
	const dashboardBtn = pageRoot.querySelector('#sbox-dashboard');
	const appVersion = pageRoot.querySelector('#sbox-app-version');
	const appAction = pageRoot.querySelector('#sbox-app-action');
	const kernelVersion = pageRoot.querySelector('#sbox-kernel-version');
	const kernelAction = pageRoot.querySelector('#sbox-kernel-action');
	const modeSelect = pageRoot.querySelector('#sbox-mode-select');
	const serviceBusy = !!appState.serviceActionBusy;

	if (status && statusLabel && dot) {
		status.classList.toggle('sbox-status-on', appState.serviceRunning);
		status.classList.toggle('sbox-status-off', !appState.serviceRunning);
		dot.classList.toggle('sbox-dot-on', appState.serviceRunning);
		dot.classList.toggle('sbox-dot-off', !appState.serviceRunning);
		statusLabel.textContent = appState.serviceRunning ? _('Service running') : _('Service stopped');
	}

	if (startBtn) {
		if (!serviceBusy) startBtn.style.display = appState.serviceRunning ? 'none' : '';
		startBtn.disabled = serviceBusy || appState.serviceRunning;
	}

	if (stopBtn) {
		if (!serviceBusy) stopBtn.style.display = appState.serviceRunning ? '' : 'none';
		stopBtn.disabled = serviceBusy || !appState.serviceRunning;
	}

	if (restartBtn) {
		if (!serviceBusy) restartBtn.style.display = appState.serviceRunning ? '' : 'none';
		restartBtn.disabled = serviceBusy || !appState.serviceRunning;
	}

	if (dashboardBtn) {
		dashboardBtn.disabled = serviceBusy || !appState.serviceRunning;
		dashboardBtn.className = 'cbi-button sbox-header-button sbox-btn-dashboard ' +
			(appState.serviceRunning ? 'sbox-btn-dashboard-on' : 'sbox-btn-dashboard-off');
	}

	if (appVersion) appVersion.textContent = appState.versions.app || _('unknown');
	if (appAction && !appAction.classList.contains('sbox-version-action-busy')) {
		const appActionState = resolveAppActionState();
		appAction.classList.remove('sbox-version-action-install', 'sbox-version-action-reinstall');
		appAction.classList.add(appActionState.className);
		appAction.textContent = appActionState.icon;
		appAction.title = appActionState.title;
		appAction.setAttribute('aria-label', appActionState.title);
	}
	if (kernelVersion) {
		kernelVersion.textContent = appState.kernelStatus && appState.kernelStatus.installed
			? (appState.kernelStatus.version || appState.versions.clash || _('Installed'))
			: _('Not installed');
	}
	if (kernelAction && !kernelAction.classList.contains('sbox-version-action-busy')) {
		const kernelActionState = resolveKernelActionState();
		kernelAction.classList.remove('sbox-version-action-install', 'sbox-version-action-reinstall');
		kernelAction.classList.add(kernelActionState.className);
		kernelAction.textContent = kernelActionState.icon;
		kernelAction.title = kernelActionState.title;
		kernelAction.setAttribute('aria-label', kernelActionState.title);
	}
	if (modeSelect) modeSelect.value = normalizeProxyMode(appState.proxyMode);

	const guardPill = pageRoot.querySelector('#sbox-guard');
	const guardState = pageRoot.querySelector('#sbox-guard-state');
	const guardEnabled = isInternetOnlyEnabled();
	if (guardPill) {
		guardPill.classList.toggle('sbox-guard-on', guardEnabled);
		guardPill.classList.toggle('sbox-guard-off', !guardEnabled);
		const guardDot = guardPill.querySelector('.sbox-guard-dot');
		if (guardDot) {
			guardDot.classList.toggle('sbox-dot-on', guardEnabled);
			guardDot.classList.toggle('sbox-dot-off', !guardEnabled);
		}
	}
	if (guardState) guardState.textContent = guardEnabled ? _('ON') : _('OFF');
}

function isInternetOnlyEnabled() {
	return view_miclash_guard.isInternetOnlyEnabled(appState.settings);
}

function assertNetworkUpdateAllowed() {
	view_miclash_guard.assertNetworkUpdateAllowed(appState.settings, appState.serviceRunning);
}

function isNetworkUpdateBlocked() {
	return view_miclash_guard.isNetworkUpdateBlocked(appState.settings, appState.serviceRunning);
}

async function refreshHeaderAndControl() {
	const [running, versions, kernelStatus, proxyMode] = await Promise.all([
		getServiceStatus(),
		getVersions(),
		getMihomoStatus(),
		detectCurrentProxyMode()
	]);

	appState.serviceRunning = !!running;
	appState.versions = versions;
	appState.kernelStatus = kernelStatus;
	appState.proxyMode = proxyMode || 'tproxy';

	updateHeaderAndControlDom();
}

async function refreshHeaderAndControlSafe() {
	try {
		await refreshHeaderAndControl();
	} catch (e) {
		try {
			appState.serviceRunning = await getServiceStatus();
		} catch (statusError) {}
		updateHeaderAndControlDom();
	}
}

function renderSettingsPane() {
	if (!pageRoot) return;
	const pane = pageRoot.querySelector('#sbox-pane-settings');
	if (!pane) return;

	pane.innerHTML = buildSettingsPaneHtml();
	bindSettingsPaneEvents();
}

async function collectSettingsFormState() {
	const pane = pageRoot.querySelector('#sbox-pane-settings');
	if (!pane) return null;

	const mode = pane.querySelector('input[name="sbox-interface-mode"]:checked')?.value || 'exclude';
	const proxyMode = normalizeProxyMode(appState.proxyMode || 'tproxy');
	const tunStack = pane.querySelector('#sbox-tun-stack')?.value || 'system';
	const autoDetectLan = !!pane.querySelector('#sbox-auto-lan')?.checked;
	const autoDetectWan = !!pane.querySelector('#sbox-auto-wan')?.checked;
	const blockQuic = !!pane.querySelector('#sbox-block-quic')?.checked;
	const internetOnlyMiclash = !!pane.querySelector('#sbox-internet-only-miclash')?.checked;
	const useTmpfsRules = !!pane.querySelector('#sbox-tmpfs')?.checked;
	const autoHideNotificationsEl = pane.querySelector('#sbox-auto-hide-notifications');
	const autoHideNotifications = autoHideNotificationsEl ? !!autoHideNotificationsEl.checked : true;
	const releaseChannel = normalizeReleaseChannel(pane.querySelector('#sbox-release-channel')?.value || 'release');
	const enableHwid = !!pane.querySelector('#sbox-enable-hwid')?.checked;
	const hwidUserAgent = String(pane.querySelector('#sbox-hwid-user-agent')?.value || 'MiClash').trim() || 'MiClash';
	const hwidDeviceOS = String(pane.querySelector('#sbox-hwid-device-os')?.value || 'OpenWrt').trim() || 'OpenWrt';

	const selected = [];
	pane.querySelectorAll('.sbox-interface-check:checked').forEach((cb) => {
		selected.push(cb.value);
	});

	return {
		mode,
		proxyMode,
		tunStack,
		autoDetectLan,
		autoDetectWan,
		blockQuic,
		internetOnlyMiclash,
		useTmpfsRules,
		autoHideNotifications,
		releaseChannel,
		selected,
		enableHwid,
		hwidUserAgent,
		hwidDeviceOS
	};
}

function bindSettingsPaneEvents() {
	const pane = pageRoot.querySelector('#sbox-pane-settings');
	if (!pane) return;

	pane.querySelectorAll('input[name="sbox-interface-mode"]').forEach((radio) => {
		radio.addEventListener('change', async function() {
			appState.settings.mode = this.value;
			appState.selectedInterfaces = await loadInterfacesByMode(this.value);
			renderSettingsPane();
		});
	});

	const saveBtn = pane.querySelector('#sbox-settings-save');
	if (saveBtn) {
		saveBtn.addEventListener('click', () => withButtons(saveBtn, async () => {
			const formState = await collectSettingsFormState();
			if (!formState) return;
			const previousReleaseChannel = normalizeReleaseChannel(appState.settings && appState.settings.releaseChannel);

			const ok = await saveOperationalSettings(
				formState.mode,
				formState.proxyMode,
				formState.tunStack,
				formState.autoDetectLan,
				formState.autoDetectWan,
				formState.blockQuic,
				formState.internetOnlyMiclash,
				formState.useTmpfsRules,
				formState.selected,
				formState.enableHwid,
				formState.hwidUserAgent,
				formState.hwidDeviceOS,
				formState.autoHideNotifications,
				formState.releaseChannel,
				{ silent: true }
			);

				if (!ok) return;
				try {
					if (!(await restartOrReloadService('restart'))) {
						throw new Error(_('Service did not enter running state in time.'));
					}
					notify('info', _('Settings saved and Clash service restarted.'));
				} catch (e) {
					notify('error', _('Settings saved, but failed to restart Clash service: %s').format(e.message));
				}

				appState.settings = await loadOperationalSettings();
				appState.selectedInterfaces = await loadInterfacesByMode(appState.settings.mode);
				appState.detectedLan = appState.settings.detectedLan || (await detectLanBridge()) || '';
				appState.detectedWan = appState.settings.detectedWan || (await detectWanInterface()) || '';
				appState.proxyMode = appState.settings.proxyMode || await detectCurrentProxyMode();
				appState.serviceRunning = await getServiceStatus();
				const releaseChannelChanged = normalizeReleaseChannel(appState.settings.releaseChannel) !== previousReleaseChannel;

				const freshConfig = await L.resolveDefault(
					fs.read(getConfigPathByName(appState.selectedConfigName)),
					''
				);
				appState.configContent = freshConfig;
				if (editor) {
					editor.setValue(String(freshConfig || ''), -1);
					editor.clearSelection();
				}

				await refreshHeaderAndControl();
				if (releaseChannelChanged) {
					await refreshReleaseMeta({ force: true });
				}
				renderSettingsPane();
				updateHeaderAndControlDom();
			}).catch((e) => {
				notify('error', _('Failed to save settings: %s').format(e.message));
			}));
	}
}

async function refreshLogs() {
	const raw = await loadClashLogs();
	appState.logsRaw = raw;
	appState.logsUpdatedAt = Date.now();

	const content = pageRoot && pageRoot.querySelector('#sbox-log-content');
	const updated = pageRoot && pageRoot.querySelector('#sbox-log-updated');

	if (content) content.innerHTML = colorizeLog(raw);
	if (updated) {
		const text = appState.logsUpdatedAt
			? new Date(appState.logsUpdatedAt).toLocaleString()
			: '-';
		updated.textContent = _('Updated: %s').format(text);
	}
}

function startLogPolling() {
	logPollTimer = view_miclash_ui_shell.startInterval(logPollTimer, () => {
		if (appState.activeCfgTab === 'logs') refreshLogs().catch(() => {});
	}, LOG_POLL_MS);
}

function stopLogPolling() {
	logPollTimer = view_miclash_ui_shell.stopInterval(logPollTimer);
}

function startControlPolling() {
	controlPollTimer = view_miclash_ui_shell.startInterval(controlPollTimer, async () => {
		try {
			appState.serviceRunning = await getServiceStatus();
			updateHeaderAndControlDom();
		} catch (e) {}
	}, STATUS_POLL_MS, { replace: true });
}

function startUpdatePolling() {
	updatePollTimer = view_miclash_ui_shell.startInterval(updatePollTimer, () => {
		if (document.hidden) return;
		refreshReleaseMeta({ force: false }).catch(() => {});
	}, UPDATE_CHECK_MS, { replace: true });
}

function bindControlAndHeaderEvents() {
	const kernelAction = pageRoot.querySelector('#sbox-kernel-action');
	const appAction = pageRoot.querySelector('#sbox-app-action');
	if (appAction) {
		const runAppAction = () => {
			if (appAction.classList.contains('sbox-version-action-busy')) return;
			const appActionKind = resolveAppActionState().kind;

			appAction.classList.add('sbox-version-action-busy');
			appAction.innerHTML = '<span class="sbox-spinner"></span>';

			installMiClashFromSettings(appActionKind).catch((e) => {
				notify('error', _('Failed to update MiClash: %s').format(e.message));
			}).finally(async () => {
				if (appAction && appAction.isConnected) {
					appAction.classList.remove('sbox-version-action-busy');
					try {
						await refreshHeaderAndControl();
					} catch (refreshError) {}
					updateHeaderAndControlDom();
				}
			});
		};

		appAction.addEventListener('click', runAppAction);
		appAction.addEventListener('keydown', (ev) => {
			if (ev.key === 'Enter' || ev.key === ' ') {
				ev.preventDefault();
				runAppAction();
			}
		});
	}

	if (kernelAction) {
		const runKernelAction = () => {
			if (kernelAction.classList.contains('sbox-version-action-busy')) return;

			kernelAction.classList.add('sbox-version-action-busy');
			kernelAction.innerHTML = '<span class="sbox-spinner"></span>';

			installKernelFromSettings().then(() => {
				renderSettingsPane();
			}).catch((e) => {
				notify('error', _('Failed to load kernel information: %s').format(e.message));
			}).finally(() => {
				if (kernelAction && kernelAction.isConnected) {
					kernelAction.classList.remove('sbox-version-action-busy');
					updateHeaderAndControlDom();
				}
			});
		};

		kernelAction.addEventListener('click', runKernelAction);
		kernelAction.addEventListener('keydown', (ev) => {
			if (ev.key === 'Enter' || ev.key === ' ') {
				ev.preventDefault();
				runKernelAction();
			}
		});
	}

	const modeSelect = pageRoot.querySelector('#sbox-mode-select');
	if (modeSelect) {
		modeSelect.addEventListener('change', async function() {
			const select = this;
			const previousMode = normalizeProxyMode(appState.proxyMode);
			const nextMode = normalizeProxyMode(select.value);
			if (nextMode === previousMode) return;

			select.disabled = true;
			try {
				await switchProxyModeFromHeader(nextMode);
			} catch (e) {
				appState.proxyMode = previousMode;
				updateHeaderAndControlDom();
				notify('error', _('Failed to switch proxy mode: %s').format(e.message));
			} finally {
				if (select && select.isConnected) select.disabled = false;
			}
		});
	}

	const startBtn = pageRoot.querySelector('#sbox-start');
	const stopBtn = pageRoot.querySelector('#sbox-stop');
	if (startBtn) {
		startBtn.addEventListener('click', async () => {
			try {
				await withServiceButtons(startBtn, stopBtn, async () => {
					await ensureMihomoKernelInstalled();
					if (!(await view_miclash_service.dispatchActionsAndWait(['enable', 'start'], true))) {
						throw new Error(_('Service did not enter running state in time.'));
					}
				});
				await refreshHeaderAndControlSafe();
			} catch (e) {
				await refreshHeaderAndControlSafe();
				notify('error', _('Unable to start service: %s').format(e.message));
			}
		});
	}

	if (stopBtn) {
		stopBtn.addEventListener('click', async () => {
			try {
				await withServiceButtons(stopBtn, startBtn, async () => {
					if (!(await view_miclash_service.dispatchActionsAndWait(['stop', 'disable'], false))) {
						throw new Error(_('Service did not stop in time.'));
					}
				});
				await refreshHeaderAndControlSafe();
			} catch (e) {
				await refreshHeaderAndControlSafe();
				notify('error', _('Unable to stop service: %s').format(e.message));
			}
		});
	}

	const restartBtn = pageRoot.querySelector('#sbox-restart');
	if (restartBtn) {
		restartBtn.addEventListener('click', () => withButtons(restartBtn, async () => {
			if (!(await restartOrReloadService('restart'))) {
				throw new Error(_('Service did not enter running state in time.'));
			}
			notify('info', _('Clash service restarted successfully.'));
			await refreshHeaderAndControl();
		}).catch((e) => {
			notify('error', _('Failed to restart Clash service: %s').format(e.message));
		}));
	}

	const dashboardBtn = pageRoot.querySelector('#sbox-dashboard');
	if (dashboardBtn) {
		dashboardBtn.addEventListener('click', () => {
			if (dashboardBtn.disabled) return;
			openDashboard().catch((e) => {
			notify('error', _('Failed to open dashboard: %s').format(e.message));
			});
		});
	}
}

async function switchConfigProfile(profileName) {
	const selected = normalizeConfigProfileName(profileName);
	const [content, url] = await Promise.all([
		readConfigFileByName(selected),
		readSubscriptionUrl(selected)
	]);

	appState.selectedConfigName = selected;
	appState.configContent = String(content || '');
	appState.subscriptionUrl = String(url || '');

	if (editor) {
		editor.setValue(appState.configContent, -1);
		editor.clearSelection();
	}

	if (pageRoot) {
		const selectEl = pageRoot.querySelector('#sbox-config-select');
		const urlEl = pageRoot.querySelector('#sbox-subscription-url');
		const setMainBtn = pageRoot.querySelector('#sbox-set-main-config');
		if (selectEl) selectEl.value = selected;
		if (urlEl) urlEl.value = appState.subscriptionUrl;
		if (setMainBtn) setMainBtn.style.display = selected === MAIN_CONFIG_NAME ? 'none' : '';
	}
}

async function setSelectedConfigAsMain() {
	const selected = normalizeConfigProfileName(appState.selectedConfigName);
	if (selected === MAIN_CONFIG_NAME) return;

	const [mainContent, selectedContent, mainUrl, selectedUrl] = await Promise.all([
		readConfigFileByName(MAIN_CONFIG_NAME),
		readConfigFileByName(selected),
		readSubscriptionUrl(MAIN_CONFIG_NAME),
		readSubscriptionUrl(selected)
	]);

	await writeConfigFileByName(MAIN_CONFIG_NAME, selectedContent);
	await writeConfigFileByName(selected, mainContent);
	await saveSubscriptionUrl(selectedUrl, MAIN_CONFIG_NAME);
	await saveSubscriptionUrl(mainUrl, selected);

	if (!(await restartOrReloadService('restart'))) {
		throw new Error(_('Service did not enter running state in time.'));
	}
	appState.serviceRunning = await getServiceStatus();
	await switchConfigProfile(MAIN_CONFIG_NAME);
	await refreshHeaderAndControl();

	notify('info', _('%s is now main config.').format(_(getConfigLabel(selected))));
}

function bindConfigEvents() {
	const subInput = pageRoot.querySelector('#sbox-subscription-url');
	const configSelect = pageRoot.querySelector('#sbox-config-select');
	const setMainBtn = pageRoot.querySelector('#sbox-set-main-config');

	if (configSelect) {
		configSelect.addEventListener('change', async function() {
			const nextConfig = normalizeConfigProfileName(this.value);
			this.disabled = true;
			try {
				await switchConfigProfile(nextConfig);
			} catch (e) {
				notify('error', _('Failed to load config profile: %s').format(e.message));
			} finally {
				if (this.isConnected) this.disabled = false;
			}
		});
	}

	if (setMainBtn) {
		setMainBtn.addEventListener('click', () => withButtons(setMainBtn, async () => {
			const selected = normalizeConfigProfileName(appState.selectedConfigName);
			if (selected === MAIN_CONFIG_NAME) return;

			showModal({
				title: _('Set as Main'),
				body: _('Selected config will be swapped with Main config, saved, and Clash will restart. Continue?'),
				buttons: [
					{
						label: _('Set as Main'),
						className: 'cbi-button cbi-button-apply',
						onClick: async function(ctx) {
							await setSelectedConfigAsMain();
							ctx.closeModal();
						}
					},
					{
						label: _('Cancel'),
						className: 'cbi-button cbi-button-neutral'
					}
				]
			});
		}).catch((e) => {
			notify('error', _('Failed to set main config: %s').format(e.message));
		}));
	}

	const saveUpdateBtn = pageRoot.querySelector('#sbox-save-update-sub');
	if (saveUpdateBtn) {
		saveUpdateBtn.addEventListener('click', () => withButtons(saveUpdateBtn, async () => {
				const url = String(subInput?.value || '').trim();
				if (!url) throw new Error(_('Subscription URL is empty.'));
				if (!isValidUrl(url)) throw new Error(_('Invalid subscription URL.'));

				const selectedConfig = normalizeConfigProfileName(appState.selectedConfigName);
				const selectedPath = getConfigPathByName(selectedConfig);
				await saveSubscriptionUrl(url, selectedConfig);
				appState.subscriptionUrl = url;
				appState.serviceRunning = await getServiceStatus();
				updateHeaderAndControlDom();

				if (isNetworkUpdateBlocked()) {
					notify('warning', _('Subscription URL saved. Download skipped because "Internet only through MiClash" is enabled while the service is stopped.'));
					return;
				}

				await ensureMihomoKernelInstalled();

				const downloadedInfo = await fetchSubscriptionAsYaml(url, selectedPath);
				const currentSettings = appState.settings || await loadOperationalSettings();
				const downloaded = transformProxyMode(
					String(downloadedInfo.content || '').trimEnd() + '\n',
					normalizeProxyMode(appState.proxyMode || currentSettings.proxyMode || 'tproxy'),
					currentSettings.tunStack || 'system'
				);

				const tested = await testConfigContent(downloaded, true, selectedPath);
				if (!tested.ok) throw new Error(_('YAML validation failed: %s').format(tested.message));

				appState.configContent = downloaded;
				if (editor) {
					editor.setValue(downloaded, -1);
					editor.clearSelection();
				}

				let serviceReloaded = false;
				if (selectedConfig === MAIN_CONFIG_NAME) {
					if (await getServiceStatus()) {
						if (!(await restartOrReloadService('reload'))) {
							throw new Error(_('Service did not enter running state in time.'));
						}
						serviceReloaded = true;
					}
					appState.serviceRunning = await getServiceStatus();
					updateHeaderAndControlDom();
				}

				if (downloadedInfo.mode === 'remnawave-client-path' && serviceReloaded) {
					notify('info', _('Subscription downloaded and applied (Remnawave /mihomo fallback).'));
				} else if (serviceReloaded) {
					notify('info', _('Subscription downloaded and applied.'));
				} else {
					notify('info', _('%s downloaded and saved.').format(_(getConfigLabel(selectedConfig))));
				}
			}).catch((e) => {
				notify('error', _('Failed to apply subscription: %s').format(e.message));
			}).finally(async () => {
				await view_miclash_subscription.cleanupTemp();
			})
		);
	}

	const validateBtn = pageRoot.querySelector('#sbox-validate');
	if (validateBtn) {
		validateBtn.addEventListener('click', () => withButtons(validateBtn, async () => {
			if (!editor) return;
			const tested = await testConfigContent(
				editor.getValue(),
				false,
				getConfigPathByName(appState.selectedConfigName)
			);
			if (!tested.ok) {
				notifyDetailedError(_('YAML validation failed.'), tested.message);
				return;
			}
			notify('info', _('YAML validation passed.'));
		}).catch((e) => {
			notify('error', _('YAML validation failed: %s').format(e.message));
		}));
	}

	const saveBtn = pageRoot.querySelector('#sbox-save');
	if (saveBtn) {
		saveBtn.addEventListener('click', () => withButtons(saveBtn, async () => {
			if (!editor) return;
			const selectedConfig = normalizeConfigProfileName(appState.selectedConfigName);
			const selectedPath = getConfigPathByName(selectedConfig);
			const tested = await testConfigContent(editor.getValue(), true, selectedPath);
			if (!tested.ok) {
				notifyDetailedError(
					_('Configuration test failed Р Р†Р вЂљРІР‚Сњ service not reloaded. Please fix the errors below:'),
					tested.message
				);
				return;
			}
			appState.configContent = editor.getValue();

			if (selectedConfig === MAIN_CONFIG_NAME) {
				const wasRunning = await getServiceStatus();
				if (wasRunning) {
					if (!(await restartOrReloadService('reload'))) {
						throw new Error(_('Service did not enter running state in time.'));
					}
				}
				appState.serviceRunning = await getServiceStatus();
				updateHeaderAndControlDom();
				notify('info', wasRunning ? _('Configuration applied and service reloaded.') : _('%s saved.').format(_(getConfigLabel(selectedConfig))));
			} else {
				notify('info', _('%s saved.').format(_(getConfigLabel(selectedConfig))));
			}
		}).catch((e) => {
			notify('error', _('Failed to apply configuration: %s').format(e.message));
		}));
	}

	const clearBtn = pageRoot.querySelector('#sbox-clear-editor');
	if (clearBtn) {
		clearBtn.addEventListener('click', () => {
			showModal({
				title: _('Clear editor?'),
				body: _('This will clear only editor content. File is not modified until you click Save.'),
				buttons: [
					{
						label: _('Clear'),
						className: 'cbi-button cbi-button-negative',
						onClick: async function(ctx) {
							if (editor) {
								editor.setValue('', -1);
								editor.clearSelection();
							}
							ctx.closeModal();
						}
					},
					{
						label: _('Cancel'),
						className: 'cbi-button cbi-button-neutral'
					}
				]
			});
		});
	}

	const rulesetsBtn = pageRoot.querySelector('#sbox-open-rulesets');
	if (rulesetsBtn) {
		rulesetsBtn.addEventListener('click', () => withButtons(rulesetsBtn, async () => {
			await openRulesetsModal();
		}).catch((e) => {
			notify('error', _('Failed to open rulesets: %s').format(e.message));
		}));
	}

	const logRefreshBtn = pageRoot.querySelector('#sbox-log-refresh');
	if (logRefreshBtn) {
		logRefreshBtn.addEventListener('click', () => withButtons(logRefreshBtn, async () => {
			await refreshLogs();
		}).catch((e) => {
			notify('error', _('Failed to refresh logs: %s').format(e.message));
		}));
	}
}

function bindTabEvents() {
	view_miclash_ui_shell.bindTabGroup(pageRoot, {
		tabAttr: 'ctrl-tab',
		initial: appState.activeCtrlTab || 'control',
		panes: {
			control: '#sbox-pane-control',
			settings: '#sbox-pane-settings'
		},
		onChange: (name) => {
			appState.activeCtrlTab = name;
			if (name === 'settings') renderSettingsPane();
		}
	});

	view_miclash_ui_shell.bindTabGroup(pageRoot, {
		tabAttr: 'cfg-tab',
		initial: appState.activeCfgTab || 'config',
		panes: {
			config: '#sbox-pane-config',
			logs: '#sbox-pane-logs'
		},
		onChange: (name) => {
			appState.activeCfgTab = name;
			if (name === 'logs') {
				refreshLogs().catch(() => {});
				startLogPolling();
			} else {
				stopLogPolling();
			}
		}
	});
}

const PAGE_CSS = `
.sbox-page {
	--sbox-bg: transparent;
	--sbox-card: var(--background-color-high, var(--background-color-medium, Canvas));
	--sbox-border: var(--border-color-medium, var(--border-color-low, currentColor));
	--sbox-text: var(--text-color-high, var(--text-color, CanvasText));
	--sbox-muted: var(--text-color-medium, var(--text-color-low, GrayText));
	--sbox-accent: var(--primary-color, var(--link-color, #0069d9));
	--sbox-success: var(--success-color, #198754);
	--sbox-danger: var(--error-color, var(--danger-color, #dc3545));
	--sbox-warn: var(--warning-color, #b7791f);
	--sbox-log-bg: var(--background-color-low, var(--background-color, Canvas));
	--sbox-panel-bg: var(--background-color-medium, transparent);
	--sbox-modal-bg: var(--background-color-high, Canvas);
	--sbox-button-text: var(--button-text-color, #fff);
	color: var(--sbox-text);
}
.sbox-page .main {
	background: var(--sbox-bg);
}
.sbox-header {
	display: flex;
	align-items: center;
	justify-content: center;
	flex-wrap: wrap;
	gap: 8px;
	margin-bottom: 12px;
	font-size: 13px;
	color: var(--sbox-muted);
}
.sbox-header strong {
	color: var(--sbox-text);
	font-weight: 700;
}
.sbox-version-inline {
	display: inline-flex;
	align-items: center;
	gap: 6px;
}
.sbox-version-action-icon {
	display: inline-flex;
	align-items: center;
	justify-content: center;
	width: 16px;
	height: 16px;
	font-size: 14px;
	line-height: 1;
	cursor: pointer;
	user-select: none;
	opacity: 0.95;
	transition: transform 0.16s ease, opacity 0.16s ease;
}
.sbox-version-action-icon:hover,
.sbox-version-action-icon:focus {
	transform: scale(1.08);
	opacity: 1;
	outline: none;
}
.sbox-version-action-install { color: var(--sbox-success); }
.sbox-version-action-reinstall { color: var(--sbox-accent); }
.sbox-version-action-busy {
	pointer-events: none;
}
.sbox-header-dot {
	opacity: 0.55;
}
.sbox-header-button {
	font-size: 11px;
	padding: 2px 8px;
	min-height: 24px;
}
.sbox-btn-validate,
.sbox-btn-restart,
.sbox-btn-dashboard-on {
	background: var(--sbox-accent) !important;
	border-color: var(--sbox-accent) !important;
	color: var(--sbox-button-text) !important;
}
.sbox-btn-start {
	background: var(--sbox-success) !important;
	border-color: var(--sbox-success) !important;
	color: var(--sbox-button-text) !important;
}
.sbox-btn-stop,
.sbox-btn-dashboard-off {
	background: var(--sbox-danger) !important;
	border-color: var(--sbox-danger) !important;
	color: var(--sbox-button-text) !important;
}
.sbox-btn-dashboard:disabled {
	cursor: not-allowed;
	opacity: 0.8;
}
.sbox-card {
	background: var(--sbox-card);
	border: 1px solid var(--sbox-border);
	border-radius: 10px;
	padding: 14px;
	margin-bottom: 10px;
}
.sbox-card-tabs {
	display: flex;
	gap: 2px;
	border-bottom: 1px solid var(--sbox-border);
	margin-bottom: 12px;
}
.sbox-tab {
	appearance: none;
	border: none;
	background: transparent;
	color: var(--sbox-muted);
	text-transform: uppercase;
	letter-spacing: 0.08em;
	font-size: 11px;
	font-weight: 700;
	padding: 6px 10px;
	border-bottom: 2px solid transparent;
	cursor: pointer;
}
.sbox-tab:hover { color: var(--sbox-text); }
.sbox-tab-active {
	color: var(--sbox-text);
	border-bottom-color: var(--sbox-accent);
}
.sbox-row {
	display: flex;
	flex-wrap: wrap;
	align-items: center;
	gap: 8px;
}
.sbox-service-button {
	min-width: 72px;
}
.sbox-status {
	display: inline-flex;
	align-items: center;
	gap: 6px;
	padding: 4px 10px;
	border-radius: 999px;
	border: 1px solid transparent;
	font-size: 12px;
	font-weight: 700;
}
.sbox-status-on {
	border-color: var(--sbox-success);
	color: var(--sbox-success);
}
.sbox-status-off {
	border-color: var(--sbox-danger);
	color: var(--sbox-danger);
}
.sbox-dot {
	width: 8px;
	height: 8px;
	border-radius: 50%;
	flex-shrink: 0;
}
.sbox-dot-on {
	background: var(--sbox-success);
}
.sbox-dot-off {
	background: var(--sbox-danger);
}
.sbox-proxy-mode-inline {
	font-size: 11px;
	color: var(--sbox-muted);
	text-transform: uppercase;
	letter-spacing: 0.06em;
}
.sbox-guard-pill {
	display: inline-flex;
	align-items: center;
	gap: 5px;
	padding: 2px 8px;
	border-radius: 999px;
	border: 1px solid transparent;
	font-size: 11px;
	font-weight: 700;
	text-transform: uppercase;
	letter-spacing: 0.06em;
	cursor: help;
}
.sbox-guard-on {
	border-color: var(--sbox-success);
	color: var(--sbox-success);
}
.sbox-guard-off {
	border-color: var(--sbox-border);
	color: var(--sbox-muted);
}
.sbox-guard-dot {
	width: 7px;
	height: 7px;
	border-radius: 50%;
	flex-shrink: 0;
}
.sbox-guard-label {
	letter-spacing: 0.08em;
}
.sbox-guard-state {
	font-weight: 800;
}
.sbox-mode-select {
	min-width: 96px;
	height: 24px;
	padding: 0 6px;
	font-size: 11px;
	background: var(--sbox-card);
	color: var(--sbox-text);
	border: 1px solid var(--sbox-border);
	border-radius: 6px;
}
.sbox-mode-select:disabled {
	opacity: 0.75;
}
.sbox-config-toolbar {
	display: grid;
	grid-template-columns: minmax(140px, 180px) minmax(220px, 1fr) minmax(240px, auto);
	gap: 8px;
	align-items: center;
	margin-bottom: 10px;
}
.sbox-save-update-sub {
	width: 100%;
	min-height: 32px;
	font-weight: 700;
}
.sbox-select,
.sbox-input {
	width: 100%;
	box-sizing: border-box;
}
.sbox-editor {
	width: 100%;
	height: 560px;
	border: 1px solid var(--sbox-border);
	border-radius: 8px;
}
.sbox-actions {
	display: flex;
	flex-wrap: wrap;
	gap: 8px;
	margin-top: 10px;
}
.sbox-config-footer {
	display: flex;
	justify-content: flex-end;
	gap: 8px;
	flex-wrap: wrap;
	margin-top: 8px;
}
.sbox-muted {
	color: var(--sbox-muted);
	font-size: 12px;
	line-height: 1.5;
}
.sbox-log-toolbar {
	display: flex;
	align-items: center;
	gap: 8px;
	margin-bottom: 8px;
}
.sbox-log-updated {
	margin-left: auto;
	color: var(--sbox-muted);
	font-size: 12px;
}
.sbox-log-content {
	width: 100%;
	height: 520px;
	overflow: auto;
	background: var(--sbox-log-bg);
	border: 1px solid var(--sbox-border);
	border-radius: 8px;
	padding: 10px;
	box-sizing: border-box;
	margin: 0;
	font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
	font-size: 11.5px;
	line-height: 1.45;
	white-space: pre;
}
.sbox-log-info { color: var(--sbox-success); }
.sbox-log-warn { color: var(--sbox-warn); }
.sbox-log-error { color: var(--sbox-danger); }
.sbox-log-muted { color: var(--sbox-muted); }
.sbox-settings-grid {
	display: grid;
	grid-template-columns: repeat(2, minmax(220px, 1fr));
	gap: 10px;
}
.sbox-settings-block {
	border: 1px solid var(--sbox-border);
	border-radius: 8px;
	padding: 10px;
	background: var(--sbox-panel-bg);
}
.sbox-settings-block h4 {
	margin: 0 0 8px;
	font-size: 13px;
	color: var(--sbox-text);
}
.sbox-settings-block-wide {
	grid-column: 1 / -1;
}
.sbox-radio-row,
.sbox-checkbox-row {
	display: flex;
	align-items: flex-start;
	gap: 8px;
	margin: 6px 0;
	font-size: 12px;
}
.sbox-form-grid {
	margin-top: 8px;
	display: grid;
	grid-template-columns: repeat(2, minmax(180px, 1fr));
	gap: 8px;
}
.sbox-form-grid label {
	display: block;
	margin-bottom: 4px;
	font-size: 12px;
	color: var(--sbox-muted);
}
.sbox-interface-group {
	margin-bottom: 8px;
}
.sbox-interface-group-title {
	font-size: 11px;
	text-transform: uppercase;
	letter-spacing: 0.08em;
	color: var(--sbox-muted);
	margin-bottom: 4px;
}
.sbox-interface-grid {
	display: grid;
	grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
	gap: 6px;
}
.sbox-interface-item {
	display: flex;
	align-items: center;
	gap: 8px;
	font-size: 12px;
	border: 1px solid var(--sbox-border);
	border-radius: 6px;
	padding: 5px 8px;
	background: var(--sbox-panel-bg);
}
.sbox-interface-item em {
	color: var(--sbox-success);
	font-style: normal;
	font-size: 11px;
}
.sbox-interface-auto {
	border-color: var(--sbox-success);
}
.sbox-settings-status {
	margin-top: 10px;
	border-left: 3px solid var(--sbox-accent);
	padding: 8px 10px;
	border-radius: 0 6px 6px 0;
	background: var(--sbox-panel-bg);
	font-size: 12px;
	color: var(--sbox-text);
	line-height: 1.5;
}
.sbox-settings-gap {
	height: 12px;
}
.sbox-settings-save-wrap {
	margin-top: 12px;
}
.sbox-settings-save-btn {
	width: 100%;
	min-height: 42px;
	padding-top: 10px;
	padding-bottom: 10px;
}
@keyframes sbox-spin { to { transform: rotate(360deg); } }
.sbox-spinner {
	display: inline-block;
	width: 0.75em;
	height: 0.75em;
	border: 2px solid currentColor;
	border-top-color: transparent;
	border-radius: 50%;
	animation: sbox-spin 0.65s linear infinite;
	vertical-align: -0.1em;
}
.sbox-modal-overlay {
	position: fixed;
	inset: 0;
	background: var(--modal-overlay-background, rgba(0, 0, 0, 0.7));
	z-index: 10000;
	display: flex;
	align-items: center;
	justify-content: center;
}
.sbox-modal {
	width: min(92vw, 420px);
	border: 1px solid var(--sbox-border);
	border-radius: 10px;
	background: var(--sbox-modal-bg);
	color: var(--sbox-text);
	padding: 14px;
	box-shadow: var(--shadow-large, 0 20px 50px rgba(0, 0, 0, 0.45));
}
.sbox-modal-title {
	font-size: 14px;
	font-weight: 700;
	margin-bottom: 8px;
}
.sbox-modal-body {
	color: var(--sbox-muted);
	font-size: 12px;
	line-height: 1.5;
}
.sbox-modal-actions {
	margin-top: 12px;
	display: flex;
	gap: 8px;
	flex-wrap: wrap;
	justify-content: flex-end;
}
.sbox-modal-wide {
	width: min(96vw, 1180px);
	max-height: 92vh;
}
.sbox-modal-wide .sbox-modal-body {
	max-height: calc(92vh - 104px);
	overflow: hidden;
}
.sbox-rulesets-modal-body {
	color: var(--sbox-text);
}
.sbox-rulesets-layout {
	display: grid;
	grid-template-columns: minmax(230px, 280px) minmax(0, 1fr);
	gap: 12px;
}
.sbox-rulesets-sidebar,
.sbox-rulesets-main {
	border: 1px solid var(--sbox-border);
	border-radius: 8px;
	background: var(--sbox-panel-bg);
	padding: 10px;
}
.sbox-rulesets-title {
	font-size: 13px;
	font-weight: 700;
	margin-bottom: 6px;
}
.sbox-rulesets-create-row {
	margin-top: 8px;
	display: grid;
	grid-template-columns: 1fr auto;
	gap: 8px;
}
.sbox-rulesets-list {
	margin-top: 10px;
	display: flex;
	flex-direction: column;
	gap: 6px;
	max-height: 55vh;
	overflow: auto;
}
.sbox-ruleset-list-item {
	width: 100%;
	text-align: left;
	border: 1px solid var(--sbox-border);
	border-radius: 6px;
	background: var(--sbox-panel-bg);
	color: var(--sbox-text);
	padding: 6px 8px;
	cursor: pointer;
	font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
	font-size: 12px;
}
.sbox-ruleset-list-item:hover {
	border-color: var(--sbox-accent);
}
.sbox-ruleset-list-item.active {
	border-color: var(--sbox-accent);
}
.sbox-rulesets-toolbar {
	display: flex;
	align-items: center;
	gap: 8px;
	margin-bottom: 8px;
}
.sbox-ruleset-current {
	font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
	font-size: 12px;
	color: var(--sbox-muted);
}
.sbox-rulesets-toolbar-actions {
	margin-left: auto;
	display: flex;
	gap: 8px;
}
.sbox-ruleset-editor-wrap {
	display: none;
}
.sbox-ruleset-editor {
	height: 48vh;
	min-height: 320px;
	border: 1px solid var(--sbox-border);
	border-radius: 8px;
}
.sbox-rulesets-empty {
	border: 1px dashed var(--sbox-border);
	border-radius: 8px;
	padding: 16px;
	color: var(--sbox-muted);
	font-size: 12px;
}
.sbox-rulesets-example {
	margin-top: 8px;
}
.sbox-rulesets-example pre {
	margin: 0;
	border: 1px solid var(--sbox-border);
	border-radius: 6px;
	padding: 8px;
	background: var(--sbox-log-bg);
	font-size: 11px;
	line-height: 1.45;
	font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
}
.sbox-rulesets-whitelist {
	margin-top: 10px;
	border: 1px solid var(--sbox-success);
	border-radius: 8px;
	padding: 10px;
}
.sbox-rulesets-whitelist-head {
	font-size: 13px;
	font-weight: 700;
	margin-bottom: 4px;
}
.sbox-ruleset-whitelist-editor {
	height: 240px;
	border: 1px solid var(--sbox-border);
	border-radius: 8px;
}
@media (max-width: 980px) {
	.sbox-config-toolbar {
		grid-template-columns: 1fr;
	}
	.sbox-settings-grid {
		grid-template-columns: 1fr;
	}
	.sbox-form-grid {
		grid-template-columns: 1fr;
	}
	.sbox-modal-wide {
		width: min(98vw, 980px);
	}
	.sbox-rulesets-layout {
		grid-template-columns: 1fr;
	}
	.sbox-rulesets-list {
		max-height: 220px;
	}
	.sbox-ruleset-editor {
		height: 42vh;
		min-height: 280px;
	}
}
`;

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	load: function() {
		return Promise.all([
			L.resolveDefault(fs.read(CONFIG_PATH), ''),
			readSubscriptionUrl(),
			loadOperationalSettings(),
			getNetworkInterfaces(),
			getVersions(),
			getMihomoStatus(),
			getServiceStatus(),
			detectCurrentProxyMode()
		]);
	},

	render: async function(data) {
		const routeSection = view_miclash_route.getSection();
		await ensureConfigProfilesReady(data[0] || '');
		appState.configProfiles = CONFIG_PROFILES.slice();
		appState.selectedConfigName = MAIN_CONFIG_NAME;
		appState.configContent = await readConfigFileByName(MAIN_CONFIG_NAME);
		appState.subscriptionUrl = await readSubscriptionUrl(MAIN_CONFIG_NAME);
		appState.settings = data[2] || await loadOperationalSettings();
		appState.interfaces = data[3] || [];
		appState.versions = data[4] || { app: 'unknown', clash: 'unknown' };
		appState.kernelStatus = data[5] || { installed: false, version: null };
		appState.serviceRunning = !!data[6];
		appState.proxyMode = data[7] || 'tproxy';
		view_miclash_route.applySection(appState, routeSection);

		appState.selectedInterfaces = await loadInterfacesByMode(appState.settings.mode || 'exclude');
		appState.detectedLan = appState.settings.detectedLan || (await detectLanBridge()) || '';
		appState.detectedWan = appState.settings.detectedWan || (await detectWanInterface()) || '';

		pageRoot = E('div', { 'class': 'sbox-page' }, [
			E('style', {}, PAGE_CSS),
			E('div', { 'id': 'sbox-root' })
		]);

		pageRoot.querySelector('#sbox-root').innerHTML = buildPageHtml();

		try {
			await initializeAceEditor(appState.configContent);
		} catch (e) {
			notify('error', _('Failed to initialize editor: %s').format(e.message));
		}

		bindControlAndHeaderEvents();
		bindConfigEvents();
		bindTabEvents();
		renderSettingsPane();
		updateHeaderAndControlDom();
		refreshReleaseMeta({ force: true }).catch(() => {});

		startControlPolling();
		startUpdatePolling();

		if (routeSection === 'rulesets') {
			setTimeout(() => {
				openRulesetsModal().catch((e) => {
					notify('error', _('Failed to open rulesets: %s').format(e.message));
				});
			}, 0);
		}

		document.addEventListener('visibilitychange', () => {
			if (document.hidden) {
				stopLogPolling();
			} else if (appState.activeCfgTab === 'logs') {
				refreshLogs().catch(() => {});
				startLogPolling();
			}
			if (!document.hidden) {
				refreshReleaseMeta({ force: false }).catch(() => {});
			}
		});

		return pageRoot;
	}
});
