'use strict';
'require fs';

function isInternetOnlyEnabled(settings) {
	return !!(settings && settings.internetOnlyMiclash);
}

function isNetworkUpdateBlocked(settings, serviceRunning) {
	return isInternetOnlyEnabled(settings) && !serviceRunning;
}

function blockedNetworkMessage() {
	return _('Network access is blocked by "Internet only through MiClash". Start the service or disable this option in Settings to update.');
}

function assertNetworkUpdateAllowed(settings, serviceRunning) {
	if (isNetworkUpdateBlocked(settings, serviceRunning)) {
		throw new Error(blockedNetworkMessage());
	}
}

function execMessage(result) {
	return String((result && (result.stderr || result.stdout)) || '').trim();
}

async function prepareNetworkUpdate(settings, serviceRunning) {
	assertNetworkUpdateAllowed(settings, serviceRunning);

	if (!isInternetOnlyEnabled(settings) || !serviceRunning) {
		return { repaired: false, warning: '' };
	}

	const result = await fs.exec('/opt/clash/bin/clash-rules', [ 'repair_network_path' ]);
	if (result.code !== 0) {
		return {
			repaired: false,
			warning: execMessage(result) || _('Network path repair failed.')
		};
	}

	return { repaired: true, warning: '' };
}

return L.Class.extend({
	isInternetOnlyEnabled: isInternetOnlyEnabled,
	isNetworkUpdateBlocked: isNetworkUpdateBlocked,
	blockedNetworkMessage: blockedNetworkMessage,
	assertNetworkUpdateAllowed: assertNetworkUpdateAllowed,
	prepareNetworkUpdate: prepareNetworkUpdate
});
