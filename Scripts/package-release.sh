#!/bin/zsh
set -euo pipefail

if (( $# < 1 || $# > 2 )); then
  print -u2 "usage: Scripts/package-release.sh <version> [output-directory]"
  exit 64
fi

version=$1
if ! print -r -- "$version" | /usr/bin/grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  print -u2 "version must use numeric semantic versioning, for example 0.1.0"
  exit 64
fi

script_dir=${0:A:h}
repository_root=${script_dir:h}
output_directory=${2:-"$repository_root/.build/artifacts"}
mkdir -p "$output_directory"
output_directory=${output_directory:A}

bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$repository_root/Resources/Info.plist")
if [[ "$bundle_version" != "$version" ]]; then
  print -u2 "release version $version does not match app version $bundle_version"
  exit 65
fi

"$repository_root/Scripts/build-app.sh" release universal
app_path="$repository_root/.build/release/Tokenboard.app"
"$repository_root/Scripts/verify-entitlements.sh" "$app_path"

archive_path="$output_directory/Tokenboard-$version.zip"
checksum_path="$archive_path.sha256"
if [[ -e "$archive_path" || -e "$checksum_path" ]]; then
  print -u2 "refusing to overwrite an existing release artifact for $version"
  exit 73
fi
temporary_archive=$(/usr/bin/mktemp "$output_directory/.tokenboard-release.XXXXXX")
temporary_checksum=$(/usr/bin/mktemp "$output_directory/.tokenboard-checksum.XXXXXX")
trap '/bin/rm -f -- "$temporary_archive" "$temporary_checksum"' EXIT

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$temporary_archive"
/bin/ln -- "$temporary_archive" "$archive_path"
/bin/rm -f -- "$temporary_archive"
archive_hash=$(/usr/bin/shasum -a 256 "$archive_path" | /usr/bin/awk '{print $1}')
print -r -- "$archive_hash  ${archive_path:t}" > "$temporary_checksum"
/bin/ln -- "$temporary_checksum" "$checksum_path"
/bin/rm -f -- "$temporary_checksum"
trap - EXIT

/bin/cat "$checksum_path"
