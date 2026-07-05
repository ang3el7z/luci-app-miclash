import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const viewDir = 'luci-app-miclash/rootfs/www/luci-static/resources/view/miclash';
const locales = [
	'luci-app-miclash/rootfs/po/ru/miclash.po',
	'luci-app-miclash/rootfs/po/zh-cn/miclash.po'
];

function walkJs(dir) {
	return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
		const file = join(dir, entry.name);
		if (entry.isDirectory()) return entry.name === 'ace' ? [] : walkJs(file);
		return entry.isFile() && entry.name.endsWith('.js') ? [file] : [];
	});
}

function unquoteJs(quote, value) {
	try {
		return Function('return ' + quote + value + quote)();
	} catch (_) {
		return value;
	}
}

function extractLocalizedStrings(file) {
	const source = readFileSync(file, 'utf8');
	const strings = [];
	const pattern = /_\(\s*(['"])((?:\\.|(?!\1)[\s\S])*?)\1\s*\)/g;
	let match;

	while ((match = pattern.exec(source))) {
		const line = source.slice(0, match.index).split(/\r?\n/).length;
		strings.push({
			file,
			line,
			text: unquoteJs(match[1], match[2])
		});
	}

	return strings;
}

function unquotePo(value) {
	return JSON.parse(value);
}

function parsePo(file) {
	const entries = new Map();
	const duplicates = [];
	const lines = readFileSync(file, 'utf8').split(/\r?\n/);
	let state = null;
	let msgid = null;
	let msgstr = null;

	function flush() {
		if (msgid !== null) {
			if (entries.has(msgid)) duplicates.push(msgid);
			entries.set(msgid, msgstr ?? '');
		}
		state = null;
		msgid = null;
		msgstr = null;
	}

	for (const line of lines) {
		let match = line.match(/^msgid\s+(".*")$/);
		if (match) {
			flush();
			state = 'msgid';
			msgid = unquotePo(match[1]);
			msgstr = null;
			continue;
		}

		match = line.match(/^msgstr\s+(".*")$/);
		if (match) {
			state = 'msgstr';
			msgstr = unquotePo(match[1]);
			continue;
		}

		match = line.match(/^\s*(".*")$/);
		if (match) {
			if (state === 'msgid') msgid += unquotePo(match[1]);
			if (state === 'msgstr') msgstr = (msgstr ?? '') + unquotePo(match[1]);
		}
	}

	flush();
	return { entries, duplicates };
}

function placeholders(text) {
	const matches = String(text || '').match(/%[sd]/g);
	return matches ? matches.join(' ') : '';
}

const references = walkJs(viewDir).flatMap(extractLocalizedStrings);
const unique = [...new Map(references.map((ref) => [ref.text, ref])).values()]
	.sort((a, b) => a.text.localeCompare(b.text));

let failed = false;

for (const locale of locales) {
	const parsed = parsePo(locale);
	const entries = parsed.entries;
	const missing = unique.filter((ref) => !entries.has(ref.text));
	const empty = unique.filter((ref) => entries.has(ref.text) && !entries.get(ref.text));
	const placeholderMismatch = unique.filter((ref) => {
		if (!entries.has(ref.text)) return false;
		return placeholders(ref.text) !== placeholders(entries.get(ref.text));
	});

	if (missing.length || empty.length || placeholderMismatch.length || parsed.duplicates.length) {
		console.error(locale);
		for (const id of parsed.duplicates) {
			console.error(`duplicate ${JSON.stringify(id)}`);
		}
		for (const ref of missing) {
			console.error(`missing ${ref.file}:${ref.line} ${JSON.stringify(ref.text)}`);
		}
		for (const ref of empty) {
			console.error(`empty ${ref.file}:${ref.line} ${JSON.stringify(ref.text)}`);
		}
		for (const ref of placeholderMismatch) {
			console.error(`placeholder ${ref.file}:${ref.line} ${JSON.stringify(ref.text)} -> ${JSON.stringify(entries.get(ref.text))}`);
		}
		failed = true;
	}
}

if (failed) process.exit(1);
console.log(`translation check passed (${unique.length} localized strings)`);
