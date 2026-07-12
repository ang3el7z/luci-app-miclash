import { fail } from 'miclash.errors';

const EVENTS = {
	boot: true,
	daemon_crash: true,
	rules_rebuild: true,
	mihomo_restart: true,
	explicit_disable: true,
	explicit_enable: true,
	package_upgrade: true,
	wan_change: true
};

function valid_desired(value) {
	if (type(value) != 'object' || type(value.enabled) != 'bool')
		fail('INVALID_ARGUMENT');
	return value;
};

function valid_transition_state(value, next) {
	if (type(value) != 'object' || type(value.desired_on) != 'bool' ||
	    type(value.main_rules_present) != 'bool' ||
	    (!next && type(value.bootstrap_installed) != 'bool') ||
	    (next && !EVENTS[value.event]))
		fail('INVALID_ARGUMENT');
	return value;
};

function adapter(runtime) {
	let value = runtime?.observers?.guard;
	if (type(value?.verify) != 'function' || type(value?.install) != 'function' ||
	    type(value?.remove) != 'function' || type(value?.persist) != 'function' ||
	    type(value?.record_status) != 'function')
		fail('INVALID_ARGUMENT');
	return value;
};

export function desired(settings, observations) {
	let setting = settings?.guard?.enabled;
	let persisted = observations?.persisted;
	let persisted_valid = type(persisted) == 'object' && persisted.schema_version === 1 &&
		type(persisted.enabled) == 'bool';
	let installed_on = observations?.installed?.verified === true &&
		observations.installed.enabled === true;

	if (setting === true)
		return {
			enabled: true,
			source: 'settings',
			explicit_disable: false
		};

	if (setting === false) {
		if (observations?.explicit_disable === true)
			return { enabled: false, source: 'explicit_disable', explicit_disable: true };
		if (installed_on)
			return { enabled: true, source: 'installed', explicit_disable: false };
		if (persisted_valid)
			return { enabled: persisted.enabled, source: 'persisted', explicit_disable: false };
		if (type(observations?.legacy_enabled) == 'bool')
			return { enabled: observations.legacy_enabled, source: 'legacy', explicit_disable: false };
		return { enabled: false, source: 'settings', explicit_disable: true };
	}

	if (installed_on)
		return { enabled: true, source: 'installed', explicit_disable: false };

	if (persisted_valid)
		return {
			enabled: persisted.enabled,
			source: 'persisted',
			explicit_disable: false
		};
	if (type(observations?.legacy_enabled) == 'bool')
		return { enabled: observations.legacy_enabled, source: 'legacy', explicit_disable: false };

	return { enabled: true, source: 'fail_closed', explicit_disable: false };
};

export function verify(runtime, wanted) {
	valid_desired(wanted);
	return adapter(runtime).verify(wanted) === true;
};

export function install_bootstrap(runtime, wanted) {
	valid_desired(wanted);
	let guard = adapter(runtime);
	let verified = guard.verify(wanted) === true;

	if (!verified) {
		let changed = wanted.enabled ? guard.install(wanted) : guard.remove(wanted);
		if (changed !== true || guard.verify(wanted) !== true)
			fail('INTERNAL');
	}

	if (guard.persist(wanted) !== true || guard.record_status({
		schema_version: 1,
		enabled: wanted.enabled,
		installed: wanted.enabled
	}) !== true)
		fail('INTERNAL');

	return true;
};

export function transition_plan(old, next) {
	valid_transition_state(old, false);
	valid_transition_state(next, true);
	let plan = [];

	if (!old.desired_on && next.desired_on) {
		push(plan, 'install_bootstrap');
		push(plan, 'persist_on');
	}
	else if (old.desired_on && !next.desired_on) {
		if (next.event != 'explicit_disable')
			fail('INVALID_ARGUMENT');
		push(plan, 'persist_off');
		push(plan, 'remove_main_rules');
		push(plan, 'remove_bootstrap');
		return plan;
	}
	else if (next.desired_on) {
		push(plan, old.bootstrap_installed ? 'verify_bootstrap' : 'install_bootstrap');
	}

	if (next.desired_on && next.event == 'daemon_crash') {
		// A crash is not schedulable: model the loss before reconciliation.
		pop(plan);
		push(plan, 'daemon_exit');
		push(plan, old.bootstrap_installed ? 'verify_bootstrap' : 'install_bootstrap');
	}
	else if (next.desired_on && next.event == 'package_upgrade')
		push(plan, 'replace_package');

	if (next.desired_on && (next.event == 'rules_rebuild' || next.event == 'wan_change')) {
		push(plan, 'remove_main_rules');
		push(plan, 'install_main_rules');
	}

	return plan;
};
