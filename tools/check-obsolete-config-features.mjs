import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';

const root = 'luci-app-miclash/rootfs/';
const removedFiles = [
	'usr/share/miclash/history.uc',
	'usr/share/miclash/diff.uc',
	'usr/share/miclash/backup.uc',
	'www/luci-static/resources/view/miclash/history-panel.js',
	'www/luci-static/resources/view/miclash/backup-panel.js'
];
for (const path of removedFiles)
	assert.equal(existsSync(root + path), false, `obsolete feature file still ships: ${path}`);

const sources = [
	'www/luci-static/resources/view/miclash/api.js',
	'www/luci-static/resources/view/miclash/config.js',
	'www/luci-static/resources/view/miclash/settings-panels.js',
	'usr/share/miclash/api.uc',
	'usr/share/miclash/application.uc',
	'usr/share/miclash/config.uc',
	'usr/share/miclash/daemon.uc',
	'usr/share/miclash/settings.uc',
	'usr/share/miclash/telegram.uc',
	'usr/share/miclash/notify.uc',
	'usr/share/rpcd/acl.d/luci-app-miclash.json',
	'etc/config/miclash'
].map((path) => [path, readFileSync(root + path, 'utf8')]);

const obsolete = [
	'config_read_draft', 'config_save_draft',
	'history_list', 'history_diff', 'history_open_draft', 'history_restore',
	'backup_list', 'backup_create', 'backup_inspect', 'backup_restore',
	'backup_outcome'
];
for (const [path, source] of sources)
	for (const token of obsolete)
		assert.doesNotMatch(source, new RegExp(`\\b${token}\\b`), `${path} still exposes ${token}`);

const telegram = sources.find(([path]) => path.endsWith('telegram.uc'))[1];
assert.doesNotMatch(telegram, /\/backup\b/, 'Telegram still advertises the removed backup command');
const settings = sources.find(([path]) => path.endsWith('settings.uc'))[1];
assert.doesNotMatch(settings, /\bbackup\s*:/, 'settings schema still contains backup configuration');
const defaults = sources.find(([path]) => path === 'etc/config/miclash')[1];
assert.doesNotMatch(defaults, /config backup\b/, 'default UCI still creates a backup section');
const makefile = readFileSync('luci-app-miclash/Makefile', 'utf8');
assert.match(makefile, /rm -rf "\$\$ROOT\/opt\/clash\/history" "\$\$ROOT\/etc\/miclash\/backups"/,
	'package upgrade does not remove retired persistent state');

console.log('Removed Draft, History, and Backup surfaces contract passed');
