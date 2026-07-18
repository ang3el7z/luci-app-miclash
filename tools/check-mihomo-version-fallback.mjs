import assert from 'node:assert/strict';
import fs from 'node:fs';

const daemon = fs.readFileSync(
	'luci-app-miclash/rootfs/usr/share/miclash/daemon.uc', 'utf8');
const test = fs.readFileSync('tests/ucode/test-daemon.uc', 'utf8');

assert.match(daemon, /export function mihomo_version\(/,
	'the bounded Mihomo version resolver must remain directly testable');
assert.match(daemon, /popen\('\/opt\/clash\/bin\/clash -v 2>&1', 'r'\)/,
	'an installed core must have a fixed-path binary version fallback');
assert.match(daemon, /length\(output\) > 512/,
	'the binary version fallback output must be bounded');
assert.match(test, /Mihomo Meta v1\.19\.10 linux arm64/,
	'the daemon unit test must cover the real `clash -v` output shape');
assert.match(test, /API is unavailable.*1\.19\.10/s,
	'the daemon unit test must cover the stopped or unavailable API path');

console.log('Mihomo version fallback contract passed');
