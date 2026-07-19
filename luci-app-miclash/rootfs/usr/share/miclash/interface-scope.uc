import { fail } from 'miclash.errors';

function valid_interface(value) {
	return type(value) == 'string' && length(value) > 0 && length(value) <= 15 &&
		!!match(value, /^[A-Za-z0-9][A-Za-z0-9_.:@-]*$/);
};

function interface_name(value) {
	if (!valid_interface(value)) fail('INVALID_ARGUMENT');
	return value;
};

function unique(values) {
	if (type(values) != 'array') fail('INVALID_ARGUMENT');
	let result = [];
	for (let value in values) {
		value = interface_name(value);
		if (index(result, value) < 0) push(result, value);
	}
	return result;
};

function detected(configured, snapshot, field) {
	let live = snapshot[field] ?? '';
	if (length(live)) {
		interface_name(live);
		if (index(snapshot.interfaces, live) < 0) fail('INVALID_ARGUMENT');
		return live;
	}
	let saved = configured[field] ?? '';
	if (!length(saved)) return '';
	interface_name(saved);
	// An unavailable topology snapshot may still use the last valid persisted hint.
	if (snapshot.available === false || !length(snapshot.interfaces)) return saved;
	return index(snapshot.interfaces, saved) >= 0 ? saved : '';
};

export function detect(runtime, settings) {
	if (type(runtime) != 'object' || type(runtime.fs) != 'object') fail('INVALID_ARGUMENT');
	let configured = settings?.interfaces ?? settings;
	if (type(configured) != 'object') fail('INVALID_ARGUMENT');
	let names, available = true;
	try { names = runtime.fs.lsdir('/sys/class/net'); }
	catch (error) { names = []; available = false; }
	if (type(names) != 'array') { names = []; available = false; }
	let interfaces = [];
	for (let name in names) {
		if (length(interfaces) >= 128) break;
		if (!valid_interface(name) || name == 'lo' || name == 'clash-tun' ||
		    index(interfaces, name) >= 0) continue;
		push(interfaces, name);
	}
	interfaces = sort(interfaces);
	let lan = configured.detected_lan ?? '', wan = configured.detected_wan ?? '';
	if (!valid_interface(lan) || index(interfaces, lan) < 0)
		lan = index(interfaces, 'br-lan') >= 0 ? 'br-lan' :
			(index(interfaces, 'lan') >= 0 ? 'lan' : '');
	if (!valid_interface(wan) || index(interfaces, wan) < 0) {
		wan = '';
		let routes = '';
		try { routes = runtime.fs.readfile('/proc/net/route') ?? ''; }
		catch (error) {}
		if (type(routes) != 'string') routes = '';
		for (let line in split(substr(routes, 0, 65536), '\n')) {
			let found = match(line,
				/^([A-Za-z0-9][A-Za-z0-9_.:@-]{0,14})[ \t]+00000000[ \t]+[0-9A-Fa-f]{8}[ \t]+/);
			if (found != null && index(interfaces, found[1]) >= 0) { wan = found[1]; break; }
		}
		if (!length(wan) && index(interfaces, 'wan') >= 0) wan = 'wan';
	}
	return { available, interfaces, detected_lan: lan, detected_wan: wan };
};

export function resolve(settings, snapshot) {
	let configured = settings?.interfaces;
	if (type(configured) != 'object' ||
	    (configured.mode != 'explicit' && configured.mode != 'exclude') ||
	    type(configured.auto_detect_lan) != 'bool' ||
	    type(configured.auto_detect_wan) != 'bool' || type(snapshot) != 'object' ||
	    type(snapshot.interfaces) != 'array') fail('INVALID_ARGUMENT');
	let interfaces = unique(snapshot.interfaces);
	snapshot = { ...snapshot, interfaces };
	let lan = detected(configured, snapshot, 'detected_lan');
	let wan = detected(configured, snapshot, 'detected_wan');
	let included = unique(configured.included ?? []), excluded = unique(configured.excluded ?? []);
	if (configured.auto_detect_lan && length(lan) && index(included, lan) < 0) push(included, lan);
	if (configured.auto_detect_wan && length(wan) && index(excluded, wan) < 0) push(excluded, wan);
	return { mode: configured.mode, interfaces, detected_lan: lan, detected_wan: wan,
		included, excluded };
};

export function contains(projection, name) {
	name = interface_name(name);
	if (type(projection) != 'object' ||
	    (projection.mode != 'explicit' && projection.mode != 'exclude') ||
	    type(projection.included) != 'array' || type(projection.excluded) != 'array')
		fail('INVALID_ARGUMENT');
	return projection.mode == 'explicit' ? index(projection.included, name) >= 0 :
		index(projection.excluded, name) < 0;
};

export function effective_settings(settings, snapshot) {
	if (type(settings) != 'object') fail('INVALID_ARGUMENT');
	let projection = resolve(settings, snapshot), configured = settings.interfaces;
	return { ...settings, interfaces: { ...configured,
		detected_lan: projection.detected_lan, detected_wan: projection.detected_wan } };
};
