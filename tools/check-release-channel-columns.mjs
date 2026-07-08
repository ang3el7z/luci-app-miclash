import { readFileSync } from 'node:fs';

const files = {
	config: 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/config.js',
	settings: 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/settings-model.js',
	style: 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/style.css'
};

const config = readFileSync(files.config, 'utf8');
const settings = readFileSync(files.settings, 'utf8');
const style = readFileSync(files.style, 'utf8');

let failed = false;

function check(condition, message) {
	if (!condition) {
		console.error(message);
		failed = true;
	}
}

check(settings.includes('miclashReleaseChannel') && settings.includes('mihomoReleaseChannel'),
	'Settings model must expose separate MiClash and Mihomo release channels.');
check(settings.includes("case 'MICLASH_RELEASE_CHANNEL'") && settings.includes("case 'MIHOMO_RELEASE_CHANNEL'"),
	'Settings model must read MICLASH_RELEASE_CHANNEL and MIHOMO_RELEASE_CHANNEL.');
check(settings.includes('settings.MICLASH_RELEASE_CHANNEL =') && settings.includes('settings.MIHOMO_RELEASE_CHANNEL ='),
	'Settings model must write MICLASH_RELEASE_CHANNEL and MIHOMO_RELEASE_CHANNEL.');
check(!settings.includes("case 'RELEASE_CHANNEL'") && !settings.includes("'RELEASE_CHANNEL='"),
	'Settings model must not keep the old shared RELEASE_CHANNEL fallback/write path.');

check(config.includes('includeMiClashPrereleases') && config.includes('includeMihomoPrereleases'),
	'Config UI must use separate prerelease checks for MiClash and Mihomo.');
check(config.includes('sbox-miclash-release-channel') && config.includes('sbox-mihomo-release-channel'),
	'Settings UI must render separate radio groups for MiClash and Mihomo.');
check(!config.includes('id="sbox-release-channel"'),
	'Settings UI must not render the old shared release channel select.');
check(config.includes('miclashReleaseChannel') && config.includes('mihomoReleaseChannel'),
	'Config UI must collect and save separate release channel values.');

check(style.includes('.sbox-release-channel-grid') && style.includes('.sbox-release-channel-column'),
	'CSS must style the two-column release channel picker.');

if (failed) process.exit(1);
console.log('release channel columns check passed');
