import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';

const SOURCES = {
	oui: { bits: 24, url: 'https://standards-oui.ieee.org/oui/oui.csv' },
	mam: { bits: 28, url: 'https://standards-oui.ieee.org/oui28/mam.csv' },
	oui36: { bits: 36, url: 'https://standards-oui.ieee.org/oui36/oui36.csv' }
};
const MAX_BYTES = 4 * 1024 * 1024;

function argumentsFrom(values) {
	const result = {};
	for (let index = 0; index < values.length; index += 2) {
		const name = values[index], value = values[index + 1];
		if (!/^--(?:date|oui|mam|oui36|output|manifest)$/.test(name || '') || value == null)
			throw new Error('Usage: generate-device-vendors.mjs --date YYYY-MM-DD --oui FILE --mam FILE --oui36 FILE --output FILE --manifest FILE');
		result[name.slice(2)] = value;
	}
	if (!/^20\d{2}-\d{2}-\d{2}$/.test(result.date || '') ||
		!result.oui || !result.mam || !result.oui36 || !result.output || !result.manifest)
		throw new Error('Missing device vendor generator argument');
	return result;
}

function csvRows(text) {
	const rows = [];
	let row = [], field = '', quoted = false;
	for (let index = 0; index < text.length; index++) {
		const char = text[index];
		if (quoted) {
			if (char === '"' && text[index + 1] === '"') { field += '"'; index++; }
			else if (char === '"') quoted = false;
			else field += char;
		}
		else if (char === '"') quoted = true;
		else if (char === ',') { row.push(field); field = ''; }
		else if (char === '\n') {
			row.push(field.replace(/\r$/, '')); rows.push(row); row = []; field = '';
		}
		else field += char;
	}
	if (quoted) throw new Error('Unterminated CSV field');
	if (field || row.length) { row.push(field.replace(/\r$/, '')); rows.push(row); }
	return rows;
}

function registry(path, bits) {
	const rows = csvRows(readFileSync(path, 'utf8'));
	const header = rows.shift() || [];
	const assignmentIndex = header.indexOf('Assignment');
	const nameIndex = header.indexOf('Organization Name');
	if (assignmentIndex < 0 || nameIndex < 0) throw new Error(`Invalid IEEE CSV header: ${path}`);
	const wantedLength = bits === 24 ? 6 : (bits === 28 ? 7 : 9);
	const entries = [];
	for (const row of rows) {
		const prefix = String(row[assignmentIndex] || '').replace(/[^0-9A-F]/gi, '').toUpperCase();
		const name = String(row[nameIndex] || '').replace(/[\t\r\n]+/g, ' ').replace(/\s+/g, ' ').trim();
		if (!prefix && !name) continue;
		if (!new RegExp(`^[0-9A-F]{${wantedLength}}$`).test(prefix) || !name || name.length > 160)
			throw new Error(`Invalid IEEE ${bits}-bit registry row: ${prefix}`);
		entries.push({ bits, prefix, name });
	}
	return entries;
}

const args = argumentsFrom(process.argv.slice(2));
const registryEntries = Object.entries(SOURCES).flatMap(([ name, source ]) => registry(args[name], source.bits));
const grouped = new Map();
for (const entry of registryEntries) {
	const key = `${entry.bits}:${entry.prefix}`;
	if (!grouped.has(key)) grouped.set(key, []);
	grouped.get(key).push(entry);
}
let ambiguous = 0;
const entries = [];
for (const candidates of grouped.values()) {
	const names = new Set(candidates.map((entry) => entry.name));
	if (names.size !== 1) { ambiguous++; continue; }
	entries.push(candidates[0]);
}
const lexical = (left, right) => left < right ? -1 : (left > right ? 1 : 0);
const names = Array.from(new Set(entries.map((entry) => entry.name))).sort(lexical);
const identifiers = new Map(names.map((name, index) => [ name, index.toString(36).toUpperCase() ]));
entries.sort((left, right) => left.bits - right.bits || lexical(left.prefix, right.prefix));

const lines = [
	'# miclash-device-vendors-v1',
	`# snapshot=${args.date}`,
	...Object.values(SOURCES).map((source) => `# source=${source.url}`),
	...names.map((name) => `V\t${identifiers.get(name)}\t${name}`),
	...entries.map((entry) => `P\t${entry.bits}\t${entry.prefix}\t${identifiers.get(entry.name)}`),
	''
];
const output = lines.join('\n');
if (Buffer.byteLength(output, 'utf8') > MAX_BYTES)
	throw new Error(`Generated database exceeds ${MAX_BYTES} bytes`);
writeFileSync(args.output, output, { encoding: 'utf8' });
writeFileSync(args.manifest, JSON.stringify({ version: 1, snapshot: args.date,
	size: Buffer.byteLength(output, 'utf8'),
	sha256: createHash('sha256').update(output).digest('hex') }) + '\n', { encoding: 'utf8' });
console.log(`generated ${entries.length} prefixes and ${names.length} manufacturers; omitted ${ambiguous} ambiguous prefixes (${Buffer.byteLength(output)} bytes)`);
