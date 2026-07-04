'use strict';
'require fs';

async function detectPackageManager() {
	const checks = [
		{ type: 'apk', bin: '/usr/bin/apk' },
		{ type: 'apk', bin: '/bin/apk' },
		{ type: 'opkg', bin: '/bin/opkg' },
		{ type: 'opkg', bin: '/usr/bin/opkg' }
	];

	for (let i = 0; i < checks.length; i++) {
		try {
			const probe = await fs.exec(checks[i].bin, ['--version']);
			if (probe && typeof probe.code === 'number') return checks[i];
		} catch (e) {}
	}

	return null;
}

return L.Class.extend({
	detectPackageManager: detectPackageManager
});
