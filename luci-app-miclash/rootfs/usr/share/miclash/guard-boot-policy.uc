import { fail } from 'miclash.errors';
import * as guard from 'miclash.guard';

const ACTIONS = { install: true, disable: true, remove: true };

export function desired(settings, safety_latched, action) {
	if (type(safety_latched) != 'bool' || !ACTIONS[action])
		fail('INVALID_ARGUMENT');
	if (safety_latched)
		return { enabled: true, source: 'safety_latch', explicit_disable: false };
	if (action == 'disable' || action == 'remove')
		return { enabled: false, source: action, explicit_disable: true };
	return guard.desired(settings, null);
};

export function apply(runtime, settings, safety_latched, action) {
	return guard.install_bootstrap(runtime,
		desired(settings, safety_latched, action));
};
