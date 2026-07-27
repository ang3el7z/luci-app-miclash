import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import * as scope from 'miclash.interface-scope';

function encoded(value) { return sprintf('%J', value); };

let base = {
	interfaces: {
		mode: 'exclude', auto_detect_lan: true, auto_detect_wan: true,
		detected_lan: '', detected_wan: '', included: [], excluded: []
	}
};
let live = { interfaces: [ 'br-lan', 'eth0', 'wan' ], detected_lan: 'br-lan', detected_wan: 'wan' };

let detected = scope.detect({ fs: {
	lsdir: (path) => path == '/sys/class/net' ? [ 'lo', 'br-lan', 'wan', 'clash-tun' ] : [],
	readfile: (path) => path == '/proc/net/route'
		? 'Iface\tDestination\tGateway\tFlags\nwan\t00000000\t0101A8C0\t0003\n' : null
} }, base);
assert_equal(detected.detected_lan, 'br-lan');
assert_equal(detected.detected_wan, 'wan');

let excluded = scope.resolve(base, live);
assert_equal(excluded.mode, 'exclude');
assert_equal(excluded.detected_lan, 'br-lan');
assert_equal(excluded.detected_wan, 'wan');
assert_equal(encoded(excluded.included), encoded([ 'br-lan' ]));
assert_equal(encoded(excluded.excluded), encoded([ 'wan' ]));
assert_equal(scope.contains(excluded, 'br-lan'), true,
	'exclude mode must include local ingress when only WAN is excluded');
assert_equal(scope.contains(excluded, 'wan'), false,
	'live WAN detection must remain outside MiClash without a LuCI save');

let explicit = scope.resolve({ interfaces: {
	mode: 'explicit', auto_detect_lan: true, auto_detect_wan: true,
	detected_lan: '', detected_wan: '', included: [], excluded: []
} }, live);
assert_equal(encoded(explicit.included), encoded([ 'br-lan' ]));
assert_equal(scope.contains(explicit, 'br-lan'), true);
assert_equal(scope.contains(explicit, 'wan'), false);

let stale = scope.resolve({ interfaces: {
	mode: 'exclude', auto_detect_lan: true, auto_detect_wan: true,
	detected_lan: 'lan', detected_wan: 'pppoe-wan', included: [], excluded: [ 'guest' ]
} }, live);
assert_equal(stale.detected_lan, 'br-lan');
assert_equal(stale.detected_wan, 'wan');
assert_equal(encoded(stale.excluded), encoded([ 'guest', 'wan' ]),
	'current topology must replace a stale auto-detected WAN hint');

let manual = scope.resolve({ interfaces: {
	mode: 'exclude', auto_detect_lan: false, auto_detect_wan: false,
	detected_lan: 'br-lan', detected_wan: 'wan', included: [], excluded: [ 'br-lan' ]
} }, live);
assert_equal(encoded(manual.excluded), encoded([ 'br-lan' ]));
assert_equal(scope.contains(manual, 'br-lan'), false);
assert_equal(scope.contains(manual, 'wan'), true,
	'disabled auto detection must not silently add persisted or live WAN hints');

let effective = scope.effective_settings(base, live);
assert_equal(effective.interfaces.detected_lan, 'br-lan');
assert_equal(effective.interfaces.detected_wan, 'wan');
assert_equal(base.interfaces.detected_lan, '', 'effective settings must not mutate persisted settings');

assert_throws(() => scope.resolve(base, { interfaces: [ 'wan' ], detected_lan: 'bad name', detected_wan: 'wan' }),
	'INVALID_ARGUMENT');
assert_throws(() => scope.contains(excluded, ''), 'INVALID_ARGUMENT');
assert_true(scope.contains(scope.resolve({ interfaces: {
	mode: 'explicit', auto_detect_lan: false, auto_detect_wan: false,
	detected_lan: '', detected_wan: '', included: [], excluded: []
} }, live), 'br-lan') === false, 'empty explicit scope must handle no client ingress');

print('interface scope tests passed\n');
