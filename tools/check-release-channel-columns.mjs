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
check(settings.includes('updates.miclash_release_channel') && settings.includes('updates.mihomo_release_channel'),
	'Settings model must read MICLASH_RELEASE_CHANNEL and MIHOMO_RELEASE_CHANNEL.');
check(config.includes('miclash_release_channel:') && config.includes('mihomo_release_channel:'),
	'Unified Settings save must write MICLASH_RELEASE_CHANNEL and MIHOMO_RELEASE_CHANNEL.');
check(!settings.includes("case 'RELEASE_CHANNEL'") && !settings.includes("'RELEASE_CHANNEL='"),
	'Settings model must not keep the old shared RELEASE_CHANNEL fallback/write path.');

check(config.includes('includeMiClashPrereleases') && config.includes('includeMihomoPrereleases'),
	'Config UI must use separate prerelease checks for MiClash and Mihomo.');
check(config.includes('sbox-miclash-release-channel') && config.includes('sbox-mihomo-release-channel'),
	'Settings UI must render separate radio groups for MiClash and Mihomo.');
check(config.includes('function buildReleaseChannelSectionHtml(') &&
	config.includes('sbox-settings-zone-updates') &&
	config.includes('sbox-settings-pair-grid') &&
	config.includes('sbox-release-channel-section sbox-settings-card sbox-updates-card') &&
	!config.includes('sbox-settings-subtitle') &&
	!config.includes("'<label>' + safeText(_('Release channels')) + '</label>'"),
	'Release channels must render in their own semantic card beside Additional.');
check(config.includes('sbox-major-update-policy') &&
	config.indexOf('id="sbox-auto-major-miclash"') > config.indexOf('sbox-release-channel-grid'),
	'Major MiClash updates must be visually separated from the channel radio groups.');
check(config.indexOf('id="sbox-auto-update-config"') > config.indexOf('class="sbox-runtime-switches"'),
	'Configuration auto-update must live in Additional rather than in release channels.');
check(!config.includes('sbox-settings-gap') && !style.includes('.sbox-settings-gap'),
	'Settings pane must not keep the removed vertical spacer markup or CSS.');
check(!config.includes('id="sbox-release-channel"'),
	'Settings UI must not render the old shared release channel select.');
check(config.includes('miclashReleaseChannel') && config.includes('mihomoReleaseChannel'),
	'Config UI must collect and save separate release channel values.');

check(style.includes('.sbox-release-channel-grid') && style.includes('.sbox-release-channel-column'),
	'CSS must style the two-column release channel picker.');
check(style.includes('.sbox-settings-pair-grid') &&
	style.includes('.sbox-release-channel-section') &&
	style.includes('.sbox-major-update-policy'),
	'Release channel and Additional cards must share the responsive pair grid.');

if (failed) process.exit(1);
console.log('release channel columns check passed');
