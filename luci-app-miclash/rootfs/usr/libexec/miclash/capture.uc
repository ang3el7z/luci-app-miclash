#!/usr/bin/env ucode

let fs = require('fs');

function reject() {
	exit(125);
};

if (length(ARGV) < 4 || !match(ARGV[0], /^(0|[1-9][0-9]*)$/) ||
    !match(ARGV[1], /^[1-9][0-9]*$/) || !match(ARGV[2], /^[1-9][0-9]*$/))
	reject();

let inherited_fd = +ARGV[0];
let limit = +ARGV[1];
let timeout = +ARGV[2];
if (inherited_fd < 3 || limit < 1 || limit > 8192 ||
    timeout < 1 || timeout > 300000)
	reject();

let capture = fs.open('/proc/self/fd/' + inherited_fd, 'ae', 0o600);
let inherited = fs.fdopen(inherited_fd, 'a');
if (capture == null || inherited == null || inherited.close() != true)
	reject();

let pipe = fs.pipe();
if (type(pipe) != 'array' || length(pipe) != 2)
	reject();
let writer_fd = pipe[1].fileno();

if (fs.stdout.close() != true)
	reject();
let stdout = fs.open('/proc/self/fd/' + writer_fd, 'a');
if (stdout == null || stdout.fileno() != 1)
	reject();
if (fs.stderr.close() != true)
	reject();
let stderr = fs.open('/proc/self/fd/' + writer_fd, 'a');
if (stderr == null || stderr.fileno() != 2 || pipe[1].close() != true)
	reject();

let command = [ ARGV[3], ...slice(ARGV, 4) ];
let code = system(command, timeout);
stdout.flush();
stderr.flush();
stdout.close();
stderr.close();

let output = pipe[0].read(limit + 1);
if (type(output) != 'string' || pipe[0].close() != true ||
    capture.write(output) != length(output) || capture.flush() != null ||
    capture.close() != true)
	reject();

exit(code < 0 ? 255 : code);
