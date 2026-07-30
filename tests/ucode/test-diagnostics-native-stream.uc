import { assert_equal, assert_match, assert_true } from 'testlib';
import { sha256_file } from 'digest';
import * as diagnostics_json from 'miclash.diagnostics-json';

let fs = require('fs');
let directory = fs.realpath('/tmp');
assert_true(type(directory) == 'string' && length(directory), 'native temporary directory is canonical');
let path = directory + '/miclash-diagnostics-native-stream.json';
try { fs.unlink(path); } catch (error) {}

let handle = fs.open(path, 'w', 0o600);
assert_true(handle != null, 'native fs.open returns a writable resource');
assert_equal(type(handle), 'resource', 'regression must exercise the pinned native handle type');

let runtime = {
	fs: {
		write: (resource, value) => resource.write(value),
		flush: (resource) => {
			let result = resource.flush();
			return result === true || (result == null && resource.error() == null);
		},
		close: (resource) => resource.close(),
		fstat: (resource) => fs.stat('/proc/self/fd/' + resource.fileno()) ??
			fs.stat('/dev/fd/' + resource.fileno()),
		lstat: (name) => fs.lstat(name),
		realpath: (name) => fs.realpath(name)
	},
	digest: { sha256_file }
};

let writer = diagnostics_json.create(runtime, {
	resource: handle,
	path,
	abort: () => { try { fs.unlink(path); } catch (error) {} }
});
writer.begin_object();
writer.begin_object_field('details');
writer.begin_array_field('logs');
writer.item({ message: 'native stream' });
writer.end_array();
writer.end_object();
writer.end_object();
let result = writer.finish();
assert_match(result.sha256, /^[0-9a-f]{64}$/);
assert_equal(json(fs.readfile(path)).details.logs[0].message, 'native stream');
fs.unlink(path);

print('native diagnostic stream tests passed\n');
