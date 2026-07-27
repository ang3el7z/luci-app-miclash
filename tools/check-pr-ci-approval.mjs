import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const workflow = readFileSync('.github/workflows/checks.yml', 'utf8');
const approvalGate = "if: ${{ github.event_name == 'push' || github.event.label.name == 'ci-approved' }}";

assert.match(workflow,
	/^on:\s*\n\s{2}pull_request:\s*\n\s{4}types:\s*\n\s{6}- labeled\s*\n\s{2}push:\s*\n\s{4}branches:\s*\n\s{6}- main/m,
	'PR checks must run only for label events while main pushes remain protected');

for (const job of [ 'repository-checks', 'ucode-tests', 'package-build' ]) {
	const start = workflow.indexOf(`  ${job}:`);
	assert.ok(start >= 0, `missing CI job: ${job}`);

	const remainder = workflow.slice(start + 2);
	const nextJob = remainder.search(/^  [a-z0-9-]+:\s*$/m);
	const block = nextJob >= 0 ? remainder.slice(0, nextJob) : remainder;

	assert.ok(block.includes(approvalGate),
		`${job} must be gated by the ci-approved label on pull requests`);
}

console.log('manual PR CI approval contract passed');
