#!/usr/bin/ucode

import * as runtime_module from 'miclash.runtime';
import * as legacy from 'miclash.legacy-network';

function main() {
	let runtime = runtime_module.create();
	legacy.handoff(runtime);
};

try { main(); }
catch (error) {
	die('MiClash legacy firewall cleanup refused: ' +
		(error?.code ?? error?.message ?? 'INTERNAL') + '\n');
}
