import { fail } from 'miclash.errors';

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
	memory: { enabled: 'bool' },
	updates: {
		auto_subscription: 'bool',
		interval_hours: 'interval',
		miclash_release_channel: 'release_channel',
		mihomo_release_channel: 'release_channel'
	},
	telegram: {
		enabled: 'bool',
		token: 'secret_string',
		user_id: 'string'
	},
	notifications: { auto_hide: 'bool' },
	backup: {
		enabled: 'bool',
		retention: 'retention',
		include_secrets: 'bool'
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
		memory: { enabled: false },
		updates: {
			auto_subscription: true,
			interval_hours: 4,
			miclash_release_channel: 'release',
			mihomo_release_channel: 'release'
		},
		telegram: { enabled: false, token: '', user_id: '' },
		notifications: { auto_hide: true },
		backup: { enabled: false, retention: 5, include_secrets: false },
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
	if (kind == 'retention') {
		let normalized = positive_integer(value, null, 100);
		if (normalized == null)
			invalid();
		return normalized;
	}
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
	if (kind == 'interval' || kind == 'retention' || kind == 'schema_version')
		return sprintf('%d', value);
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

export function save(runtime, patch) {
	let normalized_patch = validate_patch(patch);

	let uci = cursor(runtime);
	for (let section, values in normalized_patch)
		for (let option, value in values) {
			let kind = FIELDS[section][option];
			uci.set(CONFIG, section, option, encoded(kind, value));
		}

	uci.commit(CONFIG);
	return load_cursor(uci);
};

function legacy_boolean(value, fallback, default_unless_false) {
	if (value == 'true')
		return true;
	if (value == 'false')
		return false;
	return default_unless_false ? value != 'false' : fallback;
};

function legacy_enum(value, allowed, fallback) {
	for (let candidate in allowed)
		if (value == candidate)
			return value;
	return fallback;
};

function legacy_string(value, fallback) {
	if (type(value) != 'string' || length(value) > 4096 || contains_control(value))
		return fallback;
	return value;
};

function parse_legacy(text) {
	if (type(text) != 'string' ||
	    match(replace(text, /[\r\n]/g, ''), /[[:cntrl:]]/))
		invalid();

	let values = {};
	for (let raw in split(text, '\n')) {
		let line = raw;
		if (length(line) && substr(line, length(line) - 1) == '\r')
			line = substr(line, 0, length(line) - 1);
		if (!length(trim(line)) || match(trim(line), /^#/))
			continue;

		let position = index(line, '=');
		if (position <= 0)
			invalid();
		let key = trim(substr(line, 0, position));
		let value = trim(substr(line, position + 1));
		if (!match(key, /^[A-Z][A-Z0-9_]*$/) || contains_control(value))
			invalid();
		values[key] = value;
	}
	return values;
};

export function migrate_legacy(runtime, text) {
	let legacy = parse_legacy(text);
	let base = defaults();
	let patch = defaults();

	patch.core.proxy_mode = legacy_enum(legacy.PROXY_MODE,
		[ 'tproxy', 'tun', 'mixed' ], base.core.proxy_mode);
	patch.core.tun_stack = legacy_enum(legacy.TUN_STACK,
		[ 'system', 'gvisor', 'mixed' ], base.core.tun_stack);
	patch.core.block_quic = legacy_boolean(legacy.BLOCK_QUIC, base.core.block_quic, false);
	patch.core.use_tmpfs_rules = legacy_boolean(legacy.USE_TMPFS_RULES, base.core.use_tmpfs_rules, false);
	patch.core.hwid_enabled = legacy_boolean(legacy.ENABLE_HWID, base.core.hwid_enabled, false);
	patch.core.hwid_user_agent = legacy_string(legacy.HWID_USER_AGENT, base.core.hwid_user_agent);
	patch.core.hwid_device_os = legacy_string(legacy.HWID_DEVICE_OS, base.core.hwid_device_os);
	patch.core.subscription_url = legacy_string(legacy.SUBSCRIPTION_URL, base.core.subscription_url);
	patch.core.subscription_url_config_yaml = legacy_string(legacy.SUBSCRIPTION_URL_CONFIG_YAML,
		patch.core.subscription_url);
	patch.core.subscription_url_config2_yaml = legacy_string(legacy.SUBSCRIPTION_URL_CONFIG2_YAML, '');
	patch.core.subscription_url_config3_yaml = legacy_string(legacy.SUBSCRIPTION_URL_CONFIG3_YAML, '');

	patch.interfaces.mode = legacy_enum(legacy.INTERFACE_MODE,
		[ 'exclude', 'explicit' ], base.interfaces.mode);
	patch.interfaces.auto_detect_lan = legacy_boolean(legacy.AUTO_DETECT_LAN,
		base.interfaces.auto_detect_lan, false);
	patch.interfaces.auto_detect_wan = legacy_boolean(legacy.AUTO_DETECT_WAN,
		base.interfaces.auto_detect_wan, false);
	patch.interfaces.detected_lan = clean_interface(legacy.DETECTED_LAN ?? '');
	patch.interfaces.detected_wan = clean_interface(legacy.DETECTED_WAN ?? '');
	patch.interfaces.included = clean_interfaces(length(legacy.INCLUDED_INTERFACES ?? '') ?
		split(legacy.INCLUDED_INTERFACES, ',') : []);
	patch.interfaces.excluded = clean_interfaces(length(legacy.EXCLUDED_INTERFACES ?? '') ?
		split(legacy.EXCLUDED_INTERFACES, ',') : []);

	patch.guard.enabled = legacy_boolean(legacy.INTERNET_ONLY_MICLASH, base.guard.enabled, false);
	patch.guard.auto_fakeip_whitelist = legacy_boolean(legacy.AUTO_FAKEIP_WHITELIST,
		base.guard.auto_fakeip_whitelist, false);
	patch.memory.enabled = legacy_boolean(legacy.ENABLE_MEMORY_GUARD, base.memory.enabled, false);
	patch.updates.auto_subscription = legacy_boolean(legacy.AUTO_UPDATE_CONFIG,
		base.updates.auto_subscription, true);
	patch.updates.interval_hours = positive_integer(legacy.AUTO_UPDATE_INTERVAL_HOURS,
		base.updates.interval_hours, 8760);
	patch.updates.miclash_release_channel = legacy_enum(legacy.MICLASH_RELEASE_CHANNEL,
		[ 'release', 'prerelease' ], base.updates.miclash_release_channel);
	patch.updates.mihomo_release_channel = legacy_enum(legacy.MIHOMO_RELEASE_CHANNEL,
		[ 'release', 'prerelease' ], base.updates.mihomo_release_channel);
	patch.notifications.auto_hide = legacy_boolean(legacy.AUTO_HIDE_NOTIFICATIONS,
		base.notifications.auto_hide, true);

	return save(runtime, patch);
};
