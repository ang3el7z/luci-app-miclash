import { fail } from 'miclash.errors';

export function create(runtime) {
	if (type(runtime?.digest?.sha256) != 'function') fail('INVALID_ARGUMENT');
	return {
		validate: (name, content) => {
			if (type(name) != 'string' || length(name) < 5 || length(name) > 90 ||
			    !match(name, /^[a-z0-9][a-z0-9_-]*\.txt$/) || type(content) != 'string' ||
			    length(content) > 4194304 || index(content, sprintf('%c', 0)) >= 0)
				return false;
			let lines = split(content, '\n');
			if (length(lines) > 65536) return false;
			for (let line in lines) {
				let visible = replace(replace(line, '\t', ''), '\r', '');
				if (length(line) > 4096 || match(visible, /[[:cntrl:]]/)) return false;
			}
			let digest = runtime.digest.sha256(content);
			return type(digest) == 'string' && match(digest, /^[0-9a-f]{64}$/) != null;
		}
	};
};
