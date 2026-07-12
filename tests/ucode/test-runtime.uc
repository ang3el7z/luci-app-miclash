import { assert_equal, assert_throws, assert_true } from './testlib.uc';
import * as runtime from 'miclash.runtime';
import * as fakes from './fakes.uc';

let fake_process = fakes.process({
	'echo:hello': { code: 0, stdout: 'hello\n', stderr: '' }
});
let fake_clock = fakes.clock(1000);
let rt = runtime.create({ process: fake_process, clock: fake_clock });

assert_true(rt.fs != null);
assert_equal(rt.clock.now(), 1000);
let timer_fired = false;
fake_clock.set_timeout(10, () => timer_fired = true);
fake_clock.advance(9);
assert_equal(timer_fired, false);
fake_clock.advance(1);
assert_equal(timer_fired, true);
assert_equal(rt.process.run({ command: 'echo', args: [ 'hello' ] }).stdout, 'hello\n');
assert_equal(length(fake_process.calls), 1);
assert_equal(fake_process.calls[0].command, 'echo');
assert_throws(() => fake_process.run('echo hello'), 'INVALID_ARGUMENT');
assert_throws(() => fake_process.run({ command: 'echo', args: [], shell: true }), 'INVALID_ARGUMENT');

let production = runtime.create();
assert_true(type(production.clock.set_timeout) == 'function');
assert_throws(() => production.process.run('echo hello'), 'INVALID_ARGUMENT');
assert_throws(() => production.process.run({ command: 'echo', args: [], shell: true }), 'INVALID_ARGUMENT');
assert_throws(() => production.process.run({ command: 'echo', args: [], stdin: 'data' }), 'INVALID_ARGUMENT');

let fake_fs = fakes.fs({ '/etc/miclash/config': 'old' });
assert_equal(fake_fs.readfile('/etc/miclash/config'), 'old');
fake_fs.writefile('/etc/miclash/config', 'new');
assert_equal(fake_fs.readfile('/etc/miclash/config'), 'new');

let fake_uci = fakes.uci({ miclash: { core: { enabled: '1' } } });
assert_equal(fake_uci.get('miclash', 'core', 'enabled'), '1');
fake_uci.set('miclash', 'core', 'enabled', '0');
assert_equal(fake_uci.get('miclash', 'core', 'enabled'), '0');

let events = fakes.events();
events.emit('operation', { id: 'op-1' });
assert_equal(events.items[0].type, 'operation');
