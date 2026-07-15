import * as errors from 'miclash.errors';
import * as http from 'miclash.http';
import * as schema from 'miclash.schema';

const URL_OPTIONS = {
	'config.yaml': 'subscription_url_config_yaml',
	'config2.yaml': 'subscription_url_config2_yaml',
	'config3.yaml': 'subscription_url_config3_yaml'
};

function invalid() { errors.fail('INVALID_ARGUMENT'); };

function exact(value, allowed) {
	if (type(value) != 'object')
		invalid();
	for (let name in value)
		if (!exists(allowed, name))
			invalid();
	return value;
};

function clean_header(value) {
	if (type(value) != 'string' || !length(value) || length(value) > 256 ||
	    match(value, /[[:cntrl:]]/))
		invalid();
	return value;
};

function settings_headers(value) {
	let core = value?.core;
	if (type(core) != 'object')
		invalid();
	return {
		'User-Agent': clean_header(core.hwid_user_agent ?? 'MiClash'),
		'X-Device-OS': clean_header(core.hwid_device_os ?? 'OpenWrt'),
		'Accept': 'application/yaml, text/yaml, text/plain, */*',
		'Cache-Control': 'no-cache',
		'Pragma': 'no-cache'
	};
};

function interval(headers) {
	let value = headers?.['profile-update-interval'];
	if (type(value) != 'string' || !match(value, /^(0|[1-9][0-9]*)$/))
		return null;
	let parsed = int(value);
	return parsed != null && parsed >= 1 && parsed <= 8760 ? parsed : null;
};

function yaml_payload(content) {
	return type(content) == 'string' && length(content) &&
		match(content, /(^|\n)[ \t]*(proxies|proxy-providers|proxy-groups|mixed-port|port|mode|rules):[ \t]*/);
};

function uri_payload(content) {
	return type(content) == 'string' &&
		match(content, /(^|[ \t\r\n])(vmess|vless|trojan|ss|ssr|hysteria|hysteria2|tuic):\/\//);
};

function prepared_payload(content) {
	if (yaml_payload(content))
		return { content, payload: 'yaml', needs_fallback: false };
	let compact = type(content) == 'string' ? replace(content, /[ \t\r\n]/g, '') : '';
	if (length(compact) >= 48 && !match(compact, /:/) &&
	    match(compact, /^[A-Za-z0-9+\/=]+$/)) {
		let decoded = null;
		try { decoded = b64dec(compact); } catch (error) {}
		if (yaml_payload(decoded))
			return { content: decoded, payload: 'base64-yaml', needs_fallback: false };
		return { content, payload: 'base64', needs_fallback: true };
	}
	if (uri_payload(content))
		return { content, payload: 'uri', needs_fallback: true };
	return { content, payload: 'unknown', needs_fallback: false };
};

function remnawave_url(url) {
	let query_at = index(url, '?');
	let query = query_at >= 0 ? substr(url, query_at) : '';
	let base = query_at >= 0 ? substr(url, 0, query_at) : url;
	if (match(base, /\/mihomo$/))
		return null;
	let scheme_at = index(base, '://'), rest = substr(base, scheme_at + 3);
	let slash = index(rest, '/');
	let authority = slash >= 0 ? substr(rest, 0, slash) : rest;
	let path = slash >= 0 ? substr(rest, slash + 1) : '';
	let pieces = length(path) ? split(path, '/') : [];
	let changed = false;
	for (let index = 0; index < length(pieces); index++)
		if (pieces[index] == 'sub' && index + 1 < length(pieces)) {
			if (index + 2 < length(pieces))
				pieces[index + 2] = 'mihomo';
			else
				push(pieces, 'mihomo');
			changed = true;
			break;
		}
	if (!changed)
		push(pieces, 'mihomo');
	return substr(base, 0, scheme_at) + '://' + authority + '/' + join('/', pieces) + query;
};

function github_alternate(url) {
	let raw = match(url,
		/^https:\/\/raw\.githubusercontent\.com\/([^\/]+)\/([^\/]+)\/([^\/]+)\/(.+)$/);
	if (raw != null)
		return { url: 'https://cdn.jsdelivr.net/gh/' + raw[1] + '/' + raw[2] + '@' +
			raw[3] + '/' + raw[4], mode: 'github-cdn' };
	let cdn = match(url,
		/^https:\/\/cdn\.jsdelivr\.net\/gh\/([^\/]+)\/([^\/@]+)@([^\/]+)\/(.+)$/);
	if (cdn != null)
		return { url: 'https://raw.githubusercontent.com/' + cdn[1] + '/' + cdn[2] +
			'/' + cdn[3] + '/' + cdn[4], mode: 'github-raw' };
	return null;
};

function proxy_block(mode, stack) {
	if (mode == 'tun')
		return '# Proxy Mode: TUN\ntun:\n  enable: true\n  device: clash-tun\n' +
			'  stack: ' + stack + '\n  auto-route: false\n  auto-redirect: false\n' +
			'  auto-detect-interface: false';
	if (mode == 'mixed')
		return '# Proxy Mode: MIXED (TCP via TPROXY, UDP via TUN)\n' +
			'redir-port: 7892\ntproxy-port: 7894\ntun:\n  enable: true\n' +
			'  device: clash-tun\n  stack: ' + stack + '\n  auto-route: false\n' +
			'  auto-redirect: false\n  auto-detect-interface: false';
	return '# Proxy Mode: TPROXY\nredir-port: 7892\ntproxy-port: 7894';
};

// This is the one canonical top-level proxy-mode transform used by both probe
// preparation and activation. It deliberately does not parse or rewrite nested
// provider fields with the same names.
function transform(content, mode, stack) {
	if (type(content) != 'string' || !length(content) ||
	    (mode != 'tproxy' && mode != 'tun' && mode != 'mixed') ||
	    (stack != 'system' && stack != 'gvisor' && stack != 'mixed'))
		invalid();
	let output = [], in_tun = false, inserted = false;
	for (let line in split(replace(content, /\r\n/g, '\n'), '\n')) {
		let top = !match(line, /^[ \t]/), clean = trim(line);
		if (in_tun) {
			if (!length(clean) || match(clean, /^#/) || !top)
				continue;
			in_tun = false;
		}
		if (top && (match(clean, /^#[ \t]*Proxy[ \t]+Mode:/) ||
		    match(clean, /^(redir-port|tproxy-port):/)))
			continue;
		if (top && match(clean, /^tun:[ \t]*$/)) {
			in_tun = true;
			continue;
		}
		push(output, line);
		if (!inserted && top && match(clean, /^mode:/)) {
			push(output, proxy_block(mode, stack));
			inserted = true;
		}
	}
	if (!inserted)
		unshift(output, proxy_block(mode, stack));
	while (length(output) && !length(output[length(output) - 1]))
		pop(output);
	return join('\n', output) + '\n';
};

function safe_url(url) {
	url = schema.url(url);
	let scheme_end = index(url, '://');
	let scheme = substr(url, 0, scheme_end), rest = substr(url, scheme_end + 3);
	let end = length(rest);
	for (let marker in [ '/', '?', '#' ]) {
		let position = index(rest, marker);
		if (position >= 0 && position < end)
			end = position;
	}
	return scheme + '://' + substr(rest, 0, end) + '/[REDACTED]';
};

export function create(app) {
	let adapter = app?.http ?? http;
	if (type(app?.runtime) != 'object' || type(app?.operations?.submit) != 'function' ||
	    type(app?.config?.validate_in_operation) != 'function' ||
	    type(app?.config?.apply_in_operation) != 'function' ||
	    type(app?.settings?.get) != 'function' || type(app?.settings?.validate) != 'function' ||
	    type(app?.settings?.set) != 'function' || type(adapter?.download) != 'function')
		invalid();
	function current() {
		let value = app.settings.get();
		if (type(value?.core) != 'object' || type(value?.updates) != 'object')
			invalid();
		return value;
	};

	function profile_url(profile, supplied, value) {
		profile = schema.profile_name(profile);
		let url = supplied;
		if (url == null) {
			url = value.core[URL_OPTIONS[profile]];
			if (profile == 'config.yaml' && !length(url ?? ''))
				url = value.core.subscription_url;
		}
		return schema.url(url);
	};

	function fetch(options) {
		exact(options, { url: true });
		let value = current(), url = schema.url(options.url);
		let request_headers = settings_headers(value);
		let candidates = [ { url, mode: 'direct' } ];
		let github = github_alternate(url);
		let remnawave = github == null ? remnawave_url(url) : null;
		if (remnawave != null && remnawave != url)
			push(candidates, { url: remnawave, mode: 'remnawave' });
		if (github != null)
			push(candidates, github);
		let primary_interval = null, primary_needs_fallback = false;
		for (let candidate in candidates) {
			let result = null;
			try {
				result = adapter.download(app.runtime, {
					url: candidate.url,
					headers: request_headers,
					connect_timeout_ms: 8000,
					timeout_ms: 120000,
					max_redirects: 3,
					max_bytes: 8 * 1024 * 1024,
					allow_insecure_http: match(candidate.url, /^http:\/\//) != null
				});
			}
			catch (error) {
				let code = errors.normalize(error).code;
				if (code != 'DOWNLOAD_FAILED')
					errors.fail(code);
				continue;
			}
			if (type(result) != 'object' || type(result.status) != 'int' ||
			    result.status < 200 || result.status >= 300 ||
			    type(result.headers) != 'object' || type(result.body) != 'string')
				errors.fail('INVALID_RESPONSE');
			let payload = prepared_payload(result.body);
			let found_interval = interval(result.headers);
			if (candidate.mode == 'direct') {
				primary_interval = found_interval;
				primary_needs_fallback = payload.needs_fallback;
			}
			if (payload.needs_fallback)
				continue;
			return {
				content: payload.content,
				mode: candidate.mode,
				payload: payload.payload,
				interval_hours: found_interval ?? primary_interval,
				insecure: match(candidate.url, /^http:\/\//) != null
			};
		}
		if (primary_needs_fallback)
			errors.fail('INVALID_RESPONSE');
		errors.fail('DOWNLOAD_FAILED');
	};

	let api = {};
	api.probe = (options) => {
		let found = fetch(options);
		return {
			mode: found.mode,
			payload: found.payload,
			interval_hours: found.interval_hours,
			insecure: found.insecure
		};
	};
	function update(options, source, pre_enqueue) {
		exact(options, { profile: true, url: true });
		if (pre_enqueue != null && type(pre_enqueue) != 'function')
			invalid();
		let value = current(), profile = schema.profile_name(options.profile);
		let url = profile_url(profile, options.url, value);
		let insecure = match(url, /^http:\/\//) != null;
		return app.operations.submit('subscription.update', source,
			{ profile, insecure }, (ctx) => {
				ctx.stage('attempt', 10, 'Subscription attempt started');
				let candidate = fetch({ url });
				ctx.stage('download', 35, 'Subscription downloaded');
				ctx.result({ interval_hours: candidate.interval_hours });
				let content = transform(candidate.content, value.core.proxy_mode,
					value.core.tun_stack);
				ctx.stage('validation', 55, 'Validating subscription');
				let checked = app.config.validate_in_operation(ctx, profile, content);
				if (checked?.ok !== true) {
					ctx.complete(checked?.error ?? errors.new('VALIDATION_FAILED'));
					return false;
				}
				ctx.stage('activation', 75, 'Activating subscription');
				let applied = app.config.apply_in_operation(ctx, profile, content, source, {
					attempt_result: 'success', download_result: 'success',
					validation_result: 'success', activation_result: 'pending',
					reload_result: 'pending', interval_hours: candidate.interval_hours
				});
				if (applied?.ok !== true) {
					let failure = applied?.error ?? errors.new('HEALTH_FAILED');
					if (applied?.activated === true && applied?.reload_ok !== true &&
					    errors.normalize(failure).code == 'HEALTH_FAILED') {
						ctx.stage('reload', 95, 'Subscription reload failed');
					}
					ctx.complete(failure);
					return false;
				}
				if (applied?.activated !== true || applied?.reload_ok !== true)
					errors.fail('INTERNAL');
				ctx.stage('reload', 95, 'Subscription active');
				return true;
			}, pre_enqueue);
	};
	api.update = (options, source) => update(options, source, null);
	// Internal scheduler entrypoint: the durability hook is owned by the
	// operation manager and runs after queued journal persistence, before run.
	api.update_scheduled = (options, source, pre_enqueue) =>
		update(options, source, pre_enqueue);
	api.set_url = (options, source) => {
		exact(options, { profile: true, url: true, interval_hours: true });
		let profile = schema.profile_name(options.profile), url = schema.url(options.url);
		let hours = options.interval_hours;
		if (type(hours) != 'int' || hours < 1 || hours > 8760)
			invalid();
		let patch = {
			core: { [URL_OPTIONS[profile]]: url },
			updates: { interval_hours: hours }
		};
		patch = app.settings.validate(patch);
		return app.operations.submit('subscription.set_url', source,
			{ profile, insecure: match(url, /^http:\/\//) != null }, (ctx) => {
				ctx.stage('settings', 50, 'Saving subscription settings');
				app.settings.set(patch);
				return true;
			});
	};
	api.get_redacted = (profile) => {
		profile = schema.profile_name(profile);
		let value = current(), url = value.core[URL_OPTIONS[profile]];
		if (profile == 'config.yaml' && !length(url ?? ''))
			url = value.core.subscription_url;
		if (!length(url ?? ''))
			return { configured: false, url: null, insecure: false,
				interval_hours: value.updates.interval_hours };
		try {
			url = schema.url(url);
			return { configured: true, url: safe_url(url),
				insecure: match(url, /^http:\/\//) != null,
				interval_hours: value.updates.interval_hours };
		}
		catch (error) {
			return { configured: true, url: '[INVALID]', insecure: null,
				interval_hours: value.updates.interval_hours };
		}
	};
	return api;
};
