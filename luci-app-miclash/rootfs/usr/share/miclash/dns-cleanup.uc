#!/usr/bin/ucode

import { cleanup } from 'miclash.dns';
import { normalize } from 'miclash.errors';
import * as runtime_module from 'miclash.runtime';

const BARRIER = '/var/run/miclash/package-removal';

try {
	let runtime = runtime_module.create();
	if (runtime.fs.lstat(BARRIER) == null)
		die('MiClash DNS cleanup refused: BUSY\n');
	runtime.package_removal_cleanup = true;
	runtime.package_removal_preserve_manifest = true;
	runtime.mutation_lock_token = getenv('MICLASH_MUTATION_LOCK_TOKEN');
	cleanup(runtime);
}
catch (error) {
	die('MiClash DNS cleanup refused: ' + normalize(error).code + '\n');
}
