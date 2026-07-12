#!/usr/bin/env ucode

let fs = require('fs');

function reject() { exit(125); };

if (length(ARGV) != 4)
	reject();

let suffixes = [ '.config', '.request', '.status', '.response' ];
let fds = [];
for (let i = 0; i < 4; i++) {
	if (!match(ARGV[i], /^(0|[1-9][0-9]*)$/))
		reject();
	let fd = int(ARGV[i]);
	if (fd == null || fd < 3 || fd > 1024)
		reject();
	let procpath = '/proc/self/fd/' + fd;
	let stat = fs.stat(procpath);
	let target = fs.realpath(procpath);
	if (stat?.type != 'file' || stat.nlink != 1 ||
	    !match(target ?? '', /^\/tmp\/miclash\/curl-[0-9a-f]{16}\.(config|request|status|response)$/) ||
	    substr(target, -length(suffixes[i])) != suffixes[i])
		reject();
	push(fds, fd);
}

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
		'/usr/bin/curl', '--config', '/proc/self/fd/' + fds[0],
		'--output', '/proc/self/fd/' + fds[3]
	], 0);
}
catch (error) { reject(); }

if (type(code) != 'int')
	reject();
if (code < 0)
	exit(124);
if (code == 125)
	exit(126);
if (code >= 254)
	exit(123);
exit(code);
