#!/bin/sh

set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
required='/start /menu /start_service /stop_service /reload_service /restart_service /reboot_router'
failed=0

for name in README.md README.ru.md README.zh-cn.md; do
	file="$repo_root/$name"
	for command in $required; do
		if ! grep -Fq "$command" "$file"; then
			echo "$name: missing Telegram command $command" >&2
			failed=1
		fi
	done
	if grep -Eq '(^|[[:space:]`])/(stop|reload|restart|reboot)([[:space:]`]|$)' "$file"; then
		echo "$name: contains a retired short Telegram command" >&2
		failed=1
	fi
done

[ "$failed" -eq 0 ]
echo 'Telegram README commands are consistent'
