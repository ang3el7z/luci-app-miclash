import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';

for (const path of [
	'tools/run-ucode-tests.sh',
	'tests/ucode/testlib.uc',
	'tests/ucode/test-testlib.uc'
]) assert.ok(existsSync(path), `missing ${path}`);

console.log('ucode layout check passed');
