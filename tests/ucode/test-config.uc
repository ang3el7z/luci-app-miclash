import { assert_equal, assert_throws, assert_true } from 'testlib';
import * as config from 'miclash.config';
import * as operations from 'miclash.operations';
import * as schema from 'miclash.schema';
import * as fakes from 'fakes';

function fixture(name) {
	return require('fs').readfile('tests/fixtures/config/' + name);
};

function validation_key(id) {
	return '/usr/bin/ucode:-- /usr/libexec/miclash/validate-config.uc ' +
		'/tmp/miclash/candidates/' + id + '/config.yaml';
};

function environment(service, setup) {
	let fs = fakes.fs({
		'/opt/clash/config.yaml': 'original-active\n',
		'/opt/clash/config2.yaml': 'second-active\n',
		'/opt/clash/config3.yaml': 'third-active\n',
		'/usr/libexec/miclash/validate-config.uc': 'installed-helper\n'
	});
	for (let path in [ '/tmp', '/tmp/miclash', '/tmp/miclash/operations', '/opt', '/opt/clash' ])
		fs.mkdir(path);
	if (type(setup) == 'function') setup(fs);
	let clock = fakes.clock(1700000000000);
	let process = fakes.process();
	let runtime = {
		fs, clock, process, random: fakes.entropy(), digest: fakes.digest(fs),
		service: service ?? { reload: () => true, health: () => true },
		paths: { tmp: '/tmp/miclash', run: '/var/run/miclash' }
	};
	let ops = operations.create(runtime);
	ops.recover_interrupted();
	return { fs, clock, process, runtime, ops, cfg: config.create(runtime, ops) };
};

function finish(env, record) {
	env.clock.advance(0);
	return env.ops.get(record.id);
};

for (let profile in [ 'config.yaml', 'config2.yaml', 'config3.yaml' ])
	assert_equal(schema.profile_name(profile), profile);
for (let profile in [ 'config0.yaml', 'config4.yaml', '../config.yaml' ])
	assert_throws(() => schema.profile_name(profile), 'INVALID_ARGUMENT');

let env = environment();
assert_equal(join(',', env.cfg.list_profiles()), 'config.yaml,config2.yaml,config3.yaml');
assert_equal(env.cfg.read_active('config.yaml'), 'original-active\n');
let reads_before_stream = length(env.fs.calls.readfile);
let active_stream = env.cfg.open_active('config.yaml');
assert_equal(active_stream.size, length('original-active\n'));
assert_equal(active_stream.sha256, env.runtime.digest.sha256_file('/opt/clash/config.yaml'));
let active_reader = active_stream.open(), streamed_active = '';
while (length(streamed_active) < active_stream.size)
	streamed_active += active_reader.read(3);
assert_equal(active_reader.finish(), true);
assert_equal(streamed_active, 'original-active\n');
assert_equal(length(env.fs.calls.readfile), reads_before_stream,
	'active config streaming never uses readfile');
assert_true(length(env.fs.calls.read) > 1,
	'active config streaming uses bounded file reads');

let invalid = env.cfg.validate('config.yaml', fixture('invalid.yaml'), 'luci');
env.process.replies[validation_key(invalid.id)] = { code: 1 };
assert_equal(finish(env, invalid).error.code, 'VALIDATION_FAILED');
assert_equal(env.fs.readfile('/opt/clash/config.yaml'), 'original-active\n');
assert_equal(env.fs.lstat('/tmp/miclash/candidates/' + invalid.id), null);

let applied = env.cfg.apply('config.yaml', fixture('valid.yaml'), 'luci');
assert_equal(finish(env, applied).state, 'success');
assert_equal(env.fs.readfile('/opt/clash/config.yaml'), fixture('valid.yaml'));
assert_equal(env.cfg.detect_external('config.yaml').changed, false);

// Applying a validated profile while Mihomo is intentionally stopped must
// commit the file without starting or recovering the service.
let stopped_recovery_calls = 0;
let stopped = environment({
	observe: () => ({ state: 'stopped', running: false }),
	recover: () => { stopped_recovery_calls++; return { ok: true }; },
	reload: () => true,
	health: () => true
});
let stopped_apply = stopped.cfg.apply('config.yaml', fixture('valid.yaml'), 'luci');
assert_equal(finish(stopped, stopped_apply).state, 'success');
assert_equal(stopped_recovery_calls, 0);
assert_equal(stopped.fs.readfile('/opt/clash/config.yaml'), fixture('valid.yaml'));

let recovery_calls = 0;
let unhealthy = environment({
	reload: () => { recovery_calls++; return recovery_calls > 1; },
	health: () => recovery_calls > 1
});
let failed = unhealthy.cfg.apply('config.yaml', fixture('valid.yaml'), 'luci');
assert_equal(finish(unhealthy, failed).error.code, 'HEALTH_FAILED');
assert_equal(unhealthy.fs.readfile('/opt/clash/config.yaml'), 'original-active\n');

let transaction_settings = { proxy_mode: 'tproxy' };
let transaction = environment({ reload: () => true, health: () => true });
let operational = transaction.cfg.apply_operational('config.yaml', fixture('valid.yaml'), 'luci', {
	prepare: () => json(sprintf('%J', transaction_settings)),
	commit: () => { transaction_settings.proxy_mode = 'tun'; return true; },
	rollback: (before) => { transaction_settings = before; return true; }
});
assert_equal(finish(transaction, operational).state, 'success');
assert_equal(transaction_settings.proxy_mode, 'tun');
assert_equal(transaction.fs.readfile('/opt/clash/config.yaml'), fixture('valid.yaml'));

let swap_calls = [];
let swapping = environment({
	observe: () => ({ state: 'running', running: true }),
	reload: (profile, previous) => { push(swap_calls, { profile, previous }); return true; },
	health: () => true
});
let swapped = swapping.cfg.swap('config2.yaml', 'luci');
assert_equal(finish(swapping, swapped).state, 'success');
assert_equal(swapping.fs.readfile('/opt/clash/config.yaml'), 'second-active\n');
assert_equal(swapping.fs.readfile('/opt/clash/config2.yaml'), 'original-active\n');
assert_equal(length(swap_calls), 1);

let external = environment();
external.fs.writefile('/opt/clash/config.yaml', fixture('valid.yaml'));
assert_equal(external.cfg.detect_external('config.yaml').changed, true);
let adopted = external.cfg.adopt_external('config.yaml', 'system');
assert_equal(finish(external, adopted).state, 'success');
assert_equal(external.cfg.detect_external('config.yaml').changed, false);

let internal = environment();
let context_seen = null;
let checked_seen = null, activated_seen = null, internal_error = null;
let record = internal.ops.submit('subscription.update', 'auto', {}, (ctx) => {
	context_seen = ctx;
	try {
		checked_seen = internal.cfg.validate_in_operation(ctx, 'config.yaml', fixture('valid.yaml'));
		activated_seen = internal.cfg.apply_in_operation(ctx, 'config.yaml', fixture('valid.yaml'));
		ctx.result({ interval_hours: null, insecure: false });
	}
	catch (error) { internal_error = error; }
	return true;
});
let internal_done = finish(internal, record);
assert_equal(internal_error, null, sprintf('internal API failed: %J', internal_error));
assert_equal(internal_done.state, 'success', sprintf('internal operation failed: %J', internal_done));
assert_equal(checked_seen.ok, true);
assert_equal(activated_seen.ok, true);
assert_throws(() => internal.cfg.validate_in_operation(
	context_seen, 'config.yaml', fixture('valid.yaml')), 'INVALID_ARGUMENT');
assert_true(length(internal.ops.list()) == 1);

print('config tests passed\n');
