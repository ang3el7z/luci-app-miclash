import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const path = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/devices-panel.js';
const source = readFileSync(path, 'utf8');
const css = readFileSync('luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/style.css', 'utf8');
const module = new Function('baseclass', source)({ extend: (value) => value });

assert.equal(typeof module.deviceRows, 'function', 'deviceRows model builder must be exported');

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

assert.match(source, /_\('Set policy'\)/, 'inherited rows need the Set policy action');
assert.match(source, /_\('Change policy'\)/, 'explicit rows need the Change policy action');
assert.doesNotMatch(source, /_\('Last seen'\)/, 'unified device list must not retain the history column');
assert.match(css, /\.sbox-device-online[\s\S]*color:\s*var\(--sbox-success\)/,
	'online device state must use the shared success color');
assert.match(css, /\.sbox-device-offline[\s\S]*color:\s*var\(--sbox-muted\)/,
	'offline device state must remain visually secondary');

console.log('MiClash client-only device policy list contract passed');
