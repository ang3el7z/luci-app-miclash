#!/usr/bin/ucode

import * as nft from 'miclash.firewall.nft';
import * as iptables from 'miclash.firewall.iptables';
import * as runtime_module from 'miclash.runtime';

try {
	let runtime = runtime_module.create();
	if (runtime.fs.lstat('/var/run/miclash/package-removal') == null)
		die('MiClash firewall cleanup refused: package-removal barrier missing\n');
	runtime.mutation_lock_token = getenv('MICLASH_MUTATION_LOCK_TOKEN');
	nft.cleanup(runtime, { preserve_guard: true });
	let legacy_available = false;
	for (let path in [ '/usr/sbin/iptables-save', '/sbin/iptables-save',
		'/usr/bin/iptables-save', '/bin/iptables-save' ])
		if (runtime.fs.lstat(path)?.type == 'file') legacy_available = true;
	if (legacy_available)
		iptables.cleanup(runtime, { preserve_guard: true, generations: [] });
}
catch (error) {
	die('MiClash firewall cleanup refused: ' +
		(error?.code ?? error?.message ?? 'INTERNAL') + '\n');
}
