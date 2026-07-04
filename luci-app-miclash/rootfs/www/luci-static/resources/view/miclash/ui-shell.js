'use strict';
'require ui';

function showModal(options) {
	const opts = options || {};
	const bodyNode = opts.body && opts.body.nodeType
		? opts.body
		: E('div', { 'class': 'sbox-modal-body' }, String(opts.body || ''));
	const actionsNode = E('div', { 'class': 'sbox-modal-actions' });
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

	const content = E('div', {
		'class': 'sbox-modal-content' + (opts.modalClass ? ' ' + opts.modalClass : '')
	}, [
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
	const activeClass = opts.activeClass || 'sbox-tab-active';
	if (!root || !tabAttr) return function() {};

	const tabs = Array.from(root.querySelectorAll('[data-' + tabAttr + ']'));
	const paneNodes = {};
	Object.keys(panes).forEach((name) => {
		paneNodes[name] = root.querySelector(panes[name]);
	});

	function setActive(name) {
		tabs.forEach((tab) => {
			const active = tab.getAttribute('data-' + tabAttr) === name;
			tab.classList.toggle(activeClass, active);
			if (tab.classList.contains('cbi-tab') || tab.classList.contains('cbi-tab-disabled')) {
				tab.classList.toggle('cbi-tab', active);
				tab.classList.toggle('cbi-tab-disabled', !active);
			}
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
	startInterval: startInterval,
	stopInterval: stopInterval
});
