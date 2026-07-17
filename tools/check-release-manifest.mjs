import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { lstatSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { buildReleaseManifest } from './build-release-manifest.mjs';

const MANIFEST_NAME = 'miclash-release-manifest.json';
const SHA_PATTERN = /^[0-9a-f]{64}$/;
const COMMIT_PATTERN = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;
const SAFE_FILENAME = /^[A-Za-z0-9][A-Za-z0-9._+-]*\.(?:ipk|apk)$/;

function exactKeys(value, keys, label) {
	assert.deepEqual(Object.keys(value), keys, `${label} has unexpected or missing fields`);
}

function sha256(path) {
	return createHash('sha256').update(readFileSync(path)).digest('hex');
}

export function verifyReleaseManifest({ manifestPath, assetsDir }) {
	assert.equal(lstatSync(manifestPath).isSymbolicLink(), false, 'manifest must not be a symlink');
	assert.equal(lstatSync(manifestPath).isFile(), true, 'manifest must be a regular file');
	assert.equal(lstatSync(assetsDir).isSymbolicLink(), false, 'assets directory must not be a symlink');
	assert.equal(lstatSync(assetsDir).isDirectory(), true, 'assets directory is invalid');
	const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
	exactKeys(manifest, [ 'schema_version', 'tag', 'source_tag_sha', 'synced_build_sha', 'installer', 'artifacts' ],
		'release manifest');
	assert.equal(manifest.schema_version, 1);
	assert.match(manifest.tag, /^v[0-9]+\.[0-9]+\.[0-9]+(?:[.-][0-9A-Za-z.-]+)?$/);
	assert.match(manifest.source_tag_sha, COMMIT_PATTERN);
	assert.match(manifest.synced_build_sha, COMMIT_PATTERN);
	exactKeys(manifest.installer, [ 'filename', 'sha256' ], 'installer');
	assert.equal(manifest.installer.filename, 'install-miclash.sh');
	assert.match(manifest.installer.sha256, SHA_PATTERN);
	const installerChecksum = join(assetsDir, 'install-miclash.sh.sha256');
	assert.equal(lstatSync(installerChecksum).isSymbolicLink(), false,
		'installer checksum must not be a symlink');
	assert.equal(lstatSync(installerChecksum).isFile(), true);
	assert.equal(readFileSync(installerChecksum, 'utf8'),
		`${manifest.installer.sha256}  install-miclash.sh\n`);
	assert.ok(Array.isArray(manifest.artifacts) && manifest.artifacts.length > 0,
		'release manifest has no artifacts');
	const filenames = manifest.artifacts.map((artifact) => artifact.filename);
	assert.deepEqual(filenames, filenames.slice().sort(), 'manifest artifacts are not filename-sorted');
	assert.equal(new Set(filenames).size, filenames.length, 'manifest contains duplicate filenames');
	for (const artifact of manifest.artifacts) {
		exactKeys(artifact, [ 'filename', 'sdk', 'package_type', 'size', 'sha256' ],
			`artifact ${artifact.filename || '<missing>'}`);
		exactKeys(artifact.sdk, [ 'release', 'target' ], `SDK for ${artifact.filename}`);
		assert.match(artifact.filename, SAFE_FILENAME);
		assert.match(artifact.sdk.release, /^(?:24\.10|25\.12)\.[0-9]+$/);
		assert.match(artifact.sdk.target, /^[a-z0-9][a-z0-9._+-]*\/[a-z0-9][a-z0-9._+-]*$/);
		assert.ok(artifact.package_type === 'ipk' || artifact.package_type === 'apk');
		assert.equal(artifact.filename.endsWith(`.${artifact.package_type}`), true);
		assert.ok(Number.isSafeInteger(artifact.size) && artifact.size > 0);
		assert.match(artifact.sha256, SHA_PATTERN);
		const packagePath = join(assetsDir, artifact.filename);
		const packageStat = lstatSync(packagePath);
		assert.equal(packageStat.isSymbolicLink(), false, `${artifact.filename} must not be a symlink`);
		assert.equal(packageStat.isFile(), true);
		assert.equal(packageStat.size, artifact.size);
		assert.equal(sha256(packagePath), artifact.sha256);
		const checksumPath = `${packagePath}.sha256`;
		assert.equal(lstatSync(checksumPath).isSymbolicLink(), false,
			`${artifact.filename}.sha256 must not be a symlink`);
		assert.equal(lstatSync(checksumPath).isFile(), true);
		assert.equal(readFileSync(checksumPath, 'utf8'),
			`${artifact.sha256}  ${artifact.filename}\n`);
	}
	const expectedFiles = [ MANIFEST_NAME, 'install-miclash.sh.sha256',
		...filenames.flatMap((filename) => [ filename, `${filename}.sha256` ]) ].sort();
	assert.deepEqual(readdirSync(assetsDir).sort(), expectedFiles,
		'release directory contains stale, missing, or unmanifested files');
	return manifest;
}

function writeBuild(root, directory, metadata, bytes) {
	const path = join(root, directory);
	mkdirSync(path, { recursive: true });
	writeFileSync(join(path, metadata.filename), bytes);
	writeFileSync(join(path, 'release-metadata.json'), `${JSON.stringify(metadata, null, 2)}\n`);
}

function expectFailure(fn, pattern) {
	assert.throws(fn, pattern);
}

function runBuilderContracts() {
	const root = mkdtempSync(join(tmpdir(), 'miclash-release-'));
	try {
		const artifacts = join(root, 'artifacts');
		const first = join(root, 'out-a');
		const second = join(root, 'out-b');
		const apk = {
			filename: 'luci-app-miclash-1.2.3.apk', sdk: { release: '25.12.5', target: 'x86/64' },
			package_type: 'apk'
		};
		const ipk = {
			filename: 'luci-app-miclash_1.2.3_all.ipk', sdk: { release: '24.10.7', target: 'x86/64' },
			package_type: 'ipk'
		};
		writeBuild(artifacts, 'z-apk', apk, Buffer.from('apk fixture\n'));
		writeBuild(artifacts, 'a-ipk', ipk, Buffer.from('ipk fixture\n'));
		const options = {
			artifactsDir: artifacts, tag: 'v1.2.3', sourceTagSha: 'a'.repeat(40),
			syncedBuildSha: 'b'.repeat(40), installerPath: join(root, 'install-miclash.sh')
		};
		writeFileSync(options.installerPath, '#!/bin/sh\nexit 0\n');
		process.env.GH_TOKEN = 'must-never-appear-in-release-output';
		buildReleaseManifest({ ...options, outputDir: first });
		buildReleaseManifest({ ...options, outputDir: second });
		const manifest = verifyReleaseManifest({
			manifestPath: join(first, MANIFEST_NAME), assetsDir: first
		});
		verifyReleaseManifest({ manifestPath: join(second, MANIFEST_NAME), assetsDir: second });
		assert.equal(readFileSync(join(first, MANIFEST_NAME), 'utf8'),
			readFileSync(join(second, MANIFEST_NAME), 'utf8'), 'manifest is not reproducible');
		assert.deepEqual(manifest.artifacts.map((entry) => entry.filename),
			[ apk.filename, ipk.filename ].sort());
		for (const file of readdirSync(first))
			assert.equal(readFileSync(join(first, file)).includes('must-never-appear-in-release-output'), false,
				`${file} leaked an environment secret`);

		const unsafeRoot = join(root, 'unsafe');
		mkdirSync(join(unsafeRoot, 'one'), { recursive: true });
		writeFileSync(join(unsafeRoot, 'one', 'release-metadata.json'), JSON.stringify({
			...ipk, filename: '../escape.ipk'
		}));
		expectFailure(() => buildReleaseManifest({ ...options, artifactsDir: unsafeRoot,
			outputDir: join(root, 'unsafe-out') }), /filename/i);

		const duplicateRoot = join(root, 'duplicate');
		writeBuild(duplicateRoot, 'one', apk, Buffer.from('one'));
		writeBuild(duplicateRoot, 'two', apk, Buffer.from('two'));
		expectFailure(() => buildReleaseManifest({ ...options, artifactsDir: duplicateRoot,
			outputDir: join(root, 'duplicate-out') }), /duplicate/i);
	} finally {
		rmSync(root, { recursive: true, force: true });
		delete process.env.GH_TOKEN;
	}
}

function sdkEntries(workflow, marker) {
	const start = workflow.indexOf(marker);
	assert.ok(start >= 0, `workflow is missing ${marker}`);
	return [ ...workflow.slice(start).matchAll(/- sdk_version: ["']([^"']+)["'][\s\S]*?(?:package_manager|pkg_type): ["']?([a-z]+)["']?[\s\S]*?arch: ["']?([^\s"']+)/g) ]
		.map((match) => `${match[1]}:${match[2]}:${match[3]}`);
}

function runRepositoryContracts() {
	const release = readFileSync('.github/workflows/makefile.yml', 'utf8');
	const checks = readFileSync('.github/workflows/checks.yml', 'utf8');
	assert.match(release, /github-actions\[bot\]: sync Makefile version/,
		'release bot sync behavior was removed');
	assert.match(release, /SYNCED_BUILD_SHA="\$\(git rev-parse HEAD\)"/);
	assert.match(release, /sync_sha=\$SYNCED_BUILD_SHA/);
	assert.match(release, /source_tag_sha/);
	assert.match(release, /git diff --name-only[^\n]*SOURCE_TAG_SHA[^\n]*SYNCED_BUILD_SHA/,
		'release must compare the tagged and synchronized source trees');
	assert.match(release, /PKG_VERSION[\s\S]*SOURCE_TAG_SHA[\s\S]*SYNCED_BUILD_SHA/,
		'release must allow only the isolated package-version change');
	assert.ok(release.indexOf('git diff --name-only "$SOURCE_TAG_SHA" "$SYNCED_BUILD_SHA"') <
		release.indexOf('git push origin "HEAD:${TARGET_BRANCH}"'),
		'release must validate the synchronized tree before pushing it');
	assert.match(release, /Create the GitHub Release for this tag manually first/,
		'existing manual release lookup requirement was removed');
	assert.match(release, /-X DELETE[\s\S]*releases\/assets\/\$\{asset_id\}[\s\S]*-X POST/,
		'same-name replacement must retain explicit delete-before-upload');
	assert.doesNotMatch(release, /\bgh release upload\b|--clobber/);
	assert.match(release, /release-metadata\.json/);
	assert.ok(release.includes('dst="${{ github.workspace }}/${PACKAGE_NAME}_${TAG_VERSION}_all.ipk"'),
		'release workflow must normalize the raw SDK IPK revision suffix');
	assert.ok(release.includes('dst="${{ github.workspace }}/${PACKAGE_NAME}-${TAG_VERSION}.apk"'),
		'release workflow must normalize the raw SDK APK revision suffix');
	assert.match(release, /RELEASE_METADATA_PATH="\$\{\{ github\.workspace \}\}\/release-metadata\.json"/);
	assert.match(release, /node tools\/build-release-manifest\.mjs/);
	assert.match(release, /--installer install-miclash\.sh/);
	assert.match(release, /git rev-parse HEAD[\s\S]*SOURCE_TAG_SHA/,
		'release assets must be generated from the tagged source checkout');
	assert.match(release, /node tools\/check-release-manifest\.mjs/);
	assert.match(release, /miclash-release-manifest\.json/);
	for (const phase of [ 'Delete Existing Publication Manifest',
		'Upload Non-Manifest Release Assets', 'Verify Published Non-Manifest Assets',
		'Upload Publication Manifest Last' ])
		assert.match(release, new RegExp(phase), `release workflow is missing ${phase}`);
	assert.ok(release.indexOf('Verify Published Non-Manifest Assets') <
		release.indexOf('Upload Publication Manifest Last'),
		'publication manifest must be uploaded only after asset verification');
	assert.match(release, /\.sha256/);
	assert.deepEqual(sdkEntries(release, 'build:'), [
		'24.10.7:ipk:x86/64', '25.12.5:apk:x86/64'
	], 'release SDK matrix differs from the supported package formats');
	assert.deepEqual(sdkEntries(checks, 'package-build:'), [
		'24.10.7:opkg:x86/64', '25.12.5:apk:x86/64', '25.12.5:apk:mediatek/filogic'
	], 'PR CI must build the exact three-SDK supported matrix');
	for (const [ name, workflow ] of [ [ 'release', release ], [ 'checks', checks ] ]) {
		assert.match(workflow, /# CONFIG_ALL_KMODS is not set/,
			`${name} workflow must disable the SDK-wide kmod build`);
		assert.match(workflow, /# CONFIG_ALL_NONSHARED is not set/,
			`${name} workflow must disable the SDK-wide nonshared build`);
		assert.match(workflow, /CONFIG_PACKAGE_luci-app-miclash=m/,
			`${name} workflow must select only MiClash and its dependencies`);
		const packageBuild = workflow.slice(workflow.indexOf('ln -s'));
		assert.ok(packageBuild.indexOf('# CONFIG_ALL_KMODS is not set') <
			packageBuild.indexOf('make defconfig'),
			`${name} workflow must disable SDK-wide selections before its first defconfig`);
	}
	assert.doesNotMatch(release + checks, /23\.05|25\.12\.0-rc/);
	assert.match(checks, /actionlint/);
	for (const gate of [ 'check-native-cutover.sh', 'check-dns-lifecycle.sh',
		'check-guard-runtime.sh', 'check-routing-netns.sh', 'check-mutation-lock.sh',
		'check-package-cleanup.sh', 'check-package-release.sh', 'check-package-removal.sh',
		'check-hard-reinstall-marker.sh', 'check-ready-release-selection.sh',
		'check-update-status-protocol.sh' ])
		assert.match(checks, new RegExp(gate.replace('.', '\\.')));

	const docs = [ 'README.md', 'README.ru.md', 'README.zh-cn.md' ];
	const commands = [ '/status', '/health', '/memory', '/diagnostics', '/logs', '/help',
		'/start', '/stop', '/restart', '/reload', '/reboot', '/subscription URL',
		'/update_subscription', '/update_miclash', '/update_mihomo', '/guard_on',
		'/guard_off', '/backup' ];
	const required = [ 'OpenWrt 24.10+', '25.12', 'miclashd', 'ubus', 'UCI', 'Guard', 'latch',
		'Draft', 'Active', 'diagnostic', 'route test', 'notification', 'Telegram', '/status',
		'/reboot', 'history', 'rollback', 'backup', 'restore', 'device polic', 'v0.9.2',
		'update', 'recovery', 'removal' ];
	for (const path of docs) {
		const text = readFileSync(path, 'utf8');
		assert.doesNotMatch(text, /23\.05/, `${path} still documents unsupported OpenWrt 23.05`);
		for (const token of required)
			assert.ok(text.toLowerCase().includes(token.toLowerCase()), `${path} is missing ${token}`);
		const commandBlocks = [ ...text.matchAll(/```text\r?\n([\s\S]*?)```/g) ];
		assert.equal(commandBlocks.length, 1, `${path} must contain one Telegram command block`);
		assert.deepEqual(commandBlocks[0][1].trim().split(/\r?\n/), commands,
			`${path} has inconsistent Telegram command documentation`);
		assert.doesNotMatch(text, /-o \/tmp\/luci-app-miclash|apk add \/tmp\/luci-app-miclash|opkg install \/tmp\/luci-app-miclash/,
			`${path} documents a predictable world-writable package path`);
		assert.ok(text.includes('main/install-miclash.sh | ash'),
			`${path} must delegate ready-release selection to the maintained installer`);
		assert.doesNotMatch(text, /releases\/latest|package="luci-app-miclash[-_]/,
			`${path} must not construct a package from a possibly incomplete latest release`);
	}
}

function parseArguments(values) {
	const result = {};
	for (let index = 0; index < values.length; index += 2) {
		const flag = values[index], value = values[index + 1];
		assert.ok(flag?.startsWith('--') && value != null && !value.startsWith('--'),
			'arguments must be --name value pairs');
		const name = flag.slice(2);
		assert.ok(name === 'manifest' || name === 'assets-dir', `unknown argument: ${flag}`);
		assert.equal(result[name], undefined, `duplicate argument: ${flag}`);
		result[name] = value;
	}
	return result;
}

if (process.argv.length > 2) {
	const args = parseArguments(process.argv.slice(2));
	assert.ok(args.manifest && args['assets-dir'],
		'usage: check-release-manifest.mjs --manifest FILE --assets-dir DIRECTORY');
	verifyReleaseManifest({ manifestPath: args.manifest, assetsDir: args['assets-dir'] });
	console.log('release manifest assets verified');
} else {
	runBuilderContracts();
	runRepositoryContracts();
	console.log('release manifest/workflow/documentation contracts passed');
}
