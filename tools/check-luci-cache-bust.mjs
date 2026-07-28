import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';

const makefile = readFileSync('luci-app-miclash/Makefile', 'utf8');
const helper_path = 'luci-app-miclash/rootfs/usr/share/miclash/luci-cache-bust';
assert.ok(existsSync(helper_path), 'LuCI cache-bust helper is missing');
const helper = readFileSync(helper_path, 'utf8');

assert.match(makefile,
	/\$\(INSTALL_BIN\) \.\/rootfs\/usr\/share\/miclash\/luci-cache-bust \$\(1\)\/usr\/share\/miclash\//,
	'Makefile must package the LuCI cache-bust helper');

const postinst = makefile.match(/define Package\/\$\(PKG_NAME\)\/postinst\n([\s\S]*?)\nendef/);
assert.ok(postinst, 'package postinst is missing');
assert.match(postinst[1], /\/usr\/share\/miclash\/luci-cache-bust \|\| exit 1/,
	'postinst must run the LuCI cache-bust helper on the live router');

assert.match(helper, /rm -rf \/tmp\/luci-indexcache \/tmp\/luci-indexcache\.\* \/tmp\/luci-modulecache \/tmp\/luci-modulecache\.\*/,
	'helper must clear LuCI caches from /tmp');
assert.match(helper, /\/var\/luci-indexcache \/var\/luci-indexcache\.\* \/var\/luci-modulecache \/var\/luci-modulecache\.\*/,
	'helper must clear compatible LuCI cache paths from /var');
assert.match(helper, /for package_db in \/lib\/apk\/db\/installed \/usr\/lib\/opkg\/status;/,
	'helper must support both apk and opkg package databases');
assert.match(helper, /\[ -f "\$package_db" \] && \[ ! -L "\$package_db" \] \|\| continue/,
	'helper must not follow a package-database symlink');
assert.match(helper, /touch "\$package_db" \|\| exit 1/,
	'helper must advance the active package database mtime');

console.log('LuCI cache-bust hook contract passed');
