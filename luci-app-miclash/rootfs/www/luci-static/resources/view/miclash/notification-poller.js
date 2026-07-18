'use strict';
'require baseclass';

const GENERATION = /^ng_[0-9a-f]{32}$/;
const BATCH = 32;
const POLL_MS = 5000;
const MAX_POLL_MS = 60000;

function create(options) {
	options = options || {};
	const api = options.api, doc = options.document || document, win = options.window || window;
	if (!api || typeof api.notificationEvents !== 'function' ||
		typeof options.onEvent !== 'function') throw new Error('Typed notification API is required');
	let generation = null, cursor = 0, timer = null, running = false,
		busy = false, destroyed = false, retryMs = POLL_MS, lifecycle = 0;

	function clearTimer() {
		if (timer != null) win.clearTimeout(timer);
		timer = null;
	}
	function schedule(delay) {
		clearTimer();
		if (!running || doc.hidden) return;
		timer = win.setTimeout(() => {
			timer = null;
			poll().catch(report);
		}, delay == null ? retryMs : delay);
	}
	function report(error) {
		if (running && typeof options.onError === 'function') options.onError(error);
	}
	function validReply(reply) {
		if (!reply || typeof reply !== 'object' || Array.isArray(reply) ||
			!GENERATION.test(String(reply.generation || '')) ||
			!Number.isSafeInteger(reply.cursor) || reply.cursor < 0 ||
			typeof reply.stale !== 'boolean' || typeof reply.has_more !== 'boolean' ||
			!Array.isArray(reply.events) || reply.events.length > BATCH)
			throw new Error('Invalid notification response');
		return reply;
	}
	async function poll() {
		if (!running || busy || doc.hidden) return false;
		busy = true;
		const token = lifecycle;
		try {
			const reply = validReply(await api.notificationEvents(generation, cursor, BATCH));
			if (!running || token !== lifecycle) return false;
			if (reply.stale) {
				generation = reply.generation;
				cursor = reply.cursor;
				retryMs = POLL_MS;
				schedule(0);
				return true;
			}
			if (generation != null && reply.generation !== generation)
				throw new Error('Notification generation changed without stale cursor');
			let next = cursor;
			for (const entry of reply.events) {
				if (!entry || typeof entry !== 'object' ||
					!Number.isSafeInteger(entry.cursor) || entry.cursor <= next ||
					entry.cursor > reply.cursor || !entry.event ||
					typeof entry.event !== 'object' || Array.isArray(entry.event))
					throw new Error('Invalid notification event');
				options.onEvent(entry.event);
				next = entry.cursor;
			}
			if (reply.cursor !== next)
				throw new Error('Invalid notification cursor');
			generation = reply.generation;
			cursor = reply.cursor;
			retryMs = POLL_MS;
			schedule(reply.has_more ? 0 : POLL_MS);
			return true;
		} catch (error) {
			retryMs = Math.min(MAX_POLL_MS, Math.max(POLL_MS, retryMs * 2));
			schedule(retryMs);
			throw error;
		} finally {
			busy = false;
		}
	}
	function visibilitychange() {
		if (doc.hidden) clearTimer();
		else if (running) poll().catch(report);
	}
	function start() {
		if (running || destroyed) return false;
		running = true; lifecycle++;
		if (!doc.hidden) poll().catch(report);
		return true;
	}
	function destroy() {
		if (destroyed) return false;
		destroyed = true; running = false; lifecycle++; clearTimer();
		doc.removeEventListener('visibilitychange', visibilitychange);
		if (typeof api.destroy === 'function') api.destroy();
		return true;
	}

	doc.addEventListener('visibilitychange', visibilitychange);
	return { start, poll, destroy };
}

return baseclass.extend({ create });
