#!/usr/bin/ucode

import * as migration from 'miclash.migrate';
import * as runtime from 'miclash.runtime';

if (length(ARGV) != 1)
	die('usage: migrate.uc {prepare|apply|verify|cleanup|status}\n');

let result = migration.run(runtime.create(), null, ARGV[0]);
if (ARGV[0] == 'status')
	print(sprintf('%J\n', result));
