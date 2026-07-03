'use strict';
'require view.miclash.store';

const UI_THEME_KEY = 'UI_THEME';

function normalizeTheme(theme) {
	return theme === 'light' ? 'light' : 'dark';
}

function getPreferredAceTheme(theme) {
	return normalizeTheme(theme) === 'light' ? 'ace/theme/textmate' : 'ace/theme/tomorrow_night_bright';
}

function applyThemeToEditor(editorInstance, theme) {
	if (!editorInstance) return;
	try {
		editorInstance.setTheme(getPreferredAceTheme(theme));
	} catch (e) {
		editorInstance.setTheme('ace/theme/tomorrow_night_bright');
	}
}

async function readThemePreference() {
	const settings = await view_miclash_store.readSettingsMap();
	const saved = String(settings[UI_THEME_KEY] || '').trim();
	return saved ? normalizeTheme(saved) : '';
}

async function saveThemePreference(theme) {
	const settings = await view_miclash_store.readSettingsMap();
	settings[UI_THEME_KEY] = normalizeTheme(theme);
	await view_miclash_store.writeSettingsMap(settings);
}

function detectInitialTheme() {
	const root = document.documentElement;
	const body = document.body;
	const signal = [
		root ? root.className : '',
		body ? body.className : '',
		root ? root.getAttribute('data-theme') : '',
		root ? root.getAttribute('theme') : '',
		body ? body.getAttribute('data-theme') : '',
		body ? body.getAttribute('theme') : ''
	].join(' ').toLowerCase();

	if (/(^|\s)(dark|night)(\s|$)/.test(signal)) return 'dark';
	if (/(^|\s)(light|bright)(\s|$)/.test(signal)) return 'light';
	if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) return 'dark';
	return 'light';
}

function applyUiTheme(pageRoot, theme, editors) {
	const normalized = normalizeTheme(theme);

	if (pageRoot) {
		pageRoot.classList.toggle('sbox-theme-dark', normalized === 'dark');
		pageRoot.classList.toggle('sbox-theme-light', normalized === 'light');

		const btn = pageRoot.querySelector('#sbox-theme-toggle');
		if (btn) {
			btn.textContent = normalized === 'dark' ? '\u2600' : '\u263D';
			btn.title = normalized === 'dark'
				? _('Switch to light theme')
				: _('Switch to dark theme');
		}
	}

	(editors || []).forEach((editorInstance) => applyThemeToEditor(editorInstance, normalized));
	return normalized;
}

function showModal(options) {
	const opts = options || {};
	const mountNode = opts.mountNode && opts.mountNode.appendChild ? opts.mountNode : document.body;
	const overlayClass = 'sbox-modal-overlay' + (opts.overlayClass ? ' ' + opts.overlayClass : '');
	const modalClass = 'sbox-modal' + (opts.modalClass ? ' ' + opts.modalClass : '');
	const overlay = E('div', { 'class': overlayClass });
	const modal = E('div', { 'class': modalClass });
	const titleNode = E('div', { 'class': 'sbox-modal-title' }, String(opts.title || ''));
	const bodyNode = opts.body && opts.body.nodeType
		? opts.body
		: E('div', { 'class': 'sbox-modal-body' }, String(opts.body || ''));
	const actionsNode = E('div', { 'class': 'sbox-modal-actions' });
	let isClosed = false;

	function closeModal() {
		if (isClosed) return;
		isClosed = true;
		document.removeEventListener('keydown', onKeyDown);
		if (opts.onClose) {
			try { opts.onClose(); } catch (e) {}
		}
		overlay.remove();
	}

	function onKeyDown(ev) {
		if (ev.key === 'Escape') closeModal();
	}

	(opts.buttons || []).forEach((item) => {
		const button = E('button', {
			'class': item.className || 'cbi-button cbi-button-neutral'
		}, String(item.label || ''));

		button.addEventListener('click', async function(ev) {
			ev.preventDefault();
			if (item.onClick) {
				const oldText = button.textContent;
				button.disabled = true;
				try {
					await item.onClick({ closeModal: closeModal, button: button });
				} finally {
					if (button.isConnected) {
						button.disabled = false;
						button.textContent = oldText;
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
	document.addEventListener('keydown', onKeyDown);

	mountNode.appendChild(overlay);
	return closeModal;
}

async function withButtons(btns, fn, escapeText) {
	const list = Array.isArray(btns) ? btns : (btns ? [btns] : []);
	const saved = list.map((b) => b.innerHTML);
	const esc = escapeText || ((value) => String(value || ''));

	list.forEach((b) => {
		b.disabled = true;
		b.innerHTML = '<span class="sbox-spinner"></span> ' + esc(b.textContent || '').trim();
	});

	try {
		return await fn();
	} finally {
		list.forEach((b, i) => {
			if (b && b.isConnected) {
				b.disabled = false;
				b.innerHTML = saved[i];
			}
		});
	}
}

function bindTabGroup(root, options) {
	const opts = options || {};
	const tabAttr = opts.tabAttr;
	const panes = opts.panes || {};
	const activeClass = opts.activeClass || 'sbox-tab-active';
	if (!root || !tabAttr) return function() {};

	const tabs = Array.from(root.querySelectorAll('[data-' + tabAttr + ']'));
	const paneNodes = {};
	Object.keys(panes).forEach((name) => {
		paneNodes[name] = root.querySelector(panes[name]);
	});

	function setActive(name) {
		tabs.forEach((tab) => {
			tab.classList.toggle(activeClass, tab.getAttribute('data-' + tabAttr) === name);
		});

		Object.keys(paneNodes).forEach((paneName) => {
			const pane = paneNodes[paneName];
			if (pane) pane.style.display = paneName === name ? '' : 'none';
		});

		if (opts.onChange) opts.onChange(name);
	}

	tabs.forEach((tab) => {
		tab.addEventListener('click', () => setActive(tab.getAttribute('data-' + tabAttr)));
	});

	setActive(opts.initial || tabs[0]?.getAttribute('data-' + tabAttr) || '');
	return setActive;
}

function startInterval(timer, fn, intervalMs, options) {
	const opts = options || {};
	if (timer && !opts.replace) return timer;
	if (timer) clearInterval(timer);
	return setInterval(fn, intervalMs);
}

function stopInterval(timer) {
	if (timer) clearInterval(timer);
	return null;
}

return L.Class.extend({
	normalizeTheme: normalizeTheme,
	applyThemeToEditor: applyThemeToEditor,
	readThemePreference: readThemePreference,
	saveThemePreference: saveThemePreference,
	detectInitialTheme: detectInitialTheme,
	applyUiTheme: applyUiTheme,
	showModal: showModal,
	withButtons: withButtons,
	bindTabGroup: bindTabGroup,
	startInterval: startInterval,
	stopInterval: stopInterval
});
