#!/bin/sh
set -eu

if [ "$#" -lt 1 ]; then
  printf '%s\n' '必须提供平台 PowerShell 入口路径。' >&2
  exit 2
fi

if ! command -v pwsh >/dev/null 2>&1; then
  printf '%s\n' '需要 PowerShell 7（pwsh），但未找到可执行文件。' >&2
  exit 127
fi

entrypoint=$1
shift
exec pwsh -NoLogo -NoProfile -File "$entrypoint" "$@"
