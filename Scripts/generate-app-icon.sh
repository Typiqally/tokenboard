#!/bin/zsh
set -euo pipefail

if (( $# != 2 )); then
  print -u2 "usage: Scripts/generate-app-icon.sh <1024px-source.png> <output.icns>"
  exit 64
fi

source_image=${1:A}
destination=${2:A}

if [[ ! -f "$source_image" ]]; then
  print -u2 "app icon source does not exist: $source_image"
  exit 66
fi

width=$(/usr/bin/sips -g pixelWidth "$source_image" | /usr/bin/awk '/pixelWidth:/ { print $2 }')
height=$(/usr/bin/sips -g pixelHeight "$source_image" | /usr/bin/awk '/pixelHeight:/ { print $2 }')
if [[ "$width" != "1024" || "$height" != "1024" ]]; then
  print -u2 "app icon source must be exactly 1024 x 1024 pixels"
  exit 65
fi

temporary_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/tokenboard-icon.XXXXXX")
trap '/bin/rm -rf -- "$temporary_root"' EXIT
iconset="$temporary_root/Tokenboard.iconset"
/bin/mkdir -p "$iconset"

for specification in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"
do
  size=${specification%% *}
  filename=${specification#* }
  /usr/bin/sips -z "$size" "$size" "$source_image" \
    --out "$iconset/$filename" >/dev/null
done

/bin/mkdir -p "${destination:h}"
/usr/bin/iconutil -c icns "$iconset" -o "$destination"
