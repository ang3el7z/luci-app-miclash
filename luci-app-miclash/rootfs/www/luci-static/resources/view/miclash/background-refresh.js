'use strict';
'require baseclass';

function create(report) {
	let failures = 0;
	let reported = false;

	async function run(callback) {
		try {
			const result = await callback();
			failures = 0;
			reported = false;
			return result;
		}
		catch (error) {
			failures++;
			if (failures >= 2 && !reported) {
				reported = true;
				if (typeof report === 'function') report(error, { background: true });
			}
			return undefined;
		}
	}

	return { run };
}

return baseclass.extend({ create });
