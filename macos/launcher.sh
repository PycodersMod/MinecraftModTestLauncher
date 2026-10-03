#!/bin/sh
set -eu
if [ "$(uname -s)" != 'Darwin' ]; then
  printf '%s\n' '此入口仅适用于 macOS。' >&2
  exit 126
fi
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$script_dir/../common/launcher-posix.sh" "$script_dir/launcher.ps1" "$@"
