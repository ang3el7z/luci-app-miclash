import { assert_throws, assert_true } from './testlib.uc';
import { observe } from 'miclash.routing';

let fs = require('fs');
let runtime = {
	fs: {
		popen: (command, mode) => fs.popen(command, mode),
		readfile: (path) => null
	},
	paths: { run: '/var/run/miclash' }
};

let started = time();
assert_throws(() => observe(runtime), 'INTERNAL');
let elapsed = time() - started;
assert_true(elapsed <= 3, 'stubborn oversized producer terminates within the hard deadline');
