import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const config = readFileSync('luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js', 'utf8');
const panel = readFileSync('luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/diagnostics-panel.js', 'utf8');
const css = readFileSync('luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/style.css', 'utf8');

assert.match(config, /serviceStateLoading:\s*true/,
	'the initial service state must be loading rather than falsely stopped');
assert.match(config, /serviceStateLoading\s*=\s*false/,
	'initial service loading must end after a real service observation');
assert.match(config, /_\('Loading service state…'\)/,
	'the control card must communicate an honest loading state');
assert.match(config, /initialHydration\.finally\([\s\S]*managementOwner\.refresh\(true\)/,
	'Settings panels must start after initial state, without waiting for the editor hydration');
assert.match(panel, /guardEnabled[\s\S]*_\('Ready'\) \+ '\*'/,
	'Firewall must distinguish an active Guard without adding a separate component row');
assert.doesNotMatch(css, /rgba\(255,\s*255,\s*255/,
	'shimmers must not use a hard-coded white band');

console.log('MiClash loading and Guard presentation contract passed');
