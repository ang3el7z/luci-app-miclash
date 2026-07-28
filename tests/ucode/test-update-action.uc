import { assert_equal, assert_throws } from 'testlib';
import * as update_action from 'miclash.update-action';

assert_equal(update_action.compare('2.5.3', '2.5.4'), -1);
assert_equal(update_action.compare('v2.5.4-r1', 'v2.5.4'), 0);
assert_equal(update_action.compare('2.5.4', '2.5.3'), 1);
assert_equal(update_action.compare('2.5.4_rc1', '2.5.4'), -1);
assert_equal(update_action.compare('2.5.4-beta.1', '2.5.4-beta.2'), -1);
assert_equal(update_action.compare('unknown', '2.5.4'), null);

assert_equal(update_action.classify(null, '2.5.4'), 'install');
assert_equal(update_action.classify('2.5.3', '2.5.4'), 'update');
assert_equal(update_action.classify('2.5.4-r1', 'v2.5.4'), 'reinstall');
assert_equal(update_action.classify('2.5.5', '2.5.4'), 'downgrade');
assert_equal(update_action.classify('unknown', '2.5.4'), 'unknown');

assert_equal(update_action.validate('install', null, '2.5.4'), true);
assert_equal(update_action.validate('update', '2.5.3', '2.5.4'), true);
assert_equal(update_action.validate('reinstall', '2.5.4-r1', '2.5.4'), true);
assert_equal(update_action.validate('downgrade', '2.5.5', '2.5.4'), true);
assert_throws(() => update_action.validate('update', '2.5.5', '2.5.4'),
	'INVALID_ARGUMENT');
assert_throws(() => update_action.validate('downgrade', '2.5.3', '2.5.4'),
	'INVALID_ARGUMENT');
assert_throws(() => update_action.validate('replace', '2.5.4', '2.5.4'),
	'INVALID_ARGUMENT');

print('update action tests passed\n');
