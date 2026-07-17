#!/usr/bin/ucode

import { apply, cleanup, desired, observe, recover } from 'miclash.dns';
import { fail, normalize } from 'miclash.errors';
import * as runtime_module from 'miclash.runtime';

if (length(ARGV) != 1 || (ARGV[0] != 'apply' && ARGV[0] != 'cleanup'))
	die('MiClash DNS reconciliation refused: INVALID_ARGUMENT\n');

try {
	let runtime = runtime_module.create();
	runtime.mutation_lock_token = getenv('MICLASH_MUTATION_LOCK_TOKEN');
	if (ARGV[0] == 'cleanup') cleanup(runtime);
	else {
		let missing = false;
		try { recover(runtime, 'active'); }
		catch (error) {
			let code = error?.code ?? error?.message;
			if (code != 'NOT_FOUND') fail(code);
			missing = true;
		}
		if (missing) apply(runtime, desired(observe(runtime)));
	}
}
catch (error) {
	die('MiClash DNS reconciliation refused: ' + normalize(error).code + '\n');
}
