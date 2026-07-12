import { assert_equal, assert_throws } from 'testlib';
import * as application from 'miclash.application';

let submitted = [];
let sequence = 0;
let operations = {
	submit: (kind, source, context, worker) => {
		let record = { id: 'application-' + (++sequence), kind, source };
		push(submitted, { record, context, worker });
		return record;
	},
	get: (id) => ({ id }),
	list: (filter) => [ { id: 'listed' } ]
};
let actions = [];
let service = {
	start: (profile) => push(actions, 'start:' + profile),
	stop: (profile) => push(actions, 'stop:' + profile),
	reload: (profile) => { push(actions, 'reload:' + profile); return { ok: true }; },
	restart_service: (profile) => push(actions, 'restart:' + profile),
	wait_ready: (deadline, profile, options) => ({ ok: true })
};
let settings_value = { core: { proxy_mode: 'tproxy' } };
let validated = 0, saved = 0, desired = null;
let settings = {
	get: () => settings_value,
	validate: (patch) => { validated++; return patch; },
	set: (patch) => { saved++; settings_value = patch; return patch; }
};
let config = {
	list_profiles: () => [ 'config.yaml' ],
	read_active: (profile) => 'exact-active\n',
	validate: (profile, content, source) =>
		operations.submit('config.validate', source, { profile }, () => null),
	apply: (profile, content, source) =>
		operations.submit('config.apply', source, { profile }, () => null)
};
let state = {
	snapshot: () => ({ status: 'safe' }),
	health: () => ({ health: 'safe' }),
	set_desired: (value) => desired = value
};
let app = application.create({
	operations, service, settings, config, state, clock: { now: () => 1000 }
});

assert_equal(app.status().status, 'safe');
assert_equal(app.health().health, 'safe');
assert_equal(app.operation_get('id').id, 'id');
assert_equal(app.operation_list({})[0].id, 'listed');
assert_equal(app.config_list()[0], 'config.yaml');
assert_equal(app.config_read('config.yaml'), 'exact-active\n');
assert_equal(app.settings_get().core.proxy_mode, 'tproxy');

for (let action in [ 'start', 'stop', 'reload', 'restart' ]) {
	let before = length(submitted);
	let record = app['service_' + action]('config.yaml', 'luci');
	assert_equal(length(submitted), before + 1);
	assert_equal(record.id, submitted[length(submitted) - 1].record.id);
	submitted[length(submitted) - 1].worker({ stage: () => null });
}
assert_equal(join(',', actions),
	'start:config.yaml,stop:config.yaml,reload:config.yaml,restart:config.yaml');

let before_config = length(submitted);
app.config_validate('config.yaml', 'valid\n', 'luci');
assert_equal(length(submitted), before_config + 1);
app.config_apply('config.yaml', 'valid\n', 'luci');
assert_equal(length(submitted), before_config + 2);

let setting_record = app.settings_set({ core: { proxy_mode: 'tun' } }, 'luci');
assert_equal(validated, 1);
assert_equal(saved, 0);
submitted[length(submitted) - 1].worker({ stage: () => null });
assert_equal(saved, 1);
assert_equal(desired.core.proxy_mode, 'tun');
assert_equal(setting_record.id, submitted[length(submitted) - 1].record.id);

app.set_draining(true);
for (let mutation in [
	() => app.service_start('config.yaml', 'luci'),
	() => app.config_validate('config.yaml', 'valid\n', 'luci'),
	() => app.settings_set({}, 'luci')
]) assert_throws(mutation, 'BUSY');
assert_equal(app.status().status, 'safe');
