#!/bin/sh
set -eu
if ! command -v pwsh >/dev/null 2>&1; then
  printf '%s\n' '需要 PowerShell 7（pwsh），但未找到可执行文件。' >&2
  exit 127
fi
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec pwsh -NoLogo -NoProfile -File "$script_dir/launcher.ps1" "$@"
