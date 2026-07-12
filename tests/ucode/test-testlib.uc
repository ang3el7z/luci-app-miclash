import { assert_equal, assert_match, assert_throws, assert_true } from './testlib.uc';

assert_true(true);
assert_equal('expected', 'expected');
assert_match('ucode test library', /test library/);
assert_throws(() => die('EXPECTED'), 'EXPECTED');
