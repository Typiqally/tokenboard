#!/bin/zsh
set -euo pipefail

configuration=${1:-debug}
architecture=${2:-native}
if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
  print -u2 "usage: Scripts/build-app.sh <debug|release> [native|universal]"
  exit 64
fi
if [[ "$architecture" != "native" && "$architecture" != "universal" ]]; then
  print -u2 "usage: Scripts/build-app.sh <debug|release> [native|universal]"
  exit 64
fi

script_dir=${0:A:h}
repository_root=${script_dir:h}
cd "$repository_root"
"$repository_root/Scripts/verify-asset-rights.sh" development

destination="$repository_root/.build/$configuration/Tokenboard.app"
if [[ "$destination" != "$repository_root/.build/"* ]]; then
  print -u2 "refusing unexpected destination: $destination"
  exit 65
fi

staging_root=$(mktemp -d "${TMPDIR:-/tmp}/tokenboard-app.XXXXXX")
trap '/bin/rm -rf -- "$staging_root"' EXIT
staging_app="$staging_root/Tokenboard.app"
mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Resources"

if [[ "$architecture" == "universal" ]]; then
  binary_paths=()
  for target_architecture in arm64 x86_64; do
    target_triple="$target_architecture-apple-macosx14.0"
    swift build -c "$configuration" --product TokenboardApp --triple "$target_triple"
    binary_dir=$(swift build -c "$configuration" --show-bin-path --triple "$target_triple")
    binary_paths+=("$binary_dir/TokenboardApp")
  done
  /usr/bin/lipo -create "${binary_paths[@]}" -output "$staging_app/Contents/MacOS/TokenboardApp"
else
  swift build -c "$configuration" --product TokenboardApp
  binary_dir=$(swift build -c "$configuration" --show-bin-path)
  ditto "$binary_dir/TokenboardApp" "$staging_app/Contents/MacOS/TokenboardApp"
fi

ditto Resources/Info.plist "$staging_app/Contents/Info.plist"
"$repository_root/Scripts/generate-app-icon.sh" \
  "$repository_root/Resources/AppIcon.png" \
  "$staging_app/Contents/Resources/Tokenboard.icns"
if [[ -f Resources/tokenboard-pricing.json ]]; then
  ditto Resources/tokenboard-pricing.json "$staging_app/Contents/Resources/tokenboard-pricing.json"
fi
companion_source="$repository_root/Resources/Companions"
companion_destination="$staging_app/Contents/Resources/Companions"
companion_manifest="$companion_source/rights-manifest.json"
mkdir -p "$companion_destination"
ditto "$companion_source/README.md" "$companion_destination/README.md"
ditto "$companion_manifest" "$companion_destination/rights-manifest.json"
companion_group_count=$(/usr/bin/plutil -extract assetGroups raw -o - -- "$companion_manifest")
for (( index = 0; index < companion_group_count; index++ )); do
  bundle_path=$(/usr/bin/plutil -extract "assetGroups.$index.bundlePath" raw -o - -- "$companion_manifest")
  ditto "$companion_source/$bundle_path" "$companion_destination/$bundle_path"
done

sign_identity=${TOKENBOARD_SIGN_IDENTITY:--}
sign_arguments=(--force --sign "$sign_identity" --entitlements Resources/Tokenboard.entitlements)
if [[ "$sign_identity" != "-" ]]; then
  sign_arguments+=(--options runtime --timestamp)
fi
codesign "${sign_arguments[@]}" "$staging_app"

/bin/rm -rf -- "$destination"
ditto "$staging_app" "$destination"
print "$destination"
