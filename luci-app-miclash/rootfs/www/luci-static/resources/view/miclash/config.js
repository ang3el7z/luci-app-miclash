'use strict';
'require view';
'require ui';
'require view.miclash.utils';
'require view.miclash.store';
'require view.miclash.release';
'require view.miclash.package';
'require view.miclash.logs';
'require view.miclash.settings-model';
'require view.miclash.rulesets-model';
'require view.miclash.ui-shell';
'require view.miclash.subscription';
'require view.miclash.editor';
'require view.miclash.api';
'require view.miclash.diagnostics-panel';
'require view.miclash.settings-panels';
'require view.miclash.devices-panel';
'require view.miclash.notification-poller';
'require view.miclash.performance';
'require view.miclash.performance-panel';

const CONFIG_PATH = view_miclash_store.CONFIG_PATH;
const MAIN_CONFIG_NAME = view_miclash_store.MAIN_CONFIG_NAME;
const CONFIG_PROFILES = view_miclash_store.CONFIG_PROFILES;
const selectActiveOperation = view_miclash_store.selectActiveOperation;
const RULESET_PATH = view_miclash_rulesets_model.RULESET_PATH;
const FAKEIP_WHITELIST_FILENAME = view_miclash_rulesets_model.FAKEIP_WHITELIST_FILENAME;
const UPDATE_CHECK_MS = 10 * 60 * 1000;
const LOG_POLL_MS = 5000;
const STATUS_POLL_MS = 5000;
const UPDATE_JOB_POLL_MS = 1000;
const UPDATE_JOB_TIMEOUT_MS = 7 * 60 * 1000;
const SERVICE_JOB_POLL_MS = 1000;
const SERVICE_JOB_TIMEOUT_MS = 3 * 60 * 1000;
const OPERATION_TOKEN_STORAGE_PREFIX = 'miclash-operation-token-';
const AUTO_UPDATE_PRESET_INTERVAL_HOURS = ['2', '4', '12', '24'];
const DEVELOPER_TAP_COUNT = 7;
const DEVELOPER_TAP_HINT_COUNT = 5;
const DEVELOPER_TAP_WINDOW_MS = 5000;
const DEVELOPER_SESSION_MS = 10 * 60 * 1000;

let editor = null;
let pageRoot = null;
let controlPollTimer = null;
let logPollTimer = null;
let updatePollTimer = null;
let operationAutoClearTimer = null;
let controlPollBusy = false;
let rulesetMainEditor = null;
let rulesetWhitelistEditor = null;
let configApi = null;
let visibilityChangeHandler = null;
let subscriptionUpdateBusy = false;
let logsLoaded = false;
let logsRefreshPromise = null;
let logSearch = createLogSearchState();
let pageGeneration = 0;
let sessionExpired = false;
let cfgTabSetter = null;
let developerVisible = false;
let developerTapTimes = [];
let developerExpiryTimer = null;
let releaseRefreshPromise = null;
const performanceOwner = view_miclash_performance_panel.create();
const diagnosticsOwner = view_miclash_diagnostics_panel.createOwner({
	createClient: () => view_miclash_api.create(),
	createPanel: (options) => view_miclash_diagnostics_panel.create(options)
});
const notificationOwner = (() => {
	let poller = null, generation = 0;
	function destroy() {
		generation++;
		if (!poller) return false;
		const owned = poller; poller = null;
		owned.destroy();
		return true;
	}
	function replace() {
		destroy();
		const token = ++generation;
		const api = view_miclash_api.create();
		poller = view_miclash_notification_poller.create({
			api,
			onEvent: (event) => {
				if (token !== generation) return;
				const severity = String(event?.severity || 'info');
				const kind = /^(?:warning|error|critical)$/.test(severity) ? 'error' : 'info';
				notify(kind, [ event?.title, event?.message ].filter(Boolean).join(': '), event?.type);
			},
			onError: () => {}
		});
		api.notificationSettings().then((settings) => {
			if (token === generation) applyNotificationSettings(settings);
		}).catch(() => {});
		poller.start();
		return poller;
	}
	return { replace, destroy };
})();
const managementOwner = (() => {
	let panels = null;
	function destroy() {
		if (!panels) return false;
		const owned = panels; panels = null;
		for (const panel of owned) panel.destroy();
		return true;
	}
	function replace() {
		destroy();
		const factories = [ view_miclash_settings_panels, view_miclash_devices_panel ];
		const created = [];
		try {
			for (const factory of factories) created.push(factory.create({
				api: view_miclash_api.create(),
				onError: (error, context) => {
					if (!context?.background) setOperationError(error);
					notify('error', error?.message || error);
				},
				onNotificationSettings: (settings) => {
					applyNotificationSettings(settings);
				},
				onProgress: (message, operation) => setOperationStatus('running', message, {
					detail: operation?.stage || '', context: 'management'
				}),
				onSuccess: (message) => {
					setOperationSuccess(message);
					notify('info', message);
				}
			}));
		} catch (error) {
			for (const panel of created) panel.destroy();
			throw error;
		}
		panels = created;
		return panels;
	}
	function mount(root) {
		if (!panels || !root) return;
		const hosts = [ '#sbox-management-settings', '#sbox-management-devices' ];
		for (let i = 0; i < panels.length; i++) {
			const host = root.querySelector(hosts[i]); if (host) panels[i].mount(host);
		}
	}
	function collectPatch() {
		if (!panels || typeof panels[0]?.collectPatch !== 'function')
			throw new Error(_('Management settings are not ready.'));
		return panels[0].collectPatch();
	}
	async function applyPending() {
		if (!panels || typeof panels[1]?.applyChanges !== 'function')
			throw new Error(_('Device policies are not ready.'));
		return panels[1].applyChanges();
	}
	async function markSaved() {
		if (!panels) return;
		for (const panel of panels)
			if (typeof panel.markSaved === 'function') await panel.markSaved();
	}
	function refresh(force) {
		if (!panels) return Promise.resolve([]);
		return Promise.all(panels.map((panel) =>
			typeof panel.refresh === 'function'
				? Promise.resolve(panel.refresh(force === true)).catch(() => undefined)
				: Promise.resolve(undefined)));
	}
	function setActive(active) {
		if (!panels) return false;
		for (const panel of panels)
			if (typeof panel.setActive === 'function') panel.setActive(active);
		return true;
	}
	return { replace, mount, destroy, collectPatch, applyPending, markSaved, refresh, setActive,
		ready: () => panels != null };
})();
view_miclash_utils.bumpRpcTimeout();

const appState = {
	versions: { app: 'unknown', clash: 'unknown' },
	kernelStatus: { installed: false, version: null },
	serviceStateLoading: true,
	serviceRunning: false,
	serviceHealth: 'unknown',
	serviceState: {},
	guardObservedState: 'loading',
	proxyMode: 'tproxy',
	configContent: '',
	subscriptionUrl: '',
	selectedConfigName: MAIN_CONFIG_NAME,
	configProfiles: CONFIG_PROFILES.slice(),
	settings: null,
	notificationAutoHide: true,
	notificationSettings: { luci_enabled: false, luci_events: [] },
	interfaces: [],
	selectedInterfaces: [],
	detectedLan: '',
	detectedWan: '',
	activeCtrlTab: 'control',
	activeCfgTab: 'config',
	logsRaw: '',
	operationStatus: null,
	releaseMeta: {
		appVersion: '',
		kernelVersion: '',
		checkedAt: 0
	},
	systemMetadataReady: false,
	serviceActionBusy: false,
	serviceJobBusy: false,
	updateJobBusy: false,
	autoUpdateIntervalProbeBusy: false,
	autoUpdateIntervalProbeAttempted: false,
	configReady: false
};

function applyNotificationSettings(settings) {
	const source = settings && typeof settings === 'object' ? settings : {};
	appState.notificationAutoHide = source.auto_hide !== false;
	appState.notificationSettings = {
		luci_enabled: source.luci_enabled === true,
		luci_events: Array.isArray(source.luci_events) ? source.luci_events.slice() : []
	};
}

function isLuciNotificationEnabled(eventType) {
	const settings = appState.notificationSettings || {};
	return settings.luci_enabled === true && Array.isArray(settings.luci_events) &&
		settings.luci_events.includes(String(eventType || 'miclash_event'));
}

function notify(type, message, eventType) {
	if (type === 'error' && view_miclash_api.isSessionExpired(message)) {
		suspendForSessionExpiry();
		return null;
	}
	if (!isLuciNotificationEnabled(eventType || 'miclash_event')) return null;
	const node = ui.addNotification(null, E('p', String(message || '')), type);
	// "Auto-hide notifications" defaults to true; the toast disappears after a
	// short timeout (longer for errors so the user has time to read them).
	// When the user turns the option off, the toast stays until they close it
	// manually - useful for diagnosing rare issues without losing the message.
	const autoHide = appState.notificationAutoHide !== false;
	if (node && autoHide) {
		const timeout = type === 'error' ? 10000 : 6000;
		setTimeout(() => {
			try {
				node.remove();
			} catch (e) {}
		}, timeout);
	}
}

async function logUiAction(level, message) {
	const cleanLevel = /^(info|warn|err)$/.test(String(level || '')) ? level : 'info';
	const logger = cleanLevel === 'err' ? console.error : (cleanLevel === 'warn' ? console.warn : console.info);
	logger.call(console, '[MiClash]', String(message || '').slice(0, 512));
}

function delay(ms) {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

function getOperationMessage(error) {
	const raw = getOperationDetail(error);
	const firstLine = raw.split(/\r?\n/)
		.map((line) => line.trim())
		.filter(Boolean)[0] || _('unknown error');
	return firstLine.length > 180 ? firstLine.slice(0, 177) + '...' : firstLine;
}

function getOperationDetail(error) {
	const raw = String(error && error.message ? error.message : (error || '')).trim();
	return raw || _('unknown error');
}

function setOperationStatus(type, message, options) {
	const opts = options || {};
	const statusType = /^(running|error|success)$/.test(String(type || '')) ? type : 'running';
	const detail = opts.detail == null ? '' : String(opts.detail || '');
	const dismissible = opts.dismissible != null ? !!opts.dismissible : statusType === 'error';
	const autoClearMs = Number(opts.autoClearMs || 0);

	if (operationAutoClearTimer) {
		clearTimeout(operationAutoClearTimer);
		operationAutoClearTimer = null;
	}

	appState.operationStatus = {
		type: statusType,
		message: String(message || ''),
		detail: detail,
		context: String(opts.context || ''),
		dismissible: dismissible
	};
	updateHeaderAndControlDom();

	if (autoClearMs > 0) {
		const expected = appState.operationStatus;
		operationAutoClearTimer = setTimeout(() => {
			operationAutoClearTimer = null;
			const current = appState.operationStatus;
			if (current &&
				current.type === expected.type &&
				current.message === expected.message &&
				current.detail === expected.detail) {
				clearOperationStatus();
			}
		}, autoClearMs);
	}
}

function setOperationSuccess(message, options) {
	const opts = options || {};
	const statusMessage = String(message || '');
	setOperationStatus('success', statusMessage, Object.assign({}, opts, {
		dismissible: opts.dismissible === true,
		autoClearMs: opts.autoClearMs == null ? 1800 : Number(opts.autoClearMs)
	}));
}

function clearOperationStatus() {
	if (operationAutoClearTimer) {
		clearTimeout(operationAutoClearTimer);
		operationAutoClearTimer = null;
	}
	appState.operationStatus = null;
	updateHeaderAndControlDom();
}

function setOperationError(error, options) {
	if (view_miclash_api.isSessionExpired(error)) {
		suspendForSessionExpiry();
		return;
	}
	const opts = options || {};
	const detail = getOperationDetail(error);
	const message = getOperationMessage(error);
	setOperationStatus('error', _('Error: %s').format(message), Object.assign({
		detail: detail,
		dismissible: true,
		autoClearMs: opts.autoClearMs == null ? 0 : Number(opts.autoClearMs)
	}, opts));
}

function suspendForSessionExpiry() {
	if (sessionExpired) return;
	sessionExpired = true;
	controlPollTimer = view_miclash_ui_shell.stopInterval(controlPollTimer);
	logPollTimer = view_miclash_ui_shell.stopInterval(logPollTimer);
	updatePollTimer = view_miclash_ui_shell.stopInterval(updatePollTimer);
	diagnosticsOwner.destroy();
	notificationOwner.destroy();
	managementOwner.destroy();
	if (configApi) configApi.destroy();
}

function suspendForBackendRestart() {
	controlPollTimer = view_miclash_ui_shell.stopInterval(controlPollTimer);
	logPollTimer = view_miclash_ui_shell.stopInterval(logPollTimer);
	updatePollTimer = view_miclash_ui_shell.stopInterval(updatePollTimer);
	diagnosticsOwner.destroy();
	notificationOwner.destroy();
	managementOwner.destroy();
}

function operationStageOptions(initialMessage) {
	return {
		onStage: (message) => setOperationStatus('running', message || initialMessage)
	};
}

function safeText(value) {
	return String(value == null ? '' : value)
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;');
}

function buildInlineIcon(name, className) {
	const icons = {
		download: '<path d="M12 3v11"></path><path d="m7 10 5 5 5-5"></path><path d="M5 21h14"></path>',
		refresh: '<path d="M20 11a8 8 0 0 0-14.8-4"></path><path d="M5 3v4h4"></path><path d="M4 13a8 8 0 0 0 14.8 4"></path><path d="M19 21v-4h-4"></path>',
		clock: '<circle cx="12" cy="12" r="9"></circle><path d="M12 7v5l3 2"></path>',
		x: '<path d="M18 6 6 18"></path><path d="M6 6l12 12"></path>',
		info: '<path d="M12 11v6"></path><circle cx="12" cy="7" r="1.2"></circle>'
	};
	const body = icons[name];
	if (!body) return '';
	return '<svg class="' + safeText(className || 'sbox-button-icon') + '" viewBox="0 0 24 24" aria-hidden="true" focusable="false">' + body + '</svg>';
}

function buildVersionActionIcon(state) {
	const iconName = state && (state.iconName === 'refresh' || state.iconName === 'clock')
		? state.iconName : 'download';
	return buildInlineIcon(iconName, 'sbox-version-action-icon');
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
const swapConfigProfiles = view_miclash_store.swapConfigProfiles;
const listConfigProfiles = view_miclash_store.listConfigProfiles;
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
const detectPackageManager = view_miclash_package.detectPackageManager;
const getNetworkSnapshot = view_miclash_settings_model.getNetworkSnapshot;
const getNetworkInterfaces = view_miclash_settings_model.getNetworkInterfaces;
const transformProxyMode = view_miclash_settings_model.transformProxyMode;
const detectCurrentProxyMode = view_miclash_settings_model.detectCurrentProxyMode;
const loadLegacyOperationalSettings = view_miclash_settings_model.loadOperationalSettings;
const loadInterfacesByMode = view_miclash_settings_model.loadInterfacesByMode;
const detectLanBridge = view_miclash_settings_model.detectLanBridge;
const detectWanInterface = view_miclash_settings_model.detectWanInterface;
const normalizeProxyMode = view_miclash_settings_model.normalizeProxyMode;
const operationalSettingsChanged = view_miclash_settings_model.operationalSettingsChanged;
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

async function typedCall(callback) {
	const owned = !configApi;
	const api = configApi || view_miclash_api.create();
	try { return await callback(api); }
	finally { if (owned) api.destroy(); }
}

async function typedSettings() { return typedCall((api) => api.settings_get()); }

async function loadOperationalSettings() {
	return loadLegacyOperationalSettings();
}

function operationFailure(record) {
	const error = new Error(record?.error?.message || _('Guard transition failed.'));
	error.code = record?.error?.code || 'HEALTH_FAILED';
	return error;
}

function awaitTypedOperation(reply, message) {
	const id = reply?.operation_id;
	if (!configApi || typeof configApi.watchOperation !== 'function' || typeof id !== 'string' || !id.length)
		return Promise.reject(new Error(_('Invalid operation response.')));
	return new Promise((resolve, reject) => {
		let done = false, cancel = null;
		const finish = (callback, value) => {
			if (done) return;
			done = true;
			if (typeof cancel === 'function') cancel();
			callback(value);
		};
		cancel = configApi.watchOperation(id, (record, error) => {
			if (error) return finish(reject, error);
			if (record?.stage) setOperationStatus('running', message, { detail: record.stage });
			if (record?.state === 'success') finish(resolve, record);
			else if (record?.state === 'failure' || record?.state === 'interrupted')
				finish(reject, operationFailure(record));
		});
	});
}

async function refreshCanonicalGuardState() {
	const typed = await typedSettings();
	const enabled = !!(typed.guard && typed.guard.enabled);
	if (appState.settings) appState.settings.internetOnlyMiclash = enabled;
	const checkbox = pageRoot?.querySelector('#sbox-internet-only-miclash');
	if (checkbox) checkbox.checked = enabled;
	updateHeaderAndControlDom();
	return enabled;
}

async function getVersions() {
	const system = await typedCall((api) => api.system_info());
	return {
		app: normalizeAppVersion(system?.app_version || 'unknown'),
		clash: system?.mihomo?.installed ? String(system.mihomo.version || _('Installed')) : 'unknown'
	};
}
async function detectSystemArchitecture() {
	try {
		const system = await typedCall((api) => api.system_info());
		const distribArch = String(system?.architecture || '');

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
	try {
		const system = await typedCall((api) => api.system_info());
		return { installed: system?.mihomo?.installed === true,
			version: system?.mihomo?.installed ? String(system.mihomo.version || _('Installed')) : null };
	} catch (e) { return { installed: false, version: null }; }
}

async function ensureMihomoKernelInstalled() {
	const status = await getMihomoStatus();
	appState.kernelStatus = status;

	if (!status || !status.installed) {
		updateHeaderAndControlDom();
		throw new Error(_('Install the Mihomo kernel first.'));
	}

	return status;
}

function includeMiClashPrereleases() {
	return normalizeReleaseChannel(appState.settings && appState.settings.miclashReleaseChannel) === 'prerelease';
}

function includeMihomoPrereleases() {
	return normalizeReleaseChannel(appState.settings && appState.settings.mihomoReleaseChannel) === 'prerelease';
}

async function getLatestMihomoRelease() {
	return view_miclash_release.getLatestMihomoRelease(includeMihomoPrereleases());
}

async function getLatestMiClashRelease() {
	return view_miclash_release.getLatestMiClashRelease(includeMiClashPrereleases());
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
			iconName: 'download',
			className: 'cbi-button-positive',
			title: _('Install MiClash')
		};
	}

	if (hasUpdate) {
		const localMajor = /^\d+\.\d+\.\d+$/.test(local) ? parseInt(local.split('.')[0], 10) : null;
		const latestMajor = /^\d+\.\d+\.\d+$/.test(latest) ? parseInt(latest.split('.')[0], 10) : null;
		const scheduledMajor = appState.settings?.autoMajorMiclash !== false &&
			normalizeReleaseChannel(appState.settings?.miclashReleaseChannel) === 'release' &&
			localMajor != null && latestMajor != null && latestMajor > localMajor;
		if (scheduledMajor) {
			return {
				kind: 'update', scheduled: true, targetVersion: latest,
				iconName: 'clock', className: 'cbi-button-positive',
				title: _('Major update %s is scheduled for the night. Click to update now.').format(latest)
			};
		}
		return {
			kind: 'update',
			targetVersion: latest,
			iconName: 'download',
			className: 'cbi-button-positive',
			title: _('Update MiClash to %s').format(latest)
		};
	}

	return {
		kind: 'reinstall',
		iconName: 'refresh',
		className: 'cbi-button-neutral',
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
	const hasUpdate = installed && !!local && !!latest &&
		(cmp === -1 || (cmp === null && local !== latest));

	if (!installed) {
		return {
			kind: 'install',
			iconName: 'download',
			className: 'cbi-button-positive',
			title: _('Install Kernel')
		};
	}

	if (hasUpdate) {
		return {
			kind: 'update',
			targetVersion: latest,
			iconName: 'download',
			className: 'cbi-button-positive',
			title: _('Update Mihomo to %s').format(latest)
		};
	}

	return {
		kind: 'reinstall',
		iconName: 'refresh',
		className: 'cbi-button-neutral',
		title: _('Reinstall Mihomo')
	};
}

function shouldCheckAppRelease(force) {
	return !!force || resolveAppActionState().kind !== 'update';
}

function shouldCheckKernelRelease(force) {
	return !!force || resolveKernelActionState().kind !== 'update';
}

function refreshReleaseMeta(options) {
	const opts = options || {};
	const force = !!opts.force;
	if (!force && appState.releaseMeta.checkedAt > 0 &&
		Date.now() - appState.releaseMeta.checkedAt < UPDATE_CHECK_MS)
		return Promise.resolve(false);
	if (releaseRefreshPromise) return releaseRefreshPromise;
	const checkApp = shouldCheckAppRelease(force);
	const checkKernel = shouldCheckKernelRelease(force);

	if (!checkApp && !checkKernel) return Promise.resolve(false);

	const running = (async () => {
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
	})();
	const tracked = running.finally(() => {
		if (releaseRefreshPromise === tracked) releaseRefreshPromise = null;
	});
	releaseRefreshPromise = tracked;
	return releaseRefreshPromise;
}

function isRpcReconnectLikeError(error) {
	const text = String(error?.message || error || '').toLowerCase();
	if (!text) return false;
	if (text.indexOf('ubus code 7') !== -1) return true;
	if (text.indexOf('тайм-аут') !== -1) return true;
	if (text.indexOf('xhr') !== -1 && text.indexOf('timeout') !== -1) return true;
	if (text.indexOf('request timed out') !== -1) return true;
	if (text.indexOf('networkerror') !== -1) return true;
	if (text.indexOf('failed to fetch') !== -1) return true;
	if (text.indexOf('connection') !== -1 && (text.indexOf('closed') !== -1 || text.indexOf('reset') !== -1 || text.indexOf('refused') !== -1)) return true;
	return false;
}

function isExpectedBackendRestartInterruption(error) {
	const text = String(error?.message || error || '').toLowerCase();
	return isRpcReconnectLikeError(error) || text.indexOf('ubus code 4') !== -1 ||
		text.indexOf('resource not found') !== -1 || text.indexOf('ресурс не найден') !== -1;
}

async function waitForMiClashBackendRestart(api, options) {
	const opts = options || {};
	const timeoutMs = Math.max(1000, Number(opts.timeoutMs) || 30000);
	const intervalMs = Math.max(10, Number(opts.intervalMs) || 500);
	const now = typeof opts.now === 'function' ? opts.now : () => Date.now();
	const sleep = typeof opts.sleep === 'function' ? opts.sleep :
		(delay) => new Promise((resolve) => window.setTimeout(resolve, delay));
	const deadline = now() + timeoutMs;
	let unavailable = false;

	while (now() < deadline) {
		await sleep(intervalMs);
		try {
			await api.system_info();
			if (unavailable) return true;
		} catch (error) {
			if (!isExpectedBackendRestartInterruption(error)) throw error;
			unavailable = true;
		}
	}

	return false;
}

async function waitForCurrentMiClashBackendRestart() {
	const probe = view_miclash_api.create({ startupRetryMs: 0 });
	try {
		return await waitForMiClashBackendRestart(probe);
	} finally {
		probe.destroy();
	}
}

async function clearMiClashUpdateStatus() {
	appState.pendingUpdateOperation = null;
	clearStoredOperationToken('update');
}

async function readMiClashServiceState() {
	const snapshot = await typedCall((api) => api.overview());
	const observed = snapshot?.observed || {};
	const service = observed.service || {};
	const readiness = observed.readiness || {};
	const running = service.running === true || service.state === 'running';
	const current = selectActiveOperation(snapshot?.recent_operations, 'service.');
	return {
		service: running ? 'running' : 'stopped',
		health: running ? (readiness.ok === true ? 'ready' : 'not_ready') : 'stopped',
		operation: current ? 'running' : 'idle', phase: current?.stage || '',
		operation_id: current?.id || null,
		message: readiness?.message || '',
		desired: snapshot?.desired || null,
		observedGuard: observed?.guard || { state: 'unknown' }
	};
}

function getServiceOperationState(status) {
	return String((status && (status.operation || status.state)) || 'idle').trim() || 'idle';
}

function applyServiceState(status) {
	const state = status || {};
	const service = String(state.service || '').trim();
	const health = String(state.health || '').trim();
	const operation = getServiceOperationState(state);

	appState.serviceState = state;
	appState.serviceStateLoading = false;
	appState.serviceRunning = service === 'running';
	appState.serviceHealth = health || (appState.serviceRunning ? 'unknown' : 'stopped');
	appState.serviceJobBusy = operation === 'running';
	appState.guardObservedState = String(state.observedGuard?.state || 'unknown');
	if (state.desired?.guard && appState.settings)
		appState.settings.internetOnlyMiclash = state.desired.guard.enabled === true;

	return state;
}

async function clearMiClashServiceStatus() {
	appState.pendingServiceOperation = null;
}

function getOperationTokenStorageKey(kind) {
	return OPERATION_TOKEN_STORAGE_PREFIX + String(kind || '');
}

function getStoredOperationToken(kind) {
	try {
		return String(window.sessionStorage.getItem(getOperationTokenStorageKey(kind)) || '');
	} catch (e) {
		return '';
	}
}

function clearStoredOperationToken(kind, token) {
	try {
		const key = getOperationTokenStorageKey(kind);
		const expected = String(token || '');
		if (!expected || String(window.sessionStorage.getItem(key) || '') === expected) {
			window.sessionStorage.removeItem(key);
		}
	} catch (e) {}
}

function setStoredOperationToken(kind, operation) {
	const token = String(operation?.operation_id || operation?.id || '').trim();
	if (!token) return;
	try {
		window.sessionStorage.setItem(getOperationTokenStorageKey(kind), token);
	} catch (e) {}
}

async function startMiClashUpdateJob(kind, args) {
	await clearMiClashUpdateStatus();
	const reply = kind === 'kernel'
		? await configApi.update_mihomo(normalizeReleaseChannel(
			appState.settings?.mihomoReleaseChannel), 'luci')
		: await configApi.update_miclash(normalizeReleaseChannel(
			appState.settings?.miclashReleaseChannel), 'luci');
	appState.pendingUpdateOperation = reply;
	setStoredOperationToken('update', reply);
	return true;
}

async function startMiClashServiceJob(action) {
	await clearMiClashServiceStatus();
	const method = configApi['service_' + action];
	if (typeof method !== 'function') throw new Error('Unsupported service action');
	appState.pendingServiceOperation = await method('config.yaml', 'luci');
	setStoredOperationToken('service', appState.pendingServiceOperation);
	return true;
}

async function pollMiClashUpdateJob(initialMessage, options) {
	const fallback = initialMessage || _('Updating MiClash...');

	appState.updateJobBusy = true;
	setOperationStatus('running', fallback);

	try {
		await awaitTypedOperation(appState.pendingUpdateOperation, fallback);
		clearStoredOperationToken('update');
		clearOperationStatus();
		return { state: 'success', phase: 'done', message: '' };
	} finally {
		appState.updateJobBusy = false;
		updateHeaderAndControlDom();
	}
}

async function pollMiClashServiceJob(initialMessage, options) {
	const fallback = initialMessage || _('Updating service status...');

	appState.serviceJobBusy = true;
	setOperationStatus('running', fallback);

	try {
		await awaitTypedOperation(appState.pendingServiceOperation, fallback);
		clearStoredOperationToken('service');
		const status = await refreshServiceState();
		clearOperationStatus();
		return status;
	} finally {
		appState.serviceJobBusy = false;
		updateHeaderAndControlDom();
	}
}

async function runMiClashServiceJob(action, initialMessage) {
	await startMiClashServiceJob(action);
	return pollMiClashServiceJob(initialMessage);
}

async function resumeMiClashUpdateJobStatus() {
	const operationId = getStoredOperationToken('update');
	if (!operationId) return;
	appState.pendingUpdateOperation = { operation_id: operationId };
	try {
		await pollMiClashUpdateJob(_('Updating MiClash...'));
		clearOperationStatus();
	} catch (error) {
		setOperationError(error);
	} finally {
		await clearMiClashUpdateStatus();
	}
}

async function resumeMiClashServiceJobStatus() {
	const operationId = getStoredOperationToken('service');
	if (!operationId) return;
	appState.pendingServiceOperation = { operation_id: operationId };
	try {
		await pollMiClashServiceJob(_('Updating service status...'));
		clearOperationStatus();
	} catch (error) {
		setOperationError(error);
	} finally {
		await clearMiClashServiceStatus();
		clearStoredOperationToken('service', operationId);
	}
}

async function installMiClashFromSettings(actionKind) {
	setOperationStatus('running', _('Preparing MiClash package update...'));
	const manager = await detectPackageManager();
	if (!manager) throw new Error(_('No supported package manager found (apk/opkg).'));

	const release = await getLatestMiClashRelease();
	if (!release) throw new Error(_('Failed to load MiClash release information: %s').format(_('Unavailable')));
	if (!release.version) throw new Error(_('Failed to load MiClash release information: %s').format(_('Download failed')));

	const mode = String(actionKind || 'update');

	try {
		await logUiAction('info', 'MiClash package update started');
		notify('info', _('Updating MiClash package on router...'));
		await startMiClashUpdateJob('app', ['--target-tag', release.version, '--mode', mode]);
		await pollMiClashUpdateJob(_('Updating MiClash package on router...'));
	} catch (e) {
		if (isRpcReconnectLikeError(e)) {
			notify('info', _('Connection interrupted while finalizing MiClash update. Reloading interface...'));
			suspendForBackendRestart();
			await waitForCurrentMiClashBackendRestart();
			window.location.reload();
			return true;
		}
		setOperationError(e);
		throw e;
	}

	await logUiAction('info', 'MiClash package installed');
	notify('info', _('MiClash package installed. Reloading interface...'));
	setOperationStatus('running', _('MiClash package installed. Reloading interface...'));
	suspendForBackendRestart();
	await waitForCurrentMiClashBackendRestart();
	window.location.reload();
	return true;
}

async function downloadMihomoKernel(downloadUrl, version, arch) {
	try {
		await logUiAction('info', 'mihomo kernel update started');
		setOperationStatus('running', _('Preparing Mihomo kernel update...'));
		notify('info', _('Updating mihomo kernel on router...'));
		await startMiClashUpdateJob('kernel', ['--url', downloadUrl]);
		const status = await pollMiClashUpdateJob(_('Updating mihomo kernel on router...'));
		const message = String(status.message || '').trim();
		await logUiAction('info', message || 'mihomo kernel installed');
		notify('info', message || _('Mihomo kernel downloaded and installed.'));
		clearOperationStatus();
		return true;
	} catch (e) {
		setOperationError(e);
		await logUiAction('err', 'mihomo kernel update failed: ' + e.message);
		notify('error', _('Kernel download failed: %s').format(e.message));
		return false;
	}
}

async function installKernelFromSettings() {
	setOperationStatus('running', _('Preparing Mihomo kernel update...'));
	const arch = await detectSystemArchitecture();
	const release = await getLatestMihomoRelease();
	const asset = findKernelAsset(release, arch);

	if (!release) throw new Error(_('Failed to load kernel information: %s').format(_('Unavailable')));
	if (!asset || !asset.browser_download_url) throw new Error(_('Failed to load kernel information: %s').format(_('Download failed')));

	const ok = await downloadMihomoKernel(asset.browser_download_url, release.version, arch);
	if (!ok) return false;

	appState.kernelStatus = await getMihomoStatus();
	appState.versions.clash = (appState.kernelStatus && appState.kernelStatus.version) || appState.versions.clash;
	await refreshHeaderAndControl();
	await refreshReleaseMeta({ force: true });
	return true;
}

function showModal(options) {
	const opts = Object.assign({}, options || {}, { mountNode: pageRoot });
	opts.modalClass = (opts.modalClass ? opts.modalClass + ' ' : '') + 'sbox-modal-responsive-shell';
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

		const info = E('div', { 'class': 'cbi-section' }, [
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

function actionMetricName(btns) {
	const values = Array.isArray(btns) ? btns : [ btns ];
	for (const button of values) {
		if (!button || typeof button !== 'object') continue;
		const value = button.id || button.getAttribute?.('data-action') ||
			button.getAttribute?.('data-developer-action');
		if (value) return String(value);
	}
	return 'control';
}

async function withButtons(btns, fn) {
	const metric = view_miclash_performance.begin('action.' + actionMetricName(btns));
	try {
		const result = await view_miclash_ui_shell.withButtons(btns, fn, safeText);
		view_miclash_performance.end(metric, true);
		return result;
	} catch (error) {
		view_miclash_performance.end(metric, false);
		throw error;
	}
}

async function withServiceButtons(activeBtn, inactiveBtn, fn) {
	const activeHtml = activeBtn ? activeBtn.innerHTML : '';
	const inactiveDisabled = inactiveBtn ? inactiveBtn.disabled : false;
	const metric = view_miclash_performance.begin('action.' + actionMetricName(activeBtn));
	let succeeded = false;

	appState.serviceActionBusy = true;

	if (activeBtn) {
		activeBtn.disabled = true;
		activeBtn.innerHTML = '<span class="sbox-spinner"></span> ' + safeText(activeBtn.textContent || '').trim();
	}
	if (inactiveBtn) inactiveBtn.disabled = true;
	updateHeaderAndControlDom();

	try {
		const result = await fn();
		succeeded = true;
		return result;
	} finally {
		view_miclash_performance.end(metric, succeeded);
		appState.serviceActionBusy = false;

		if (activeBtn && activeBtn.isConnected) {
			activeBtn.disabled = false;
			activeBtn.innerHTML = activeHtml;
		}
		if (inactiveBtn && inactiveBtn.isConnected) inactiveBtn.disabled = inactiveDisabled;
		updateHeaderAndControlDom();
	}
}

async function withRestartButtonFeedback(fn) {
	const restartBtn = pageRoot ? pageRoot.querySelector('#sbox-restart') : null;
	return withServiceButtons(restartBtn, null, fn);
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

function getDashboardConfigIssue(config) {
	const ec = parseYamlValue(config, 'external-controller');
	const ecTls = parseYamlValue(config, 'external-controller-tls');
	const externalUi = parseYamlValue(config, 'external-ui');
	const externalUiName = parseYamlValue(config, 'external-ui-name');

	if (!ec && !ecTls) {
		return _('Dashboard is not configured: external-controller is missing in config.yaml.');
	}

	if (!externalUi && !externalUiName) {
		return _('Dashboard is not configured: external-ui or external-ui-name is missing in config.yaml.');
	}

	return '';
}

function resolveDashboardButtonState() {
	if (!appState.serviceRunning) {
		return {
			disabled: true,
			className: 'cbi-button-neutral',
			title: _('Start the service to open dashboard.')
		};
	}
	if (appState.serviceHealth === 'checking') {
		return {
			disabled: true,
			className: 'cbi-button-neutral',
			title: _('Updating service status...')
		};
	}
	if (appState.serviceHealth === 'not_ready') {
		return {
			disabled: true,
			className: 'cbi-button-negative',
			title: _('Service is not ready.')
		};
	}

	const issue = getDashboardConfigIssue(appState.configContent || '');
	if (issue) {
		return {
			disabled: false,
			className: 'cbi-button-negative',
			title: issue
		};
	}

	return {
		disabled: false,
		className: 'cbi-button-positive',
		title: _('Open dashboard')
	};
}

async function getServiceStatus() {
	try {
		const status = await readMiClashServiceState();
		applyServiceState(status);
		return appState.serviceRunning;
	} catch (e) {
		const running = await view_miclash_utils.getClashRunning();
		appState.serviceRunning = !!running;
		appState.serviceHealth = running ? 'unknown' : 'stopped';
		return appState.serviceRunning;
	}
}

async function checkServiceHealthOrThrow() {
	const status = await readMiClashServiceState();
	applyServiceState(status);
	if (!appState.serviceRunning) {
		throw new Error(_('Service is not running.'));
	}
	if (appState.serviceHealth !== 'ready') {
		throw new Error(String(status.message || _('Service is not ready.')).trim());
	}
	return true;
}

async function restartOrReloadServiceOrThrow(action, options) {
	const opts = options || {};
	const message = action === 'reload'
		? _('Reloading Mihomo configuration...')
		: _('Restarting Clash service...');
	if (opts.onStage) opts.onStage(message);
	return runMiClashServiceJob(action, message);
}

function notifyDetailedError(title, detail) {
	ui.addNotification(null, E('div', {}, [
		E('p', String(title || '')),
		E('pre', { 'class': 'sbox-error-detail' }, String(detail || _('unknown error')))
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

async function applySubscriptionOnRouter(targetName) {
	return view_miclash_subscription.applySubscriptionOnRouter({
		targetName: targetName
	});
}

function normalizeAutoUpdateIntervalHours(value) {
	const clean = String(value || '').trim();
	const parsed = parseInt(clean, 10);
	return parsed > 0 ? String(parsed) : '';
}

async function applySubscriptionProfileUpdateInterval(hours) {
	const clean = normalizeAutoUpdateIntervalHours(hours);
	if (!clean) return;

	const settings = await readSettingsMap();
	if (settings.AUTO_UPDATE_INTERVAL_HOURS === clean) {
		if (appState.settings) appState.settings.autoUpdateIntervalStored = true;
		return;
	}

	settings.AUTO_UPDATE_INTERVAL_HOURS = clean;
	await writeSettingsMap(settings);
	if (appState.settings) {
		appState.settings.autoUpdateIntervalHours = clean;
		appState.settings.autoUpdateIntervalStored = true;
	}
}

async function probeAutoUpdateIntervalFromSubscription() {
	notify('info', _('The provider update interval will be learned during the next protected subscription update. The selected interval is used until then.'));
	return false;
}

async function testConfigContent(content, keepOnSuccess, targetPath) {
	return view_miclash_subscription.testConfigContent(
		content,
		keepOnSuccess,
		targetPath,
		{ ensureKernelInstalled: ensureMihomoKernelInstalled }
	);
}

async function validateContentAsMainConfig(content) {
	setOperationStatus('running', _('Validating YAML...'));
	const tested = await testConfigContent(content, false, CONFIG_PATH);
	if (tested.ok) return true;
	setOperationError(new Error(tested.message || _('YAML validation failed.')));
	notifyDetailedError(_('YAML validation failed.'), tested.message);
	return false;
}

async function validateMainConfigBeforeStart() {
	const content = await readConfigFileByName(MAIN_CONFIG_NAME);
	return validateContentAsMainConfig(content);
}

async function fetchSubscriptionAsYaml(url, targetPath) {
	const settingsMap = await readSettingsMap();
	const versions = await getVersions();
	const profile = buildSubscriptionClientProfile(settingsMap, versions.app);
	const deviceHeaders = await buildSubscriptionDeviceHeaders(settingsMap);
	const resolved = normalizeSubscriptionDownloadUrl(url);
	let mode = resolved.mode;
	let payload = '';
	let profileUpdateIntervalHours = '';
	let primaryError = null;

	try {
		const info = await downloadSubscriptionWithProfile(resolved.url, profile, deviceHeaders, mode);
		payload = String(info && info.content != null ? info.content : info || '');
		profileUpdateIntervalHours = normalizeAutoUpdateIntervalHours(info && info.profileUpdateIntervalHours);
	} catch (e) {
		primaryError = e;
	}

	const needsFallbackByPayload = !primaryError &&
		(looksLikeBase64Blob(payload) || looksLikeUriSubscription(payload));
	const shouldTryFallback = !!resolved.remnawaveCandidateUrl &&
		(needsFallbackByPayload || (primaryError && resolved.fallbackOnError));

	if (shouldTryFallback) {
		try {
			const info = await downloadSubscriptionWithProfile(
				resolved.remnawaveCandidateUrl,
				profile,
				deviceHeaders,
				'remnawave-client-path'
			);
			payload = String(info && info.content != null ? info.content : info || '');
			profileUpdateIntervalHours = normalizeAutoUpdateIntervalHours(info && info.profileUpdateIntervalHours);
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

	return { content: payload, mode: mode, profileUpdateIntervalHours: profileUpdateIntervalHours };
}

async function openDashboard() {
	try {
		if (!(await getServiceStatus())) {
			notify('error', _('Service is not running.'));
			return;
		}

		const config = await readConfigFileByName(MAIN_CONFIG_NAME);
		const configIssue = getDashboardConfigIssue(config);
		if (configIssue) {
			notify('error', configIssue);
			return;
		}

		setOperationStatus('running', _('Checking Clash service readiness...'));
		await checkServiceHealthOrThrow();

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
		clearOperationStatus();
	} catch (e) {
		setOperationError(e);
		notify('error', _('Failed to open dashboard: %s').format(e.message));
	}
}

async function saveOperationalSettings(mode, proxyMode, tunStack, autoDetectLan, autoDetectWan, blockQuic, internetOnlyMiclash, useTmpfsRules, interfaces, enableHwid, hwidUserAgent, hwidDeviceOS, miclashReleaseChannel, mihomoReleaseChannel, autoUpdateConfig, autoUpdateIntervalHours, autoMajorMiclash, options) {
	const opts = options || {};
	try {
		await view_miclash_settings_model.saveOperationalSettings(
			mode,
			proxyMode,
			tunStack,
			autoDetectLan,
			autoDetectWan,
			blockQuic,
			useTmpfsRules,
			interfaces,
			enableHwid,
			hwidUserAgent,
			hwidDeviceOS,
			miclashReleaseChannel,
			mihomoReleaseChannel,
			autoUpdateConfig,
			autoUpdateIntervalHours,
			autoMajorMiclash
		);
		const typed = await configApi.settings_get();
		if (!opts.skipGuard && !!(typed.guard && typed.guard.enabled) !== !!internetOnlyMiclash) {
			setOperationStatus('running', _('Applying protection setting...'));
			await awaitTypedOperation(
				await configApi.guard_transition(!!internetOnlyMiclash, 'luci'),
				_('Applying protection setting...')
			);
		}
		if (!opts.silent) {
			notify('info', _('Settings saved.'));
		}
		await logUiAction('info', 'Settings saved');
		return true;
	} catch (e) {
		try { await refreshCanonicalGuardState(); } catch (refreshError) {}
		await logUiAction('err', 'Failed to save settings: ' + e.message);
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
		current.miclashReleaseChannel || 'release',
		current.mihomoReleaseChannel || 'release',
		current.autoUpdateConfig !== false,
		current.autoUpdateIntervalHours || '4',
		current.autoMajorMiclash !== false,
		{ silent: true }
	);

	if (!ok) throw new Error(_('Cannot save proxy mode.'));

	appState.settings = await loadOperationalSettings();
	appState.selectedInterfaces = await loadInterfacesByMode(appState.settings.mode || 'exclude');
	appState.detectedLan = appState.settings.detectedLan || (await detectLanBridge()) || '';
	appState.detectedWan = appState.settings.detectedWan || (await detectWanInterface()) || '';
	appState.proxyMode = normalizeProxyMode(appState.settings.proxyMode || nextMode);
	appState.serviceRunning = await getServiceStatus();

	const freshConfig = await L.resolveDefault(readConfigFileByName(appState.selectedConfigName), '');
	appState.configContent = freshConfig;
	if (editor) {
		editor.setValue(String(freshConfig || ''), -1);
		editor.clearSelection();
	}

	updateHeaderAndControlDom();
	if (appState.activeCfgTab === 'settings') renderSettingsPane();
	const message = _('Proxy mode switched to %s.').format(appState.proxyMode);
	setOperationSuccess(message);
	notify('info', message);
}

async function loadClashLogs() {
	return view_miclash_logs.readRaw();
}

function createLogSearchState() {
	return { query: '', activeIndex: -1, matches: [] };
}

function matchOffsets(text, query) {
	const value = String(text || '');
	const needle = String(query || '').trim().toLocaleLowerCase();
	if (!needle) return [];
	const haystack = value.toLocaleLowerCase();
	const offsets = [];
	for (let start = haystack.indexOf(needle); start !== -1;
		start = haystack.indexOf(needle, start + needle.length))
		offsets.push([ start, start + needle.length ]);
	return offsets;
}

function logRows(raw) {
	if (!raw) return [];

	return String(raw || '').split('\n')
		.map((line) => view_miclash_logs.formatLine(line))
		.map((item) => {
			if (!item || !item.text) return null;
			if (item.daemon && item.time && item.level) return item;

			const legacy = String(item.text || '').match(/^\[([^\]]+)\]\s+\[((?:clash(?:-rules|-hotplug)?)|miclash)\]\s+\[([^\]]+)\]\s+(.*)$/);
			if (!legacy) return null;
			const level = String(legacy[3] || 'MUTED').toUpperCase();
			const daemon = legacy[2];
			return {
				time: legacy[1],
				daemon: daemon,
				level: level,
				message: legacy[4],
				levelClass: 'sbox-log-level-' + level.toLowerCase(),
				daemonClass: 'sbox-log-daemon-' + daemon
			};
		})
		.filter((item) => !!item && !!item.message);
}

function appendLogText(parent, text) {
	const value = String(text || '');
	let cursor = 0;
	for (const [ start, end ] of matchOffsets(value, logSearch.query)) {
		if (start > cursor) parent.appendChild(document.createTextNode(value.slice(cursor, start)));
		const match = E('mark', { 'class': 'sbox-log-search-match' }, [ value.slice(start, end) ]);
		logSearch.matches.push(match);
		parent.appendChild(match);
		cursor = end;
	}
	if (cursor < value.length || !value.length) parent.appendChild(document.createTextNode(value.slice(cursor)));
}

function updateLogSearchControls(scrollActive) {
	const toolbar = pageRoot?.querySelector('#sbox-log-search');
	if (!toolbar) return;
	toolbar.hidden = !developerVisible;
	if (!developerVisible) return;

	const total = logSearch.matches.length;
	if (logSearch.activeIndex >= total) logSearch.activeIndex = total - 1;
	if (total === 0) logSearch.activeIndex = -1;
	for (let i = 0; i < total; i++)
		logSearch.matches[i].classList.toggle('sbox-log-search-match-active', i === logSearch.activeIndex);

	const count = toolbar.querySelector('#sbox-log-search-count');
	const next = toolbar.querySelector('#sbox-log-search-next');
	const previous = toolbar.querySelector('#sbox-log-search-previous');
	if (count) count.textContent = total ? String(logSearch.activeIndex + 1) + ' / ' + String(total) : '0 / 0';
	if (next) next.disabled = total === 0;
	if (previous) previous.disabled = total === 0;
	if (scrollActive && logSearch.activeIndex >= 0)
		logSearch.matches[logSearch.activeIndex].scrollIntoView({ block: 'center', behavior: 'smooth' });
}

function renderLogs(options) {
	const content = pageRoot?.querySelector('#sbox-log-content');
	if (!content) return;
	const opts = options || {};
	const rows = logRows(appState.logsRaw);
	logSearch.matches = [];
	content.replaceChildren();
	if (!rows.length) {
		content.appendChild(E('span', { 'class': 'sbox-log-muted' }, [
			_('No MiClash or Mihomo records match the current log level yet. Current level: %s')
				.format(configuredLogLevel())
		]));
	} else {
		for (let i = 0; i < rows.length; i++) {
			const item = rows[i];
			const row = E('span', { 'class': 'sbox-log-line ' + item.levelClass + ' ' + item.daemonClass });
			const time = E('span', { 'class': 'sbox-log-time' });
			const daemon = E('span', { 'class': 'sbox-log-daemon' });
			const level = E('span', { 'class': 'sbox-log-level' });
			const message = E('span', { 'class': 'sbox-log-message' });
			appendLogText(time, item.time || '--:--:--');
			appendLogText(daemon, item.daemon || 'clash');
			appendLogText(level, item.level || 'MUTED');
			appendLogText(message, item.message || item.text);
			row.append(time, daemon, level, message);
			if (i > 0) content.appendChild(document.createTextNode('\n'));
			content.appendChild(row);
		}
	}
	if (logSearch.query.trim() && logSearch.activeIndex < 0 && logSearch.matches.length)
		logSearch.activeIndex = 0;
	updateLogSearchControls(opts.scrollActive === true);
	if (opts.followBottom === true) content.scrollTop = content.scrollHeight;
}

function setLogSearchQuery(value) {
	const query = String(value || '');
	if (logSearch.query === query) return;
	logSearch.query = query;
	logSearch.activeIndex = -1;
	renderLogs({ scrollActive: query.trim().length > 0 });
}

function moveLogSearchResult(direction) {
	const total = logSearch.matches.length;
	if (!total) return;
	const step = direction < 0 ? -1 : 1;
	const current = logSearch.activeIndex < 0 ? (step < 0 ? 0 : -1) : logSearch.activeIndex;
	logSearch.activeIndex = (current + step + total) % total;
	updateLogSearchControls(true);
}

function clearLogSearch() {
	logSearch = createLogSearchState();
	const input = pageRoot?.querySelector('#sbox-log-search-input');
	if (input) input.value = '';
	if (pageRoot?.querySelector('#sbox-log-content')) renderLogs();
}

function configuredLogLevel() {
	const match = String(appState.configContent || '').match(/^\s*log-level\s*:\s*([^\s#]+)/mi);
	return match ? String(match[1] || '').trim() : _('unknown');
}


async function initializeConfigEditor(content) {
	const editorHost = (pageRoot && pageRoot.querySelector('#miclash-editor')) || document.getElementById('miclash-editor');
	if (!editorHost) throw new Error('editor container #miclash-editor not found');
	editor = await view_miclash_editor.createEditor(editorHost, content, { mode: 'yaml' });
	editor.clearSelection();
	resizeConfigEditor();
}

function setConfigWorkspaceReady(ready) {
	appState.configReady = !!ready;
	if (!pageRoot) return;
	[
		'#sbox-config-select', '#sbox-subscription-url', '#sbox-save-sub-url',
		'#sbox-update-sub', '#sbox-clear-sub-url', '#sbox-validate', '#sbox-save',
		'#sbox-clear-editor', '#sbox-set-main-config', '#sbox-open-rulesets'
	].forEach((selector) => {
		const control = pageRoot.querySelector(selector);
		if (control) control.disabled = !ready;
	});
}

async function hydrateConfigWorkspace(generation) {
	const [ content, subscriptionUrl, profiles ] = await Promise.all([
		readConfigFileByName(MAIN_CONFIG_NAME),
		readSubscriptionUrl(MAIN_CONFIG_NAME),
		listConfigProfiles()
	]);
	if (generation !== pageGeneration || !pageRoot) return;

	appState.configProfiles = profiles;
	appState.selectedConfigName = MAIN_CONFIG_NAME;
	appState.configContent = String(content || '');
	appState.subscriptionUrl = String(subscriptionUrl || '');
	const select = pageRoot.querySelector('#sbox-config-select');
	const subscription = pageRoot.querySelector('#sbox-subscription-url');
	if (select) select.innerHTML = buildConfigOptionsHtml();
	if (subscription) subscription.value = appState.subscriptionUrl;

	await initializeConfigEditor(appState.configContent);
	if (generation !== pageGeneration || !pageRoot) return;
	setConfigWorkspaceReady(true);
	updateSetMainAvailability(appState.configContent, MAIN_CONFIG_NAME);
}

function beginPageHydration(generation) {
	return Promise.resolve().then(() => hydrateConfigWorkspace(generation)).catch((error) => {
		if (generation !== pageGeneration || !pageRoot) return;
		console.error('[MiClash] Failed to hydrate config workspace:', error);
		// Keep the editor shimmer visible. A later page visit can retry safely.
	});
}

async function hydrateSystemMetadata(generation) {
	const system = await typedCall((api) => api.system_info());
	if (generation !== pageGeneration || !pageRoot) return;
	appState.versions = {
		app: normalizeAppVersion(system?.app_version || 'unknown'),
		clash: system?.mihomo?.installed ? String(system.mihomo.version || _('Installed')) : 'unknown'
	};
	appState.kernelStatus = {
		installed: system?.mihomo?.installed === true,
		version: system?.mihomo?.installed ? String(system.mihomo.version || '') : null
	};
	appState.systemMetadataReady = true;
	updateHeaderAndControlDom();
}

async function hydrateInitialState(generation) {
	const [ serviceState, networkSnapshot ] = await Promise.all([
		readMiClashServiceState(),
		getNetworkSnapshot()
	]);
	if (generation !== pageGeneration || !pageRoot) return;
	if (serviceState?.desired)
		appState.settings = view_miclash_settings_model.operationalSettingsFromTyped(serviceState.desired);
	appState.settings ||= {};
	appState.interfaces = Array.isArray(networkSnapshot?.interfaces) ? networkSnapshot.interfaces : [];
	appState.selectedInterfaces = (appState.settings.mode === 'explicit'
		? appState.settings.includedInterfaces : appState.settings.excludedInterfaces) || [];
	appState.detectedLan = appState.settings.detectedLan || networkSnapshot?.detectedLan || '';
	appState.detectedWan = appState.settings.detectedWan || networkSnapshot?.detectedWan || '';
	appState.proxyMode = normalizeProxyMode(appState.settings.proxyMode || 'tproxy');
	applyServiceState(serviceState);
	updateHeaderAndControlDom();
}

function releaseConfigRuntime() {
	pageGeneration++;
	view_miclash_logs.reset();
	appState.configReady = false;
	subscriptionUpdateBusy = false;
	logsLoaded = false;
	logsRefreshPromise = null;
	if (visibilityChangeHandler) document.removeEventListener('visibilitychange', visibilityChangeHandler);
	visibilityChangeHandler = null;
	if (editor) { try { editor.destroy(); } catch (error) {} editor = null; }
	if (configApi) configApi.destroy();
	configApi = null;
	controlPollTimer = view_miclash_ui_shell.stopInterval(controlPollTimer);
	logPollTimer = view_miclash_ui_shell.stopInterval(logPollTimer);
	updatePollTimer = view_miclash_ui_shell.stopInterval(updatePollTimer);
}

function resizeConfigEditor() {
	if (!editor || typeof editor.resize !== 'function') return;
	const resize = function() {
		try { editor.resize(true); } catch (e) {}
	};
	window.requestAnimationFrame(resize);
	window.setTimeout(resize, 50);
	window.setTimeout(resize, 250);
	window.setTimeout(resize, 750);
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
	const data = await readRulesetsData();
	let rulesetNames = data.rulesetNames.slice();
	let currentRuleset = rulesetNames[0] || '';
	const rulesetCache = Object.assign({}, data.contentMap || {});

		const body = E('div', { 'class': 'sbox-rulesets-modal-body sbox-modal-responsive' });
	body.innerHTML = '' +
		'<div class="sbox-rulesets-layout">' +
			'<aside class="cbi-section sbox-rulesets-sidebar">' +
				'<div class="sbox-rulesets-title">' + safeText(_('Local Rulesets')) + '</div>' +
				'<div class="sbox-muted">' + safeText(_('Manage local .txt lists for rule-providers.')) + '</div>' +
				'<div class="sbox-rulesets-create-row">' +
					'<input id="sbox-ruleset-new-name" class="cbi-input-text sbox-input" type="text" placeholder="' + safeText(_('new-list-name')) + '" />' +
					'<button id="sbox-ruleset-create" type="button" class="cbi-button cbi-button-positive">' + safeText(_('Create')) + '</button>' +
				'</div>' +
				'<div id="sbox-rulesets-list" class="sbox-rulesets-list"></div>' +
			'</aside>' +
			'<section class="cbi-section sbox-rulesets-main">' +
				'<div class="sbox-rulesets-toolbar">' +
					'<span id="sbox-ruleset-current" class="sbox-ruleset-current"></span>' +
					'<div class="sbox-rulesets-toolbar-actions">' +
						'<button id="sbox-ruleset-save" type="button" class="cbi-button cbi-button-positive">' + safeText(_('Save')) + '</button>' +
						'<button id="sbox-ruleset-delete" type="button" class="cbi-button cbi-button-negative">' + safeText(_('Delete')) + '</button>' +
					'</div>' +
				'</div>' +
				'<div id="sbox-ruleset-empty" class="cbi-section-descr sbox-rulesets-empty">' + safeText(_('No ruleset selected. Create one to begin.')) + '</div>' +
				'<div id="sbox-ruleset-editor-wrap" class="sbox-ruleset-editor-wrap" hidden>' +
					'<div id="sbox-ruleset-editor" class="sbox-ruleset-editor"></div>' +
				'</div>' +
				'<div class="cbi-section-descr sbox-rulesets-example">' +
					'<div class="sbox-rulesets-example-label">' + safeText(_('Example usage in config.yaml')) + '</div>' +
					'<pre>rule-providers:\n  your-list:\n    behavior: classical\n    type: file\n    format: text\n    path: ./lst/your-list.txt</pre>' +
				'</div>' +
				(data.whitelistMode ? '' +
					'<div class="cbi-section sbox-rulesets-whitelist">' +
						'<div class="sbox-rulesets-whitelist-head">' + safeText(_('IP-CIDR List (fake-ip whitelist mode)')) + '</div>' +
						'<div class="sbox-muted sbox-rulesets-whitelist-note">' + safeText(_('One IPv4/CIDR per line. Save applies firewall update without restarting Mihomo.')) + '</div>' +
						'<div id="sbox-ruleset-whitelist-editor" class="sbox-ruleset-whitelist-editor"></div>' +
						'<div class="sbox-actions sbox-rulesets-whitelist-actions">' +
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

	async function ensureRulesetEditor() {
		if (rulesetMainEditor) return;
		rulesetMainEditor = await view_miclash_editor.createEditor('sbox-ruleset-editor', '', { mode: 'text' });
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
		if (emptyNode) emptyNode.hidden = hasCurrent;
		if (editorWrap) editorWrap.hidden = !hasCurrent;
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
				'class': 'cbi-button ' + (name === currentRuleset ? 'cbi-button-apply' : 'cbi-button-neutral') + ' sbox-ruleset-list-item'
			}, name);

			button.addEventListener('click', async () => {
				currentRuleset = name;
				renderRulesetList();
				refreshToolbarState();
				await ensureRulesetEditor();
				const content = rulesetCache[currentRuleset] != null
					? rulesetCache[currentRuleset]
					: await L.resolveDefault(view_miclash_rulesets_model.readFile(currentRuleset), '');
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
		await ensureRulesetEditor();
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
			await ensureRulesetEditor();
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
			setOperationStatus('running', _('Saving ruleset...'));
			const raw = String(rulesetMainEditor.getValue() || '').replace(/\r\n/g, '\n');
			const finalContent = raw.trim() ? raw.trimEnd() + '\n' : '';
			await saveRulesetFile(currentRuleset, finalContent);
			rulesetCache[currentRuleset] = finalContent;
			setOperationSuccess(_('Ruleset "%s" saved.').format(currentRuleset));
			notify('info', _('Ruleset "%s" saved.').format(currentRuleset));
		}).catch((e) => {
			setOperationError(e);
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
		rulesetWhitelistEditor = await view_miclash_editor.createEditor('sbox-ruleset-whitelist-editor', data.whitelistContent || '', { mode: 'text' });
		rulesetWhitelistEditor.clearSelection();

		saveWhitelistBtn.addEventListener('click', () => withButtons(saveWhitelistBtn, async () => {
			setOperationStatus('running', _('Saving IP-CIDR list...'));
			const raw = String(rulesetWhitelistEditor.getValue() || '').replace(/\r\n/g, '\n');
			const finalContent = raw.trim() ? raw.trimEnd() + '\n' : '';
			await saveRulesetWhitelist(finalContent);
			setOperationSuccess(_('IP-CIDR list saved and firewall rules updated.'));
			notify('info', _('IP-CIDR list saved and firewall rules updated.'));
		}).catch((e) => {
			setOperationError(e);
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
	lines.push([ _('Operating mode'), s.mode === 'explicit' ? _('Selected interfaces') : _('Exclusions') ]);

	if (s.mode === 'explicit') {
		if (s.autoDetectLan && appState.detectedLan) lines.push([ _('Interfaces'), appState.detectedLan ]);
	} else {
		if (s.autoDetectWan && appState.detectedWan) lines.push([ _('WAN'), appState.detectedWan ]);
	}

	const manual = (s.mode === 'explicit' ? s.includedInterfaces : s.excludedInterfaces) || [];
	if (manual.length) {
		lines.push([ _('Interfaces'), manual.join(', ') ]);
	}

	lines.push([ _('Proxy Mode'), s.proxyMode || appState.proxyMode || 'tproxy' ]);
	lines.push([ _('Tun stack'), s.tunStack || 'system' ]);

	return lines.map((line) =>
		'<div class="sbox-diagnostics-row">' +
			'<span class="sbox-diagnostics-label">' + safeText(line[0]) + '</span>' +
			'<span class="sbox-diagnostics-value">' + safeText(line[1]) + '</span>' +
		'</div>'
	).join('');
}

function buildAutoUpdateIntervalOptionsHtml(current, fixed) {
	const preset = AUTO_UPDATE_PRESET_INTERVAL_HOURS.includes(current);
	const values = fixed ? [current] : preset ? AUTO_UPDATE_PRESET_INTERVAL_HOURS : [current];
	return values.map((value) =>
		'<label class="sbox-auto-update-choice">' +
			'<input type="radio" name="sbox-auto-update-interval" value="' + safeText(value) + '"' + (value === current ? ' checked' : '') + ' />' +
			'<span>' + safeText(_('%s h').format(value)) + '</span>' +
		'</label>'
	).join('');
}

function buildAutoUpdateIntervalChoicesHtml(settings) {
	const current = normalizeAutoUpdateIntervalHours(settings && settings.autoUpdateIntervalHours || '4') || '4';
	const provider = settings?.autoUpdateIntervalSource === 'provider';

	return '' +
		'<span class="sbox-auto-update-every">' + safeText(_('Every:')) + '</span>' +
		'<span id="sbox-auto-update-interval" class="sbox-auto-update-interval"' + (settings && settings.autoUpdateConfig !== false ? '' : ' hidden') + '>' +
			buildAutoUpdateIntervalOptionsHtml(current, provider) +
		'</span>' +
		(provider ? '<span id="sbox-auto-update-provider" class="sbox-muted sbox-auto-update-provider">' +
			safeText(_('Interval set by subscription')) + '</span>' : '');
}

function refreshAutoUpdateIntervalChoices(hours) {
	const current = normalizeAutoUpdateIntervalHours(hours);
	if (!current) return;
	if (appState.settings) {
		appState.settings.autoUpdateIntervalHours = current;
		appState.settings.autoUpdateIntervalStored = true;
		appState.settings.autoUpdateIntervalSource = 'provider';
	}
	const choices = pageRoot?.querySelector('#sbox-auto-update-interval');
	if (choices) choices.innerHTML = buildAutoUpdateIntervalOptionsHtml(current, true);
	const provider = pageRoot?.querySelector('#sbox-auto-update-provider');
	if (!provider && choices?.parentNode) {
		const note = E('span', { id: 'sbox-auto-update-provider',
			'class': 'sbox-muted sbox-auto-update-provider' }, _('Interval set by subscription'));
		choices.parentNode.appendChild(note);
	}
}

function buildReleaseChannelSectionHtml(settings) {
	const s = settings || {};

	return '' +
		'<article class="sbox-release-channel-section sbox-settings-card sbox-updates-card">' +
			'<h4>' + safeText(_('Release channels')) + '</h4>' +
			'<div class="sbox-release-channel-grid">' +
				'<div class="sbox-release-channel-column">' +
					'<div class="sbox-release-channel-title">MiClash</div>' +
					'<label class="sbox-radio-row">' +
						'<input type="radio" name="sbox-miclash-release-channel" value="release"' + (normalizeReleaseChannel(s.miclashReleaseChannel) === 'release' ? ' checked' : '') + ' />' +
						'<span>' + safeText(_('Latest')) + '</span>' +
					'</label>' +
					'<label class="sbox-radio-row">' +
						'<input type="radio" name="sbox-miclash-release-channel" value="prerelease"' + (normalizeReleaseChannel(s.miclashReleaseChannel) === 'prerelease' ? ' checked' : '') + ' />' +
						'<span>' + safeText(_('Pre-release')) + '</span>' +
					'</label>' +
				'</div>' +
				'<div class="sbox-release-channel-column">' +
					'<div class="sbox-release-channel-title">Mihomo</div>' +
					'<label class="sbox-radio-row">' +
						'<input type="radio" name="sbox-mihomo-release-channel" value="release"' + (normalizeReleaseChannel(s.mihomoReleaseChannel) === 'release' ? ' checked' : '') + ' />' +
						'<span>' + safeText(_('Latest')) + '</span>' +
					'</label>' +
					'<label class="sbox-radio-row">' +
						'<input type="radio" name="sbox-mihomo-release-channel" value="prerelease"' + (normalizeReleaseChannel(s.mihomoReleaseChannel) === 'prerelease' ? ' checked' : '') + ' />' +
						'<span>' + safeText(_('Pre-release')) + '</span>' +
					'</label>' +
				'</div>' +
			'</div>' +
			'<div class="sbox-major-update-policy">' +
				'<label class="sbox-checkbox-row">' +
					'<input type="checkbox" id="sbox-auto-major-miclash"' + (s.autoMajorMiclash !== false ? ' checked' : '') + ' />' +
					'<span>' + safeText(_('Automatically install major MiClash updates at night')) + '</span>' +
				'</label>' +
			'</div>' +
		'</article>';
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
				'<label class="sbox-interface-item">' +
				'<input type="checkbox" class="sbox-interface-check" value="' + safeText(iface.name) + '"' + (isChecked ? ' checked' : '') + ' />' +
				'<span>' + safeText(iface.name) + (isAuto ? ' <span class="sbox-muted">(' + safeText(_('auto')) + ')</span>' : '') + '</span>' +
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

	return '<div class="sbox-interface-groups">' + chunks.join('') + '</div>';
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
		enableMemoryGuard: false,
		autoUpdateConfig: true,
		autoUpdateIntervalHours: '4',
		autoMajorMiclash: true,
		miclashReleaseChannel: 'release',
		mihomoReleaseChannel: 'release',
		enableHwid: false,
		hwidUserAgent: 'MiClash',
		hwidDeviceOS: 'OpenWrt'
	};

	const currentProxyMode = appState.proxyMode || s.proxyMode || 'tproxy';
	const showTunStack = currentProxyMode === 'tun' || currentProxyMode === 'mixed';

	return '' +
		'<div class="sbox-settings-page">' +
			'<section class="sbox-settings-zone sbox-settings-zone-overview" aria-label="MiClash">' +
				'<div class="sbox-overview-grid">' +
					'<article id="sbox-settings-status" class="sbox-settings-card sbox-overview-card sbox-overview-routing">' +
						'<h4>' + safeText(_('Routing')) + '</h4>' +
						'<div class="sbox-settings-summary-current">' + buildSettingsSummary() + '</div>' +
						'<div class="sbox-diagnostics-actions">' +
							'<button type="button" class="cbi-button cbi-button-neutral" data-action="route-test">' + safeText(_('Route test')) + '</button>' +
						'</div>' +
					'</article>' +
					'<div id="sbox-diagnostics-summary" class="sbox-diagnostics-summary"></div>' +
				'</div>' +
			'</section>' +

			'<section class="sbox-settings-zone sbox-settings-zone-routing">' +
				'<div class="sbox-settings-card sbox-routing-composite">' +
					'<div class="sbox-routing-config-grid">' +
						'<div class="sbox-settings-subgroup sbox-traffic-scope">' +
							'<h4>' + safeText(_('Traffic Scope')) + '</h4>' +
							'<label class="sbox-radio-row">' +
								'<input type="radio" name="sbox-interface-mode" value="exclude"' + (s.mode !== 'explicit' ? ' checked' : '') + ' />' +
								'<span>' + safeText(_('Exclude mode: proxy all interfaces except selected ones')) + '</span>' +
							'</label>' +
							'<label class="sbox-radio-row">' +
								'<input type="radio" name="sbox-interface-mode" value="explicit"' + (s.mode === 'explicit' ? ' checked' : '') + ' />' +
								'<span>' + safeText(_('Explicit mode: proxy only selected interfaces')) + '</span>' +
							'</label>' +
						'</div>' +
						'<div class="sbox-settings-subgroup sbox-routing-detection">' +
							'<h4>' + safeText(_('Auto Detection')) + '</h4>' +
							'<label class="sbox-checkbox-row" id="sbox-auto-lan-row"' + (s.mode === 'explicit' ? '' : ' hidden') + '>' +
								'<input type="checkbox" id="sbox-auto-lan"' + (s.autoDetectLan ? ' checked' : '') + ' />' +
								'<span>' + safeText(_('Auto detect LAN bridge')) + '</span>' +
							'</label>' +
							'<label class="sbox-checkbox-row" id="sbox-auto-wan-row"' + (s.mode !== 'explicit' ? '' : ' hidden') + '>' +
								'<input type="checkbox" id="sbox-auto-wan"' + (s.autoDetectWan ? ' checked' : '') + ' />' +
								'<span>' + safeText(_('Auto detect WAN interface')) + '</span>' +
							'</label>' +
							'<div class="sbox-detected-facts sbox-muted">' +
								'<span>' + safeText(_('Detected LAN: %s').format(appState.detectedLan || '-')) + '</span>' +
								'<span>' + safeText(_('Detected WAN: %s').format(appState.detectedWan || '-')) + '</span>' +
							'</div>' +
						'</div>' +
					'</div>' +
					'<div class="sbox-card-divider"></div>' +
					'<div class="sbox-interface-section">' +
						'<h4>' + safeText(_('Interfaces')) + '</h4>' +
						'<div class="sbox-muted sbox-settings-help">' +
							(s.mode === 'explicit' ? safeText(_('Choose interfaces that should go through proxy.')) : safeText(_('Choose interfaces that should bypass proxy.'))) +
						'</div>' +
						buildInterfaceListHtml() +
					'</div>' +
				'</div>' +
			'</section>' +

			'<section class="sbox-settings-zone sbox-settings-zone-updates">' +
				'<div class="sbox-settings-pair-grid">' +
					buildReleaseChannelSectionHtml(s) +
					'<article class="sbox-settings-card sbox-runtime-card">' +
						'<h4>' + safeText(_('Additional')) + '</h4>' +
						'<div id="sbox-tun-stack-row" class="sbox-settings-field"' + (showTunStack ? '' : ' hidden') + '>' +
							'<label for="sbox-tun-stack">' + safeText(_('Tun stack')) + '</label>' +
							'<select id="sbox-tun-stack" class="cbi-input-select sbox-select">' +
								'<option value="system"' + ((s.tunStack || 'system') === 'system' ? ' selected' : '') + '>system</option>' +
								'<option value="gvisor"' + ((s.tunStack || 'system') === 'gvisor' ? ' selected' : '') + '>gvisor</option>' +
								'<option value="mixed"' + ((s.tunStack || 'system') === 'mixed' ? ' selected' : '') + '>mixed</option>' +
							'</select>' +
						'</div>' +
						'<div class="sbox-runtime-switches">' +
							'<label class="sbox-checkbox-row"><input type="checkbox" id="sbox-block-quic"' + (s.blockQuic ? ' checked' : '') + ' /><span>' + safeText(_('Block QUIC (UDP/443)')) + '</span></label>' +
							'<label class="sbox-checkbox-row"><input type="checkbox" id="sbox-internet-only-miclash"' + (s.internetOnlyMiclash ? ' checked' : '') + ' /><span>' + safeText(_('Direct connection guard')) + '</span></label>' +
							'<label class="sbox-checkbox-row"><input type="checkbox" id="sbox-tmpfs"' + (s.useTmpfsRules ? ' checked' : '') + ' /><span>' + safeText(_('Store rules/providers on tmpfs')) + '</span></label>' +
							'<label class="sbox-checkbox-row sbox-auto-update-row">' +
								'<input type="checkbox" id="sbox-auto-update-config"' + (s.autoUpdateConfig !== false ? ' checked' : '') + ' />' +
								'<span>' + safeText(_('Auto-update config')) + '</span>' +
								buildAutoUpdateIntervalChoicesHtml(s) +
							'</label>' +
							'<label class="sbox-checkbox-row"><input type="checkbox" id="sbox-enable-hwid"' + (s.enableHwid ? ' checked' : '') + ' /><span>' + safeText(_('Inject HWID headers into proxy-providers')) + '</span></label>' +
						'</div>' +
						'<div class="sbox-form-grid sbox-hwid-fields"' + (s.enableHwid ? '' : ' hidden') + '>' +
								'<div><label for="sbox-hwid-user-agent">' + safeText(_('User-Agent')) + '</label><input id="sbox-hwid-user-agent" class="cbi-input-text sbox-input" type="text" value="' + safeText(s.hwidUserAgent || 'MiClash') + '" /></div>' +
								'<div><label for="sbox-hwid-device-os">' + safeText(_('Device OS')) + '</label><input id="sbox-hwid-device-os" class="cbi-input-text sbox-input" type="text" value="' + safeText(s.hwidDeviceOS || 'OpenWrt') + '" /></div>' +
						'</div>' +
					'</article>' +
				'</div>' +
			'</section>' +

			'<section class="sbox-settings-zone sbox-settings-zone-integrations">' +
				'<div id="sbox-management-panels" class="sbox-management-grid">' +
					'<section id="sbox-management-settings" class="sbox-management-module sbox-management-settings"></section>' +
				'</div>' +
			'</section>' +

			'<section class="sbox-settings-zone sbox-settings-zone-devices">' +
				'<section id="sbox-management-devices" class="sbox-settings-card sbox-management-module sbox-management-wide"></section>' +
			'</section>' +

			'<div class="sbox-settings-save-wrap">' +
				'<button id="sbox-settings-save" type="button" class="cbi-button cbi-button-apply sbox-settings-save-btn">' + safeText(_('Apply Settings')) + '</button>' +
			'</div>' +
		'</div>';
}

function buildConfigOptionsHtml() {
	return (appState.configProfiles || CONFIG_PROFILES).map((item) =>
		'<option value="' + safeText(item.name) + '"' +
		(item.name === appState.selectedConfigName ? ' selected' : '') +
		'>' + safeText(_(item.label)) + '</option>'
	).join('');
}

function buildPageHtml() {
	const appActionState = resolveAppActionState();
	const kernelActionState = resolveKernelActionState();
	const dashboardButtonState = resolveDashboardButtonState();
	const metadataReady = appState.systemMetadataReady === true;
	const versionLoadingClass = metadataReady ? '' : ' class="sbox-version-loading"';
	const versionLoadingState = metadataReady ? '' : ' aria-busy="true" aria-label="' + safeText(_('Loading…')) + '"';
	const versionApp = metadataReady ? safeText(appState.versions.app || _('unknown')) : '';
	const appTarget = appActionState.scheduled && appActionState.targetVersion
		? ' data-target-version="' + safeText(appActionState.targetVersion) + '"' : '';
	const versionKernel = metadataReady ? safeText(
		appState.kernelStatus && appState.kernelStatus.installed
			? (appState.kernelStatus.version || appState.versions.clash || _('Installed'))
			: _('Not installed')
	) : '';
	const guardHeader = resolveGuardHeaderState();
	const guardLoadingState = guardHeader.loading
		? ' aria-busy="true" aria-label="' + safeText(_('Loading…')) + '"' : '';

	return '' +
		'<div class="sbox-header">' +
			'MiClash <span class="sbox-version-inline">' +
				'<strong id="sbox-app-version" data-developer-toggle' + versionLoadingClass + versionLoadingState + '>' + versionApp + '</strong>' +
				'<button id="sbox-app-action" type="button" class="cbi-button ' + appActionState.className + ' sbox-version-action-button" title="' + safeText(appActionState.title) + '" aria-label="' + safeText(appActionState.title) + '"' + appTarget + (metadataReady ? '' : ' hidden') + '>' + buildVersionActionIcon(appActionState) + '</button>' +
			'</span>' +
			'mihomo <span class="sbox-version-inline">' +
				'<strong id="sbox-kernel-version"' + versionLoadingClass + versionLoadingState + '>' + versionKernel + '</strong>' +
				'<button id="sbox-kernel-action" type="button" class="cbi-button ' + kernelActionState.className + ' sbox-version-action-button" title="' + safeText(kernelActionState.title) + '" aria-label="' + safeText(kernelActionState.title) + '"' + (metadataReady ? '' : ' hidden') + '>' + buildVersionActionIcon(kernelActionState) + '</button>' +
			'</span>' +
			'<span class="sbox-proxy-mode-inline">' + safeText(_('Mode')) + '</span>' +
			'<select id="sbox-mode-select" class="cbi-input-select sbox-mode-select" aria-label="' + safeText(_('Mode')) + '">' +
				'<option value="tproxy"' + (appState.proxyMode === 'tproxy' ? ' selected' : '') + '>tproxy</option>' +
				'<option value="tun"' + (appState.proxyMode === 'tun' ? ' selected' : '') + '>tun</option>' +
				'<option value="mixed"' + (appState.proxyMode === 'mixed' ? ' selected' : '') + '>mixed</option>' +
			'</select>' +
			'<span id="sbox-guard" class="sbox-guard-state-label ' + guardHeader.className + '" title="' + safeText(_('Direct connection guard')) + '"' + guardLoadingState + '>' +
				'<span class="sbox-guard-label">' + safeText(_('Guard')) + ': </span>' +
				'<span id="sbox-guard-state" class="sbox-guard-state">' + safeText(guardHeader.label) + '</span>' +
			'</span>' +
			'<button id="sbox-dashboard" type="button" class="cbi-button ' + dashboardButtonState.className + ' sbox-header-button sbox-btn-dashboard"' +
				(dashboardButtonState.disabled ? ' disabled' : '') +
			'>' + safeText(_('Dashboard')) + '</button>' +
		'</div>' +

		'<div class="cbi-section">' +
			'<div class="cbi-tabmenu sbox-tabs">' +
				'<button type="button" class="cbi-tab sbox-tab" data-ctrl-tab="control">' + safeText(_('Control')) + '</button>' +
			'</div>' +

				'<div id="sbox-pane-control">' +
					'<div class="sbox-row">' +
						'<span id="sbox-status" class="sbox-status ' + (appState.serviceRunning ? 'sbox-status-on' : 'sbox-status-off') + '">' +
							'<span id="sbox-status-label">' + safeText(appState.serviceStateLoading ? _('Loading service state…') : (appState.serviceRunning ? _('Service running') : _('Service stopped'))) + '</span>' +
						'</span>' +
						'<button id="sbox-start" type="button" class="cbi-button cbi-button-positive sbox-service-button"' + (appState.serviceRunning ? ' hidden' : '') + '>' + safeText(_('Start')) + '</button>' +
						'<button id="sbox-stop" type="button" class="cbi-button cbi-button-negative sbox-service-button"' + (appState.serviceRunning ? '' : ' hidden') + '>' + safeText(_('Stop core')) + '</button>' +
						'<button id="sbox-restart" type="button" class="cbi-button cbi-button-apply"' + (appState.serviceRunning ? '' : ' hidden') + '>' + safeText(_('Restart')) + '</button>' +
					'</div>' +
					'<div id="sbox-operation-status" class="sbox-operation-status" role="status" aria-live="polite" aria-atomic="true" hidden></div>' +
				'</div>' +
		'</div>' +

		'<div class="cbi-section">' +
			'<div class="cbi-tabmenu sbox-tabs">' +
				'<button type="button" class="cbi-tab sbox-tab" data-cfg-tab="config">' + safeText(_('Config')) + '</button>' +
				'<button type="button" class="cbi-tab-disabled sbox-tab" data-cfg-tab="settings">' + safeText(_('Settings')) + '</button>' +
				'<button type="button" class="cbi-tab-disabled sbox-tab" data-cfg-tab="logs">' + safeText(_('Logs')) + '</button>' +
				'<button id="sbox-developer-tab" type="button" class="cbi-tab-disabled sbox-tab" data-cfg-tab="developer" hidden>' + safeText(_('Developer')) + '</button>' +
			'</div>' +

				'<div id="sbox-pane-config">' +
					'<div class="sbox-config-toolbar">' +
						'<select id="sbox-config-select" class="cbi-input-select sbox-select" aria-label="' + safeText(_('Config')) + '" disabled>' + buildConfigOptionsHtml() + '</select>' +
						'<input id="sbox-subscription-url" class="cbi-input-text sbox-input" type="text" aria-label="' + safeText(_('Subscription URL')) + '" placeholder="https://..." value="' + safeText(appState.subscriptionUrl || '') + '" disabled />' +
						'<div class="sbox-subscription-actions">' +
							'<button id="sbox-save-sub-url" type="button" class="cbi-button cbi-button-positive sbox-subscription-action" disabled>' + safeText(_('Save')) + '</button>' +
							'<button id="sbox-update-sub" type="button" class="cbi-button cbi-button-apply sbox-subscription-action" disabled>' + safeText(_('Update')) + '</button>' +
							'<button id="sbox-clear-sub-url" type="button" class="cbi-button cbi-button-negative sbox-url-clear-button sbox-icon-button" title="' + safeText(_('Clear subscription URL')) + '" aria-label="' + safeText(_('Clear subscription URL')) + '" disabled>' + buildInlineIcon('x', 'sbox-button-icon') + '</button>' +
						'</div>' +
					'</div>' +
					'<div id="miclash-editor" class="sbox-editor">' + view_miclash_ui_shell.loadingHtml({ kind: 'editor', lines: 8 }) + '</div>' +
					'<div class="sbox-actions">' +
						'<button id="sbox-validate" type="button" class="cbi-button cbi-button-apply" disabled>' + safeText(_('Validate')) + '</button>' +
						'<button id="sbox-save" type="button" class="cbi-button cbi-button-positive" disabled>' + safeText(_('Apply')) + '</button>' +
						'<button id="sbox-clear-editor" type="button" class="cbi-button cbi-button-negative" disabled>' + safeText(_('Clear editor content')) + '</button>' +
						'<button id="sbox-set-main-config" type="button" class="cbi-button cbi-button-apply sbox-action-right" disabled' + (appState.selectedConfigName === MAIN_CONFIG_NAME ? ' hidden' : '') + '>' + safeText(_('Set as Main')) + '</button>' +
						'<span class="sbox-actions-spacer" aria-hidden="true"></span>' +
						'<button id="sbox-open-rulesets" type="button" class="cbi-button cbi-button-neutral sbox-rulesets-action" disabled>' + safeText(_('Rulesets')) + '</button>' +
					'</div>' +
				'</div>' +

			'<div id="sbox-pane-settings" hidden></div>' +

			'<div id="sbox-pane-logs" hidden>' +
				'<div id="sbox-log-search" class="sbox-log-search" hidden>' +
					'<input id="sbox-log-search-input" class="cbi-input-text sbox-input sbox-log-search-input" type="search" placeholder="' + safeText(_('Search logs')) + '" />' +
					'<button id="sbox-log-search-next" type="button" class="cbi-button cbi-button-neutral sbox-log-search-button" aria-label="' + safeText(_('Next match')) + '">↓</button>' +
					'<span id="sbox-log-search-count" class="sbox-log-search-count">0 / 0</span>' +
					'<button id="sbox-log-search-previous" type="button" class="cbi-button cbi-button-neutral sbox-log-search-button" aria-label="' + safeText(_('Previous match')) + '">↑</button>' +
				'</div>' +
				'<pre id="sbox-log-content" class="sbox-log-content">' +
					view_miclash_ui_shell.loadingHtml({ kind: 'editor', lines: 7 }) +
				'</pre>' +
			'</div>' +

			'<div id="sbox-pane-developer" class="sbox-developer-pane" hidden>' +
				'<div class="sbox-developer-intro">' +
					'<h4>' + safeText(_('Developer tools')) + '</h4>' +
					'<p>' + safeText(_('This hidden session stays open for 10 minutes. These emergency actions can interrupt access to the router.')) + '</p>' +
				'</div>' +
				'<div id="sbox-performance-panel"></div>' +
				'<div class="sbox-developer-actions">' +
					'<article class="sbox-settings-card sbox-developer-action">' +
						'<div><h4>' + safeText(_('Restore OpenWrt network')) + '</h4><p>' + safeText(_('Stop Mihomo and remove MiClash DNS, firewall and routing ownership. Remove Guard first if it is enabled.')) + '</p></div>' +
						'<button type="button" class="cbi-button cbi-button-negative" data-developer-action="restore-network">' + safeText(_('Restore network')) + '</button>' +
					'</article>' +
					'<article class="sbox-settings-card sbox-developer-action">' +
						'<div><h4>' + safeText(_('Remove Guard')) + '</h4><p>' + safeText(_('Disable Guard and remove its active fail-closed rules.')) + '</p></div>' +
						'<button type="button" class="cbi-button cbi-button-negative" data-developer-action="remove-guard">' + safeText(_('Remove Guard')) + '</button>' +
					'</article>' +
					'<article class="sbox-settings-card sbox-developer-action">' +
						'<div><h4>' + safeText(_('Remove MiClash')) + '</h4><p>' + safeText(_('Remove MiClash through the OpenWrt package manager after its normal network cleanup.')) + '</p></div>' +
						'<button type="button" class="cbi-button cbi-button-negative" data-developer-action="remove-miclash">' + safeText(_('Remove MiClash')) + '</button>' +
					'</article>' +
				'</div>' +
			'</div>' +
		'</div>';
}

function updateHeaderAndControlDom() {
	if (!pageRoot) return;

	const status = pageRoot.querySelector('#sbox-status');
	const statusLabel = pageRoot.querySelector('#sbox-status-label');
	const startBtn = pageRoot.querySelector('#sbox-start');
	const stopBtn = pageRoot.querySelector('#sbox-stop');
	const restartBtn = pageRoot.querySelector('#sbox-restart');
	const dashboardBtn = pageRoot.querySelector('#sbox-dashboard');
	const operationStatus = pageRoot.querySelector('#sbox-operation-status');
	const appVersion = pageRoot.querySelector('#sbox-app-version');
	const appAction = pageRoot.querySelector('#sbox-app-action');
	const kernelVersion = pageRoot.querySelector('#sbox-kernel-version');
	const kernelAction = pageRoot.querySelector('#sbox-kernel-action');
	const modeSelect = pageRoot.querySelector('#sbox-mode-select');
	const serviceBusy = !!appState.serviceActionBusy || !!appState.serviceJobBusy || !!appState.updateJobBusy;

	if (status && statusLabel) {
		status.classList.toggle('sbox-status-on', !appState.serviceStateLoading && appState.serviceRunning);
		status.classList.toggle('sbox-status-off', !appState.serviceStateLoading && !appState.serviceRunning);
		statusLabel.textContent = appState.serviceStateLoading ? _('Loading service state…') :
			(appState.serviceRunning ? _('Service running') : _('Service stopped'));
	}

	if (startBtn) {
		if (!serviceBusy) startBtn.hidden = appState.serviceRunning;
		startBtn.disabled = serviceBusy || appState.serviceStateLoading || appState.serviceRunning;
	}

	if (stopBtn) {
		if (!serviceBusy) stopBtn.hidden = !appState.serviceRunning;
		stopBtn.disabled = serviceBusy || appState.serviceStateLoading || !appState.serviceRunning;
	}

	if (restartBtn) {
		if (!serviceBusy) restartBtn.hidden = !appState.serviceRunning;
		restartBtn.disabled = serviceBusy || appState.serviceStateLoading || !appState.serviceRunning;
	}

	if (operationStatus) {
		const state = appState.operationStatus;
		if (!state || !state.message) {
			operationStatus.hidden = true;
			operationStatus.innerHTML = '';
			operationStatus.className = 'sbox-operation-status';
			operationStatus.removeAttribute('title');
			operationStatus.setAttribute('role', 'status');
			operationStatus.setAttribute('aria-live', 'polite');
		} else {
			const type = /^(running|error|success)$/.test(String(state.type || '')) ? state.type : 'running';
			operationStatus.hidden = false;
			operationStatus.className = 'sbox-operation-status sbox-operation-status-' + type;
			operationStatus.setAttribute('role', type === 'error' ? 'alert' : 'status');
			operationStatus.setAttribute('aria-live', type === 'error' ? 'assertive' : 'polite');
			operationStatus.innerHTML =
				'<span class="sbox-operation-status-content">' +
				'<span class="sbox-operation-status-message">' + safeText(state.message) + '</span>' +
				'</span>' + (state.dismissible ?
				'<button type="button" class="cbi-button cbi-button-neutral sbox-operation-dismiss" aria-label="' + safeText(_('Dismiss')) + '">' + safeText(_('Dismiss')) + '</button>' : '');
			operationStatus.title = state.message;
			const dismiss = operationStatus.querySelector('.sbox-operation-dismiss');
			if (dismiss) dismiss.addEventListener('click', clearOperationStatus, { once: true });
		}
	}

	if (dashboardBtn) {
		const dashboardState = resolveDashboardButtonState();
		dashboardBtn.disabled = serviceBusy || dashboardState.disabled;
		dashboardBtn.className = 'cbi-button ' +
			dashboardState.className +
			' sbox-header-button sbox-btn-dashboard';
		dashboardBtn.title = dashboardState.title;
		dashboardBtn.setAttribute('aria-label', dashboardState.title);
	}

	if (appVersion) {
		appVersion.classList.toggle('sbox-version-loading', !appState.systemMetadataReady);
		appVersion.toggleAttribute('aria-busy', !appState.systemMetadataReady);
		if (appState.systemMetadataReady) appVersion.removeAttribute('aria-label');
		else appVersion.setAttribute('aria-label', _('Loading…'));
		appVersion.textContent = appState.systemMetadataReady ? (appState.versions.app || _('unknown')) : '';
	}
	if (appAction && !appAction.classList.contains('sbox-version-action-busy')) {
		appAction.hidden = !appState.systemMetadataReady;
		const appActionState = resolveAppActionState();
		appAction.classList.remove('cbi-button-positive', 'cbi-button-neutral');
		appAction.classList.add(appActionState.className);
		appAction.innerHTML = buildVersionActionIcon(appActionState);
		appAction.title = appActionState.title;
		appAction.setAttribute('aria-label', appActionState.title);
		if (appActionState.scheduled && appActionState.targetVersion)
			appAction.setAttribute('data-target-version', appActionState.targetVersion);
		else
			appAction.removeAttribute('data-target-version');
	}
	if (kernelVersion) {
		kernelVersion.classList.toggle('sbox-version-loading', !appState.systemMetadataReady);
		kernelVersion.toggleAttribute('aria-busy', !appState.systemMetadataReady);
		if (appState.systemMetadataReady) kernelVersion.removeAttribute('aria-label');
		else kernelVersion.setAttribute('aria-label', _('Loading…'));
		kernelVersion.textContent = !appState.systemMetadataReady ? '' : appState.kernelStatus && appState.kernelStatus.installed
			? (appState.kernelStatus.version || appState.versions.clash || _('Installed'))
			: _('Not installed');
	}
	if (kernelAction && !kernelAction.classList.contains('sbox-version-action-busy')) {
		kernelAction.hidden = !appState.systemMetadataReady;
		const kernelActionState = resolveKernelActionState();
		kernelAction.classList.remove('cbi-button-positive', 'cbi-button-neutral');
		kernelAction.classList.add(kernelActionState.className);
		kernelAction.innerHTML = buildVersionActionIcon(kernelActionState);
		kernelAction.title = kernelActionState.title;
		kernelAction.setAttribute('aria-label', kernelActionState.title);
	}
	if (modeSelect) modeSelect.value = normalizeProxyMode(appState.proxyMode);

	const guardPill = pageRoot.querySelector('#sbox-guard');
	const guardState = pageRoot.querySelector('#sbox-guard-state');
	const guardHeader = resolveGuardHeaderState();
	if (guardPill) {
		guardPill.classList.remove('cbi-button', 'cbi-button-apply', 'cbi-button-neutral', 'cbi-button-positive', 'cbi-button-negative');
		guardPill.classList.remove('sbox-guard-on', 'sbox-guard-off', 'sbox-guard-error', 'sbox-guard-unknown', 'sbox-guard-loading');
		guardPill.classList.add(guardHeader.className);
		guardPill.title = _('Direct connection guard');
		guardPill.toggleAttribute('aria-busy', guardHeader.loading === true);
		if (guardHeader.loading) guardPill.setAttribute('aria-label', _('Loading…'));
		else guardPill.removeAttribute('aria-label');
	}
	if (guardState) guardState.textContent = guardHeader.label;
}

function isInternetOnlyEnabled() {
	return !!(appState.settings && appState.settings.internetOnlyMiclash);
}

function resolveGuardHeaderState() {
	const desired = isInternetOnlyEnabled();
	const observed = String(appState.guardObservedState || 'unknown');
	if (observed === 'loading') return { className: 'sbox-guard-loading', label: '', loading: true };
	if (desired && observed === 'enabled') return { className: 'sbox-guard-on', label: _('ON') };
	if (!desired && observed === 'disabled') return { className: 'sbox-guard-off', label: _('OFF') };
	if (observed === 'failed') return { className: 'sbox-guard-error', label: _('Error') };
	return { className: 'sbox-guard-unknown', label: _('Unknown') };
}

async function refreshHeaderAndControl() {
	const [serviceState, system, proxyMode] = await Promise.all([
		readMiClashServiceState(),
		typedCall((api) => api.system_info()),
		detectCurrentProxyMode()
	]);

	applyServiceState(serviceState);
	appState.versions = {
		app: normalizeAppVersion(system?.app_version || 'unknown'),
		clash: system?.mihomo?.installed ? String(system.mihomo.version || _('Installed')) : 'unknown'
	};
	appState.kernelStatus = {
		installed: system?.mihomo?.installed === true,
		version: system?.mihomo?.installed ? String(system.mihomo.version || '') : null
	};
	appState.proxyMode = proxyMode || 'tproxy';

	updateHeaderAndControlDom();
}

async function refreshServiceState() {
	const serviceState = await readMiClashServiceState();
	applyServiceState(serviceState);
	updateHeaderAndControlDom();
	return serviceState;
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

async function warmBackgroundPanels(generation, configHydration) {
	if (generation !== pageGeneration || !pageRoot || document.hidden) return;
	const metric = view_miclash_performance.begin('background.warmup');
	let succeeded = true;
	try {
		notificationOwner.replace();
		await managementOwner.refresh(true);
		if (generation !== pageGeneration || !pageRoot || document.hidden) return;
		const results = await Promise.allSettled([
			Promise.resolve(diagnosticsOwner.refresh(true)),
			refreshLogs()
		]);
		succeeded = results.every((result) => result.status === 'fulfilled');
		if (generation !== pageGeneration || !pageRoot || document.hidden) return;
		await configHydration;
		if (generation !== pageGeneration || !pageRoot || document.hidden) return;
		await refreshReleaseMeta({ force: false });
	} catch (error) {
		succeeded = false;
	} finally {
		view_miclash_performance.end(metric, succeeded);
	}
}

function renderSettingsPane() {
	if (!pageRoot) return;
	const pane = pageRoot.querySelector('#sbox-pane-settings');
	if (!pane) return;
	if (pane.getAttribute('data-settings-mounted') !== 'true') {
		pane.innerHTML = buildSettingsPaneHtml();
		bindSettingsPaneEvents();
		const diagnosticsHost = pane.querySelector('#sbox-diagnostics-summary');
		if (diagnosticsHost) diagnosticsOwner.mount(diagnosticsHost);
		if (!managementOwner.ready?.()) managementOwner.replace();
		managementOwner.mount(pane);
		pane.setAttribute('data-settings-mounted', 'true');
	}
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
	const autoUpdateConfigEl = pane.querySelector('#sbox-auto-update-config');
	const autoUpdateIntervalEl = pane.querySelector('input[name="sbox-auto-update-interval"]:checked');
	const autoUpdateConfig = autoUpdateConfigEl ? !!autoUpdateConfigEl.checked : true;
	const autoUpdateIntervalHours = normalizeAutoUpdateIntervalHours(autoUpdateIntervalEl?.value || '4') || '4';
	const autoUpdateIntervalSource = appState.settings?.autoUpdateIntervalSource === 'provider' ? 'provider' : 'manual';
	const autoMajorMiclashEl = pane.querySelector('#sbox-auto-major-miclash');
	const autoMajorMiclash = autoMajorMiclashEl ? !!autoMajorMiclashEl.checked : true;
	const enableHwid = !!pane.querySelector('#sbox-enable-hwid')?.checked;
	const hwidUserAgent = String(pane.querySelector('#sbox-hwid-user-agent')?.value || 'MiClash').trim() || 'MiClash';
	const hwidDeviceOS = String(pane.querySelector('#sbox-hwid-device-os')?.value || 'OpenWrt').trim() || 'OpenWrt';
	const miclashReleaseChannel = normalizeReleaseChannel(
		pane.querySelector('input[name="sbox-miclash-release-channel"]:checked')?.value || 'release'
	);
	const mihomoReleaseChannel = normalizeReleaseChannel(
		pane.querySelector('input[name="sbox-mihomo-release-channel"]:checked')?.value || 'release'
	);

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
		autoUpdateConfig,
		autoUpdateIntervalHours,
		autoUpdateIntervalSource,
		autoMajorMiclash,
		selected,
		enableHwid,
		hwidUserAgent,
		hwidDeviceOS,
		miclashReleaseChannel,
		mihomoReleaseChannel
	};
}

function updatesPatchFromForm(formState) {
	return {
		auto_subscription: formState.autoUpdateConfig !== false,
		interval_hours: parseInt(formState.autoUpdateIntervalHours || '4', 10),
		interval_source: formState.autoUpdateIntervalSource === 'provider' ? 'provider' : 'manual',
		miclash_release_channel: normalizeReleaseChannel(formState.miclashReleaseChannel),
		mihomo_release_channel: normalizeReleaseChannel(formState.mihomoReleaseChannel),
		auto_major_miclash: formState.autoMajorMiclash !== false
	};
}

async function saveAllSettings() {
	const pane = pageRoot?.querySelector('#sbox-pane-settings');
	const saveBtn = pane?.querySelector('#sbox-settings-save');
	if (!pane || !saveBtn) throw new Error(_('Settings are not ready.'));

	return withButtons(saveBtn, async () => {
		const formState = await collectSettingsFormState();
		if (!formState) return false;
		const managementPatch = managementOwner.collectPatch();
		const before = await configApi.settings_get();
		const previousMiClashReleaseChannel = normalizeReleaseChannel(
			before?.updates?.miclash_release_channel);
		const previousMihomoReleaseChannel = normalizeReleaseChannel(
			before?.updates?.mihomo_release_channel);
		const runtimeChanged = operationalSettingsChanged(appState.settings, formState, {
			detectedLan: appState.detectedLan,
			detectedWan: appState.detectedWan
		});
		setOperationStatus('running', _('Saving settings...'));

		await awaitTypedOperation(await configApi.settings_set({
			...managementPatch,
			updates: updatesPatchFromForm(formState)
		}, 'luci'), _('Saving settings...'));

		if (!!before?.guard?.enabled !== !!formState.internetOnlyMiclash) {
			setOperationStatus('running', _('Applying protection setting...'));
			await awaitTypedOperation(
				await configApi.guard_transition(!!formState.internetOnlyMiclash, 'luci'),
				_('Applying protection setting...')
			);
		}

		if (runtimeChanged) {
			setOperationStatus('running', _('Applying Mihomo settings...'));
			const applied = await saveOperationalSettings(
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
				formState.miclashReleaseChannel,
				formState.mihomoReleaseChannel,
				formState.autoUpdateConfig,
				formState.autoUpdateIntervalHours,
				formState.autoMajorMiclash,
				{ silent: true, skipGuard: true }
			);
			if (!applied) throw new Error(_('Failed to apply Mihomo settings.'));
		}

		await managementOwner.applyPending();

		appState.settings = await loadOperationalSettings();
		appState.selectedInterfaces = await loadInterfacesByMode(appState.settings.mode);
		appState.detectedLan = appState.settings.detectedLan || (await detectLanBridge()) || '';
		appState.detectedWan = appState.settings.detectedWan || (await detectWanInterface()) || '';
		appState.proxyMode = appState.settings.proxyMode || await detectCurrentProxyMode();
		appState.serviceRunning = await getServiceStatus();
		const releaseChannelChanged =
			normalizeReleaseChannel(appState.settings.miclashReleaseChannel) !== previousMiClashReleaseChannel ||
			normalizeReleaseChannel(appState.settings.mihomoReleaseChannel) !== previousMihomoReleaseChannel;

		if (runtimeChanged) {
			const freshConfig = await L.resolveDefault(
				readConfigFileByName(appState.selectedConfigName), '');
			appState.configContent = freshConfig;
			if (editor) {
				editor.setValue(String(freshConfig || ''), -1);
				editor.clearSelection();
			}
		}

		await refreshHeaderAndControl();
		if (releaseChannelChanged) await refreshReleaseMeta({ force: true });
		await managementOwner.markSaved();
		await logUiAction('info', runtimeChanged ?
			'Settings saved and Mihomo settings applied' : 'Settings saved without Mihomo restart');
		setOperationSuccess(runtimeChanged ? _('Settings saved and applied.') : _('Settings saved.'));
		notify('info', runtimeChanged ? _('Settings saved and applied.') : _('Settings saved.'));
		renderSettingsPane();
		updateHeaderAndControlDom();
		return true;
	}).catch((error) => {
		setOperationError(error);
		notify('error', _('Failed to save settings: %s').format(error.message));
		throw error;
	});
}

function bindSettingsPaneEvents() {
	const pane = pageRoot.querySelector('#sbox-pane-settings');
	if (!pane) return;
	const routeTestButton = pane.querySelector('[data-action="route-test"]');
	if (routeTestButton) routeTestButton.addEventListener('click', () => diagnosticsOwner.openRouteTest());

	pane.querySelectorAll('input[name="sbox-interface-mode"]').forEach((radio) => {
		radio.addEventListener('change', async function() {
			appState.settings.mode = this.value;
			appState.selectedInterfaces = await loadInterfacesByMode(this.value);
			renderSettingsPane();
		});
	});

	const autoUpdateConfigEl = pane.querySelector('#sbox-auto-update-config');
	const autoUpdateIntervalEl = pane.querySelector('#sbox-auto-update-interval');
	if (autoUpdateConfigEl && autoUpdateIntervalEl) {
		const syncAutoUpdateInterval = async () => {
			autoUpdateIntervalEl.hidden = !autoUpdateConfigEl.checked;
			autoUpdateIntervalEl.querySelectorAll('input').forEach((input) => {
				input.disabled = !autoUpdateConfigEl.checked;
			});
			if (autoUpdateConfigEl.checked && !(appState.settings && appState.settings.autoUpdateIntervalStored) && !appState.autoUpdateIntervalProbeBusy && !appState.autoUpdateIntervalProbeAttempted) {
				appState.autoUpdateIntervalProbeBusy = true;
				appState.autoUpdateIntervalProbeAttempted = true;
				try {
					await probeAutoUpdateIntervalFromSubscription();
					appState.settings = await loadOperationalSettings();
					if (appState.settings.autoUpdateIntervalStored) renderSettingsPane();
				} finally {
					appState.autoUpdateIntervalProbeBusy = false;
				}
			}
		};
		autoUpdateConfigEl.addEventListener('change', () => {
			if (autoUpdateConfigEl.checked) appState.autoUpdateIntervalProbeAttempted = false;
			syncAutoUpdateInterval();
		});
		syncAutoUpdateInterval();
	}
	pane.querySelectorAll('input[name="sbox-auto-update-interval"]').forEach((input) => {
		input.addEventListener('change', () => {
			if (appState.settings) appState.settings.autoUpdateIntervalSource = 'manual';
			pane.querySelector('#sbox-auto-update-provider')?.remove();
		});
	});

	const enableHwidEl = pane.querySelector('#sbox-enable-hwid');
	const hwidFields = pane.querySelector('.sbox-hwid-fields');
	if (enableHwidEl && hwidFields) {
		const syncHwidFields = () => { hwidFields.hidden = !enableHwidEl.checked; };
		enableHwidEl.addEventListener('change', syncHwidFields);
		syncHwidFields();
	}

	const saveBtn = pane.querySelector('#sbox-settings-save');
	if (saveBtn) saveBtn.addEventListener('click', () => saveAllSettings().catch(() => {}));
}

async function refreshLogs() {
	if (logsRefreshPromise) return logsRefreshPromise;
	logsRefreshPromise = (async () => {
		const raw = await loadClashLogs();
		appState.logsRaw = raw;
		logsLoaded = true;
		const content = pageRoot && pageRoot.querySelector('#sbox-log-content');
		if (content) {
			const nearBottom = (content.scrollHeight - content.scrollTop - content.clientHeight) < 48;
			renderLogs({ followBottom: nearBottom && !logSearch.query.trim() });
		}
	})().finally(() => { logsRefreshPromise = null; });
	return logsRefreshPromise;
}

function startLogPolling() {
	logPollTimer = view_miclash_ui_shell.startInterval(logPollTimer, () => {
		refreshLogs().catch(() => {});
	}, LOG_POLL_MS);
}

function stopLogPolling() {
	logPollTimer = view_miclash_ui_shell.stopInterval(logPollTimer);
}

function startControlPolling() {
	controlPollTimer = view_miclash_ui_shell.startInterval(controlPollTimer, async () => {
		if (document.hidden || controlPollBusy) return;
		controlPollBusy = true;
		try {
			await refreshServiceState();
		} catch (e) {
			try {
				appState.serviceRunning = await view_miclash_utils.getClashRunning();
				appState.serviceHealth = appState.serviceRunning ? 'unknown' : 'stopped';
				updateHeaderAndControlDom();
			} catch (statusError) {}
		} finally {
			controlPollBusy = false;
		}
	}, STATUS_POLL_MS, { replace: true });
}

function startUpdatePolling() {
	updatePollTimer = view_miclash_ui_shell.startInterval(updatePollTimer, () => {
		if (document.hidden) return;
		refreshReleaseMeta({ force: false }).catch(() => {});
	}, UPDATE_CHECK_MS, { replace: true });
}

function bindControlAndHeaderEvents() {
	const logSearchInput = pageRoot.querySelector('#sbox-log-search-input');
	const logSearchNext = pageRoot.querySelector('#sbox-log-search-next');
	const logSearchPrevious = pageRoot.querySelector('#sbox-log-search-previous');
	if (logSearchInput) logSearchInput.addEventListener('input', () => setLogSearchQuery(logSearchInput.value));
	if (logSearchNext) logSearchNext.addEventListener('click', () => moveLogSearchResult(1));
	if (logSearchPrevious) logSearchPrevious.addEventListener('click', () => moveLogSearchResult(-1));
	const kernelAction = pageRoot.querySelector('#sbox-kernel-action');
	const appAction = pageRoot.querySelector('#sbox-app-action');
	if (appAction) {
		const runAppAction = () => {
			if (appAction.classList.contains('sbox-version-action-busy')) return;
			const appActionKind = resolveAppActionState().kind;

			appAction.classList.add('sbox-version-action-busy');
			appAction.innerHTML = '<span class="sbox-spinner"></span>';

			installMiClashFromSettings(appActionKind).catch((e) => {
				setOperationError(e);
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
				setOperationError(e);
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
				setOperationStatus('running', _('Switching proxy mode...'));
				await switchProxyModeFromHeader(nextMode);
			} catch (e) {
				appState.proxyMode = previousMode;
				setOperationError(e);
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
					if (!(await validateMainConfigBeforeStart())) return;
					setOperationStatus('running', _('Starting Clash service...'));
					await runMiClashServiceJob('start', _('Starting Clash service...'));
					await logUiAction('info', 'Clash service started');
					setOperationSuccess(_('Clash service started successfully.'));
				});
				await refreshHeaderAndControlSafe();
			} catch (e) {
				await refreshHeaderAndControlSafe();
				setOperationError(e);
				await logUiAction('err', 'Unable to start service: ' + e.message);
				notify('error', _('Unable to start service: %s').format(e.message));
			}
		});
	}

	if (stopBtn) {
		stopBtn.addEventListener('click', async () => {
			try {
				await withServiceButtons(stopBtn, startBtn, async () => {
					setOperationStatus('running', _('Stopping Clash service...'));
					await runMiClashServiceJob('stop', _('Stopping Clash service...'));
					await logUiAction('info', 'Clash service stopped');
					setOperationSuccess(_('Clash service stopped successfully.'));
				});
				await refreshHeaderAndControlSafe();
			} catch (e) {
				await refreshHeaderAndControlSafe();
				setOperationError(e);
				await logUiAction('err', 'Unable to stop service: ' + e.message);
				notify('error', _('Unable to stop service: %s').format(e.message));
			}
		});
	}

	const restartBtn = pageRoot.querySelector('#sbox-restart');
	if (restartBtn) {
		restartBtn.addEventListener('click', () => withRestartButtonFeedback(async () => {
			if (!(await validateMainConfigBeforeStart())) return;
			setOperationStatus('running', _('Restarting Clash service...'));
			await restartOrReloadServiceOrThrow('restart', operationStageOptions(_('Restarting Clash service...')));
			await logUiAction('info', 'Clash service restarted');
			setOperationSuccess(_('Clash service restarted successfully.'));
			notify('info', _('Clash service restarted successfully.'));
			await refreshHeaderAndControl();
		}).catch((e) => {
			setOperationError(e);
			logUiAction('err', 'Failed to restart Clash service: ' + e.message);
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

function updateSetMainAvailability(content, profileName) {
	if (!pageRoot) return;
	const button = pageRoot.querySelector('#sbox-set-main-config');
	if (!button) return;
	const selected = normalizeConfigProfileName(profileName);
	const empty = !String(content || '').trim();
	button.hidden = selected === MAIN_CONFIG_NAME;
	button.disabled = selected === MAIN_CONFIG_NAME || empty || appState.configReady !== true;
	if (selected !== MAIN_CONFIG_NAME && empty)
		button.title = _('Save or download this config before setting it as Main.');
	else
		button.removeAttribute('title');
}

async function switchConfigProfile(profileName) {
	if (subscriptionUpdateBusy) throw new Error(_('An operation is already running.'));
	const selected = normalizeConfigProfileName(profileName);
	const [ content, url ] = await Promise.all([
		readConfigFileByName(selected), readSubscriptionUrl(selected)
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
		if (setMainBtn) updateSetMainAvailability(appState.configContent, selected);
	}
}

async function setSelectedConfigAsMain() {
	const selected = normalizeConfigProfileName(appState.selectedConfigName);
	if (selected === MAIN_CONFIG_NAME) return;
	setOperationStatus('running', _('Setting selected config as Main...'));

	await swapConfigProfiles(selected);
	appState.serviceRunning = await getServiceStatus();
	await switchConfigProfile(MAIN_CONFIG_NAME);
	await refreshHeaderAndControl();
	setOperationSuccess(_('%s is now main config.').format(_(getConfigLabel(selected))));

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
				body: _('Selected config will be swapped with Main config and saved. If Clash is running, it will reload; if stopped, it will remain stopped. Continue?'),
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
			setOperationError(e);
			notify('error', _('Failed to set main config: %s').format(e.message));
		}));
	}

	const saveUrlBtn = pageRoot.querySelector('#sbox-save-sub-url');
	if (saveUrlBtn) {
		saveUrlBtn.addEventListener('click', () => withButtons(saveUrlBtn, async () => {
			const url = String(subInput?.value || '').trim();
			if (!url) throw new Error(_('Subscription URL is empty.'));
			if (!isValidUrl(url)) throw new Error(_('Invalid subscription URL.'));

			const selectedConfig = normalizeConfigProfileName(appState.selectedConfigName);
			setOperationStatus('running', _('Saving subscription URL...'));
			await saveSubscriptionUrl(url, selectedConfig);
			appState.subscriptionUrl = url;
			updateHeaderAndControlDom();
			await logUiAction('info', 'Subscription URL saved for ' + getConfigLabel(selectedConfig));
			setOperationSuccess(_('Subscription URL saved.'));
			notify('info', _('Subscription URL saved.'));
		}).catch((e) => {
			setOperationError(e);
			notify('error', _('Failed to save subscription URL: %s').format(e.message));
		}));
	}

	const updateUrlBtn = pageRoot.querySelector('#sbox-update-sub');
	if (updateUrlBtn) {
		updateUrlBtn.addEventListener('click', () => withButtons(updateUrlBtn, async () => {
			const url = String(subInput?.value || '').trim();
			const selectedProfile = normalizeConfigProfileName(appState.selectedConfigName);
			const savedSubscription = url ? null : await typedCall((api) => api.subscription_get(selectedProfile));
			if (!url && !savedSubscription?.configured) throw new Error(_('Subscription URL is empty.'));
			if (url && !isValidUrl(url)) throw new Error(_('Invalid subscription URL.'));
			if (subscriptionUpdateBusy) throw new Error(_('An operation is already running.'));
			subscriptionUpdateBusy = true;
			const selectedConfig = selectedProfile;
			setOperationStatus('running', _('Saving subscription URL...'));
			if (url) await saveSubscriptionUrl(url, selectedConfig);
			appState.subscriptionUrl = url;
			appState.serviceRunning = await getServiceStatus();
			updateHeaderAndControlDom();

			await ensureMihomoKernelInstalled();
			await logUiAction('info', 'Subscription update started for ' + getConfigLabel(selectedConfig));
			setOperationStatus('running', _('Downloading subscription...'));

			const appliedInfo = await applySubscriptionOnRouter(selectedConfig);

			const freshConfig = await readConfigFileByName(selectedConfig);
			appState.configContent = String(freshConfig || '');
			updateSetMainAvailability(appState.configContent, selectedConfig);
			if (editor && selectedConfig === appState.selectedConfigName) {
				editor.setValue(appState.configContent, -1);
				editor.clearSelection();
			}

			let serviceReloaded = false;
			if (selectedConfig === MAIN_CONFIG_NAME) {
				await applySubscriptionProfileUpdateInterval(appliedInfo.profileUpdateIntervalHours);
				refreshAutoUpdateIntervalChoices(appliedInfo.profileUpdateIntervalHours);
				appState.serviceRunning = await getServiceStatus();
				serviceReloaded = appState.serviceRunning;
				updateHeaderAndControlDom();
			}

			if (serviceReloaded) {
				await logUiAction('info', 'Subscription downloaded and applied');
				setOperationSuccess(_('Subscription downloaded and applied.'));
				notify('info', _('Subscription downloaded and applied.'));
			} else {
				await logUiAction('info', getConfigLabel(selectedConfig) + ' downloaded and saved');
				setOperationSuccess(_('%s downloaded and saved.').format(_(getConfigLabel(selectedConfig))));
				notify('info', _('%s downloaded and saved.').format(_(getConfigLabel(selectedConfig))));
			}
		}).catch((e) => {
			setOperationError(e);
			logUiAction('err', 'Failed to apply subscription: ' + e.message);
			notify('error', _('Failed to apply subscription: %s').format(e.message));
		}).finally(async () => {
			subscriptionUpdateBusy = false;
			await view_miclash_subscription.cleanupTemp();
		}));
	}

	const clearUrlBtn = pageRoot.querySelector('#sbox-clear-sub-url');
	if (clearUrlBtn) {
		clearUrlBtn.addEventListener('click', () => withButtons(clearUrlBtn, async () => {
			const selectedConfig = normalizeConfigProfileName(appState.selectedConfigName);
			setOperationStatus('running', _('Clearing subscription URL...'));
			await saveSubscriptionUrl('', selectedConfig);
			appState.subscriptionUrl = '';
			if (subInput) subInput.value = '';
			updateHeaderAndControlDom();
			await logUiAction('info', 'Subscription URL cleared for ' + getConfigLabel(selectedConfig));
			setOperationSuccess(_('Subscription URL cleared.'));
			notify('info', _('Subscription URL cleared.'));
		}).catch((e) => {
			setOperationError(e);
			notify('error', _('Failed to clear subscription URL: %s').format(e.message));
		}));
	}

	const validateBtn = pageRoot.querySelector('#sbox-validate');
	if (validateBtn) {
		validateBtn.addEventListener('click', () => withButtons(validateBtn, async () => {
			if (!editor) return;
			if (subscriptionUpdateBusy) throw new Error(_('An operation is already running.'));
			const selectedConfig = normalizeConfigProfileName(appState.selectedConfigName);
			setOperationStatus('running', _('Validating YAML...'));
			await awaitTypedOperation(
				await configApi.config_validate(selectedConfig, editor.getValue(), 'luci'),
				_('Validating YAML...')
			);
			setOperationSuccess(_('YAML validation passed.'));
			notify('info', _('YAML validation passed.'));
		}).catch((e) => {
			setOperationError(e);
			notify('error', _('YAML validation failed: %s').format(e.message));
		}));
	}

	const saveBtn = pageRoot.querySelector('#sbox-save');
	if (saveBtn) {
		saveBtn.addEventListener('click', () => withButtons(saveBtn, async () => {
			if (!editor) return;
			if (subscriptionUpdateBusy) throw new Error(_('An operation is already running.'));
			setOperationStatus('running', _('Applying configuration...'));
			const selectedConfig = normalizeConfigProfileName(appState.selectedConfigName);
			const content = editor.getValue();
			await awaitTypedOperation(
				await configApi.config_apply(selectedConfig, editor.getValue(), 'luci'),
				_('Applying configuration...')
			);
			appState.configContent = content;
			updateSetMainAvailability(appState.configContent, selectedConfig);
			appState.serviceRunning = await getServiceStatus();
			updateHeaderAndControlDom();
			await logUiAction('info', 'Configuration applied: ' + selectedConfig);
			setOperationSuccess(_('Configuration applied.'));
			notify('info', _('Configuration applied.'));
		}).catch((e) => {
			setOperationError(e);
			logUiAction('err', 'Failed to apply configuration: ' + e.message);
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

}

function clearDeveloperTimer() {
	if (developerExpiryTimer != null) clearTimeout(developerExpiryTimer);
	developerExpiryTimer = null;
}

function setDeveloperVisible(visible, activate) {
	developerVisible = visible === true;
	developerTapTimes = [];
	clearDeveloperTimer();
	const tab = pageRoot?.querySelector('#sbox-developer-tab');
	const pane = pageRoot?.querySelector('#sbox-pane-developer');
	const logSearchToolbar = pageRoot?.querySelector('#sbox-log-search');
	if (tab) tab.hidden = !developerVisible;
	if (logSearchToolbar) logSearchToolbar.hidden = !developerVisible;
	if (!developerVisible && pane) pane.hidden = true;
	if (developerVisible) {
		if (pageRoot?.querySelector('#sbox-log-content')) renderLogs();
		developerExpiryTimer = window.setTimeout(() => setDeveloperVisible(false, true),
			DEVELOPER_SESSION_MS);
		if (activate && typeof cfgTabSetter === 'function') cfgTabSetter('developer');
		else if (appState.activeCfgTab === 'developer')
			performanceOwner.mount(pageRoot?.querySelector('#sbox-performance-panel'));
	} else if (activate && appState.activeCfgTab === 'developer' &&
		typeof cfgTabSetter === 'function') cfgTabSetter('settings');
	if (!developerVisible) {
		clearLogSearch();
		performanceOwner.destroy();
	}
}

function registerDeveloperTap() {
	const now = Date.now();
	developerTapTimes = developerTapTimes.filter((timestamp) =>
		now - timestamp <= DEVELOPER_TAP_WINDOW_MS);
	developerTapTimes.push(now);
	if (developerTapTimes.length === DEVELOPER_TAP_HINT_COUNT) {
		notify('info', _('Developer mode: %d taps remaining.')
			.format(DEVELOPER_TAP_COUNT - DEVELOPER_TAP_HINT_COUNT));
		return;
	}
	if (developerTapTimes.length < DEVELOPER_TAP_COUNT) return;
	setDeveloperVisible(!developerVisible, true);
}

function developerConfirmation(options) {
	view_miclash_ui_shell.showModal({
		title: options.title,
		body: E('div', { 'class': 'sbox-modal-responsive' }, [
			E('p', {}, options.message),
			options.detail ? E('p', { 'class': 'sbox-muted' }, options.detail) : null
		].filter(Boolean)),
		buttons: [
			{ label: _('Cancel'), className: 'cbi-button cbi-button-neutral' },
			{
				label: options.confirmLabel,
				className: 'cbi-button cbi-button-negative',
				onClick: async ({ closeModal }) => {
					try {
						await options.run();
						closeModal();
					} catch (error) {}
				}
			}
		]
	});
}

async function runDeveloperOperation(reply, progress) {
	setOperationStatus('running', progress, { context: 'developer' });
	const record = await awaitTypedOperation(reply, progress);
	return record;
}

function bindDeveloperEvents() {
	const appVersion = pageRoot?.querySelector('#sbox-app-version');
	if (appVersion) appVersion.addEventListener('click', registerDeveloperTap);
	const pane = pageRoot?.querySelector('#sbox-pane-developer');
	if (!pane) return;
	const restore = pane.querySelector('[data-developer-action="restore-network"]');
	const removeGuard = pane.querySelector('[data-developer-action="remove-guard"]');
	const removeMiClash = pane.querySelector('[data-developer-action="remove-miclash"]');

	if (restore) restore.addEventListener('click', () => developerConfirmation({
		title: _('Restore OpenWrt network'),
		message: _('Stop Mihomo and remove all MiClash-owned DNS, firewall and routing state?'),
		detail: _('If Guard is enabled, remove it first. No Internet connection is required.'),
		confirmLabel: _('Restore network'),
		run: async () => {
			try {
				await runDeveloperOperation(await configApi.recoverNetwork('luci'), _('Restoring OpenWrt network…'));
				setOperationSuccess(_('OpenWrt network restored'));
				notify('info', _('OpenWrt network restored'));
				await refreshHeaderAndControlSafe();
			} catch (error) { setOperationError(error); notify('error', error.message || error); throw error; }
		}
	}));

	if (removeGuard) removeGuard.addEventListener('click', () => developerConfirmation({
		title: _('Remove Guard'),
		message: _('Disable Guard and remove all active fail-closed Guard rules?'),
		detail: _('Devices may use a direct connection after this action.'),
		confirmLabel: _('Remove Guard'),
		run: async () => {
			try {
				await runDeveloperOperation(await configApi.guard_transition(false, 'luci'), _('Removing Guard…'));
				await refreshCanonicalGuardState();
				setOperationSuccess(_('Guard removed.'));
				notify('info', _('Guard removed.'));
			} catch (error) { setOperationError(error); notify('error', error.message || error); throw error; }
		}
	}));

	if (removeMiClash) removeMiClash.addEventListener('click', () => developerConfirmation({
		title: _('Remove MiClash'),
		message: _('Remove MiClash from this router?'),
		detail: _('The normal package removal protocol restores OpenWrt networking first. This page will become unavailable.'),
		confirmLabel: _('Remove MiClash'),
		run: async () => {
			try {
				const reply = await configApi.uninstallMiClash('luci');
				if (reply?.accepted !== true) throw new Error(_('MiClash removal was not accepted.'));
				setOperationSuccess(_('MiClash removal started.'));
				notify('info', _('MiClash removal started.'));
			} catch (error) { setOperationError(error); notify('error', error.message || error); throw error; }
		}
	}));
}

function bindTabEvents() {
	view_miclash_ui_shell.bindTabGroup(pageRoot, {
		tabAttr: 'ctrl-tab',
		initial: appState.activeCtrlTab || 'control',
		panes: {
			control: '#sbox-pane-control'
		},
		onChange: (name) => {
			appState.activeCtrlTab = name;
		}
	});

	let cfgTabsInitialized = false;
	cfgTabSetter = view_miclash_ui_shell.bindTabGroup(pageRoot, {
		tabAttr: 'cfg-tab',
		initial: appState.activeCfgTab || 'config',
		panes: {
			config: '#sbox-pane-config',
			settings: '#sbox-pane-settings',
			logs: '#sbox-pane-logs',
			developer: '#sbox-pane-developer'
		},
		onChange: (name) => {
			if (cfgTabsInitialized && appState.activeCfgTab === name) return;
			const metric = view_miclash_performance.begin('tab.' + name + '.open');
			cfgTabsInitialized = true;
			try {
				appState.activeCfgTab = name;
				managementOwner.setActive(name === 'settings');
				diagnosticsOwner.setActive(name === 'settings');
				if (name !== 'logs') stopLogPolling();
				if (name === 'settings') {
					renderSettingsPane();
				} else if (name === 'logs') {
					refreshLogs().catch(() => {});
					startLogPolling();
				} else {
					resizeConfigEditor();
				}
				if (name === 'developer')
					performanceOwner.mount(pageRoot?.querySelector('#sbox-performance-panel'));
				else
					performanceOwner.destroy();
			} finally {
				view_miclash_performance.end(metric, true);
			}
		}
	});
	bindDeveloperEvents();
}

return view.extend({
	handleSave: null,
	handleSaveApply: null,
	handleReset: null,

	load: function() {
		return [ {}, { interfaces: [], detectedLan: '', detectedWan: '' }, null, null ];
	},

	render: function(data) {
		sessionExpired = false;
		clearDeveloperTimer();
		developerVisible = false;
		developerTapTimes = [];
		cfgTabSetter = null;
		if (appState.activeCfgTab === 'developer') appState.activeCfgTab = 'settings';
		notificationOwner.destroy();
		managementOwner.destroy();
		performanceOwner.destroy();
		releaseConfigRuntime();
		const generation = ++pageGeneration;
		appState.configProfiles = CONFIG_PROFILES.slice();
		appState.selectedConfigName = MAIN_CONFIG_NAME;
		appState.configContent = '';
		appState.subscriptionUrl = '';
		appState.configReady = false;
		appState.systemMetadataReady = false;
		appState.serviceStateLoading = true;
		appState.settings = data[0] || {};
		const networkSnapshot = data[1] || { interfaces: [], detectedLan: '', detectedWan: '' };
		appState.interfaces = Array.isArray(networkSnapshot.interfaces) ? networkSnapshot.interfaces : [];
		const system = data[2] || {};
		appState.versions = {
			app: normalizeAppVersion(system.app_version || 'unknown'),
			clash: system.mihomo?.installed ? String(system.mihomo.version || _('Installed')) : 'unknown'
		};
		appState.kernelStatus = {
			installed: system.mihomo?.installed === true,
			version: system.mihomo?.installed ? String(system.mihomo.version || '') : null
		};
		if (data[3]) applyServiceState(data[3]);
		else appState.serviceRunning = false;
		if (data[3]?.desired?.guard)
			appState.settings.internetOnlyMiclash = data[3].desired.guard.enabled === true;
		appState.proxyMode = appState.settings.proxyMode || 'tproxy';

		appState.selectedInterfaces = (appState.settings.mode === 'explicit'
			? appState.settings.includedInterfaces
			: appState.settings.excludedInterfaces) || [];
		appState.detectedLan = appState.settings.detectedLan || networkSnapshot.detectedLan || '';
		appState.detectedWan = appState.settings.detectedWan || networkSnapshot.detectedWan || '';

		pageRoot = E('div', { 'class': 'sbox-page' }, [
			E('link', {
			'rel': 'stylesheet',
			'href': L.resource('view/miclash/style.css') + '?v=' +
				encodeURIComponent(String(appState.versions?.app || 'unknown')) + '-ui4'
			}),
			E('div', { 'id': 'sbox-root' })
		]);

		pageRoot.querySelector('#sbox-root').innerHTML = buildPageHtml();
		configApi = view_miclash_api.create();

		diagnosticsOwner.replace();
		managementOwner.replace();
		bindControlAndHeaderEvents();
		bindConfigEvents();
		bindTabEvents();
		if (appState.activeCfgTab === 'settings') renderSettingsPane();
		if (appState.activeCfgTab === 'logs') {
			refreshLogs().catch(() => {});
			startLogPolling();
		}
		updateHeaderAndControlDom();

		startControlPolling();
		startUpdatePolling();
		resumeMiClashServiceJobStatus().catch(() => {});
		resumeMiClashUpdateJobStatus().catch(() => {});
		visibilityChangeHandler = () => {
			if (document.hidden) {
				stopLogPolling();
		} else if (appState.activeCfgTab === 'logs' && logsLoaded) {
				refreshLogs().catch(() => {});
				startLogPolling();
			}
			if (!document.hidden) {
				refreshReleaseMeta({ force: false }).catch(() => {});
			}
		};
		document.addEventListener('visibilitychange', visibilityChangeHandler);
		const pageHydrationMetric = view_miclash_performance.begin('page.hydration');
		const configHydration = beginPageHydration(generation).then(
			(value) => {
				view_miclash_performance.end(pageHydrationMetric, true);
				return value;
			},
			(error) => {
				view_miclash_performance.end(pageHydrationMetric, false);
				throw error;
			}
		);
		hydrateSystemMetadata(generation).catch((error) => {
			if (generation === pageGeneration) console.error('[MiClash] Failed to hydrate system metadata:', error);
		});
		const initialHydration = hydrateInitialState(generation).catch((error) => {
			if (generation === pageGeneration) {
				console.error('[MiClash] Failed to hydrate initial state:', error);
				appState.guardObservedState = 'unknown';
				updateHeaderAndControlDom();
			}
		});
		initialHydration.finally(() => {
			window.setTimeout(() => {
				if (generation !== pageGeneration || !pageRoot || document.hidden) return;
				warmBackgroundPanels(generation, configHydration).catch(() => {});
			}, 0);
		});

		return pageRoot;
	},

	unload: function() {
		clearDeveloperTimer();
		developerVisible = false;
		developerTapTimes = [];
		cfgTabSetter = null;
		diagnosticsOwner.destroy();
		notificationOwner.destroy();
		managementOwner.destroy();
		performanceOwner.destroy();
		releaseConfigRuntime();
	}
});
