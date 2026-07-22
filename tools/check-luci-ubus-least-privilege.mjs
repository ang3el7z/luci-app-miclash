import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync } from 'node:fs';

const fixturePath = 'tests/fixtures/api/methods.json';
const backendPath = 'luci-app-miclash/rootfs/usr/share/miclash/api.uc';
const uiPath = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/api.js';
const aclPath = 'luci-app-miclash/rootfs/usr/share/rpcd/acl.d/luci-app-miclash.json';
const menuPath = 'luci-app-miclash/rootfs/usr/share/luci/menu.d/luci-app-miclash.json';
const makefilePath = 'luci-app-miclash/Makefile';

const expectedNames = 'status,overview,health,operation_get,operation_list,' +
	'service_start,service_stop,service_reload,service_restart,network_recover,config_list,config_read,' +
	'config_validate,config_apply,' +
	'operational_settings_apply,config_swap,config_external_adopt,settings_get,settings_set,' +
	'guard_transition,' +
	'subscription_get,subscription_set,subscription_update,update_release,update_miclash,' +
	'update_mihomo,update_rollback_mihomo,memory_status,memory_reset_baseline,memory_settings,' +
	'diagnostics_summary,diagnostics_create_report,diagnostics_route_test,' +
	'telegram_status,telegram_settings,telegram_token_reveal,telegram_test,telegram_ingest,' +
	'devices_list,devices_timezones,devices_policy_list,devices_policy_set,devices_policy_delete,' +
	'notifications_settings,notifications_test,notifications_list,logs_read,system_info,' +
	'network_interfaces,ruleset_list,ruleset_read,ruleset_write,ruleset_delete,' +
	'ruleset_apply_whitelist,transfer_begin,transfer_write,transfer_read,transfer_finish,' +
	'transfer_abort';
const expectedRead = new Set([
	'status', 'overview', 'health', 'operation_get', 'operation_list', 'config_list', 'settings_get',
	'subscription_get', 'update_release', 'memory_status', 'memory_settings',
	'diagnostics_summary', 'telegram_status', 'telegram_settings',
	'devices_list', 'devices_timezones', 'devices_policy_list', 'notifications_settings',
	'notifications_list', 'logs_read', 'system_info', 'network_interfaces', 'ruleset_list',
	'ruleset_read'
]);
const secretBearing = new Set([
	'config_read',
	'telegram_token_reveal',
	'transfer_begin', 'transfer_write', 'transfer_read', 'transfer_finish', 'transfer_abort'
]);

const fixture = JSON.parse(readFileSync(fixturePath, 'utf8'));
assert.deepEqual(Object.keys(fixture), [ 'methods' ], 'API fixture has hidden top-level fields');
assert.ok(Array.isArray(fixture.methods), 'API fixture methods must be an array');
const names = fixture.methods.map((method) => method.name);
assert.equal(names.join(','), expectedNames, 'canonical API method rename/add/remove requires review');
assert.equal(new Set(names).size, names.length, 'canonical API contains duplicate methods');
for (const method of fixture.methods) {
	assert.deepEqual(Object.keys(method), [ 'name', 'params', 'operation', 'access' ],
		`${method.name} must have one exact canonical contract`);
	assert.ok(method.access === 'read' || method.access === 'write' || method.access === 'internal',
		`${method.name} has no exact read/write/internal classification`);
	assert.equal(method.access, method.name === 'telegram_ingest' ? 'internal' :
		(expectedRead.has(method.name) ? 'read' : 'write'),
		`${method.name} violates the reviewed least-privilege partition`);
}
for (const name of secretBearing)
	assert.equal(expectedRead.has(name), false, `${name} exposes secret-bearing authority to read role`);

const backend = readFileSync(backendPath, 'utf8');
const backendNames = [ ...backend.matchAll(/^\t\t([a-z0-9_]+): method\(/gm) ]
	.map((match) => match[1]);
assert.deepEqual(backendNames, names, 'api.uc methods must exactly equal canonical API order');

const ui = readFileSync(uiPath, 'utf8');
const uiMethods = [ ...ui.matchAll(/\{ name: '([a-z0-9_]+)', params: \[([^\]]*)\], operation: (true|false), access: '(read|write)' \}/g) ]
	.map((match) => ({
		name: match[1],
		params: [ ...match[2].matchAll(/'([^']+)'/g) ].map((item) => item[1]),
		operation: match[3] === 'true',
		access: match[4]
	}));
assert.deepEqual(uiMethods, fixture.methods.filter((method) => method.access !== 'internal'),
	'api.js methods/access must equal the public canonical fixture');

const aclDocument = JSON.parse(readFileSync(aclPath, 'utf8'));
assert.deepEqual(Object.keys(aclDocument), [ 'luci-app-miclash' ], 'ACL exposes an orphan role');
const acl = aclDocument['luci-app-miclash'];
assert.deepEqual(Object.keys(acl).sort(), [ 'description', 'read', 'write' ]);
for (const scope of [ 'read', 'write' ]) {
	assert.deepEqual(Object.keys(acl[scope] || {}), [ 'ubus' ], `${scope} ACL is not ubus-only`);
	assert.deepEqual(Object.keys(acl[scope].ubus || {}), [ 'miclash' ],
		`${scope} ACL exposes a non-MiClash ubus object`);
	assert.ok(Array.isArray(acl[scope].ubus.miclash), `${scope} ACL methods must be explicit`);
	assert.equal(new Set(acl[scope].ubus.miclash).size, acl[scope].ubus.miclash.length,
		`${scope} ACL contains duplicate methods`);
}
const aclRead = acl.read.ubus.miclash;
const aclWrite = acl.write.ubus.miclash;
assert.deepEqual(aclRead, fixture.methods.filter((method) => method.access === 'read').map((method) => method.name),
	'read ACL differs from canonical method partition');
assert.deepEqual(aclWrite, fixture.methods.filter((method) => method.access === 'write').map((method) => method.name),
	'write ACL differs from canonical method partition');
assert.deepEqual(aclRead.filter((name) => aclWrite.includes(name)), [], 'read/write ACL overlap');
assert.deepEqual(aclRead.concat(aclWrite).sort(), fixture.methods
	.filter((method) => method.access !== 'internal').map((method) => method.name).sort(),
	'ACL has missing or orphan public methods');

function inspectAuthority(value) {
	if (Array.isArray(value)) {
		for (const item of value) inspectAuthority(item);
		return;
	}
	if (value == null || typeof value !== 'object') {
		assert.notEqual(value, '*', 'ACL wildcard authority is forbidden');
		assert.notEqual(value, 'luci-base', 'broad luci-base authority is forbidden');
		return;
	}
	for (const [key, item] of Object.entries(value)) {
		assert.ok(![ 'file', 'exec', 'service', 'uci', 'shell' ].includes(key),
			`forbidden ACL authority: ${key}`);
		inspectAuthority(item);
	}
}
inspectAuthority(aclDocument);

const menuDocument = JSON.parse(readFileSync(menuPath, 'utf8'));
assert.deepEqual(Object.keys(menuDocument), [ 'admin/services/miclash' ],
	'menu exposes obsolete aliases or hidden endpoints');
assert.deepEqual(menuDocument['admin/services/miclash'], {
	title: 'MiClash',
	action: { type: 'view', path: 'miclash/config' },
	depends: { acl: [ 'luci-app-miclash' ] },
	i18n: 'miclash'
}, 'menu target/ACL dependency differs from the current LuCI entry');
assert.ok(existsSync('luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js'),
	'menu target view is not packaged');
assert.deepEqual(readdirSync('luci-app-miclash/rootfs/usr/share/luci/menu.d'),
	[ 'luci-app-miclash.json' ], 'package contains obsolete menu files');
assert.deepEqual(readdirSync('luci-app-miclash/rootfs/usr/share/rpcd/acl.d'),
	[ 'luci-app-miclash.json' ], 'package contains obsolete ACL files');
assert.equal(existsSync('luci-app-miclash/rootfs/usr/lib/lua/luci/controller'), false,
	'legacy LuCI controller endpoints remain packaged');
const makefile = readFileSync(makefilePath, 'utf8');
for (const path of [
	'rootfs/usr/share/luci/menu.d/luci-app-miclash.json',
	'rootfs/usr/share/rpcd/acl.d/luci-app-miclash.json'
]) assert.equal(makefile.split(path).length - 1, 1, `${path} must be installed exactly once`);

console.log(`LuCI least-privilege ubus contract passed (${names.length} methods)`);
