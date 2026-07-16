import fs from 'node:fs';

function check(condition, message) {
	if (!condition) {
		console.error(message);
		process.exit(1);
	}
}

const daemon = fs.readFileSync('luci-app-miclash/rootfs/usr/sbin/miclashd', 'utf8');
const init = fs.readFileSync('luci-app-miclash/rootfs/etc/init.d/miclashd', 'utf8');
const create = daemon.indexOf('runtime.create()');
const compose = daemon.indexOf('daemon.compose(environment)');
const startup = daemon.indexOf('startup_guard.create');
const start = daemon.indexOf('.start()');
const observation = daemon.indexOf('process.state.observe');
check(daemon.includes("from 'miclash.startup-guard'"),
	'miclashd must import the production startup Guard recovery module');
check(create >= 0 && compose > create && startup > compose && start > startup && observation > start,
	'startup Guard recovery must run immediately after compose and before observation');
check(daemon.includes('startup.close()'),
	'miclashd shutdown must close the startup retry lifecycle');
const observationFailure = daemon.slice(daemon.indexOf('if (observation_timer == null)'),
	daemon.indexOf('function shutdown()'));
check(observationFailure.indexOf('startup.close()') >= 0 &&
	observationFailure.indexOf('startup.close()') < observationFailure.indexOf('process.close()'),
	'observation timer setup failure must close startup retries before daemon composition');
check(/procd_set_param respawn\s+[0-9]+\s+[0-9]+\s+[0-9]+/.test(init),
	'procd must respawn miclashd after an unrecoverable startup scheduler failure');

console.log('daemon startup Guard ordering check passed');
