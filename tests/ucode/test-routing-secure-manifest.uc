import { assert_equal, assert_true } from './testlib.uc';
import { desired, observe } from 'miclash.routing';
import { empty_outputs, runtime, seed, set_route_json, set_rule_json } from './routing-rereview-testlib.uc';

let wanted = desired({ proxy_mode: 'tproxy', ip_families: [ 'ipv4' ] }, {});
let outputs = empty_outputs();
set_route_json(outputs, wanted.routes[0]);
set_rule_json(outputs, wanted.rules[0]);
let secure = seed(runtime(outputs), wanted.routes, wanted.rules);
let observed = observe(secure);
assert_true(observed.ownership.trusted, 'a root-safe v2 manifest is trusted');
assert_equal(length(secure.fs.calls.readfile), 0,
	'manifest bytes are never read by pathname before trust checks');
assert_true(length(secure.fs.calls.open) == 1 && length(secure.fs.calls.fstat) >= 2,
	'manifest uses one bounded handle with fstat before and after reading');

let linked = runtime(outputs);
linked.fs.writefile('/var/run/miclash/target.json', linked.fs.files['/var/run/miclash/target.json'] ??
	'{"version":2}\n');
linked.fs.set_symlink('/var/run/miclash/routing-ownership.json', '/var/run/miclash/target.json');
assert_true(!observe(linked).ownership.trusted,
	'a manifest symlink is rejected instead of followed');
assert_equal(length(linked.fs.calls.read), 0,
	'a symlink target is rejected before any bytes are consumed');

let swapped = seed(runtime(outputs), wanted.routes, wanted.rules);
swapped.fs.on_lstat = (path, count) => {
	if (path == '/var/run/miclash/routing-ownership.json' && count == 2) swapped.fs.bump_inode(path);
};
assert_true(!observe(swapped).ownership.trusted,
	'a leaf identity swap between handle validation and final lstat is rejected');

let resized = seed(runtime(outputs), wanted.routes, wanted.rules), first_read = true;
let safe_read = resized.fs.read;
resized.fs.read = (handle, amount) => {
	let chunk = safe_read(handle, amount);
	if (first_read) {
		first_read = false;
		resized.fs.files['/var/run/miclash/routing-ownership.json'] += 'x';
	}
	return chunk;
};
assert_true(!observe(resized).ownership.trusted,
	'a size change between the first and second fstat is rejected');

let writable_parent = seed(runtime(outputs), wanted.routes, wanted.rules);
writable_parent.fs.set_mode('/var/run/miclash', 0o777);
assert_true(!observe(writable_parent).ownership.trusted,
	'a group/world-writable final parent prevents manifest authorization');
assert_equal(length(writable_parent.fs.calls.read), 0,
	'an untrusted final parent is rejected before manifest bytes are consumed');

function openwrt_tmp(value, mode) {
	for (let path in [ '/tmp', '/tmp/run', '/tmp/run/miclash' ]) value.fs.mkdir(path);
	value.fs.set_mode('/tmp', mode);
	let realpath = value.fs.realpath;
	value.fs.realpath = (path) => path == '/var/run/miclash'
		? '/tmp/run/miclash'
		: path == '/var/run/miclash/routing-ownership.json'
			? '/tmp/run/miclash/routing-ownership.json' : realpath(path);
	return value;
};

let writable_ancestor = openwrt_tmp(seed(runtime(outputs), wanted.routes, wanted.rules), 0o777);
assert_true(!observe(writable_ancestor).ownership.trusted,
	'a non-sticky writable ancestor prevents manifest authorization');

let sticky_ancestor = openwrt_tmp(seed(runtime(outputs), wanted.routes, wanted.rules), 0o1777);
assert_true(observe(sticky_ancestor).ownership.trusted,
	'OpenWrt canonical /tmp may be root-owned sticky writable when /tmp/run and final parent are protected');
