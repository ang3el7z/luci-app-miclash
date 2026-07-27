'use strict';
'require baseclass';

const HEADER = '# miclash-device-vendors-v1';
const MAX_DATABASE_BYTES = 4 * 1024 * 1024;
const GENERIC_HOSTNAMES = new Set([ 'lwip', 'lwip0', 'wlan0', 'localhost', 'unknown' ]);

function parseDatabase(value) {
	if (typeof value !== 'string' || value.length === 0 || value.length > MAX_DATABASE_BYTES)
		throw new Error('Invalid device vendor database size');
	const lines = value.replace(/\r/g, '').split('\n');
	if (lines[0] !== HEADER || !/^# snapshot=\d{4}-\d{2}-\d{2}$/.test(lines[1] || ''))
		throw new Error('Invalid device vendor database header');
	const database = {
		snapshot: lines[1].slice(11), vendors: new Map(),
		prefixes24: new Map(), prefixes28: new Map(), prefixes36: new Map()
	};
	for (let index = 2; index < lines.length; index++) {
		const line = lines[index];
		if (!line || line[0] === '#') continue;
		const fields = line.split('\t');
		if (fields[0] === 'V') {
			const id = fields[1], name = fields[2];
			if (fields.length !== 3 || !/^[0-9A-Z]+$/.test(id || '') ||
				!name || name !== name.trim() || name.length > 160 || database.vendors.has(id))
				throw new Error('Invalid device vendor record');
			database.vendors.set(id, name);
			continue;
		}
		if (fields[0] !== 'P' || fields.length !== 4)
			throw new Error('Invalid device vendor prefix record');
		const bits = Number(fields[1]), prefix = fields[2], vendor = fields[3];
		const target = bits === 24 ? database.prefixes24 :
			(bits === 28 ? database.prefixes28 : (bits === 36 ? database.prefixes36 : null));
		const wantedLength = bits === 24 ? 6 : (bits === 28 ? 7 : (bits === 36 ? 9 : 0));
		if (!target || !new RegExp(`^[0-9A-F]{${wantedLength}}$`).test(prefix || '') ||
			!database.vendors.has(vendor) || target.has(prefix))
			throw new Error('Invalid device vendor prefix record');
		target.set(prefix, vendor);
	}
	return database;
}

function normalizedMac(value) {
	const mac = String(value || '').replace(/[:-]/g, '').toUpperCase();
	if (!/^[0-9A-F]{12}$/.test(mac)) return null;
	const first = Number.parseInt(mac.slice(0, 2), 16);
	return (first & 3) === 0 ? mac : null;
}

function lookupManufacturer(database, value) {
	const mac = normalizedMac(value);
	if (!mac || !database?.vendors) return null;
	const id = database.prefixes36?.get(mac.slice(0, 9)) ??
		database.prefixes28?.get(mac.slice(0, 7)) ??
		database.prefixes24?.get(mac.slice(0, 6));
	return id == null ? null : (database.vendors.get(id) || null);
}

function isGenericHostname(value) {
	return GENERIC_HOSTNAMES.has(String(value || '').trim().toLowerCase());
}

function resolveDeviceLabel(device, database) {
	const hostname = String(device?.hostname || '').trim() || null;
	const manufacturer = lookupManufacturer(database, device?.mac);
	if (hostname && !isGenericHostname(hostname)) return { kind: 'hostname', hostname, manufacturer };
	if (hostname) return { kind: 'generic', hostname, manufacturer };
	if (manufacturer) return { kind: 'manufacturer', hostname: null, manufacturer };
	return { kind: 'unknown', hostname: null, manufacturer: null };
}

return baseclass.extend({
	MAX_DATABASE_BYTES, parseDatabase, lookupManufacturer, isGenericHostname, resolveDeviceLabel
});
