#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repository_root=${script_dir:h}
cd "$repository_root"

TOKENBOARD_RUN_BENCHMARK=1 /usr/bin/time -l swift test --filter ImportBenchmarkTests
