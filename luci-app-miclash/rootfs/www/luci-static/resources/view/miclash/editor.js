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

return L.Class.extend({
	createEditor: createEditor
});
