import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const installerUrl =
	'https://raw.githubusercontent.com/ang3el7z/luci-app-miclash/main/install-miclash.sh';
const readmes = [ 'README.md', 'README.ru.md', 'README.zh-cn.md' ];

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
}

assert.match(readFileSync('README.md', 'utf8'), /does \*\*not\*\* fall back/);
assert.match(readFileSync('README.ru.md', 'utf8'), /\*\*не откатывается\*\*/);
assert.match(readFileSync('README.zh-cn.md', 'utf8'), /\*\*不会回退\*\*/);

const installer = readFileSync('install-miclash.sh', 'utf8');
assert.match(installer, /releases\?per_page=20/);
assert.match(installer, /luci-app-miclash-\$\{clean_tag\}\.apk/);
assert.match(installer, /luci-app-miclash_\$\{clean_tag\}_all\.ipk/);
assert.match(installer, /miclash-release-manifest\.json/);

console.log('terminal installation documentation contract passed');
