import * as errors from 'miclash.errors';

const EVENTS = [ 'guard_outage', 'failure', 'recovery', 'fail_closed',
	'direct_fallback', 'memory_action', 'memory_outcome', 'subscription_outcome',
	'update_outcome', 'internet_restored' ];
const LUCI_ONLY_EVENTS = [ 'miclash_event' ];

function profile(settings, name) {
	if (type(settings) != 'object' || type(settings[name + '_enabled']) != 'bool' ||
	    type(settings[name + '_events']) != 'array')
		errors.fail('INVALID_ARGUMENT');
	let selected = [];
	for (let event in settings[name + '_events']) {
		let allowed = index(EVENTS, event) >= 0 ||
			(name == 'luci' && index(LUCI_ONLY_EVENTS, event) >= 0);
		if (type(event) != 'string' || !allowed || index(selected, event) >= 0)
			errors.fail('INVALID_ARGUMENT');
		push(selected, event);
	}
	return { enabled: settings[name + '_enabled'], types: selected };
};

export function notifier_config(settings) {
	let syslog = profile(settings, 'syslog');
	let luci = profile(settings, 'luci');
	return {
		dedupe_window_ms: 60000,
		syslog: { ...syslog, minimum_severity: 'info', components: [] },
		luci: { ...luci, channel: 'miclash.notification',
			minimum_severity: 'info', components: [] }
	};
};

export function telegram_config(settings) {
	return profile(settings, 'telegram');
};
