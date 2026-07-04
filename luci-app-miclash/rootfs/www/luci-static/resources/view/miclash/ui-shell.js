'use strict';

function detectNativeTheme() {
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

function getPreferredAceTheme() {
	return detectNativeTheme() === 'light' ? 'ace/theme/textmate' : 'ace/theme/tomorrow_night_bright';
}

function applyThemeToEditor(editorInstance) {
	if (!editorInstance) return;
	try {
		editorInstance.setTheme(getPreferredAceTheme());
	} catch (e) {
		editorInstance.setTheme('ace/theme/tomorrow_night_bright');
	}
}

function applyThemeToEditors(editors) {
	(editors || []).forEach(applyThemeToEditor);
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
	detectNativeTheme: detectNativeTheme,
	applyThemeToEditor: applyThemeToEditor,
	applyThemeToEditors: applyThemeToEditors,
	showModal: showModal,
	withButtons: withButtons,
	bindTabGroup: bindTabGroup,
	startInterval: startInterval,
	stopInterval: stopInterval
});
