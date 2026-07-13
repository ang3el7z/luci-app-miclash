import { assert_equal, assert_true } from './testlib.uc';
import * as runtime_guard from 'miclash.guard_runtime';

const TABLE = 'miclash_guard';
const CHAIN = 'forward';
const RESERVED4 = [ '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8',
	'169.254.0.0/16', '172.16.0.0/12', '192.0.2.0/24', '192.88.99.0/24',
	'192.168.0.0/16', '198.51.100.0/24', '203.0.113.0/24', '224.0.0.0/4',
	'240.0.0.0/4', '255.255.255.255/32' ];
const RESERVED6 = [ '::/128', '::1/128', 'fc00::/7', 'fe80::/10', 'ff00::/8' ];

function clone(value) { return json(sprintf('%J', value)); };
function match(left, op, right) { return { match: { left, op, right } }; };
function meta(key) { return { meta: { key } }; };
function payload(protocol, field) { return { payload: { protocol, field } }; };
function ct(key) { return { ct: { key } }; };
function prefix(value) {
	let at = rindex(value, '/');
	return { prefix: { addr: substr(value, 0, at), len: int(substr(value, at + 1)) } };
};
function nft_document(ifaces) {
	let entries = [
		{ metainfo: { json_schema_version: 1 } },
		{ table: { family: 'inet', name: TABLE, handle: 1 } },
		{ set: { family: 'inet', table: TABLE, name: 'local4', type: 'ipv4_addr',
			flags: [ 'interval' ], handle: 2 } },
		{ set: { family: 'inet', table: TABLE, name: 'local6', type: 'ipv6_addr',
			flags: [ 'interval' ], handle: 3 } },
		{ element: { family: 'inet', table: TABLE, name: 'local4', elem: map(RESERVED4, prefix) } },
		{ element: { family: 'inet', table: TABLE, name: 'local6', elem: map(RESERVED6, prefix) } },
		{ chain: { family: 'inet', table: TABLE, name: CHAIN, type: 'filter',
			hook: 'forward', prio: 1, policy: 'accept', handle: 4 } }
	];
	let rules = [
		[ match(ct('state'), 'in', { set: [ 'established', 'related' ] }), { accept: null } ],
		[ match(meta('iifname'), '==', 'clash-tun'), { accept: null } ],
		[ match(meta('oifname'), '==', 'clash-tun'), { accept: null } ],
		[ match(ct('status'), 'in', 'dnat'), { accept: null } ],
		[ match(payload('udp', 'sport'), '==', 67), match(payload('udp', 'dport'), '==', 68), { accept: null } ],
		[ match(payload('udp', 'sport'), '==', 68), match(payload('udp', 'dport'), '==', 67), { accept: null } ],
		[ match(payload('ip', 'daddr'), '==', { set: 'local4' }), { accept: null } ],
		[ match(payload('ip6', 'daddr'), '==', { set: 'local6' }), { accept: null } ]
	];
	if (length(ifaces))
		for (let iface in ifaces)
			push(rules, [ match(meta('oifname'), '==', iface), { drop: null } ]);
	else {
		push(rules, [ match(meta('nfproto'), '==', 'ipv4'), { drop: null } ]);
		push(rules, [ match(meta('nfproto'), '==', 'ipv6'), { drop: null } ]);
	}
	let handle = 10;
	for (let expr in rules)
		push(entries, { rule: { family: 'inet', table: TABLE, chain: CHAIN,
			handle: handle++, comment: expr[length(expr) - 1].drop === null ? 'miclash-guard' : null,
			expr } });
	return { nftables: entries };
};

let expected_ifaces = [ 'eth0', 'pppoe-wan' ];
let valid_nft = nft_document(expected_ifaces);
assert_true(runtime_guard.verify_nft(sprintf('%J', valid_nft), expected_ifaces),
	'exact multi-WAN nft runtime Guard verifies');
let kernel_nft = clone(valid_nft);
kernel_nft.nftables[2].set.elem = [ ...slice(kernel_nft.nftables[4].element.elem, 0, 11),
	{ range: [ '224.0.0.0', '255.255.255.255' ] } ];
kernel_nft.nftables[3].set.elem = [
	{ prefix: { addr: '::', len: 127 } },
	{ prefix: { addr: 'fc00::', len: 7 } },
	{ prefix: { addr: 'fe80::', len: 10 } },
	{ range: [ 'ff00::', 'ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff' ] }
];
let compact = [];
for (let entry in kernel_nft.nftables) if (entry.element == null) push(compact, entry);
kernel_nft.nftables = compact;
kernel_nft.nftables[5].rule.expr[0].match.right = [ 'established', 'related' ];
kernel_nft.nftables[11].rule.expr[0].match.right = '@local4';
kernel_nft.nftables[12].rule.expr[0].match.right = '@local6';
assert_true(runtime_guard.verify_nft(sprintf('%J', kernel_nft), expected_ifaces),
	'actual nft JSON auto-merged ranges and named-set encoding verify exactly');
let missing_iface = clone(valid_nft); missing_iface.nftables = slice(missing_iface.nftables, 0, length(missing_iface.nftables) - 1);
assert_equal(runtime_guard.verify_nft(sprintf('%J', missing_iface), expected_ifaces), false,
	'partial multi-WAN nft Guard is rejected');
let duplicated_iface = clone(valid_nft); push(duplicated_iface.nftables,
	clone(duplicated_iface.nftables[length(duplicated_iface.nftables) - 1]));
assert_equal(runtime_guard.verify_nft(sprintf('%J', duplicated_iface), expected_ifaces), false,
	'duplicate terminal nft drops are rejected');
let wrong_hook = clone(valid_nft); wrong_hook.nftables[6].chain.prio = 0;
assert_equal(runtime_guard.verify_nft(sprintf('%J', wrong_hook), expected_ifaces), false,
	'wrong nft hook priority is rejected');
let wrong_set = clone(valid_nft); pop(wrong_set.nftables[4].element.elem);
assert_equal(runtime_guard.verify_nft(sprintf('%J', wrong_set), expected_ifaces), false,
	'partial reserved nft set is rejected');
assert_true(runtime_guard.verify_nft(sprintf('%J', nft_document([])), []),
	'empty interface capture requires both family fallback drops');
let one_family = nft_document([]); pop(one_family.nftables);
assert_equal(runtime_guard.verify_nft(sprintf('%J', one_family), []), false,
	'one-family fallback is rejected');

function iptables_save(family, ifaces) {
	let reserved = family == 'ipv4' ? RESERVED4 : RESERVED6;
	let lines = [ '*filter', ':FORWARD ACCEPT [0:0]', ':MICLASH_GUARD_FORWARD - [0:0]',
		'-A FORWARD -j MICLASH_GUARD_FORWARD',
		'-A MICLASH_GUARD_FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN',
		'-A MICLASH_GUARD_FORWARD -i clash-tun -j RETURN',
		'-A MICLASH_GUARD_FORWARD -o clash-tun -j RETURN' ];
	if (family == 'ipv4')
		push(lines, '-A MICLASH_GUARD_FORWARD -m conntrack --ctstate DNAT -j RETURN');
	push(lines,
		'-A MICLASH_GUARD_FORWARD -p udp --sport 67 --dport 68 -j RETURN',
		'-A MICLASH_GUARD_FORWARD -p udp --sport 68 --dport 67 -j RETURN');
	for (let network in reserved)
		push(lines, '-A MICLASH_GUARD_FORWARD -d ' + network + ' -j RETURN');
	if (length(ifaces)) for (let iface in ifaces)
		push(lines, '-A MICLASH_GUARD_FORWARD -o ' + iface + ' -j DROP');
	else push(lines, '-A MICLASH_GUARD_FORWARD -j DROP');
	push(lines, '-A MICLASH_GUARD_FORWARD -j RETURN', 'COMMIT', '');
	return join('\n', lines);
};

for (let family in [ 'ipv4', 'ipv6' ]) {
	let valid = iptables_save(family, expected_ifaces);
	assert_true(runtime_guard.verify_iptables(valid, family, expected_ifaces),
		'exact ' + family + ' multi-WAN iptables Guard verifies');
	assert_true(runtime_guard.verify_iptables(replace(valid,
		'--ctstate ESTABLISHED,RELATED', '--ctstate RELATED,ESTABLISHED'), family, expected_ifaces),
		'kernel-normalized conntrack state order verifies for ' + family);
	assert_equal(runtime_guard.verify_iptables(replace(valid,
		'-A MICLASH_GUARD_FORWARD -o pppoe-wan -j DROP\n', ''), family, expected_ifaces), false,
		'partial ' + family + ' multi-WAN iptables Guard is rejected');
	assert_equal(runtime_guard.verify_iptables(replace(valid,
		'-A FORWARD -j MICLASH_GUARD_FORWARD',
		'-A FORWARD -j ACCEPT\n-A FORWARD -j MICLASH_GUARD_FORWARD'), family, expected_ifaces), false,
		'late base-chain jump is rejected');
	assert_equal(runtime_guard.verify_iptables(replace(valid, 'COMMIT',
		'-A FORWARD -j MICLASH_GUARD_FORWARD\nCOMMIT'), family, expected_ifaces), false,
		'duplicate base-chain jump is rejected');
}

let source = require('fs').readfile('luci-app-miclash/rootfs/opt/clash/bin/clash-rules');
let entrypoint = require('fs').readfile('luci-app-miclash/rootfs/usr/share/miclash/guard-runtime.uc');
assert_true(index(source ?? '', 'guard-runtime.uc protect') >= 0 &&
	index(source ?? '', 'guard-runtime.uc release') >= 0,
	'runtime Guard rebuilds use the emergency bootstrap entrypoint');
assert_true(index(entrypoint ?? '', 'mutation_lock_token') >= 0 &&
	index(entrypoint ?? '', 'assert_held') >= 0,
	'bootstrap entrypoint joins and asserts the inherited canonical mutation lease');

warn('runtime Guard exact-verification tests passed\n');
