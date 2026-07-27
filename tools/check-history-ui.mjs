import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';

const panelPath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/history-panel.js';
const configPath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js';
const editorPath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/editor.js';
const storePath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/store.js';
const cssPath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/style.css';

assert.equal(existsSync(panelPath), false, 'configuration history panel must not ship');

const config = readFileSync(configPath, 'utf8');
const editor = readFileSync(editorPath, 'utf8');
const store = readFileSync(storePath, 'utf8');
const css = readFileSync(cssPath, 'utf8');

for (const [name, source] of Object.entries({ config, editor, store })) {
	assert.doesNotMatch(source, /config_(?:read|save)_draft|config(?:Read|Save)Draft/,
		`${name} still calls the persistent Draft API`);
	assert.doesNotMatch(source, /history(?:List|Diff|OpenDraft|Restore)|history_(?:list|diff|open_draft|restore)/,
		`${name} still calls configuration history`);
}

assert.doesNotMatch(config, /history-panel|sbox-history|sbox-draft-label|saveRouterDraft|draftActions|draftController/,
	'configuration page still exposes Draft/History behavior');
assert.doesNotMatch(config, /pagehide/,
	'configuration page still persists editor content while leaving the page');
assert.doesNotMatch(editor, /localStorage|miclash-draft|createDraft|Router Draft/i,
	'editor still persists or coordinates Draft state');
assert.doesNotMatch(css, /sbox-history-|sbox-draft-label/,
	'Draft/History styles still ship');

assert.match(config, /configApi\.config_validate\(selectedConfig, editor\.getValue\(\), 'luci'\)/,
	'Validate must send current editor bytes directly to config_validate');
assert.match(config, /configApi\.config_apply\(selectedConfig, editor\.getValue\(\), 'luci'\)/,
	'Apply must send current editor bytes directly to config_apply');
assert.match(config, /editor\.setValue\(appState\.configContent, -1\)/,
	'profile selection must replace the editor with active configuration bytes');
assert.match(store, /api\.config_apply\(profile, normalized, 'luci'\)/,
	'store writes must apply active configuration directly');

console.log('Direct configuration editor contract passed');
