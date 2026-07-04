import fs from 'node:fs';
import { spawnSync } from 'node:child_process';

const args = new Map();
for (let i = 2; i < process.argv.length; i++) {
	const arg = process.argv[i];
	if (arg.startsWith('--')) {
		const key = arg.slice(2);
		const value = process.argv[i + 1] && !process.argv[i + 1].startsWith('--')
			? process.argv[++i]
			: 'true';
		args.set(key, value);
	}
}

const base = args.get('base') || 'upstream/main';
const head = args.get('head') || 'HEAD';
const limit = Number(args.get('limit') || 12);
const localLimit = Number(args.get('local-limit') || 25);

function git(argv, options = {}) {
	const result = spawnSync('git', argv, {
		encoding: 'utf8',
		maxBuffer: 20 * 1024 * 1024,
		...options
	});
	if (result.status !== 0) {
		throw new Error((result.stderr || result.stdout || `git ${argv.join(' ')} failed`).trim());
	}
	return String(result.stdout || '').trim();
}

function verifyRef(ref) {
	git(['rev-parse', '--verify', `${ref}^{commit}`]);
}

function mapUpstreamPath(file) {
	return file
		.replace(/^install-ssclash\.sh$/, 'install-miclash.sh')
		.replace(/^luci-app-ssclash\//, 'luci-app-miclash/')
		.replace(/\/view\/ssclash\//g, '/view/miclash/')
		.replace(/\/luci-app-ssclash\.json$/g, '/luci-app-miclash.json')
		.replace(/\/ssclash\.list$/g, '/miclash.list')
		.replace(/\/ssclash\.po$/g, '/miclash.po');
}

function filesChangedByCommit(commit) {
	const out = git(['show', '--format=', '--name-only', commit]);
	return out ? out.split('\n').filter(Boolean) : [];
}

function pathState(file) {
	if (fs.existsSync(file)) return 'present';
	const mapped = mapUpstreamPath(file);
	if (mapped !== file && fs.existsSync(mapped)) return `mapped -> ${mapped}`;
	return 'missing';
}

verifyRef(base);
verifyRef(head);

const baseSha = git(['rev-parse', '--short', base]);
const headSha = git(['rev-parse', '--short', head]);
const upstreamCommits = git(['log', '--format=%h%x09%s', `-${limit}`, base])
	.split('\n')
	.filter(Boolean);
const localOnly = git(['log', '--format=%h%x09%s', '--left-right', '--cherry-pick', `${base}...${head}`])
	.split('\n')
	.filter(Boolean);
const nameStatus = git(['diff', '--name-status', '--find-renames=50%', `${base}...${head}`])
	.split('\n')
	.filter(Boolean);

console.log(`# Upstream Sync Audit`);
console.log();
console.log(`Base: ${base} (${baseSha})`);
console.log(`Head: ${head} (${headSha})`);
console.log();

console.log(`## Recent upstream commits`);
for (const line of upstreamCommits) {
	const [hash, subject] = line.split('\t');
	console.log(`- ${hash} ${subject}`);
	const files = filesChangedByCommit(hash);
	for (const file of files) {
		const mapped = mapUpstreamPath(file);
		const state = pathState(file);
		console.log(`  - ${file}${mapped !== file ? ` -> ${mapped}` : ''} [${state}]`);
	}
}
console.log();

console.log(`## Local-only commits`);
if (localOnly.length) {
	for (const line of localOnly.slice(0, localLimit)) console.log(`- ${line.replace(/^\>/, '').trim()}`);
	if (localOnly.length > localLimit) {
		console.log(`- ... ${localOnly.length - localLimit} more (use --local-limit ${localOnly.length} to show all)`);
	}
} else {
	console.log('- none');
}
console.log();

console.log(`## File-level delta (${base}...${head})`);
for (const line of nameStatus) console.log(`- ${line}`);
console.log();

console.log(`## Useful review commands`);
console.log(`- git diff --find-renames=50% ${base}...${head}`);
console.log(`- git log --oneline --left-right --cherry-pick ${base}...${head}`);
console.log(`- node tools/upstream-sync-audit.mjs --base ${base} --head ${head} --limit ${limit} --local-limit ${localLimit}`);
