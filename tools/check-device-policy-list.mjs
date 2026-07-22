import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const path = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/devices-panel.js';
const source = readFileSync(path, 'utf8');
const css = readFileSync('luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/style.css', 'utf8');
const daemonSource = readFileSync('luci-app-miclash/rootfs/usr/share/miclash/daemon.uc', 'utf8');
const vendorSource = readFileSync(
	'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/device-vendors.js', 'utf8');
const vendorModule = new Function('baseclass', vendorSource)({ extend: (value) => value });
const module = new Function('baseclass', 'view_miclash_device_vendors', source)(
	{ extend: (value) => value }, vendorModule
);

assert.equal(typeof module.deviceRows, 'function', 'deviceRows model builder must be exported');
assert.equal(typeof module.deviceDisplayName, 'function');
assert.equal(typeof module.loadVendorDatabase, 'function');
assert.equal(typeof module.policyPresentation, 'function');
assert.equal(typeof module.createPolicyDrafts, 'function',
	'device policy drafts must use a testable page-local state model');

const drafts = module.createPolicyDrafts();
const draftMac = 'AA:BB:CC:DD:EE:50';
const savedDirect = { id: 'dp-direct', revision: 3, scope: 'device', mac: draftMac,
	action: 'direct', schedule: null };
drafts.stage(draftMac, { scope: 'device', mac: draftMac, action: 'direct', schedule: null }, null);
assert.equal(drafts.list().length, 1, 'new policy remains pending until page-level apply');
assert.equal(drafts.get(draftMac).action, 'direct');
drafts.stage(draftMac, { scope: 'device', mac: draftMac, action: 'inherit', schedule: null }, null);
assert.equal(drafts.list().length, 0, 'resetting a new draft to inherit removes the no-op');
drafts.stage(draftMac, { scope: 'device', mac: draftMac, action: 'direct', schedule: null }, savedDirect);
assert.equal(drafts.list().length, 0, 'persisted-equivalent edits are not marked dirty');
drafts.stage(draftMac, { scope: 'device', mac: draftMac, action: 'block', schedule: null }, savedDirect);
assert.equal(drafts.get(draftMac).action, 'block');
assert.equal(drafts.get(draftMac).expected_revision, 3);
drafts.stage(draftMac, { scope: 'device', mac: draftMac, action: 'inherit', schedule: null }, savedDirect);
assert.equal(drafts.get(draftMac).action, 'inherit', 'reset of a saved policy remains pending');
assert.match(source, /view\.miclash\.ui-shell/,
	'device policies must use the shared loading surface');
assert.match(source, /let hydrated = false/,
	'device policies must distinguish loading from a confirmed empty response');
assert.match(source, /loadingBlock\(\{ kind: 'table'/,
	'device policies must shimmer before discovery completes');
assert.match(source, /hydrated \? table\(rows\)/,
	'the empty table state must only render after successful hydration');

const neighbor = (mac, host) => ({ mac, hostname: host, addresses: [ {
	address: '192.168.1.20', family: 'ipv4', current: true, source: 'neighbor', interfaces: [ 'br-lan' ]
} ] });
const lease = (mac, host, address = '192.168.1.30') => ({ mac, hostname: host, addresses: [ {
	address, family: 'ipv4', current: true, source: 'dhcp', interfaces: []
} ] });

const rows = module.deviceRows([
	lease('AA:BB:CC:DD:EE:30', 'offline'),
	neighbor('AA:BB:CC:DD:EE:20', 'online'),
	neighbor('AA:BB:CC:DD:EE:40', 'managed'),
	lease('aa:bb:cc:dd:ee:40', 'managed', '192.168.1.20')
], [
	{ id: 'dp-block', scope: 'device', mac: 'aa:bb:cc:dd:ee:10', action: 'block', revision: 1 },
	{ id: 'dp-direct', scope: 'device', mac: 'aa:bb:cc:dd:ee:40', action: 'direct', revision: 1 }
]);

assert.deepEqual(rows.map((row) => row.mac), [
	'AA:BB:CC:DD:EE:40',
	'AA:BB:CC:DD:EE:10',
	'AA:BB:CC:DD:EE:20',
	'AA:BB:CC:DD:EE:30'
], 'explicit policies sort first, online before offline within each group');
assert.equal(rows.length, 4, 'duplicate discovery evidence is merged by MAC');
assert.equal(rows[1].online, false, 'saved policy without discovery remains as an offline row');
assert.equal(rows[0].online, true, 'current neighbor evidence marks a row online');
assert.equal(rows[3].online, false, 'DHCP lease alone does not claim that a device is online');
assert.equal(rows[1].explicit, true);
assert.equal(rows[2].explicit, false);
assert.deepEqual(module.currentAddresses(rows[0].device), [ '192.168.1.20' ],
	'IPv4/IPv6 discovery sources do not duplicate the same visible address');

const vendorDatabase = vendorModule.parseDatabase(readFileSync(
	'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/device-vendors.db', 'utf8'));
const vendorRows = module.deviceRows([
	neighbor('F8:17:2D:E1:4E:99', 'lwip0'),
	neighbor('08:65:F0:AF:97:3D', null),
	neighbor('36:F8:95:3F:B7:53', 'MacBookPro')
], [], vendorDatabase);
const byMac = Object.fromEntries(vendorRows.map((row) => [ row.mac, row ]));
assert.equal(module.deviceDisplayName(byMac['F8:17:2D:E1:4E:99'].label, 'Unknown device'),
	'Tuya Smart Inc. · lwip0');
assert.equal(module.deviceDisplayName(byMac['08:65:F0:AF:97:3D'].label, 'Unknown device'),
	'JM Zengge Co., Ltd — Unknown device');
assert.equal(module.deviceDisplayName(byMac['36:F8:95:3F:B7:53'].label, 'Unknown device'),
	'MacBookPro', 'a useful hostname must remain unchanged even for a private MAC');
assert.equal(await module.loadVendorDatabase(async () => { throw new Error('offline'); }), null,
	'vendor database failure must remain a silent UI fallback');
assert.equal((await module.loadVendorDatabase(async () => readFileSync(
	'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/device-vendors.db', 'utf8'))).snapshot,
	'2026-07-19');

assert.deepEqual(module.policyPresentation({ action: 'direct' }, {
	action: 'direct', safety: 'direct_exception'
}), { configured: 'direct', effective: 'direct', safety: 'direct_exception', overridden: false },
	'Direct remains the enforced action while Guard is enabled');

assert.match(source, /_\('Set policy'\)/, 'inherited rows need the Set policy action');
assert.match(source, /_\('Change policy'\)/, 'explicit rows need the Change policy action');
assert.match(source, /_\('Save required'\)/,
	'pending rows need a clear page-level apply reminder');
assert.match(source, /_\('Reset'\)/,
	'saved policies must use Reset rather than destructive Delete wording');
assert.doesNotMatch(source, /proxy:\s*\(\)\s*=>\s*_\('Proxy'\)/,
	'Proxy must not remain a selectable device policy');
assert.match(source, /_\('Priority: Block → Direct → Inherit'\)/,
	'the list and modal need the agreed policy precedence');
assert.doesNotMatch(source, /Guard has highest precedence|Guard precedence:/,
	'obsolete Guard-first explanations must be removed');
assert.match(source, /_\('Direct devices use the router shared DNS\./,
	'Direct must explain the intentionally shared DNS behavior');
const editorStart = source.indexOf('function openEditor(');
const editorEnd = source.indexOf('\n\tfunction policyFromEditor(', editorStart);
const editorSource = source.slice(editorStart, editorEnd);
assert.doesNotMatch(editorSource, /setDevicePolicy|deleteDevicePolicy|watchOperation/,
	'modal actions must only stage drafts and never mutate backend state');
assert.match(source, /function collectChanges\(\)/,
	'the unified settings flow must be able to collect policy drafts');
assert.match(source, /async function applyChanges\(\)/,
	'the unified settings flow must own policy persistence');
const applyStart = source.indexOf('async function applyChanges()');
const applyEnd = source.indexOf('\n\tasync function markSaved()', applyStart);
const applySource = source.slice(applyStart, applyEnd);
assert.match(applySource, /catch \(error\)[\s\S]*await refreshAfterMutation\(\)[\s\S]*throw error/,
	'a partial policy failure must refresh already-applied rows while retaining remaining drafts');
assert.match(source, /persistent_policy_eligible/,
	'private MAC policies need an explicit stability warning instead of silent contradiction');
assert.match(editorSource, /policyDrafts\.stage\([\s\S]*ui\.hideModal\(\); paint\(\)/,
	'a valid modal save must stage the draft, close, and repaint locally');
assert.match(source, /async function refreshAfterMutation\(\)[\s\S]*try \{ await refresh\(true\); \} catch \(error\) \{\}/,
	'a transient discovery refresh must not turn a successful policy mutation into a false failure');
assert.match(daemonSource, /modules\.devices\.discover_effective/,
	'device discovery must expose the backend-enforced action');
assert.match(daemonSource, /runtime\.reconcile\?\.apply\?\.\('device-policy'/,
	'device policy mutations must reconcile routing immediately');
assert.match(daemonSource, /guard_on[\s\S]*protect_strict\(\)[\s\S]*callback\(\)[\s\S]*apply_device_policy/,
	'Guard must become strictly fail-closed before a device policy mutation and remain protected until reconcile');
assert.match(daemonSource, /modules\.devices\.active_device_policies[\s\S]*modules\.interface_scope\.effective_settings[\s\S]*native_network\.apply\(effective, \{ device_policies,[\s\S]*server_ips:[\s\S]*fakeip_cidrs:/,
	'the native firewall compiler must receive active device policies and provider data with the effective interface scope');
assert.match(source, /\/cgi-bin\/miclash-device-vendors/,
	'the panel must load the local offline database without a large RPC response');
assert.ok((source.match(/deviceDisplayName\(/g) || []).length >= 3,
	'table, sorting model, and policy modal must share the resolved label');
assert.doesNotMatch(source, /_\('Last seen'\)/, 'unified device list must not retain the history column');
assert.match(css, /\.sbox-device-online[\s\S]*color:\s*var\(--sbox-success\)/,
	'online device state must use the shared success color');
assert.match(css, /\.sbox-device-offline[\s\S]*color:\s*var\(--sbox-muted\)/,
	'offline device state must remain visually secondary');

console.log('MiClash client-only device policy list contract passed');
