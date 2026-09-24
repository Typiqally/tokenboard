#!/bin/zsh
set -euo pipefail

if (( $# > 1 )); then
  print -u2 "usage: Scripts/export-discord-assets.sh [new-output-directory]"
  exit 64
fi
script_dir=${0:A:h}
repository_root=${script_dir:h}
destination=${1:-$repository_root/.build/discord-assets}
destination=${destination:A}
cd "$repository_root"
"$repository_root/Scripts/verify-asset-rights.sh" development
swift run TokenboardApp --export-discord-assets "$destination"
