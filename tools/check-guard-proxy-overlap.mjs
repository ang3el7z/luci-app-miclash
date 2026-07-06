import { readFileSync } from 'node:fs';

const rules = readFileSync('luci-app-miclash/rootfs/opt/clash/bin/clash-rules', 'utf8');
let failed = false;

function check(condition, message) {
	if (!condition) {
		console.error(message);
		failed = true;
	}
}

function functionBody(name) {
	const start = rules.indexOf(`${name}() {`);
	if (start < 0) return '';

	let depth = 0;
	for (let i = rules.indexOf('{', start); i < rules.length; i++) {
		const char = rules[i];
		if (char === '{') depth++;
		if (char === '}') {
			depth--;
			if (depth === 0) return rules.slice(start, i + 1);
		}
	}

	return '';
}

const nftClient = functionBody('apply_nft_server_exclusions_mangle');
const iptablesClient = functionBody('apply_iptables_server_exclusions');
const nftOutput = functionBody('apply_nft_output_rules');
const iptablesOutput = functionBody('apply_iptables_output_rules');

check(nftClient.includes('INTERNET_ONLY_MICLASH'),
	'nft client proxy-server exclusions must branch on INTERNET_ONLY_MICLASH.');
check(nftClient.includes('Client guard enabled') && nftClient.includes('return 0'),
	'nft client proxy-server exclusions must skip the bypass when client guard is enabled.');
check(nftClient.includes('nft add rule inet clash CLASH_MARK ip daddr @proxy_servers return'),
	'nft client proxy-server exclusion must remain available when client guard is disabled.');

check(iptablesClient.includes('INTERNET_ONLY_MICLASH'),
	'iptables client proxy-server exclusions must branch on INTERNET_ONLY_MICLASH.');
check(iptablesClient.includes('Client guard enabled') && iptablesClient.includes('return 0'),
	'iptables client proxy-server exclusions must skip the bypass when client guard is enabled.');
check(iptablesClient.includes('iptables -t mangle -A CLASH_PROCESS -d "$ip/32" -j RETURN'),
	'iptables destination proxy-server exclusion must remain available when client guard is disabled.');

check(nftOutput.includes('nft add rule inet clash output ip daddr @proxy_servers return'),
	'nft OUTPUT proxy-server loop-prevention must remain present.');
check(iptablesOutput.includes('CLASH_LOCAL') && iptablesOutput.includes('iptables -t mangle -A CLASH_LOCAL -d "$ip/32" -j RETURN'),
	'iptables OUTPUT proxy-server loop-prevention must remain present.');

if (failed) process.exit(1);
console.log('guard proxy overlap check passed');
