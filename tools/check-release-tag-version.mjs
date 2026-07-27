import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const workflow = readFileSync('.github/workflows/makefile.yml', 'utf8');
const found = workflow.match(/\[\[ "\$TAG_VERSION" =~ ([^\s]+) \]\]/);
assert.ok(found, 'release workflow tag-version validator is missing');

function accepted(version) {
	const result = spawnSync('bash', [ '-c', `[[ "$1" =~ ${found[1]} ]]`, '--', version ]);
	assert.equal(result.error, undefined);
	return result.status === 0;
}

for (const version of [ '2.5.2', '2.5.2-rc.1', '2.5.2_rc1' ])
	assert.equal(accepted(version), true, `release workflow rejected ${version}`);

for (const version of [ 'v2.5.2', '2.5', '2.5.2_rc', '2.5.2__rc1', '2.5.2/rc1' ])
	assert.equal(accepted(version), false, `release workflow accepted malformed ${version}`);

console.log('release tag version contract passed');
