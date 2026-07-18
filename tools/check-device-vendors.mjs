import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const source = readFileSync(
	'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/device-vendors.js',
	'utf8'
);
const vendors = new Function('baseclass', source)({ extend: (value) => value });

const sample = [
	'# miclash-device-vendors-v1',
	'# snapshot=2026-07-19',
	'V\t0\tBroad Vendor',
	'V\t1\tMedium Vendor',
	'V\t2\tNarrow Vendor',
	'P\t24\t001122\t0',
	'P\t28\t0011223\t1',
	'P\t36\t001122334\t2',
	''
].join('\n');
const database = vendors.parseDatabase(sample);

assert.equal(database.snapshot, '2026-07-19');
assert.equal(vendors.lookupManufacturer(database, '00:11:22:33:44:55'), 'Narrow Vendor');
assert.equal(vendors.lookupManufacturer(database, '00:11:22:3F:45:66'), 'Medium Vendor');
assert.equal(vendors.lookupManufacturer(database, '00:11:22:A4:45:66'), 'Broad Vendor');
assert.equal(vendors.lookupManufacturer(database, '02:11:22:34:45:66'), null,
	'locally administered MACs must not receive a vendor');
assert.equal(vendors.lookupManufacturer(database, '01:11:22:34:45:66'), null,
	'multicast MACs must not receive a vendor');
assert.equal(vendors.lookupManufacturer(database, 'invalid'), null);

assert.equal(vendors.isGenericHostname('lwip0'), true);
assert.equal(vendors.isGenericHostname('WLAN0'), true);
assert.equal(vendors.isGenericHostname('MacBookPro'), false);

assert.deepEqual(vendors.resolveDeviceLabel({
	mac: '00:11:22:33:44:55', hostname: 'MacBookPro'
}, database), { kind: 'hostname', hostname: 'MacBookPro', manufacturer: 'Narrow Vendor' });
assert.deepEqual(vendors.resolveDeviceLabel({
	mac: '00:11:22:33:44:55', hostname: 'lwip0'
}, database), { kind: 'generic', hostname: 'lwip0', manufacturer: 'Narrow Vendor' });
assert.deepEqual(vendors.resolveDeviceLabel({
	mac: '00:11:22:A4:45:66', hostname: null
}, database), { kind: 'manufacturer', hostname: null, manufacturer: 'Broad Vendor' });
assert.deepEqual(vendors.resolveDeviceLabel({
	mac: '00:FF:EE:DD:CC:BB', hostname: null
}, database), { kind: 'unknown', hostname: null, manufacturer: null });
assert.deepEqual(vendors.resolveDeviceLabel({
	mac: '00:11:22:33:44:55', hostname: 'lwip0'
}, null), { kind: 'generic', hostname: 'lwip0', manufacturer: null },
	'a missing database must preserve a usable fallback state');

for (const malformed of [
	'',
	'# miclash-device-vendors-v0\n# snapshot=2026-07-19\n',
	'# miclash-device-vendors-v1\n# snapshot=bad\n',
	'# miclash-device-vendors-v1\n# snapshot=2026-07-19\nP\t24\t001122\tmissing\n',
	'# miclash-device-vendors-v1\n# snapshot=2026-07-19\nV\t0\tVendor\nP\t28\t001122\t0\n',
	'# miclash-device-vendors-v1\n# snapshot=2026-07-19\nV\t0\tVendor\nP\t24\t001122\t0\nP\t24\t001122\t0\n'
]) assert.throws(() => vendors.parseDatabase(malformed));

const fixtureDir = mkdtempSync(join(tmpdir(), 'miclash-vendors-'));
const csvHeader = 'Registry,Assignment,Organization Name,Organization Address\n';
writeFileSync(join(fixtureDir, 'oui.csv'), csvHeader +
	'MA-L,001122,First Organization,Address\nMA-L,001122,Second Organization,Address\n' +
	'MA-L,0C0B0C,Unique Organization,Address\n');
writeFileSync(join(fixtureDir, 'mam.csv'), csvHeader + 'MA-M,0011223,Medium Organization,Address\n');
writeFileSync(join(fixtureDir, 'oui36.csv'), csvHeader + 'MA-S,001122334,Narrow Organization,Address\n');
const fixtureOutput = join(fixtureDir, 'vendors.db');
const fixtureManifest = join(fixtureDir, 'vendors.manifest.json');
const generatedFixture = spawnSync(process.execPath, [
	'tools/generate-device-vendors.mjs', '--date', '2026-07-19',
	'--oui', join(fixtureDir, 'oui.csv'), '--mam', join(fixtureDir, 'mam.csv'),
	'--oui36', join(fixtureDir, 'oui36.csv'), '--output', fixtureOutput,
	'--manifest', fixtureManifest
], { encoding: 'utf8' });
assert.equal(generatedFixture.status, 0, generatedFixture.stderr);
const fixtureDatabase = vendors.parseDatabase(readFileSync(fixtureOutput, 'utf8'));
assert.equal(vendors.lookupManufacturer(fixtureDatabase, '00:11:22:AA:BB:CC'), null,
	'ambiguous IEEE assignments must not guess a manufacturer');
assert.equal(vendors.lookupManufacturer(fixtureDatabase, '0C:0B:0C:AA:BB:CC'), 'Unique Organization');

const databasePath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/device-vendors.db';
const generatedText = readFileSync(databasePath, 'utf8');
assert.ok(Buffer.byteLength(generatedText, 'utf8') <= vendors.MAX_DATABASE_BYTES,
	'generated vendor database must stay within the browser size ceiling');
const generated = vendors.parseDatabase(generatedText);
assert.match(generated.snapshot, /^20\d{2}-\d{2}-\d{2}$/);
assert.ok(generated.prefixes24.size + generated.prefixes28.size + generated.prefixes36.size > 40000,
	'generated snapshot must contain the complete public registries');
assert.equal(vendors.lookupManufacturer(generated, 'AC:BA:C0:9F:91:90'), 'Intertech Services AG');
assert.equal(vendors.lookupManufacturer(generated, '08:65:F0:AF:97:3D'), 'JM Zengge Co., Ltd');
assert.equal(vendors.lookupManufacturer(generated, 'F8:17:2D:E1:4E:99'), 'Tuya Smart Inc.');
const manifest = JSON.parse(readFileSync(
	'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/device-vendors.manifest.json',
	'utf8'
));
assert.deepEqual(Object.keys(manifest).sort(), [ 'sha256', 'size', 'snapshot', 'version' ]);
assert.equal(manifest.version, 1);
assert.equal(manifest.snapshot, generated.snapshot);
assert.equal(manifest.size, Buffer.byteLength(generatedText));
assert.equal(manifest.sha256, createHash('sha256').update(generatedText).digest('hex'));

const daemonSource = readFileSync('luci-app-miclash/rootfs/usr/share/miclash/daemon.uc', 'utf8');
assert.match(daemonSource, /import \* as device_vendor_update from 'miclash\.device-vendor-update';/);
assert.match(daemonSource, /modules\.device_vendor_update\.create\(/);
assert.match(daemonSource, /device_vendor_domain\.start\(\)/);
assert.match(daemonSource, /device_vendors:\s*device_vendor_domain\.status\(\)/);
const makefile = readFileSync('luci-app-miclash/Makefile', 'utf8');
const cgi = readFileSync('luci-app-miclash/rootfs/www/cgi-bin/miclash-device-vendors', 'utf8');
assert.match(makefile, /rootfs\/www\/cgi-bin\/miclash-device-vendors/);
assert.match(cgi, /UPDATED="\/etc\/miclash\/device-vendors\.db"/);
assert.match(cgi, /BUNDLED="\/www\/luci-static\/resources\/view\/miclash\/device-vendors\.db"/);
assert.doesNotMatch(cgi, /QUERY_STRING|HTTP_|\$1|eval/);

console.log('offline device vendor resolver contract passed');
