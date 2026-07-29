import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const installerUrl =
	'https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh';
const readmes = [ 'README.md', 'README.ru.md', 'README.zh-cn.md' ];
const expectedDetails = [ '1:🔵', '1:🟡', '2:🔵' ];

function alternativeUrls(url) {
	const repositoryPath = url.replace('https://raw.githubusercontent.com/', '');
	return [
		`https://gh-proxy.com/${url}`,
		`https://cdn.jsdelivr.net/gh/${repositoryPath.replace('/main/', '@main/')}`
	];
}

function assertInstallationStructure(text, path) {
	const section = text.match(/^## (?:Installation|Установка|安装)\r?\n[\s\S]*?(?=^## )/m)?.[0];
	assert.ok(section, `${path} must retain a recognizable installation section`);

	const stack = [];
	const summaries = [];
	const tokens = section.matchAll(
		/<details>|<\/details>|<blockquote>|<\/blockquote>|<summary><strong>([🔵🟡🔴])[^<]*<\/strong><\/summary>/gu
	);
	for (const match of tokens) {
		const token = match[0];
		if (token === '<details>' || token === '<blockquote>') {
			stack.push(token.slice(1, -1));
		} else if (token === '</details>' || token === '</blockquote>') {
			const expected = token.slice(2, -1);
			assert.equal(stack.pop(), expected, `${path} has invalid ${token} nesting`);
		} else {
			assert.equal(stack.at(-1), 'details', `${path} has a summary outside details`);
			const depth = stack.filter((name) => name === 'details').length;
			summaries.push(`${depth}:${match[1]}`);
		}
	}
	assert.deepEqual(stack, [], `${path} has unclosed installation disclosure tags`);
	assert.deepEqual(summaries, expectedDetails,
		`${path} must order the supported download options`);

	const commandBlocks = [ ...section.matchAll(/```sh\r?\n([\s\S]*?)\r?\n```/g) ];
	assert.equal(commandBlocks.length, 6, `${path} must contain 6 installation commands`);
	for (const block of commandBlocks) {
		const commands = block[1].split(/\r?\n/).filter((line) => line.trim());
		assert.equal(commands.length, 1, `${path} must keep one command in each shell block`);
	}
}

for (const path of readmes) {
	const text = readFileSync(path, 'utf8');
	assert.match(text, /OpenWrt 24\.10\+/,
		`${path} must retain the supported OpenWrt floor`);
	assert.ok(text.includes(`wget --no-proxy -qO- ${installerUrl} | ash`),
		`${path} must provide the maintained wget installer`);
	assert.ok(text.includes(`curl -fsSL ${installerUrl} | ash`),
		`${path} must provide the maintained curl installer`);
	assert.doesNotMatch(text, /api\.github\.com\/repos\/ang3el7z\/luci-app-miclash\/releases\/latest/,
		`${path} must not construct installation from an incomplete latest release`);
	assert.doesNotMatch(text, /package="luci-app-miclash[-_]/,
		`${path} must delegate exact package selection to the maintained installer`);
	assert.match(text, /20/, `${path} must document the bounded ready-release scan`);
	for (const alternativeUrl of alternativeUrls(installerUrl)) {
		assert.ok(text.includes(`wget --no-proxy -qO- ${alternativeUrl} | ash`),
			`${path} must provide the alternative wget command for ${alternativeUrl}`);
		assert.ok(text.includes(`curl -fsSL ${alternativeUrl} | ash`),
			`${path} must provide the alternative curl command for ${alternativeUrl}`);
	}
	assertInstallationStructure(text, path);
}

assert.match(readFileSync('README.md', 'utf8'), /does \*\*not\*\* fall back/);
assert.match(readFileSync('README.ru.md', 'utf8'), /\*\*не откатывается\*\*/);
assert.match(readFileSync('README.zh-cn.md', 'utf8'), /\*\*不会回退\*\*/);

const installer = readFileSync('install-miclash.sh', 'utf8');
assert.match(installer, /releases\?per_page=20/);
assert.match(installer, /luci-app-miclash-\$\{clean_tag\}\.apk/);
assert.match(installer, /luci-app-miclash_\$\{clean_tag\}_all\.ipk/);
assert.match(installer, /miclash-release-manifest\.json/);
assert.match(installer,
	/supported_openwrt_release\(\)[\s\S]*release_major[\s\S]*release_minor[\s\S]*-gt 24[\s\S]*-eq 24[\s\S]*-ge 10/,
	'installer must enforce the exact OpenWrt 24.10 boundary instead of accepting every 24.x release');
assert.match(installer, /case "\$release" in[\s\S]*\*\.\*[\s\S]*release_minor[\s\S]*-n "\$release_minor"/,
	'installer must not interpret a major-only release such as 24 as its own minor version');

console.log('terminal installation documentation contract passed');
