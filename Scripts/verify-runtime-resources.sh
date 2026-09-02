#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
  print -u2 "usage: Scripts/verify-runtime-resources.sh <Tokenboard.app>"
  exit 64
fi

app_path=${1:A}
if [[ ! -d "$app_path" || "${app_path:e}" != "app" ]]; then
  print -u2 "usage: Scripts/verify-runtime-resources.sh <Tokenboard.app>"
  exit 64
fi

sample_seconds=${TOKENBOARD_RESOURCE_SAMPLE_SECONDS:-15}
maximum_average_cpu=${TOKENBOARD_RESOURCE_MAX_AVERAGE_CPU:-1.0}
maximum_sample_cpu=${TOKENBOARD_RESOURCE_MAX_SAMPLE_CPU:-5.0}
maximum_rss_kib=${TOKENBOARD_RESOURCE_MAX_RSS_KIB:-262144}
maximum_rss_growth_kib=${TOKENBOARD_RESOURCE_MAX_RSS_GROWTH_KIB:-32768}
maximum_file_descriptors=${TOKENBOARD_RESOURCE_MAX_FILE_DESCRIPTORS:-128}
maximum_threads=${TOKENBOARD_RESOURCE_MAX_THREADS:-64}
if (( sample_seconds < 5 || sample_seconds > 300 )); then
  print -u2 "resource sample duration must be between 5 and 300 seconds"
  exit 64
fi

script_dir=${0:A:h}
repository_root=${script_dir:h}
probe_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/tokenboard-resource-gate.XXXXXX")
probe_app="$probe_root/Tokenboard.app"
probe_executable="$probe_app/Contents/MacOS/TokenboardApp"
probe_home="$probe_root/home"
real_application_support="$HOME/Library/Application Support"
sample_file="$probe_root/samples.tsv"
probe_identifier=com.tokenboard.Tokenboard.ResourceGate
probe_pid=-1

cleanup() {
  if (( probe_pid > 0 )) && /bin/kill -0 "$probe_pid" 2>/dev/null; then
    /bin/kill -TERM "$probe_pid" 2>/dev/null || true
    /bin/sleep 1
    /bin/kill -KILL "$probe_pid" 2>/dev/null || true
  fi
  /bin/rm -rf -- "$probe_root"
}
trap cleanup EXIT

/usr/bin/ditto "$app_path" "$probe_app"
/bin/mkdir -p "$probe_home"
probe_home=${probe_home:A}
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $probe_identifier" \
  "$probe_app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$probe_app" >/dev/null

# A private Core Foundation home isolates Application Support and preferences;
# command-line defaults additionally prevent stale bookmarks from turning an
# idle-resource probe into an import benchmark over real source folders.
CFFIXED_USER_HOME="$probe_home" HOME="$probe_home" "$probe_executable" \
  -sourceBookmark.claude_code "" \
  -sourceBookmark.codex "" \
  -historicalImportApproved NO \
  -selectedCompanionTheme none \
  -showCompanionInMenuBar NO \
  -discordPresenceEnabled NO \
  >"$probe_root/stdout" 2>"$probe_root/stderr" &
probe_pid=$!
/bin/sleep 5
if ! /bin/kill -0 "$probe_pid" 2>/dev/null; then
  /bin/cat "$probe_root/stderr" >&2
  print -u2 "isolated Tokenboard process exited during warmup"
  exit 1
fi

open_file_names=$(/usr/sbin/lsof -Fn -p "$probe_pid" 2>/dev/null \
  | /usr/bin/sed -n 's/^n//p')
if print -r -- "$open_file_names" \
    | /usr/bin/grep -Fqx -- "$real_application_support/ledger.sqlite"; then
  print -u2 "isolated Tokenboard process opened the real user ledger"
  exit 1
fi
if ! print -r -- "$open_file_names" \
    | /usr/bin/grep -Fqx -- "$probe_home/Library/Application Support/ledger.sqlite"; then
  print -u2 "isolated Tokenboard process did not open its private ledger"
  exit 1
fi

: > "$sample_file"
for (( sample = 1; sample <= sample_seconds; sample++ )); do
  if ! /bin/kill -0 "$probe_pid" 2>/dev/null; then
    /bin/cat "$probe_root/stderr" >&2
    print -u2 "isolated Tokenboard process exited during idle sampling"
    exit 1
  fi
  if child_pid=$(/usr/bin/pgrep -P "$probe_pid" 2>/dev/null); then
    print -u2 "unexpected Tokenboard child process: $child_pid"
    exit 1
  fi
  /bin/ps -p "$probe_pid" -o %cpu=,rss= >> "$sample_file"
  /bin/sleep 1
done

if network_sockets=$(/usr/sbin/lsof -nP -a -p "$probe_pid" -i 2>/dev/null) \
    && [[ -n "$network_sockets" ]]; then
  print -u2 "isolated Tokenboard process opened a network socket"
  exit 1
fi
file_descriptor_count=$(/usr/sbin/lsof -nP -p "$probe_pid" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
thread_count=$(/bin/ps -M -p "$probe_pid" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
if (( file_descriptor_count > maximum_file_descriptors )); then
  print -u2 "Tokenboard file descriptor count exceeded $maximum_file_descriptors: $file_descriptor_count"
  exit 1
fi
if (( thread_count > maximum_threads )); then
  print -u2 "Tokenboard thread count exceeded $maximum_threads: $thread_count"
  exit 1
fi

resource_summary=$(/usr/bin/awk \
  -v maximum_average_cpu="$maximum_average_cpu" \
  -v maximum_sample_cpu="$maximum_sample_cpu" \
  -v maximum_rss="$maximum_rss_kib" \
  -v maximum_growth="$maximum_rss_growth_kib" '
  NR == 1 { min_rss = $2; max_rss = $2 }
  {
    cpu_sum += $1
    if ($1 > cpu_max) cpu_max = $1
    if ($2 < min_rss) min_rss = $2
    if ($2 > max_rss) max_rss = $2
  }
  END {
    average_cpu = cpu_sum / NR
    growth = max_rss - min_rss
    printf "average_cpu=%.3f max_cpu=%.3f max_rss_kib=%d rss_growth_kib=%d", average_cpu, cpu_max, max_rss, growth
    if (average_cpu > maximum_average_cpu || cpu_max > maximum_sample_cpu ||
        max_rss > maximum_rss || growth > maximum_growth) exit 1
  }
' "$sample_file") || {
  print -u2 "Tokenboard idle resource budget exceeded: $resource_summary"
  exit 1
}

/bin/kill -TERM "$probe_pid"
for _ in {1..50}; do
  if ! /bin/kill -0 "$probe_pid" 2>/dev/null; then
    break
  fi
  /bin/sleep 0.1
done
if /bin/kill -0 "$probe_pid" 2>/dev/null; then
  print -u2 "isolated Tokenboard process did not terminate promptly"
  exit 1
fi
wait "$probe_pid" 2>/dev/null || true
probe_pid=-1

print "Runtime resource gate passed: $resource_summary fds=$file_descriptor_count threads=$thread_count"
