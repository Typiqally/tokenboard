#!/bin/zsh
set -euo pipefail

configuration=${1:-debug}
if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
  print -u2 "usage: Scripts/build-app.sh <debug|release>"
  exit 64
fi

script_dir=${0:A:h}
repository_root=${script_dir:h}
cd "$repository_root"

swift build -c "$configuration" --product TokenboardApp
binary_dir=$(swift build -c "$configuration" --show-bin-path)
destination="$repository_root/.build/$configuration/Tokenboard.app"
if [[ "$destination" != "$repository_root/.build/"* ]]; then
  print -u2 "refusing unexpected destination: $destination"
  exit 65
fi

staging_root=$(mktemp -d "${TMPDIR:-/tmp}/tokenboard-app.XXXXXX")
trap '/bin/rm -rf -- "$staging_root"' EXIT
staging_app="$staging_root/Tokenboard.app"
mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Resources"
ditto "$binary_dir/TokenboardApp" "$staging_app/Contents/MacOS/TokenboardApp"
ditto Resources/Info.plist "$staging_app/Contents/Info.plist"
if [[ -f Resources/tokenboard-pricing.json ]]; then
  ditto Resources/tokenboard-pricing.json "$staging_app/Contents/Resources/tokenboard-pricing.json"
fi

sign_identity=${TOKENBOARD_SIGN_IDENTITY:--}
sign_arguments=(--force --sign "$sign_identity" --entitlements Resources/Tokenboard.entitlements)
if [[ "$sign_identity" != "-" ]]; then
  sign_arguments+=(--options runtime --timestamp)
fi
codesign "${sign_arguments[@]}" "$staging_app"

/bin/rm -rf -- "$destination"
ditto "$staging_app" "$destination"
print "$destination"
