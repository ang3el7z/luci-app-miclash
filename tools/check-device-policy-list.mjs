import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const path = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/devices-panel.js';
const source = readFileSync(path, 'utf8');
const css = readFileSync('luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/style.css', 'utf8');
const vendorSource = readFileSync(
	'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/device-vendors.js', 'utf8');
const vendorModule = new Function('baseclass', vendorSource)({ extend: (value) => value });
const module = new Function('baseclass', 'view_miclash_device_vendors', source)(
	{ extend: (value) => value }, vendorModule
);

assert.equal(typeof module.deviceRows, 'function', 'deviceRows model builder must be exported');
assert.equal(typeof module.deviceDisplayName, 'function');
assert.equal(typeof module.loadVendorDatabase, 'function');

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
	{ id: 'dp-proxy', scope: 'device', mac: 'aa:bb:cc:dd:ee:40', action: 'proxy', revision: 1 }
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

assert.match(source, /_\('Set policy'\)/, 'inherited rows need the Set policy action');
assert.match(source, /_\('Change policy'\)/, 'explicit rows need the Change policy action');
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
