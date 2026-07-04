'use strict';

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

return L.Class.extend({
	isInternetOnlyEnabled: isInternetOnlyEnabled,
	isNetworkUpdateBlocked: isNetworkUpdateBlocked,
	blockedNetworkMessage: blockedNetworkMessage,
	assertNetworkUpdateAllowed: assertNetworkUpdateAllowed
});
