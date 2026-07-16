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
function ucBody(source, name) {
	const start = source.indexOf(`function ${name}(`);
	check(start >= 0, `missing function ${name}`);
	const next = source.indexOf('\n};', start);
	check(next > start, `unterminated function ${name}`);
	return source.slice(start, next + 3);
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
ordered(apply, [ 'guard_emergency_protect || return 1', 'guard_expected_captured=false',
	'capture_guard_expected_interfaces',
	'remove_iptables_legacy_output_guard_rules', 'apply_nft_guard_rules',
	'verify_nft_guard_rules', 'guard_emergency_release' ],
	'Guard rebuild must independently protect before interface capture, mutate, prove, then release');
check((apply.match(/guard_emergency_protect/g) || []).length >= 3,
	'every rebuild failure class must freshly re-prove retained emergency protection');
check(apply.includes('guard_emergency_release || {') &&
	apply.slice(apply.indexOf('guard_emergency_release || {')).includes('guard_emergency_protect'),
	'a failed emergency release must re-establish and freshly prove protection');

const captureExpected = body(rules, 'capture_guard_expected_interfaces');
const collectExpected = body(rules, 'get_guard_wan_interfaces');
check(rules.includes('guard_expected_captured=false') &&
	captureExpected.includes('[ "$guard_expected_captured" = false ] || return 0') &&
	captureExpected.includes('guard_expected_captured=true') &&
	apply.indexOf('guard_expected_captured=false') < apply.indexOf('capture_guard_expected_interfaces'),
	'Guard expected-interface capture must freeze even an intentionally empty snapshot');
check(collectExpected.includes("awk '") && collectExpected.includes("$field == \"dev\"") &&
	collectExpected.includes('ip route show default') &&
	collectExpected.includes('ip -6 route show default'),
	'Guard capture must enumerate every default-route dev token for both families');
check((captureExpected.match(/sort -u/g) || []).length === 1,
	'Guard capture must sort and deduplicate its complete candidate set exactly once');
check(!collectExpected.includes('sort -u'),
	'Guard candidate collection must not pre-sort a partial set');

const remove = body(rules, 'remove_guard_rules');
ordered(remove, [ 'guard_emergency_protect || return 1', 'remove_guard_rules_strict' ],
	'ordinary runtime removal must establish protection first');
check(!remove.includes('guard_emergency_release'),
	'ordinary service/runtime removal must retain bootstrap protection');
const strictRemove = body(rules, 'remove_guard_rules_strict');
check(strictRemove.includes('remove_iptables_guard_rules || result=1'),
	'strict runtime removal must propagate every iptables family mutation failure');

const bootstrapDisable = body(rules, 'guard_bootstrap_disable');
ordered(bootstrapDisable, [ '/usr/share/miclash/guard-runtime.uc disable',
	'/usr/share/miclash/guard-bootstrap.uc disable' ],
	'explicit disable must delete the runtime bootstrap before persisting verified OFF');

const finalize = body(rules, 'finalize_guard_rules');
ordered(finalize, [ 'guard_emergency_protect ||', 'remove_guard_rules_strict',
	'verify_guard_absent', 'guard_bootstrap_disable' ],
	'explicit disable must prove protection and runtime absence before release');

const effective = body(rules, 'guard_effective_enabled');
check(effective.includes('guard_canonical_enabled') && effective.includes('guard_safety_latched'),
	'effective Guard must be canonical UCI OR the backend-owned safety latch');
check(body(rules, 'guard_canonical_enabled').includes('INTERNET_ONLY_MICLASH'),
	'canonical Guard helper must be the sole legacy variable decision boundary');
for (const name of [ 'apply_nft_server_exclusions_mangle', 'apply_iptables_server_exclusions' ])
	check(body(rules, name).includes('guard_effective_enabled') &&
		!body(rules, name).includes('INTERNET_ONLY_MICLASH'),
		`${name} must honor latched effective Guard exactly like canonical ON`);
const rawGuardBranches = rules.match(/(?:if|elif)[^\n]*INTERNET_ONLY_MICLASH|\[[^\n]*INTERNET_ONLY_MICLASH[^\n]*\]/g) ?? [];
check(rawGuardBranches.length === 1 &&
	body(rules, 'guard_canonical_enabled').includes(rawGuardBranches[0]),
	'raw INTERNET_ONLY_MICLASH branch decisions are forbidden outside the canonical helper');
for (const name of [ 'refresh_guard_rules', 'finalize_guard_rules', 'start', 'stop' ])
	check(body(rules, name).includes('guard_effective_enabled'),
		`${name} must honor the effective Guard safety latch`);
check(body(rules, 'guard_verify_off').includes('guard_safety_latched') &&
	body(rules, 'guard_verify_off').includes('return 1'),
	'OFF proof must reject a still-armed safety latch');
const controlledOff = body(rules, 'guard_controlled_disable');
ordered(controlledOff, [ 'finalize_guard_rules true', 'guard_safety_latch_clear',
	'guard_verify_off' ], 'controlled OFF must retain the latch until terminal physical removal succeeds');
check(body(rules, 'finalize_guard_rules').includes('controlled_off') &&
	body(rules, 'finalize_guard_rules').includes('guard_effective_enabled'),
	'ordinary finalize must honor the latch while only controlled OFF may bypass it');
check(controlledOff.includes('guard_safety_latch_set') &&
	controlledOff.includes('guard_emergency_protect'),
	'failed controlled OFF must re-arm the latch and freshly prove emergency protection');
check(rules.includes('guard_disable)') && rules.includes('guard_controlled_disable'),
	'production Guard adapter needs one locked controlled OFF entrypoint');

const disable = ucBody(entry, 'disable_bootstrap');
const mutateAt = disable.indexOf('mutate_terminal(runtime, lease, nft');
check(mutateAt >= 0 && disable.indexOf('inventory(nft)', mutateAt) < 0 &&
	disable.slice(mutateAt).includes('return true'),
	'successful atomic bootstrap deletion must be terminal without post-delete inventory');
check(disable.includes('if (!mutate_terminal(runtime, lease, nft') && disable.includes('return false'),
	'failed atomic bootstrap deletion must propagate failure for fresh re-protection');
const terminalMutate = ucBody(entry, 'mutate_terminal');
const terminalRun = terminalMutate.indexOf("args: [ '-f', BATCH ]");
check(terminalRun > terminalMutate.lastIndexOf('assert_held(runtime, lease)', terminalRun) &&
	terminalMutate.lastIndexOf('assert_held(runtime, lease)', terminalRun) >
		terminalMutate.indexOf('atomic_write(runtime, BATCH') &&
	terminalMutate.indexOf('assert_held(runtime, lease)', terminalRun) < 0 &&
	disable.includes('mutate_terminal(runtime, lease, nft'),
	'terminal deletion must prove lease authority immediately before nft and never assert afterward');
const main = ucBody(entry, 'main');
check(main.includes('terminal_success') &&
	main.includes('if (!terminal_success) assert_held(runtime, lease)') &&
	main.includes('if (!terminal_success && thrown == null) thrown = error'),
	'terminal deletion success must make lease cleanup best-effort without flipping status');

const restartAt = rules.indexOf('    restart)');
const restart = rules.slice(restartAt, rules.indexOf('    update)', restartAt));
check(/stop\s*\|\|\s*(return|exit)/.test(restart) && /start\s*\|\|\s*(return|exit)/.test(restart),
	'clash-rules restart must stop on each failed lifecycle phase');

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
