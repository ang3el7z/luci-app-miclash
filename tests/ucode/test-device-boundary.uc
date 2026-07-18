import { assert_equal } from 'testlib';
import * as daemon from 'miclash.daemon';

let external = daemon.device_external_interfaces({ detected_wan: 'wan' });
assert_equal(length(external), 1, 'detected WAN creates one external device interface');
assert_equal(external[0], 'wan', 'detected WAN is projected into the device discovery boundary');
assert_equal(length(daemon.device_external_interfaces({ detected_wan: '' })), 0,
	'missing WAN detection does not invent an interface name');

print('device daemon boundary tests passed\n');
