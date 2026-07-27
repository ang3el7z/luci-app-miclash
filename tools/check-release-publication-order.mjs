import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const workflow = readFileSync('.github/workflows/makefile.yml', 'utf8');
const phases = [
	'Delete Existing Publication Manifest',
	'Upload Non-Manifest Release Assets',
	'Verify Published Non-Manifest Assets',
	'Upload Publication Manifest Last'
];

for (const phase of phases)
	assert.ok(workflow.includes(phase), `release workflow is missing phase: ${phase}`);
for (let index = 1; index < phases.length; index++)
	assert.ok(workflow.indexOf(phases[index - 1]) < workflow.indexOf(phases[index]),
		`${phases[index]} must follow ${phases[index - 1]}`);

assert.match(workflow, /name != "miclash-release-manifest\.json"/,
	'non-manifest upload phase must explicitly exclude the publication marker');
assert.match(workflow, /miclash-release-manifest\.json[\s\S]*Upload Publication Manifest Last/,
	'the manifest must be handled before its final dedicated upload phase');
assert.match(workflow, /Delete Existing Publication Manifest[\s\S]*asset_id[\s\S]*-X DELETE/,
	'an existing publication marker must be deleted explicitly');
assert.match(workflow, /if \[ -n "\$asset_id" \]/,
	'a missing old publication marker must be tolerated');
assert.match(workflow, /Verify Published Non-Manifest Assets[\s\S]*duplicate|Verify Published Non-Manifest Assets[\s\S]*missing/i,
	'published non-manifest assets must be checked for missing or duplicate names');
assert.doesNotMatch(workflow, /Upload Publication Manifest Last[\s\S]*\n\s*- name:/,
	'no later workflow step may mutate release publication after the manifest marker');

console.log('release publication order check passed');
