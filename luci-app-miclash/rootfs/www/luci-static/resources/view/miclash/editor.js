'use strict';

const ACE_BASE = 'view/miclash/ace/';

let aceLoadPromise = null;

function loadScript(resourcePath) {
	return new Promise(function(resolve, reject) {
		const script = E('script', {
			'type': 'text/javascript',
			'src': L.resource(resourcePath)
		});

		script.onload = function() { resolve(); };
		script.onerror = function() { reject(new Error('failed to load ' + resourcePath)); };
		document.head.appendChild(script);
	});
}

function loadAce() {
	if (aceLoadPromise) return aceLoadPromise;

	aceLoadPromise = Promise.resolve()
		.then(function() {
			if (window.ace && window.ace.edit) return;
			return loadScript(ACE_BASE + 'ace.js');
		})
		.then(function() {
			if (!window.ace || !window.ace.edit) throw new Error('Ace editor unavailable');
			window.ace.config.set('basePath', L.resource(ACE_BASE).replace(/\/$/, ''));
			window.ace.config.set('modePath', L.resource(ACE_BASE).replace(/\/$/, ''));
			return Promise.all([
				loadScript(ACE_BASE + 'mode-yaml.js'),
				loadScript(ACE_BASE + 'mode-text.js')
			]).catch(function() {});
		});

	return aceLoadPromise;
}

function installLuciAceTheme() {
	if (!window.ace || !window.ace.define) return;

	window.ace.define('ace/theme/miclash_luci', ['require', 'exports', 'module', 'ace/lib/dom'], function(require, exports) {
		exports.isDark = false;
		exports.cssClass = 'ace-miclash-luci';
		exports.cssText = [
			'.ace-miclash-luci { color: var(--sbox-text); background: var(--sbox-log-bg); }',
			'.ace-miclash-luci .ace_gutter { color: var(--sbox-muted); background: transparent; border-right: 1px solid var(--sbox-border); }',
			'.ace-miclash-luci .ace_cursor { color: currentColor; }',
			'.ace-miclash-luci .ace_marker-layer .ace_selection { background: Highlight; }',
			'.ace-miclash-luci .ace_marker-layer .ace_active-line { background: transparent; }',
			'.ace-miclash-luci .ace_print-margin { display: none; }',
			'.ace-miclash-luci .ace_comment { color: var(--sbox-muted); font-style: italic; }',
			'.ace-miclash-luci .ace_entity.ace_name.ace_tag, .ace-miclash-luci .ace_meta.ace_tag { color: var(--sbox-code-key); font-weight: 700; }',
			'.ace-miclash-luci .ace_string { color: var(--sbox-code-string); }',
			'.ace-miclash-luci .ace_constant.ace_numeric { color: var(--sbox-code-number); font-weight: 700; }',
			'.ace-miclash-luci .ace_constant.ace_language, .ace-miclash-luci .ace_keyword { color: var(--sbox-code-bool); font-weight: 700; }',
			'.ace-miclash-luci .ace_marker-layer .ace_selected-word { border: 1px solid var(--sbox-border); background: var(--sbox-panel-soft); }'
		].join('\n');

		require('../lib/dom').importCssString(exports.cssText, exports.cssClass);
	});
}

function createTextareaEditor(target, content) {
	const textarea = E('textarea', {
		'class': 'cbi-input-text sbox-native-editor',
		'spellcheck': 'false',
		'wrap': 'off'
	});
	target.appendChild(textarea);

	const api = {
		container: target,
		session: {
			setMode: function() {}
		},
		setOptions: function() {},
		setValue: function(value) {
			textarea.value = String(value || '');
		},
		getValue: function() {
			return textarea.value;
		},
		clearSelection: function() {
			try {
				textarea.selectionStart = 0;
				textarea.selectionEnd = 0;
			} catch (e) {}
		},
		resize: function() {},
		focus: function() {
			textarea.focus();
		},
		destroy: function() {
			target.textContent = '';
		}
	};

	api.setValue(content);
	return api;
}

async function createEditor(host, content, options) {
	const target = typeof host === 'string' ? document.getElementById(host) : host;
	const opts = options || {};
	if (!target) throw new Error('editor container not found');
	target.textContent = '';

	try {
		await loadAce();
		const editor = window.ace.edit(target);
		editor.setOptions({
			showPrintMargin: false,
			wrap: false,
			useWorker: false,
			fontSize: '12px'
		});
		editor.session.setUseWorker(false);
		editor.session.setMode('ace/mode/' + (opts.mode || 'yaml'));
		installLuciAceTheme();
		editor.setTheme('ace/theme/miclash_luci');
		editor.container.classList.add('sbox-ace-editor');
		editor.setValue(String(content || ''), -1);
		return editor;
	} catch (e) {
		return createTextareaEditor(target, content);
	}
}

const CRASH_PREFIX = 'miclash-draft-v1:';
const MAX_CRASH_CONTENT = 1024 * 1024;
const MAX_CRASH_KEYS = 6;

function contentHash(value) {
	let hash = 2166136261;
	const text = String(value || '');
	for (let index = 0; index < text.length; index++) {
		hash ^= text.charCodeAt(index);
		hash = Math.imul(hash, 16777619);
	}
	return ('00000000' + (hash >>> 0).toString(16)).slice(-8) + ':' + text.length;
}

function createDraftController(options) {
	const opts = options || {};
	const storage = opts.storage || window.localStorage;
	const timerSet = opts.setTimeout || window.setTimeout.bind(window);
	const timerClear = opts.clearTimeout || window.clearTimeout.bind(window);
	const debounceMs = Math.max(250, Math.min(5000, Number(opts.debounceMs) || 750));
	let profile = String(opts.profile || 'config.yaml');
	let revision = String(opts.revision || '');
	let content = String(opts.content || '');
	let routerContent = String(opts.routerContent ?? content);
	let routerDraftExists = opts.routerDraftExists !== false;
	let timer = null;
	let destroyed = false;
	let pendingConflict = null;

	function key(name) { return CRASH_PREFIX + encodeURIComponent(String(name || 'config.yaml')); }
	function safeStorage(callback, fallback) {
		try { return callback(); } catch (error) { return fallback; }
	}
	function trimStorage() {
		const entries = [];
		for (let index = 0; index < Number(storage?.length || 0); index++) {
			const name = safeStorage(() => storage.key(index), null);
			if (name && name.indexOf(CRASH_PREFIX) === 0) {
				let savedAt = 0;
				try { savedAt = Number(JSON.parse(storage.getItem(name)).savedAt || 0); } catch (error) {}
				entries.push({ name, savedAt });
			}
		}
		entries.sort((left, right) => right.savedAt - left.savedAt);
		for (const entry of entries.slice(MAX_CRASH_KEYS))
			safeStorage(() => storage.removeItem(entry.name));
	}
	function flushLocal() {
		if (timer != null) { timerClear(timer); timer = null; }
		if (destroyed || pendingConflict || content.length > MAX_CRASH_CONTENT) return false;
		const record = { version: 1, profile, revision, content,
			hash: contentHash(content), savedAt: Date.now() };
		return safeStorage(() => {
			storage.setItem(key(profile), JSON.stringify(record));
			trimStorage();
			return true;
		}, false);
	}
	function scheduleLocal() {
		if (pendingConflict) return;
		if (timer != null) timerClear(timer);
		timer = timerSet(() => { timer = null; flushLocal(); }, debounceMs);
	}
	function setContent(next) {
		content = String(next || '');
		scheduleLocal();
		return contentHash(content);
	}
	function crashCopy(name) {
		return safeStorage(() => {
			const raw = storage.getItem(key(name));
			const parsed = JSON.parse(raw || 'null');
			if (!parsed || parsed.version !== 1 || parsed.profile !== name ||
				typeof parsed.content !== 'string' || parsed.content.length > MAX_CRASH_CONTENT ||
				parsed.hash !== contentHash(parsed.content)) return null;
			return { record: parsed, raw };
		}, null);
	}
	function load(name, activeReply, draftReply) {
		profile = String(name || 'config.yaml');
		const active = String(activeReply?.content || '');
		routerDraftExists = draftReply?.content != null;
		const draft = routerDraftExists ? String(draftReply.content) : active;
		revision = String(draftReply?.revision || activeReply?.revision || '');
		content = draft;
		routerContent = draft;
		const crash = crashCopy(profile);
		pendingConflict = crash && crash.record.content !== draft ?
			{ profile, key: key(profile), raw: crash.raw, record: crash.record } : null;
		return { profile, active, draft, revision, content: draft,
			crash: pendingConflict?.record || null, conflict: pendingConflict != null };
	}
	async function saveRouter(api, nextContent) {
		if (nextContent != null) content = String(nextContent);
		flushLocal();
		const nextHash = contentHash(content);
		if (routerDraftExists && content === routerContent) return { changed: false, hash: nextHash };
		const savedProfile = profile;
		const reply = await api.configSaveDraft(savedProfile, content, 'luci');
		return { changed: true, hash: nextHash, content, profile: savedProfile,
			operation_id: reply.operation_id };
	}
	function confirmRouterSaved(saved) {
		if (saved?.changed === true && saved.profile === profile && saved.content === content) {
			routerContent = saved.content;
			routerDraftExists = true;
			return true;
		}
		return false;
	}
	function useCrashCopy(record) {
		if (!pendingConflict || record !== pendingConflict.record || record.profile !== profile ||
			record.hash !== contentHash(record.content))
			throw new Error('Invalid local Draft copy');
		content = record.content;
		pendingConflict = null;
		scheduleLocal();
		return content;
	}
	function keepRouterCopy() {
		if (!pendingConflict || pendingConflict.profile !== profile) return false;
		const conflict = pendingConflict;
		pendingConflict = null;
		safeStorage(() => storage.removeItem(conflict.key));
		scheduleLocal();
		return true;
	}
	function destroy() {
		if (destroyed) return;
		if (timer != null) { timerClear(timer); timer = null; }
		if (!pendingConflict) flushLocal();
		destroyed = true;
	}
	return { hash: contentHash, setContent, flushLocal, load, saveRouter, confirmRouterSaved,
		useCrashCopy, keepRouterCopy, hasPendingConflict: () => pendingConflict != null,
		getContent: () => content, getProfile: () => profile,
		routerDraftExists: () => routerDraftExists, destroy };
}

function createDraftLoadCoordinator(getSnapshot) {
	let requestGeneration = 0;
	function same(left, right) {
		return left && right && left.generation === right.generation && left.api === right.api &&
			left.controller === right.controller && left.editor === right.editor &&
			left.selectedProfile === right.selectedProfile;
	}
	async function load(profile, fetch, commit, owns) {
		const request = ++requestGeneration;
		const captured = getSnapshot();
		const replies = await fetch(captured, profile);
		if (request !== requestGeneration || !same(captured, getSnapshot()) ||
			(typeof owns === 'function' && !owns()))
			return { stale: true };
		const value = commit(captured, replies, profile);
		return { stale: false, value };
	}
	return { load };
}

function createDraftActions(options) {
	const opts = options || {};
	const api = opts.api;
	const controller = opts.controller;
	let busy = false;
	function progress(phase, percent, stage) {
		if (typeof opts.onProgress !== 'function') return;
		opts.onProgress({ phase: String(phase || '').slice(0, 24),
			percent: Math.max(0, Math.min(100, Math.round(Number(percent) || 0))),
			stage: String(stage || '').slice(0, 80) });
	}
	function wait(operationId, phase, start, end) {
		return new Promise((resolve, reject) => {
			let cancel = null, pendingCancel = false, settled = false;
			const finish = () => { if (cancel) cancel(); else pendingCancel = true; };
			cancel = api.watchOperation(operationId, (operation, error) => {
				if (settled) return;
				if (error) { settled = true; finish(); reject(error); return; }
				const measured = Math.max(0, Math.min(100,
					Number(operation?.percent ?? operation?.progress ?? 0) || 0));
				progress(phase, start + ((end - start) * measured / 100), operation?.stage || phase);
				if (!operation || !/^(success|failure|interrupted)$/.test(operation.state || '')) return;
				settled = true; finish();
				if (operation.state === 'success') { progress(phase, end, 'complete'); resolve(operation); }
				else {
					const failure = new Error(operation.error?.message || 'Operation failed');
					failure.code = operation.error?.code || 'OPERATION_FAILED';
					reject(failure);
				}
			});
			if (pendingCancel && cancel) cancel();
		});
	}
	async function saveSnapshot(profile, content) {
		progress('save_draft', 0, 'save_draft');
		if (controller.getProfile() !== profile) throw new Error('Draft profile changed');
		controller.setContent(content);
		const saved = await controller.saveRouter(api, content);
		if (saved.changed) {
			await wait(saved.operation_id, 'save_draft', 0, 30);
			controller.confirmRouterSaved(saved);
		} else progress('save_draft', 30, 'unchanged');
		return saved;
	}
	async function validateSnapshot(profile, content) {
		await saveSnapshot(profile, content);
		const accepted = await api.config_validate(profile, content, 'luci');
		await wait(accepted.operation_id, 'validate', 30, 100);
		return { content };
	}
	async function exclusive(callback) {
		if (busy) { const error = new Error('Operation already running'); error.code = 'BUSY'; throw error; }
		busy = true;
		try { return await callback(); } finally { busy = false; }
	}
	async function save(content) {
		const profile = String(opts.getProfile());
		return exclusive(() => saveSnapshot(profile, String(content)));
	}
	async function validate() {
		const profile = String(opts.getProfile()), content = String(opts.getContent());
		return exclusive(() => validateSnapshot(profile, content));
	}
	async function apply() {
		const profile = String(opts.getProfile()), content = String(opts.getContent());
		return exclusive(async () => {
			await saveSnapshot(profile, content);
			const accepted = await api.config_apply(profile, content, 'luci');
			await wait(accepted.operation_id, 'apply', 30, 100);
			const active = await api.config_read(profile);
			if (typeof opts.onApplied === 'function' && String(opts.getProfile()) === profile)
				await opts.onApplied(active);
			return active;
		});
	}
	async function runExternal(callback) {
		const profile = String(opts.getProfile()), content = String(opts.getContent());
		return exclusive(async () => {
			await saveSnapshot(profile, content);
			return callback({ profile, content });
		});
	}
	return { save, validate, apply, runExternal, waitOperation: wait, isBusy: () => busy };
}

function createLifecycleOwner() {
	let current = null;
	function destroy() {
		if (!current) return false;
		const owned = current; current = null;
		if (typeof owned.destroy === 'function') owned.destroy();
		return true;
	}
	function replace(next) {
		destroy(); current = next || null; return current;
	}
	return { replace, destroy, get: () => current };
}

return L.Class.extend({
	createEditor: createEditor,
	createDraftController: createDraftController,
	createDraftActions: createDraftActions,
	createLifecycleOwner: createLifecycleOwner,
	createDraftLoadCoordinator: createDraftLoadCoordinator,
	contentHash: contentHash
});
