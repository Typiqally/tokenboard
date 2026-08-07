#!/bin/zsh
set -euo pipefail

validate_dependency_path() {
    local dependency=$1
    local component
    local component_index
    typeset -a components

    [[ -n "$dependency" && "$dependency" == /* ]] || return 1
    [[ "$dependency" != *'//'* \
        && "$dependency" != */ \
        && "$dependency" != */. \
        && "$dependency" != */.. ]] || return 1
    components=("${(@s:/:)dependency}")
    for (( component_index = 2; component_index <= ${#components}; component_index++ )); do
        component=$components[$component_index]
        [[ -z "$component" || "$component" == "." || "$component" == ".." ]] && return 1
    done
    case "$dependency" in
        /System/Library/*|/usr/lib/*) return 0 ;;
        *) return 1 ;;
    esac
}

validate_linkage_line() {
    local linkage=$1
    local metadata_pattern
    metadata_pattern='^(.+) \(compatibility version [0-9]+(\.[0-9]+)*, current version [0-9]+(\.[0-9]+)*(, weak)?\)$'

    [[ "$linkage" != *$'\n'* && "$linkage" != *$'\r'* ]] || return 1
    [[ "$linkage" =~ $metadata_pattern ]] || return 1
    validate_dependency_path "$match[1]"
}

main() {
if (( $# != 1 )); then
    print -u2 "usage: Scripts/verify-entitlements.sh <Tokenboard.app>"
    exit 64
fi

app_path=$1
if [[ ! -d "$app_path" || "${app_path:e}" != "app" ]]; then
    print -u2 "usage: Scripts/verify-entitlements.sh <Tokenboard.app>"
    exit 64
fi
app_path=${app_path:A}
contents_path="$app_path/Contents"
info_plist="$contents_path/Info.plist"
executable="$contents_path/MacOS/TokenboardApp"

typeset symlink_path
if ! symlink_path=$(/usr/bin/find "$contents_path" -type l -print -quit 2>/dev/null); then
    print -u2 "Unable to inspect app bundle layout"
    exit 65
fi
if [[ -n "$symlink_path" ]]; then
    print -u2 "Symlink found in app bundle"
    exit 65
fi

if [[ ! -f "$info_plist" || ! -f "$executable" || ! -x "$executable" ]]; then
    print -u2 "Tokenboard bundle layout is invalid"
    exit 65
fi

entitlements_file=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/tokenboard-entitlements.XXXXXX")
codesign_diagnostics=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/tokenboard-codesign.XXXXXX")
signature_details=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/tokenboard-signature.XXXXXX")
cleanup() {
    /bin/rm -f -- "$entitlements_file" "$codesign_diagnostics" "$signature_details"
}
trap cleanup EXIT

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
if ! /usr/bin/codesign -d --entitlements :- "$app_path" \
    >"$entitlements_file" 2>"$codesign_diagnostics"; then
    print -u2 "Unable to read signed entitlements"
    exit 66
fi
if ! /usr/bin/plutil -lint "$entitlements_file" >/dev/null; then
    print -u2 "Signed entitlements are not a property list"
    exit 66
fi

entitlement_count=$(/usr/bin/xmllint --xpath 'count(/plist/dict/key)' "$entitlements_file")
if [[ "$entitlement_count" != "3" ]]; then
    print -u2 "Signed entitlement key set is not exact"
    exit 67
fi

expected_entitlements=(
    com.apple.security.app-sandbox
    com.apple.security.files.user-selected.read-only
    com.apple.security.files.bookmarks.app-scope
)
for entitlement in "${expected_entitlements[@]}"; do
    match_count=$(/usr/bin/xmllint \
        --xpath "count(/plist/dict/key[.='$entitlement'])" \
        "$entitlements_file")
    value_type=$(/usr/bin/xmllint \
        --xpath "name(/plist/dict/key[.='$entitlement']/following-sibling::*[1])" \
        "$entitlements_file")
    if [[ "$match_count" != "1" || "$value_type" != "true" ]]; then
        print -u2 "Required entitlement is not enabled"
        exit 67
    fi
done

if [[ $(/usr/bin/plutil -extract CFBundleExecutable raw "$info_plist") != "TokenboardApp" \
    || $(/usr/bin/plutil -extract CFBundleIdentifier raw "$info_plist") != "com.tokenboard.Tokenboard" \
    || $(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$info_plist") != "14.0" \
    || $(/usr/bin/plutil -extract LSUIElement raw "$info_plist") != "true" ]]; then
    print -u2 "Tokenboard Info.plist identity or runtime policy is invalid"
    exit 68
fi

if ! /usr/bin/codesign -d --verbose=4 "$app_path" \
    >/dev/null 2>"$signature_details"; then
    print -u2 "Unable to read code-signature identity"
    exit 69
fi
if ! /usr/bin/grep -Fxq "Identifier=com.tokenboard.Tokenboard" "$signature_details"; then
    print -u2 "Signed bundle identifier is invalid"
    exit 69
fi

typeset -a executable_files mach_o_files
while IFS= read -r -d '' candidate; do
    executable_files+=("$candidate")
done < <(/usr/bin/find "$contents_path" -type f -perm -111 -print0)
while IFS= read -r -d '' candidate; do
    if /usr/bin/file -b "$candidate" | /usr/bin/grep -Eq '^Mach-O'; then
        mach_o_files+=("$candidate")
    fi
done < <(/usr/bin/find "$contents_path" -type f -print0)

if (( ${#executable_files} != 1 )) \
    || [[ "${executable_files[1]}" != "$executable" ]] \
    || (( ${#mach_o_files} != 1 )) \
    || [[ "${mach_o_files[1]}" != "$executable" ]]; then
    print -u2 "Unexpected helper or executable in app bundle"
    exit 70
fi

binary_minimum=$(/usr/bin/otool -l "$executable" | /usr/bin/awk '
    $1 == "cmd" && $2 == "LC_BUILD_VERSION" { in_build = 1; next }
    in_build && $1 == "minos" { print $2; exit }
')
if [[ "$binary_minimum" != "14.0" ]]; then
    print -u2 "Mach-O minimum macOS version is not 14.0"
    exit 71
fi

typeset linkage_output
typeset -a linkage_lines
if ! linkage_output=$(/usr/bin/otool -L "$executable"); then
    print -u2 "Unable to read runtime dependencies"
    exit 72
fi
linkage_lines=("${(@f)linkage_output}")
if (( ${#linkage_lines} < 1 )) || [[ "$linkage_lines[1]" != "$executable:" ]]; then
    print -u2 "Mach-O dependency header is invalid"
    exit 72
fi
for (( index = 2; index <= ${#linkage_lines}; index++ )); do
    linkage=$linkage_lines[$index]
    linkage=${linkage#"${linkage%%[![:space:]]*}"}
    if ! validate_linkage_line "$linkage"; then
        print -u2 "Malformed, non-system, or non-canonical runtime dependency found"
        exit 72
    fi
done

print "Tokenboard sandbox and single-process audit passed"
}

if [[ "$ZSH_EVAL_CONTEXT" == "toplevel" ]]; then
    main "$@"
fi
