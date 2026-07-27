import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const installerUrl =
	'https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh';
const upgradeUrl =
	'https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash-upgrade-0-9-x-to-2.x.x.sh';
const readmes = [ 'README.md', 'README.ru.md', 'README.zh-cn.md' ];
const expectedDetails = [ '1:🔵', '1:🟡', '2:🔵', '1:🔴', '2:🔵', '2:🟡', '3:🔵' ];

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
		`${path} must order download options as blue fallback, yellow curl and red upgrade`);

	const commandBlocks = [ ...section.matchAll(/```sh\r?\n([\s\S]*?)\r?\n```/g) ];
	assert.equal(commandBlocks.length, 12, `${path} must contain 12 installation commands`);
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
	assert.ok(text.includes(`wget --no-proxy -qO- ${upgradeUrl} | ash`),
		`${path} must provide the one-line v0.9 clean upgrade`);
	assert.ok(text.includes(`curl -fsSL ${upgradeUrl} | ash`),
		`${path} must provide the curl v0.9 clean upgrade`);
	for (const url of [ installerUrl, upgradeUrl ]) {
		for (const alternativeUrl of alternativeUrls(url)) {
			assert.ok(text.includes(`wget --no-proxy -qO- ${alternativeUrl} | ash`),
				`${path} must provide the alternative wget command for ${alternativeUrl}`);
			assert.ok(text.includes(`curl -fsSL ${alternativeUrl} | ash`),
				`${path} must provide the alternative curl command for ${alternativeUrl}`);
		}
	}
	assertInstallationStructure(text, path);
	assert.doesNotMatch(text, /mktemp -d \/tmp\/miclash-v09-clean/,
		`${path} must not expose the release-selection bootstrap`);
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

const upgrade = readFileSync('install-miclash-upgrade-0-9-x-to-2.x.x.sh', 'utf8');
assert.match(upgrade, /releases\?per_page=20/);
assert.match(upgrade, /jsonfilter/);
assert.match(upgrade, /miclash-release-manifest\.json/);
assert.match(upgrade, /Usage: .*\[--release-tag v2\.X\.Y\]/);
assert.match(upgrade, /ensure_stat_runtime\(\)[\s\S]*coreutils-stat/,
	'transition installer must bootstrap stat before invoking older v2 installers');
assert.match(upgrade, /find_resume_backup\(\)[\s\S]*upgrade-complete/,
	'transition installer must resume an interrupted replacement from its backup');
assert.doesNotMatch(upgrade, /UPGRADE_STATE='resume-restore'/,
	'an installed v2 package must not be trusted after an interrupted post-install');
assert.doesNotMatch(upgrade, /\[ -n "\$TAG" \] \|\| TAG="\$backup_tag"/,
	'an interrupted transition must select a newly ready v2 release by default');
assert.match(upgrade,
	/remove_incomplete_v2\(\)[\s\S]*apk --no-scripts del luci-app-miclash[\s\S]*opkg --force-remove remove luci-app-miclash[\s\S]*apk add coreutils-timeout ip-full ucode-mod-socket/,
	'an interrupted v2 post-install must bypass package hooks and then restore APK alternatives');
assert.match(upgrade,
	/remove_legacy_guard_rules\(\)[\s\S]*miclash_guard_bootstrap_v1 miclash_guard_emergency_v1 miclash_guard/,
	'transition cleanup must recognize every v2 Guard table');
assert.match(upgrade,
	/remove_incomplete_v2\(\)[\s\S]*remove_legacy_guard_rules[\s\S]*rm -rf \/var\/run\/miclash \/tmp\/miclash/,
	'an interrupted v2 post-install must clear only known Guard and volatile transition residue');
assert.match(upgrade,
	/UPGRADE_STATE='resume-install'[\s\S]*\[ "\$UPGRADE_STATE" = resume-install \][\s\S]*remove_incomplete_v2[\s\S]*clean-install --target-tag "\$TAG"/,
	'an interrupted v2 post-install must perform a clean ready-release reinstall');
const backupCreated = upgrade.indexOf('say "Backup created: $BACKUP"');
const guardDisabled = upgrade.indexOf('disable_legacy_guard', backupCreated);
const packageRemoved = upgrade.indexOf('apk del luci-app-miclash', guardDisabled);
assert.ok(backupCreated >= 0 && guardDisabled > backupCreated && packageRemoved > guardDisabled,
	'legacy Guard must be disabled after backup and before package removal');
assert.match(upgrade, /verify_legacy_guard_off \|\| die 'legacy Guard returned during package removal'/,
	'transition installer must verify that package removal did not restore legacy Guard');
assert.match(upgrade,
	/supported_openwrt_release\(\)[\s\S]*validate_openwrt_support\(\)/,
	'transition installer must share the exact OpenWrt 24.10 support boundary');
assert.match(upgrade, /case "\$release" in[\s\S]*\*\.\*[\s\S]*release_minor[\s\S]*-n "\$release_minor"/,
	'transition installer must reject a major-only release at the 24.x boundary');
const transitionPreflight = upgrade.indexOf('\nvalidate_openwrt_support\n');
assert.ok(transitionPreflight >= 0 && transitionPreflight < backupCreated &&
	transitionPreflight < guardDisabled && transitionPreflight < packageRemoved,
	'transition OpenWrt/fw4 preflight must run before backup, Guard changes and package removal');

console.log('terminal installation documentation contract passed');
