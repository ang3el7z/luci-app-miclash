import fs from 'node:fs';

const root = new URL('../luci-app-miclash/rootfs/www/luci-static/resources/view/miclash/', import.meta.url);
const read = (name) => fs.readFileSync(new URL(name, root), 'utf8');
const files = {
  config: read('config.js'),
  diagnostics: read('diagnostics-panel.js'),
  settings: read('settings-panels.js'),
  devices: read('devices-panel.js'),
  css: read('style.css')
};

const failures = [];
const expect = (condition, message) => { if (!condition) failures.push(message); };

for (const id of [
  'sbox-settings-status', 'sbox-diagnostics-summary', 'sbox-auto-lan', 'sbox-auto-wan',
  'sbox-block-quic', 'sbox-internet-only-miclash', 'sbox-tmpfs', 'sbox-auto-update-config',
  'sbox-auto-major-miclash', 'sbox-enable-hwid', 'sbox-hwid-user-agent',
  'sbox-hwid-device-os', 'sbox-management-settings', 'sbox-management-devices',
  'sbox-settings-save'
]) expect(files.config.includes(id), `preserves #${id}`);

for (const token of [
  'sbox-settings-zone-overview', 'sbox-settings-zone-routing', 'sbox-routing-composite',
  'sbox-settings-zone-updates', 'sbox-settings-zone-integrations', 'sbox-settings-zone-devices'
]) expect(files.config.includes(token), `config contains ${token}`);

expect(files.diagnostics.includes('sbox-overview-card'), 'diagnostics renders overview cards');
expect(files.diagnostics.includes('sbox-overview-protection'), 'diagnostics renders protection overview');
expect(files.config.includes('data-action="route-test"'), 'routing overview owns the route test action');
expect(!files.diagnostics.includes("actionButton(_('Details')"), 'redundant details action is removed');
expect(!files.diagnostics.includes("actionButton(_('Route test')"), 'route test is not duplicated in diagnostics');
expect(files.diagnostics.includes("_('Recovery')"), 'protection overview uses compact recovery copy');
expect(files.settings.includes('sbox-integration-card'), 'management panels use integration cards');
expect(files.settings.includes('sbox-protection-integration-card'), 'Memory Guard and Telegram share one integration card');
expect(files.settings.includes('sbox-integration-pane'), 'integration card uses calm internal panes');
expect(files.settings.includes('sbox-notification-tabs'), 'notifications use channel tabs');
expect(files.settings.includes('data-notification-pane'), 'notification tabs own separate panes');
expect(files.devices.includes('sbox-device-count'), 'device panel renders real counts');
expect(files.devices.includes("'tabindex': '0'"), 'device table region is keyboard scrollable');
expect(files.devices.includes('sbox-device-schedule-fields'), 'device modal progressively discloses schedule fields');
expect(!files.devices.includes("policy ? E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-negative', 'data-action': 'delete' }, _('Delete')) : null"),
  'device modal never renders a null placeholder');

for (const token of [
  '.sbox-settings-zone', '.sbox-overview-grid', '.sbox-routing-composite',
  '.sbox-notification-tabs', '.sbox-settings-save-wrap', '.sbox-device-table thead'
]) expect(files.css.includes(token), `CSS contains ${token}`);

expect(/\.sbox-management-table-wrap\s*\{[^}]*max-height:/s.test(files.css), 'device table is height-bounded');
expect(/\.sbox-settings-save-wrap\s*\{[^}]*position:\s*sticky/s.test(files.css), 'save action is sticky');
expect(/\.sbox-settings-save-wrap\s*\{[^}]*justify-self:\s*stretch/s.test(files.css), 'save action spans the settings page');
expect(!files.config.includes('<fieldset class="sbox-settings-subgroup">'), 'traffic scope does not use a cut-in legend');
expect(files.config.indexOf('id="sbox-auto-update-config"') > files.config.indexOf('class="sbox-runtime-switches"'),
  'config auto-update lives in Additional');
expect(files.config.includes('sbox-major-update-policy'), 'major MiClash updates are visually separated from release channels');
expect(files.css.includes('.sbox-protection-integration-card'), 'combined protection/integration card is styled');
expect(/\.sbox-runtime-switches\s*\{[^}]*gap:\s*7px/s.test(files.css),
  'Additional settings rows use one consistent vertical gap');
expect(!files.css.includes('.sbox-runtime-switches .sbox-auto-update-row'),
  'Additional settings no longer special-case auto-update row spacing');
expect(files.css.includes('.sbox-modal-responsive'), 'modal layouts have a shared responsive guard');
expect(/id="miclash-editor"[\s\S]{0,160}loadingHtml\(\{ kind: 'editor', lines: 8 \}\)/.test(files.config),
  'Config keeps eight shimmer rows');
expect(/id="sbox-log-content"[\s\S]{0,180}loadingHtml\(\{ kind: 'editor', lines: 7 \}\)/.test(files.config),
  'Logs keep seven shimmer rows');
expect(/\.sbox-editor\s*>\s*\.sbox-loading-editor[\s\S]{0,180}height:\s*100%/s.test(files.css),
  'Config shimmer fills the complete editor height');
expect(/\.sbox-log-content\s*>\s*\.sbox-loading-editor[\s\S]{0,180}height:\s*100%/s.test(files.css),
  'Logs shimmer fills the complete log surface height');
expect(/\.sbox-overview-components\s+\.sbox-diagnostics-actions\s*\{[^}]*padding-top:\s*12px/s.test(files.css),
  'component facts and diagnostic action have a clear gap');
for (const width of [ '1050px', '760px', '560px' ])
  expect(files.css.includes(`max-width: ${width}`), `responsive breakpoint ${width} exists`);

if (failures.length) {
  console.error(`FAIL ${failures.length} contract(s):`);
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log('PASS settings redesign contracts');
