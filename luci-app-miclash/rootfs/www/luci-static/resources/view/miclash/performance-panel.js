'use strict';
'require baseclass';
'require view.miclash.performance';

function number(value) {
	return (Number(value) || 0).toFixed(1);
}

function aggregateRows(values) {
	return Object.entries(values || {})
		.sort((left, right) => right[1].total_ms - left[1].total_ms)
		.map(([ name, metric ]) => E('tr', {}, [
			E('td', {}, name),
			E('td', {}, String(metric.count)),
			E('td', {}, String(metric.failures)),
			E('td', {}, number(metric.average_ms)),
			E('td', {}, number(metric.maximum_ms)),
			E('td', {}, number(metric.total_ms))
		]));
}

function metricsTable(title, values) {
	const rows = aggregateRows(values);
	if (!rows.length) rows.push(E('tr', {}, E('td', {
		'colspan': '6', 'class': 'sbox-muted'
	}, _('No measurements yet.'))));
	return E('article', { 'class': 'sbox-settings-card sbox-performance-card' }, [
		E('h4', {}, title),
		E('div', { 'class': 'sbox-performance-table-wrap' }, E('table', {
			'class': 'table sbox-performance-table'
		}, [
			E('thead', {}, E('tr', {}, [
				_('Metric'), _('Calls'), _('Errors'), _('Average, ms'),
				_('Maximum, ms'), _('Total, ms')
			].map((label) => E('th', {}, label)))),
			E('tbody', {}, rows)
		]))
	]);
}

function create() {
	let host = null, unsubscribe = null;

	function refresh() {
		if (!host) return;
		const snapshot = view_miclash_performance.snapshot();
		host.replaceChildren(
			E('div', { 'class': 'sbox-performance-heading' }, [
				E('div', {}, [
					E('h4', {}, _('Performance')),
					E('p', { 'class': 'sbox-muted' },
						_('Local browser measurements only. RPC arguments and payloads are never recorded.'))
				]),
				E('div', { 'class': 'sbox-performance-actions' }, [
					E('button', {
						'type': 'button', 'class': 'cbi-button cbi-button-neutral',
						'data-performance-action': 'refresh'
					}, _('Refresh')),
					E('button', {
						'type': 'button', 'class': 'cbi-button cbi-button-negative',
						'data-performance-action': 'clear'
					}, _('Reset'))
				])
			]),
			E('div', { 'class': 'sbox-performance-grid' }, [
				metricsTable(_('RPC methods'), snapshot.methods),
				metricsTable(_('Page and action timings'), snapshot.timings)
			])
		);
		host.querySelector('[data-performance-action="refresh"]')
			?.addEventListener('click', refresh);
		host.querySelector('[data-performance-action="clear"]')
			?.addEventListener('click', () => view_miclash_performance.clear());
	}

	function mount(node) {
		host = node || null;
		if (!host) return;
		if (unsubscribe) unsubscribe();
		unsubscribe = view_miclash_performance.subscribe(refresh);
		refresh();
	}

	function destroy() {
		if (unsubscribe) unsubscribe();
		unsubscribe = null;
		host = null;
	}

	return { mount, refresh, destroy };
}

return baseclass.extend({ create });
