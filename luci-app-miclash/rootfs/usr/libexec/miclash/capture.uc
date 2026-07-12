#!/usr/bin/env ucode

let fs = require('fs');

function reject() {
	exit(125);
};

if (length(ARGV) < 3 || !match(ARGV[0], /^\/tmp\/miclash\/\.capture-[0-9a-f]{16}$/) ||
    !match(ARGV[1], /^(0|[1-9][0-9]*)$/))
	reject();

let output = ARGV[0];
let timeout = +ARGV[1];
let root = fs.lstat('/tmp/miclash');
let target = fs.lstat(output);
if (root?.type != 'directory' || fs.realpath('/tmp/miclash') != '/tmp/miclash' ||
    target?.type != 'file' || target.nlink != 1 || fs.realpath(output) != output)
	reject();

if (fs.stdout.close() != true)
	reject();
let stdout = fs.open(output, 'a');
if (stdout == null || stdout.fileno() != 1)
	reject();
if (fs.stderr.close() != true)
	reject();
let stderr = fs.open(output, 'a');
if (stderr == null || stderr.fileno() != 2)
	reject();

let command = [ ARGV[2], ...slice(ARGV, 3) ];
let code = system(command, timeout);
stdout.flush();
stderr.flush();
exit(code < 0 ? 255 : code);
