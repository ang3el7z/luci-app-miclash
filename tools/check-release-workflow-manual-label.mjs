import { readFileSync } from 'node:fs';

const workflowPath = '.github/workflows/makefile.yml';
const workflow = readFileSync(workflowPath, 'utf8');

let failed = false;

function check(condition, message) {
	if (!condition) {
		console.error(message);
		failed = true;
	}
}

check(!workflow.includes('softprops/action-gh-release'),
	'Release workflow must not use action-gh-release because it overwrites manual release labels.');
check(!/^\s+prerelease:/m.test(workflow),
	'Release workflow must not set prerelease; the release label is managed manually in GitHub.');
check(!/^\s+make_latest:/m.test(workflow),
	'Release workflow must not set make_latest; the release label is managed manually in GitHub.');
check(!/^\s+draft:/m.test(workflow),
	'Release workflow must not set draft; release metadata is managed manually in GitHub.');
check(workflow.includes('Resolve Existing GitHub Release') &&
	workflow.includes('/releases/tags/${TAG_NAME}') &&
	workflow.includes('Create the GitHub Release for this tag manually'),
	'Release workflow must resolve an existing manually-created release and fail clearly when it is missing.');
check(workflow.includes('Upload Release Assets') &&
	workflow.includes('/releases/assets/') &&
	workflow.includes('upload_url') &&
	workflow.includes('--data-binary') &&
	workflow.includes('?name='),
	'Release workflow must upload build artifacts to the existing release without editing release metadata.');
check(!workflow.includes('release_notes.md') &&
	!workflow.includes('body_path') &&
	!workflow.includes('PATCH "$api/releases/'),
	'Release workflow must not overwrite manually edited release notes or other release metadata.');

if (failed) process.exit(1);
console.log('release workflow manual label check passed');
