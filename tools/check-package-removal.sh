#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

# The retryable postrm/release authority is a separate privileged process
# boundary. Its gate executes the generated postrm and the copied helper under
# a private mount namespace with fault injection and retained-Guard proofs.
exec "$repo_root/tools/check-package-release.sh"
