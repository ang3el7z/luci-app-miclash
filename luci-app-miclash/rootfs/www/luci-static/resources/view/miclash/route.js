'use strict';

function getSection() {
	const path = String((window.location && window.location.pathname) || '');
	const hash = String((window.location && window.location.hash) || '').replace(/^#/, '');

	if (/\/miclash\/settings(?:\/|$)/.test(path) || hash === 'settings') return 'settings';
	if (/\/miclash\/log(?:\/|$)/.test(path) || hash === 'log' || hash === 'logs') return 'log';
	return 'config';
}

function applySection(state, section) {
	if (section === 'settings') {
		state.activeCtrlTab = 'settings';
		state.activeCfgTab = 'config';
		return;
	}

	if (section === 'log') {
		state.activeCtrlTab = 'control';
		state.activeCfgTab = 'logs';
		return;
	}

	state.activeCtrlTab = 'control';
	state.activeCfgTab = 'config';
}

return L.Class.extend({
	getSection: getSection,
	applySection: applySection
});
