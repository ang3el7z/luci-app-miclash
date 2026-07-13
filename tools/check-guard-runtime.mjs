import { readFileSync } from 'node:fs';

const rulesPath = process.env.MICLASH_GUARD_RULES_SOURCE ||
	'luci-app-miclash/rootfs/opt/clash/bin/clash-rules';
const entryPath = process.env.MICLASH_GUARD_ENTRY_SOURCE ||
	'luci-app-miclash/rootfs/usr/share/miclash/guard-runtime.uc';
const verifierPath = process.env.MICLASH_GUARD_VERIFIER_SOURCE ||
	'luci-app-miclash/rootfs/usr/share/miclash/guard_runtime.uc';
const dnsGatePath = 'tools/check-dns-lifecycle.sh';
const cleanupGatePath = 'tools/check-package-cleanup.sh';
const rules = readFileSync(rulesPath, 'utf8');
const entry = readFileSync(entryPath, 'utf8');
const verifier = readFileSync(verifierPath, 'utf8');
const dnsGate = readFileSync(dnsGatePath, 'utf8');
const cleanupGate = readFileSync(cleanupGatePath, 'utf8');

function check(condition, message) {
	if (!condition) throw new Error(message);
}
function body(source, name) {
	const start = source.indexOf(`${name}() {`);
	check(start >= 0, `missing function ${name}`);
	const next = source.indexOf('\n}', start);
	check(next > start, `unterminated function ${name}`);
	return source.slice(start, next + 2);
}
function ordered(source, names, message) {
	let at = -1;
	for (const name of names) {
		const next = source.indexOf(name, at + 1);
		check(next > at, `${message}: missing/out-of-order ${name}`);
		at = next;
	}
}

const apply = body(rules, 'apply_guard_rules');
ordered(apply, [ 'guard_emergency_protect || return 1',
	'remove_iptables_legacy_output_guard_rules', 'apply_nft_guard_rules',
	'verify_nft_guard_rules', 'guard_emergency_release' ],
	'Guard rebuild must protect, mutate, prove, then release');
check((apply.match(/guard_emergency_protect/g) || []).length >= 3,
	'every rebuild failure class must freshly re-prove retained emergency protection');
check(apply.includes('guard_emergency_release || {') &&
	apply.slice(apply.indexOf('guard_emergency_release || {')).includes('guard_emergency_protect'),
	'a failed emergency release must re-establish and freshly prove protection');

const remove = body(rules, 'remove_guard_rules');
ordered(remove, [ 'guard_emergency_protect || return 1', 'remove_guard_rules_strict' ],
	'ordinary runtime removal must establish protection first');
check(!remove.includes('guard_emergency_release'),
	'ordinary service/runtime removal must retain bootstrap protection');
const strictRemove = body(rules, 'remove_guard_rules_strict');
check(strictRemove.includes('remove_iptables_guard_rules || result=1'),
	'strict runtime removal must propagate every iptables family mutation failure');

const finalize = body(rules, 'finalize_guard_rules');
ordered(finalize, [ 'guard_emergency_protect ||', 'remove_guard_rules_strict',
	'verify_guard_absent', 'guard_bootstrap_disable' ],
	'explicit disable must prove protection and runtime absence before release');

check(!rules.includes("grep -q 'comment \\\"miclash-guard\\\"'") &&
	!rules.includes("grep -q -- '-j DROP'"),
	'marker-only Guard verification must not remain');
check(rules.includes('refusing a partially protected iptables backend') &&
	rules.includes('verify_iptables_guard_for_cmd iptables 4') &&
	rules.includes('verify_iptables_guard_for_cmd ip6tables 6'),
	'iptables Guard must require and prove both families');

for (const line of rules.split('\n')) {
	if (/^\s*nft add (table|set|element|chain|rule) inet "\$GUARD_NFT_TABLE"/.test(line))
		check(line.includes('|| return 1'), `unchecked nft Guard mutation: ${line.trim()}`);
	if (/\$cmd -t filter -(A|I|F|N|X|D) .*GUARD_FORWARD_CHAIN/.test(line) &&
		!line.includes('while '))
		check(line.includes('|| return 1') || line.includes('>/dev/null 2>&1 ||'),
			`unchecked iptables Guard mutation: ${line.trim()}`);
}

check(entry.includes("runtime.mutation_lock_token = getenv('MICLASH_MUTATION_LOCK_TOKEN')") &&
	entry.includes('let lease = acquire(') && entry.includes('assert_held(runtime, lease)') &&
	entry.includes('trusted_package_barrier(runtime)'),
	'emergency entrypoint must join/assert the inherited canonical lease and package barrier');
check(entry.includes("const EMERGENCY = 'miclash_guard_emergency_v1'") &&
	entry.includes("const PRIMARY = 'miclash_guard_bootstrap_v1'") &&
	entry.includes('ensure_table(runtime, lease, nft, PRIMARY)') &&
	entry.includes('disable_bootstrap(runtime, lease, nft)') &&
	entry.includes('guard.verify_nft_table') && entry.includes('guard.nft_ruleset'),
	'emergency entrypoint must reuse the strict bootstrap JSON owner');

for (const marker of [ 'exact_reserved4(elements.local4)',
	'exact_reserved6(elements.local6)', 'length(terminal) != length(expected_ifaces)',
	"terminal[0].expr, null, 'ipv4'", "terminal[1].expr, null, 'ipv6'",
	"forwards[0] == '-A FORWARD -j ' + IPT_CHAIN",
	'length(filter(forwards' ])
	check(verifier.includes(marker), `exact runtime verifier missing ${marker}`);

for (const marker of [ 'guard-protect', 'guard-add', 'guard-verify', 'guard-release',
	'guard-runtime-release' ])
	check(dnsGate.includes(marker), `nft/emergency failure gate missing ${marker}`);
check(cleanupGate.includes('iptables Guard mutation failure lost emergency protection'),
	'iptables mutation failure gate must assert emergency retention');

console.log('Guard runtime transaction and exact-proof check passed');
