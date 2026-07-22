import { fail } from 'miclash.errors';
import { with_lock } from 'miclash.mutation_lock';

const CONFIG = 'miclash';

const FIELDS = {
	core: {
		proxy_mode: 'proxy_mode',
		tun_stack: 'tun_stack',
		block_quic: 'bool',
		use_tmpfs_rules: 'bool',
		hwid_enabled: 'bool',
		hwid_user_agent: 'string',
		hwid_device_os: 'string',
		subscription_url: 'string',
		subscription_url_config_yaml: 'string',
		subscription_url_config2_yaml: 'string',
		subscription_url_config3_yaml: 'string'
	},
	interfaces: {
		mode: 'interface_mode',
		auto_detect_lan: 'bool',
		auto_detect_wan: 'bool',
		detected_lan: 'interface',
		detected_wan: 'interface',
		included: 'interfaces',
		excluded: 'interfaces'
	},
	guard: {
		enabled: 'bool',
		auto_fakeip_whitelist: 'bool'
	},
	memory: {
		enabled: 'bool',
		sample_interval_ms: 'memory_sample_interval_ms',
		sustained_samples: 'memory_sustained_samples',
		warmup_ms: 'memory_warmup_ms',
		baseline_samples: 'memory_baseline_samples',
		anomaly_percent: 'memory_anomaly_percent',
		anomaly_growth_kb: 'memory_anomaly_growth_kb',
		reserve_percent: 'memory_reserve_percent',
		reserve_min_kb: 'memory_reserve_min_kb',
		reserve_max_kb: 'memory_reserve_max_kb',
		drop_percent: 'memory_drop_percent',
		drop_min_kb: 'memory_drop_min_kb',
		success_cooldown_ms: 'memory_success_cooldown_ms',
		failure_cooldown_ms: 'memory_failure_cooldown_ms',
		normal_rearm_ms: 'memory_normal_rearm_ms'
	},
	updates: {
		auto_subscription: 'bool',
		interval_hours: 'interval',
		miclash_release_channel: 'release_channel',
		mihomo_release_channel: 'release_channel',
		auto_major_miclash: 'bool'
	},
	telegram: {
		enabled: 'bool',
		token: 'secret_string',
		user_id: 'string',
		poll_timeout_seconds: 'telegram_poll_timeout_seconds'
	},
	notifications: {
		auto_hide: 'bool',
		syslog_enabled: 'bool',
		syslog_events: 'notification_events',
		luci_enabled: 'bool',
		luci_events: 'notification_events',
		telegram_enabled: 'bool',
		telegram_events: 'notification_events'
	},
	meta: { schema_version: 'schema_version' }
};

function defaults() {
	return {
		core: {
			proxy_mode: 'tproxy',
			tun_stack: 'system',
			block_quic: true,
			use_tmpfs_rules: true,
			hwid_enabled: false,
			hwid_user_agent: 'MiClash',
			hwid_device_os: 'OpenWrt',
			subscription_url: '',
			subscription_url_config_yaml: '',
			subscription_url_config2_yaml: '',
			subscription_url_config3_yaml: ''
		},
		interfaces: {
			mode: 'exclude',
			auto_detect_lan: true,
			auto_detect_wan: true,
			detected_lan: '',
			detected_wan: '',
			included: [],
			excluded: []
		},
		guard: { enabled: false, auto_fakeip_whitelist: true },
		memory: {
			enabled: true, sample_interval_ms: 60000, sustained_samples: 5,
			warmup_ms: 900000, baseline_samples: 6, anomaly_percent: 150,
			anomaly_growth_kb: 16384, reserve_percent: 10, reserve_min_kb: 16384,
			reserve_max_kb: 65536, drop_percent: 10, drop_min_kb: 8192,
			success_cooldown_ms: 21600000, failure_cooldown_ms: 86400000,
			normal_rearm_ms: 1800000
		},
		updates: {
			auto_subscription: true,
			interval_hours: 4,
			miclash_release_channel: 'release',
			mihomo_release_channel: 'release',
			auto_major_miclash: true
		},
		telegram: { enabled: false, token: '', user_id: '', poll_timeout_seconds: 25 },
		notifications: {
			auto_hide: true,
			syslog_enabled: true,
			syslog_events: [ 'guard_outage', 'failure', 'recovery', 'fail_closed',
				'direct_fallback', 'memory_action', 'memory_outcome',
				'subscription_outcome', 'update_outcome', 'internet_restored' ],
			luci_enabled: true,
			luci_events: [ 'guard_outage', 'failure', 'recovery', 'fail_closed',
				'direct_fallback', 'memory_action', 'memory_outcome',
				'subscription_outcome', 'update_outcome', 'internet_restored' ],
			telegram_enabled: false,
			telegram_events: [ 'guard_outage', 'failure', 'recovery', 'fail_closed',
				'direct_fallback', 'memory_outcome', 'subscription_outcome',
				'update_outcome', 'internet_restored' ]
		},
		meta: { schema_version: 1 }
	};
};

function invalid() {
	fail('INVALID_ARGUMENT');
};

function contains_control(value) {
	return match(value, /[[:cntrl:]]/);
};

function clean_string(value, maximum) {
	if (type(value) != 'string' || length(value) > maximum || contains_control(value))
		invalid();
	return value;
};

function clean_interface(value) {
	clean_string(value, 64);
	let result = trim(value);
	if (length(result) && !match(result, /^[A-Za-z0-9_.:-]+$/))
		invalid();
	return result;
};

function clean_interfaces(value) {
	if (type(value) != 'array' || length(value) > 128)
		invalid();

	let result = [];
	for (let item in value) {
		let cleaned = clean_interface(item);
		if (!length(cleaned))
			continue;

		let duplicate = false;
		for (let existing in result)
			if (existing == cleaned)
				duplicate = true;
		if (!duplicate)
			push(result, cleaned);
	}
	return result;
};

function enum_value(value, allowed) {
	if (type(value) != 'string')
		invalid();
	for (let candidate in allowed)
		if (value == candidate)
			return value;
	invalid();
};

function positive_integer(value, fallback, maximum) {
	if (type(value) == 'int') {
		if (value > 0 && value <= maximum)
			return value;
		return fallback;
	}
	if (type(value) == 'string' && match(value, /^[0-9]+$/)) {
		let parsed = int(value);
		if (parsed != null && parsed > 0 && parsed <= maximum)
			return parsed;
	}
	return fallback;
};

function bounded_integer(value, minimum, maximum) {
	let normalized = positive_integer(value, null, maximum);
	if (normalized == null || normalized < minimum)
		invalid();
	return normalized;
};

function unique_enum_list(value, allowed, strict) {
	if (!strict && type(value) == 'string')
		value = length(value) ? split(value, ',') : [];
	if (type(value) != 'array' || length(value) > length(allowed))
		invalid();
	let result = [];
	for (let item in value) {
		item = enum_value(item, allowed);
		let duplicate = false;
		for (let existing in result) if (existing == item) duplicate = true;
		if (!duplicate) push(result, item);
	}
	return result;
};

function normalize(kind, value, fallback, strict) {
	if (kind == 'bool') {
		if (type(value) == 'bool')
			return value;
		if (!strict && (value == '1' || value == 'true' || value == 'yes' || value == 'on'))
			return true;
		if (!strict && (value == '0' || value == 'false' || value == 'no' || value == 'off'))
			return false;
		invalid();
	}

	if (kind == 'proxy_mode')
		return enum_value(value, [ 'tproxy', 'tun', 'mixed' ]);
	if (kind == 'tun_stack')
		return enum_value(value, [ 'system', 'gvisor', 'mixed' ]);
	if (kind == 'interface_mode')
		return enum_value(value, [ 'exclude', 'explicit' ]);
	if (kind == 'release_channel')
		return enum_value(value, [ 'release', 'prerelease' ]);
	if (kind == 'interface')
		return clean_interface(value);
	if (kind == 'interfaces') {
		if (!strict && type(value) == 'string')
			value = length(value) ? split(value, ',') : [];
		return clean_interfaces(value);
	}
	if (kind == 'interval') {
		let normalized = positive_integer(value, null, 8760);
		if (normalized == null)
			invalid();
		return normalized;
	}
	if (kind == 'telegram_poll_timeout_seconds')
		return bounded_integer(value, 5, 50);
	let memory_bounds = {
		memory_sample_interval_ms: [ 10000, 3600000 ],
		memory_sustained_samples: [ 2, 60 ],
		memory_warmup_ms: [ 60000, 86400000 ],
		memory_baseline_samples: [ 3, 60 ],
		memory_anomaly_percent: [ 110, 500 ],
		memory_anomaly_growth_kb: [ 4096, 262144 ],
		memory_reserve_percent: [ 5, 50 ],
		memory_reserve_min_kb: [ 4096, 262144 ],
		memory_reserve_max_kb: [ 8192, 1048576 ],
		memory_drop_percent: [ 5, 90 ],
		memory_drop_min_kb: [ 1024, 262144 ],
		memory_success_cooldown_ms: [ 60000, 604800000 ],
		memory_failure_cooldown_ms: [ 60000, 604800000 ],
		memory_normal_rearm_ms: [ 60000, 86400000 ]
	};
	if (exists(memory_bounds, kind))
		return bounded_integer(value, memory_bounds[kind][0], memory_bounds[kind][1]);
	if (kind == 'notification_channels')
		return unique_enum_list(value, [ 'syslog', 'luci', 'telegram' ], strict);
	if (kind == 'notification_events')
		return unique_enum_list(value, [ 'guard_outage', 'failure', 'recovery',
			'fail_closed', 'direct_fallback', 'memory_action', 'memory_outcome',
			'subscription_outcome', 'update_outcome', 'internet_restored' ], strict);
	if (kind == 'schema_version') {
		let normalized = positive_integer(value, null, 1);
		if (normalized != 1)
			invalid();
		return normalized;
	}
	if (kind == 'secret_string')
		return clean_string(value, 4096);
	if (kind == 'string')
		return clean_string(value, 4096);
	invalid();
};

function encoded(kind, value) {
	if (kind == 'bool')
		return value ? '1' : '0';
	if (kind == 'interval' || kind == 'schema_version' || kind == 'telegram_poll_timeout_seconds')
		return sprintf('%d', value);
	if (substr(kind, 0, 7) == 'memory_')
		return sprintf('%d', value);
	if (kind == 'notification_channels' || kind == 'notification_events')
		return join(',', value);
	return value;
};

function cursor(runtime) {
	if (type(runtime) != 'object' || type(runtime.uci) != 'object' ||
	    type(runtime.uci.cursor) != 'function')
		invalid();
	return runtime.uci.cursor();
};

function load_cursor(uci) {
	let result = defaults();
	for (let section, fields in FIELDS)
		for (let option, kind in fields) {
			let stored = uci.get(CONFIG, section, option);
			if (stored == null)
				continue;
			result[section][option] = normalize(kind, stored, result[section][option], false);
		}
	let profile_options = [ 'syslog_enabled', 'syslog_events', 'luci_enabled',
		'luci_events', 'telegram_enabled', 'telegram_events' ];
	let has_profiles = false;
	for (let option in profile_options)
		if (uci.get(CONFIG, 'notifications', option) != null) {
			has_profiles = true;
			break;
		}
	if (!has_profiles) {
		let stored_channels = uci.get(CONFIG, 'notifications', 'channels');
		let stored_events = uci.get(CONFIG, 'notifications', 'events');
		if (stored_channels != null || stored_events != null) {
			let channels = normalize('notification_channels', stored_channels ?? '', [], false);
			let events = normalize('notification_events', stored_events ?? '', [], false);
			for (let channel in [ 'syslog', 'luci', 'telegram' ]) {
				result.notifications[channel + '_enabled'] = index(channels, channel) >= 0;
				result.notifications[channel + '_events'] = [ ...events ];
			}
		}
	}
	return result;
};

export function load(runtime) {
	return load_cursor(cursor(runtime));
};

export function validate_patch(patch) {
	if (type(patch) != 'object')
		invalid();

	let normalized_patch = {};
	for (let section, values in patch) {
		if (!exists(FIELDS, section) || type(values) != 'object')
			invalid();
		normalized_patch[section] = {};
		for (let option, value in values) {
			if (!exists(FIELDS[section], option))
				invalid();
			let kind = FIELDS[section][option];
			normalized_patch[section][option] = normalize(kind, value, null, true);
		}
	}

	return normalized_patch;
};

function validate_effective(current, patch) {
	let effective = current;
	for (let section, values in patch)
		for (let option, value in values)
			effective[section][option] = value;
	let memory = effective.memory;
	if (memory.reserve_min_kb > memory.reserve_max_kb ||
	    memory.failure_cooldown_ms < memory.success_cooldown_ms ||
	    memory.warmup_ms < memory.sample_interval_ms)
		invalid();
	let telegram = effective.telegram;
	if (length(telegram.user_id) && !match(telegram.user_id,
	    /^[1-9][0-9]{0,31}(,[[:space:]]*[1-9][0-9]{0,31})*$/))
		invalid();
	if (length(telegram.token) &&
	    !match(telegram.token, /^[1-9][0-9]{0,19}:[A-Za-z0-9_-]{8,128}$/))
		invalid();
	if (telegram.enabled && (!length(telegram.token) || !length(telegram.user_id)))
		invalid();
	return effective;
};

export function save(runtime, patch) {
	let normalized_patch = validate_patch(patch);
	let persist = () => {
		let uci = cursor(runtime);
		validate_effective(load_cursor(uci), normalized_patch);
		for (let section, values in normalized_patch)
			for (let option, value in values) {
				let kind = FIELDS[section][option];
				let stored = encoded(kind, value);
				if (kind == 'interfaces' && type(stored) == 'array' && !length(stored)) {
					if (uci.get(CONFIG, section, option) != null &&
					    uci.delete(CONFIG, section, option) !== true)
						fail('INTERNAL');
					continue;
				}
				if (uci.set(CONFIG, section, option, stored) !== true)
					fail('INTERNAL');
			}

		if (uci.commit(CONFIG) !== true)
			fail('INTERNAL');
		return load_cursor(uci);
	};
	return exists(normalized_patch, 'guard')
		? with_lock(runtime, { barrier: 'normal', wait_ms: 0 }, persist)
		: persist();
};
