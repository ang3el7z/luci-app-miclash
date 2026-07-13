#!/usr/bin/ucode

import { cleanup } from 'miclash.routing';
import * as runtime_module from 'miclash.runtime';

try {
	cleanup(runtime_module.create());
}
catch (error) {
	die('MiClash routing cleanup refused: ' + (error?.code ?? error?.message ?? 'INTERNAL') + '\n');
}
