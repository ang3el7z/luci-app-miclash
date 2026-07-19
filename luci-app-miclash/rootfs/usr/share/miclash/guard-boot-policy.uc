import { fail } from 'miclash.errors';
import * as guard from 'miclash.guard';

const ACTIONS = { install: true, disable: true, remove: true };

export function desired(settings, safety_latched, action, direct_macs) {
	if (type(safety_latched) != 'bool' || !ACTIONS[action])
		fail('INVALID_ARGUMENT');
	if (safety_latched)
		return { ...guard.desired({ guard: { enabled: true } }, { direct_macs }),
			source: 'safety_latch' };
	if (action == 'disable' || action == 'remove')
		return { ...guard.desired({ guard: { enabled: false } }, null), source: action };
	return guard.desired(settings, { direct_macs });
};

export function apply(runtime, settings, safety_latched, action, direct_macs) {
	return guard.install_bootstrap(runtime,
		desired(settings, safety_latched, action, direct_macs));
};
