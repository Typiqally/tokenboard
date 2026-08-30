#!/bin/zsh
set -euo pipefail

mode=${1:-development}
if [[ "$mode" != "development" && "$mode" != "release" ]]; then
  print -u2 "usage: Scripts/verify-asset-rights.sh <development|release>"
  exit 64
fi

script_dir=${0:A:h}
repository_root=${script_dir:h}
manifest="$repository_root/Resources/Companions/rights-manifest.json"
companions_root=${manifest:h}

if [[ ! -f "$manifest" ]]; then
  print -u2 "companion rights manifest is missing"
  exit 65
fi
parsed_manifest=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/tokenboard-rights.XXXXXX")
trap '/bin/rm -f -- "$parsed_manifest"' EXIT
/usr/bin/plutil -convert xml1 -o "$parsed_manifest" -- "$manifest"
schema_version=$(/usr/bin/plutil -extract schemaVersion raw -o - -- "$parsed_manifest")
if [[ "$schema_version" != "1" ]]; then
  print -u2 "unsupported companion rights manifest schema: $schema_version"
  exit 65
fi

group_count=$(/usr/bin/plutil -extract assetGroups raw -o - -- "$parsed_manifest")
if (( group_count == 0 )); then
  print -u2 "companion rights manifest has no asset groups"
  exit 65
fi

typeset -A declared_paths
pending_groups=()
for (( index = 0; index < group_count; index++ )); do
  prefix="assetGroups.$index"
  group_id=$(/usr/bin/plutil -extract "$prefix.id" raw -o - -- "$parsed_manifest")
  bundle_path=$(/usr/bin/plutil -extract "$prefix.bundlePath" raw -o - -- "$parsed_manifest")
  rights_status=$(/usr/bin/plutil -extract "$prefix.redistributionStatus" raw -o - -- "$parsed_manifest")
  evidence_count=$(/usr/bin/plutil -extract "$prefix.evidence" raw -o - -- "$parsed_manifest")

  if [[ -z "$group_id" || "$bundle_path" == */* || "$bundle_path" == "." || "$bundle_path" == ".." ]]; then
    print -u2 "invalid companion asset group at index $index"
    exit 65
  fi
  if [[ -n ${declared_paths[$bundle_path]-} ]]; then
    print -u2 "duplicate companion bundle path: $bundle_path"
    exit 65
  fi
  if [[ ! -d "$companions_root/$bundle_path" ]]; then
    print -u2 "declared companion bundle path is missing: $bundle_path"
    exit 65
  fi
  declared_paths[$bundle_path]=$group_id

  case "$rights_status" in
    cleared)
      if (( evidence_count == 0 )); then
        print -u2 "cleared companion group lacks evidence: $group_id"
        exit 65
      fi
      for (( evidence_index = 0; evidence_index < evidence_count; evidence_index++ )); do
        evidence=$(/usr/bin/plutil -extract "$prefix.evidence.$evidence_index" raw -o - -- "$parsed_manifest")
        if [[ "$evidence" == /* || "$evidence" == *".."* || ! -f "$repository_root/$evidence" ]]; then
          print -u2 "invalid or missing clearance evidence for $group_id: $evidence"
          exit 65
        fi
      done
      ;;
    pending)
      pending_groups+=("$group_id")
      ;;
    *)
      print -u2 "invalid redistribution status for $group_id: $rights_status"
      exit 65
      ;;
  esac
done

for theme_directory in "$companions_root"/*(/N); do
  theme_name=${theme_directory:t}
  if [[ -z ${declared_paths[$theme_name]-} ]]; then
    print -u2 "companion directory is absent from rights manifest: $theme_name"
    exit 65
  fi
done

if [[ "$mode" == "release" && ${#pending_groups} -gt 0 ]]; then
  print -u2 "public release blocked: companion rights clearance is pending for ${^pending_groups}"
  exit 78
fi

print "Companion asset rights verified for $mode"
