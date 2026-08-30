#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repository_root=${script_dir:h}
cd "$repository_root"

maximum_seconds=${TOKENBOARD_BENCHMARK_MAX_SECONDS:-10}
maximum_rss_bytes=${TOKENBOARD_BENCHMARK_MAX_RSS_BYTES:-536870912}
metrics_file=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/tokenboard-benchmark.XXXXXX")
trap '/bin/rm -f -- "$metrics_file"' EXIT

# Build once outside the measurement so the gate measures import behavior,
# not an incidental compiler cache miss.
swift test --filter ImportBenchmarkTests >/dev/null
TOKENBOARD_RUN_BENCHMARK=1 /usr/bin/time -l -o "$metrics_file" \
  swift test --skip-build --filter ImportBenchmarkTests

elapsed_seconds=$(/usr/bin/awk '$2 == "real" { print $1; exit }' "$metrics_file")
maximum_rss=$(/usr/bin/awk '
  $2 == "maximum" && $3 == "resident" && $4 == "set" { print $1; exit }
' "$metrics_file")
if [[ ! "$elapsed_seconds" =~ '^[0-9]+([.][0-9]+)?$' \
    || ! "$maximum_rss" =~ '^[0-9]+$' ]]; then
  print -u2 "unable to read import benchmark resource metrics"
  exit 65
fi
if ! /usr/bin/awk -v observed="$elapsed_seconds" -v maximum="$maximum_seconds" \
  'BEGIN { exit !(observed <= maximum) }'; then
  print -u2 "import benchmark exceeded ${maximum_seconds}s: ${elapsed_seconds}s"
  exit 1
fi
if (( maximum_rss > maximum_rss_bytes )); then
  print -u2 "import benchmark exceeded ${maximum_rss_bytes} bytes RSS: ${maximum_rss}"
  exit 1
fi

print "Import benchmark passed: ${elapsed_seconds}s, ${maximum_rss} bytes maximum RSS"
