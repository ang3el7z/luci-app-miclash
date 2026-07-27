import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import {
	copyFileSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, renameSync,
	rmSync, statSync, writeFileSync
} from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const MANIFEST_NAME = 'miclash-release-manifest.json';
const METADATA_NAME = 'release-metadata.json';
const SAFE_FILENAME = /^[A-Za-z0-9][A-Za-z0-9._+-]*\.(?:ipk|apk)$/;
const TAG_PATTERN = /^v[0-9]+\.[0-9]+\.[0-9]+(?:(?:[.-][0-9A-Za-z][0-9A-Za-z.-]*)|(?:_rc[0-9]+))?$/;
const COMMIT_PATTERN = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;
const SDK_PATTERN = /^(?:24\.10|25\.12)\.[0-9]+$/;
const TARGET_PATTERN = /^[a-z0-9][a-z0-9._+-]*\/[a-z0-9][a-z0-9._+-]*$/;
const byteOrder = (left, right) => left < right ? -1 : left > right ? 1 : 0;

function exactKeys(value, keys, label) {
	assert.ok(value && typeof value === 'object' && !Array.isArray(value), `${label} must be an object`);
	assert.deepEqual(Object.keys(value).sort(), keys.slice().sort(), `${label} has unexpected or missing fields`);
}

function metadataFiles(root) {
	const found = [];
	function walk(directory) {
		for (const entry of readdirSync(directory, { withFileTypes: true })
			.sort((left, right) => byteOrder(left.name, right.name))) {
			const path = join(directory, entry.name);
			if (entry.isSymbolicLink()) throw new Error(`symlink is forbidden in artifacts: ${path}`);
			if (entry.isDirectory()) walk(path);
			else if (entry.isFile() && entry.name === METADATA_NAME) found.push(path);
		}
	}
	walk(root);
	return found.sort(byteOrder);
}

function readBuild(metadataPath) {
	const metadata = JSON.parse(readFileSync(metadataPath, 'utf8'));
	exactKeys(metadata, [ 'filename', 'sdk', 'package_type' ], metadataPath);
	exactKeys(metadata.sdk, [ 'release', 'target' ], `${metadataPath} sdk`);
	assert.equal(typeof metadata.filename, 'string', `${metadataPath} filename must be a string`);
	assert.equal(metadata.filename, basename(metadata.filename), `${metadataPath} filename must be a basename`);
	assert.match(metadata.filename, SAFE_FILENAME, `${metadataPath} filename is unsafe`);
	assert.match(metadata.sdk.release, SDK_PATTERN, `${metadataPath} SDK release is unsupported`);
	assert.match(metadata.sdk.target, TARGET_PATTERN, `${metadataPath} SDK target is invalid`);
	assert.ok(metadata.package_type === 'ipk' || metadata.package_type === 'apk',
		`${metadataPath} package type is invalid`);
	assert.equal(metadata.filename.endsWith(`.${metadata.package_type}`), true,
		`${metadataPath} package extension does not match package type`);
	const packagePath = join(dirname(metadataPath), metadata.filename);
	assert.ok(existsSync(packagePath), `${metadataPath} package does not exist`);
	const packageStat = lstatSync(packagePath);
	assert.equal(packageStat.isSymbolicLink(), false, `${metadataPath} package must not be a symlink`);
	assert.equal(packageStat.isFile(), true, `${metadataPath} package must be a regular file`);
	assert.ok(packageStat.size > 0, `${metadataPath} package is empty`);
	return { metadata, packagePath };
}

function hash(path) {
	return createHash('sha256').update(readFileSync(path)).digest('hex');
}

function atomicCopy(source, destination) {
	const temporary = `${destination}.tmp-${process.pid}`;
	try {
		copyFileSync(source, temporary);
		renameSync(temporary, destination);
	} finally {
		rmSync(temporary, { force: true });
	}
}

function atomicWrite(destination, content) {
	const temporary = `${destination}.tmp-${process.pid}`;
	try {
		writeFileSync(temporary, content, { encoding: 'utf8', mode: 0o644 });
		renameSync(temporary, destination);
	} finally {
		rmSync(temporary, { force: true });
	}
}

export function buildReleaseManifest({
	artifactsDir, outputDir, installerPath, transitionInstallerPath, tag, sourceTagSha, syncedBuildSha
}) {
	assert.equal(typeof artifactsDir, 'string');
	assert.equal(typeof outputDir, 'string');
	assert.equal(typeof installerPath, 'string');
	assert.equal(typeof transitionInstallerPath, 'string');
	assert.match(tag, TAG_PATTERN, 'release tag is invalid');
	assert.match(sourceTagSha, COMMIT_PATTERN, 'source tag SHA is invalid');
	assert.match(syncedBuildSha, COMMIT_PATTERN, 'synced build SHA is invalid');
	const artifactsRoot = resolve(artifactsDir);
	const outputRoot = resolve(outputDir);
	const installerSource = resolve(installerPath);
	const transitionInstallerSource = resolve(transitionInstallerPath);
	assert.ok(existsSync(artifactsRoot) && statSync(artifactsRoot).isDirectory(),
		'artifacts directory does not exist');
	assert.equal(basename(installerSource), 'install-miclash.sh',
		'installer source must be install-miclash.sh');
	assert.ok(existsSync(installerSource), 'installer source does not exist');
	assert.equal(lstatSync(installerSource).isSymbolicLink(), false,
		'installer source must not be a symlink');
	assert.equal(lstatSync(installerSource).isFile(), true,
		'installer source must be a regular file');
	assert.equal(basename(transitionInstallerSource), 'install-miclash-upgrade-0-9-x-to-2.x.x.sh',
		'transition installer source has an unexpected filename');
	assert.ok(existsSync(transitionInstallerSource), 'transition installer source does not exist');
	assert.equal(lstatSync(transitionInstallerSource).isSymbolicLink(), false,
		'transition installer source must not be a symlink');
	assert.equal(lstatSync(transitionInstallerSource).isFile(), true,
		'transition installer source must be a regular file');
	assert.notEqual(artifactsRoot, outputRoot, 'output directory must differ from artifacts directory');
	const builds = metadataFiles(artifactsRoot).map(readBuild);
	assert.ok(builds.length > 0, `no ${METADATA_NAME} files found`);
	builds.sort((left, right) => byteOrder(left.metadata.filename, right.metadata.filename));
	const filenames = builds.map((build) => build.metadata.filename);
	assert.equal(new Set(filenames).size, filenames.length, 'duplicate normalized artifact filename');
	if (existsSync(outputRoot)) {
		assert.equal(lstatSync(outputRoot).isSymbolicLink(), false, 'output directory must not be a symlink');
		assert.equal(statSync(outputRoot).isDirectory(), true, 'output path is not a directory');
		assert.deepEqual(readdirSync(outputRoot), [], 'output directory must be empty');
	} else mkdirSync(outputRoot, { recursive: true, mode: 0o755 });

	const artifacts = [];
	try {
		for (const build of builds) {
			const destination = join(outputRoot, build.metadata.filename);
			atomicCopy(build.packagePath, destination);
			const sha256 = hash(destination);
			const size = statSync(destination).size;
			atomicWrite(`${destination}.sha256`, `${sha256}  ${build.metadata.filename}\n`);
			artifacts.push({
				filename: build.metadata.filename,
				sdk: { release: build.metadata.sdk.release, target: build.metadata.sdk.target },
				package_type: build.metadata.package_type,
				size,
				sha256
			});
		}
		const installers = [
			[ 'installer', 'install-miclash.sh', installerSource ],
			[ 'transition_installer', 'install-miclash-upgrade-0-9-x-to-2.x.x.sh', transitionInstallerSource ]
		];
		const installerEntries = {};
		for (const [ field, filename, source ] of installers) {
			const destination = join(outputRoot, filename);
			atomicCopy(source, destination);
			const sha256 = hash(destination);
			const size = statSync(destination).size;
			atomicWrite(`${destination}.sha256`, `${sha256}  ${filename}\n`);
			installerEntries[field] = { filename, size, sha256 };
		}
		const manifest = {
			schema_version: 1,
			tag,
			source_tag_sha: sourceTagSha,
			synced_build_sha: syncedBuildSha,
			installer: installerEntries.installer,
			transition_installer: installerEntries.transition_installer,
			artifacts
		};
		atomicWrite(join(outputRoot, MANIFEST_NAME), `${JSON.stringify(manifest, null, 2)}\n`);
		return manifest;
	} catch (error) {
		for (const name of readdirSync(outputRoot)) rmSync(join(outputRoot, name), { force: true });
		throw error;
	}
}

function parseArguments(values) {
	const result = {};
	for (let index = 0; index < values.length; index += 2) {
		const flag = values[index];
		const value = values[index + 1];
		assert.ok(flag?.startsWith('--') && value != null && !value.startsWith('--'),
			'arguments must be --name value pairs');
		const name = flag.slice(2);
		assert.equal(result[name], undefined, `duplicate argument: ${flag}`);
		result[name] = value;
	}
	return result;
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
	const args = parseArguments(process.argv.slice(2));
	for (const name of [ 'artifacts-dir', 'output-dir', 'installer', 'transition-installer', 'tag', 'source-tag-sha', 'synced-build-sha' ])
		assert.ok(args[name], `missing --${name}`);
	const manifest = buildReleaseManifest({
		artifactsDir: args['artifacts-dir'],
		outputDir: args['output-dir'],
		installerPath: args.installer,
		transitionInstallerPath: args['transition-installer'],
		tag: args.tag,
		sourceTagSha: args['source-tag-sha'],
		syncedBuildSha: args['synced-build-sha']
	});
	console.log(`release manifest built (${manifest.artifacts.length} artifacts)`);
}
