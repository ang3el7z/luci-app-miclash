#!/usr/bin/ucode

import { cleanup } from 'miclash.routing';
import * as runtime_module from 'miclash.runtime';

const PACKAGE_REMOVAL_BARRIER = '/var/run/miclash/package-removal';

try {
	let runtime = runtime_module.create();
	if (runtime.fs.lstat(PACKAGE_REMOVAL_BARRIER) == null)
		die('MiClash routing cleanup refused: package-removal barrier missing\n');
	runtime.package_removal_cleanup = true;
	runtime.package_removal_preserve_manifest = true;
	runtime.mutation_lock_token = getenv('MICLASH_MUTATION_LOCK_TOKEN');
	cleanup(runtime);
}
catch (error) {
	die('MiClash routing cleanup refused: ' + (error?.code ?? error?.message ?? 'INTERNAL') + '\n');
}
