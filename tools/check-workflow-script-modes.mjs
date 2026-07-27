import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const workflowRoot = '.github/workflows';
const referenced = new Set();

for (const name of readdirSync(workflowRoot).filter((value) => /\.ya?ml$/.test(value))) {
	const source = readFileSync(join(workflowRoot, name), 'utf8');
	for (const match of source.matchAll(/tools\/[A-Za-z0-9._-]+\.sh/g))
		referenced.add(match[0]);
}

assert.ok(referenced.size > 0, 'no workflow shell gates were discovered');

for (const path of [ ...referenced ].sort()) {
	const entry = execFileSync('git', [ 'ls-files', '-s', '--', path ],
		{ encoding: 'utf8' }).trim();
	assert.match(entry, /^100755\s/, `${path} must be tracked executable (100755)`);
}

console.log(`workflow shell mode check passed (${referenced.size} scripts)`);
