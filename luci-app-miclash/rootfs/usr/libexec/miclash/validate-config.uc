#!/usr/bin/env ucode

let fs = require('fs');

function reject() {
	exit(125);
};

if (length(ARGV) != 1 ||
    !match(ARGV[0], /^\/tmp\/miclash\/candidates\/[A-Za-z0-9][A-Za-z0-9._-]{0,63}\/config\.yaml$/))
	reject();

let candidate = ARGV[0];
let stat = fs.lstat(candidate);
if (stat?.type != 'file' || stat.nlink != 1 || fs.realpath(candidate) != candidate)
	reject();

if (fs.stdout.close() != true)
	reject();
let stdout = fs.open('/dev/null', 'w');
if (stdout == null || stdout.fileno() != 1)
	reject();
if (fs.stderr.close() != true)
	reject();
let stderr = fs.open('/dev/null', 'w');
if (stderr == null || stderr.fileno() != 2)
	reject();

let code;
try {
	code = system([
		'/opt/clash/bin/clash', '-d', '/opt/clash', '-f', candidate, '-t'
	], 30000);
}
catch (error) {
	reject();
}

if (type(code) != 'int')
	reject();
if (code < 0)
	exit(124);
if (code == 125)
	exit(126);
if (code >= 254)
	exit(123);
exit(code);
