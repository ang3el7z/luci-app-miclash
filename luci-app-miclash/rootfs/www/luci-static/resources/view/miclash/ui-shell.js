'use strict';
'require ui';

function escapeHtml(value) {
	return String(value == null ? '' : value)
		.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
		.replaceAll('"', '&quot;').replaceAll("'", '&#39;');
}

function loadingOptions(options) {
	const opts = options || {};
	const kind = [ 'compact', 'normal', 'editor', 'table' ].includes(opts.kind) ? opts.kind : 'normal';
	const lines = Number.isInteger(opts.lines) ? Math.max(2, Math.min(8, opts.lines)) :
		(kind === 'compact' ? 3 : (kind === 'editor' ? 7 : (kind === 'table' ? 6 : 4)));
	return { kind, lines, label: String(opts.label || _('Loading…')) };
}

function loadingHtml(options) {
	const opts = loadingOptions(options);
	let rows = '';
	for (let index = 0; index < opts.lines; index++)
		rows += '<span class="sbox-loading-line sbox-loading-line-' + ((index % 4) + 1) + '"></span>';
	return '<div class="sbox-loading-surface sbox-loading-' + opts.kind + '" aria-busy="true" role="status">' +
		'<span class="sbox-sr-only">' + escapeHtml(opts.label) + '</span>' + rows + '</div>';
}

function loadingBlock(options) {
	const opts = loadingOptions(options);
	const rows = [ E('span', { 'class': 'sbox-sr-only' }, opts.label) ];
	for (let index = 0; index < opts.lines; index++)
		rows.push(E('span', { 'class': 'sbox-loading-line sbox-loading-line-' + ((index % 4) + 1) }));
	return E('div', {
		'class': 'sbox-loading-surface sbox-loading-' + opts.kind,
		'aria-busy': 'true', 'role': 'status'
	}, rows);
}

function showModal(options) {
	const opts = options || {};
	const bodyNode = opts.body && opts.body.nodeType
		? opts.body
		: E('div', { 'class': 'cbi-section' }, String(opts.body || ''));
	const actionsNode = E('div', { 'class': 'cbi-page-actions' });
	let isClosed = false;
	let observer = null;

	function finalizeClose() {
		if (isClosed) return;
		isClosed = true;
		if (observer) observer.disconnect();
		if (opts.onClose) {
			try { opts.onClose(); } catch (e) {}
		}
	}

	function closeModal() {
		if (isClosed) return;
		ui.hideModal();
		finalizeClose();
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

	const content = E('div', opts.modalClass ? { 'class': opts.modalClass } : {}, [
		bodyNode,
		actionsNode
	]);

	ui.showModal(String(opts.title || ''), content);

	observer = new MutationObserver(function() {
		if (!content.isConnected) finalizeClose();
	});
	observer.observe(document.body, { childList: true, subtree: true });
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
	const activeClass = opts.activeClass || '';
	if (!root || !tabAttr) return function() {};

	const tabs = Array.from(root.querySelectorAll('[data-' + tabAttr + ']'));
	const paneNodes = {};
	Object.keys(panes).forEach((name) => {
		paneNodes[name] = root.querySelector(panes[name]);
	});
	if (tabs[0]?.parentElement) {
		tabs[0].parentElement.setAttribute('role', 'group');
		tabs[0].parentElement.setAttribute('aria-label', opts.label || _('Sections'));
	}

	function setActive(name) {
		tabs.forEach((tab) => {
			const tabName = tab.getAttribute('data-' + tabAttr);
			const active = tabName === name;
			if (activeClass) tab.classList.toggle(activeClass, active);
			if (tab.classList.contains('cbi-tab') || tab.classList.contains('cbi-tab-disabled')) {
				tab.classList.toggle('cbi-tab', active);
				tab.classList.toggle('cbi-tab-disabled', !active);
			}
			tab.setAttribute('aria-pressed', active ? 'true' : 'false');
			const pane = paneNodes[tabName];
			if (pane?.id) tab.setAttribute('aria-controls', pane.id);
		});

		Object.keys(paneNodes).forEach((paneName) => {
			const pane = paneNodes[paneName];
			if (pane) pane.hidden = paneName !== name;
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
	showModal: showModal,
	withButtons: withButtons,
	bindTabGroup: bindTabGroup,
	loadingBlock: loadingBlock,
	loadingHtml: loadingHtml,
	startInterval: startInterval,
	stopInterval: stopInterval
});
