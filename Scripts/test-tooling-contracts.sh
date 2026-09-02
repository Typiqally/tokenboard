#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repository_root=${script_dir:h}
test_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/tokenboard-tooling-tests.XXXXXX")
trap '/bin/rm -rf -- "$test_root"' EXIT

fail() {
  print -u2 "tooling contract failed: $1"
  exit 1
}

expect_status() {
  local expected=$1
  shift
  set +e
  "$@" >"$test_root/stdout" 2>"$test_root/stderr"
  local observed=$?
  set -e
  [[ $observed -eq $expected ]] || fail "expected status $expected, got $observed for $*"
}

"$repository_root/Scripts/verify-asset-rights.sh" development >/dev/null
TOKENBOARD_VERIFY_ASSET_MANIFEST_ONLY=1 \
  "$repository_root/Scripts/fetch-companion-assets.sh" "$test_root/unused-assets" >/dev/null
expect_status 78 "$repository_root/Scripts/verify-asset-rights.sh" release
for pending_group in pokemon old-school-runescape age-of-empires-ii minecraft; do
  /usr/bin/grep -q -- "$pending_group" "$test_root/stderr" \
    || fail "release gate omitted pending group $pending_group"
done
if /usr/bin/grep -E -q -- 'verify-asset-rights\.sh"?[[:space:]]+release' \
  "$repository_root/Scripts/package-release.sh" \
  "$repository_root/.github/workflows/release.yml"; then
  fail "release tooling invokes the asset-rights gate"
fi
if /usr/bin/grep -R -q -- '--clobber' \
  "$repository_root/Scripts/package-release.sh" \
  "$repository_root/.github/workflows/release.yml"; then
  fail "release tooling permits mutable artifact replacement"
fi

runtime_gate="$repository_root/Scripts/verify-runtime-resources.sh"
/usr/bin/grep -q -- 'CFFIXED_USER_HOME=' "$runtime_gate" \
  || fail "runtime resource gate does not isolate Application Support from the real user home"
/usr/bin/grep -q -- 'ResourceGate.$probe_suffix' "$runtime_gate" \
  || fail "runtime resource gate reuses a persistent preferences identity"
/usr/bin/grep -q -- 'defaults delete "$probe_identifier"' "$runtime_gate" \
  || fail "runtime resource gate does not remove its isolated preferences"
for isolated_default in \
  'sourceBookmark.claude_code' \
  'sourceBookmark.codex' \
  'historicalImportApproved' \
  'selectedCompanionTheme'; do
  /usr/bin/grep -q -- "-$isolated_default" "$runtime_gate" \
    || fail "runtime resource gate inherits $isolated_default from its test container"
done

benchmark_gate="$repository_root/Scripts/benchmark-import.sh"
/usr/bin/grep -q -- 'xcrun xctest' "$benchmark_gate" \
  || fail "import benchmark includes SwiftPM orchestration in its timed interval"
if /usr/bin/grep -q -- 'swift test --skip-build' "$benchmark_gate"; then
  fail "import benchmark includes SwiftPM orchestration in its timed interval"
fi

claude_root="$test_root/claude"
codex_root="$test_root/codex"
ledger_path="$test_root/ledger.sqlite"
/bin/mkdir -p "$claude_root" "$codex_root"
/bin/chmod 0700 "$claude_root" "$codex_root"

codex_log="$codex_root/session.jsonl"
print -r -- '{"type":"session_meta","payload":{"id":"synthetic-session"}}' > "$codex_log"
print -r -- '{"type":"turn_context","payload":{"model":"gpt-test"}}' >> "$codex_log"
print -r -- '{"type":"event_msg","timestamp":"2026-08-26T12:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":2,"cache_write_input_tokens":1,"output_tokens":3,"reasoning_output_tokens":0,"total_tokens":13}}}}' >> "$codex_log"
/bin/chmod 0600 "$codex_log"

/usr/bin/sqlite3 "$ledger_path" <<'SQL'
CREATE TABLE daily_usage (
  provider TEXT NOT NULL,
  observed_model_id TEXT NOT NULL,
  metric TEXT NOT NULL,
  aggregation TEXT NOT NULL,
  quantity INTEGER NOT NULL
);
INSERT INTO daily_usage VALUES ('codex', 'gpt-test', 'input_uncached', 'additive', 7);
INSERT INTO daily_usage VALUES ('codex', 'gpt-test', 'input_cache_read', 'additive', 2);
INSERT INTO daily_usage VALUES ('codex', 'gpt-test', 'input_cache_write', 'additive', 1);
INSERT INTO daily_usage VALUES ('codex', 'gpt-test', 'output', 'additive', 3);
SQL
/bin/chmod 0600 "$ledger_path"

source_hash_before=$(/usr/bin/shasum -a 256 "$codex_log" | /usr/bin/awk '{print $1}')
ledger_hash_before=$(/usr/bin/shasum -a 256 "$ledger_path" | /usr/bin/awk '{print $1}')
TOKENBOARD_CLAUDE_AUDIT_ROOT="$claude_root" \
TOKENBOARD_CODEX_AUDIT_ROOT="$codex_root" \
TOKENBOARD_LEDGER_AUDIT_PATH="$ledger_path" \
  "$repository_root/Scripts/audit-local-usage.sh" >"$test_root/audit-clean"
/usr/bin/grep -q 'No differences found' "$test_root/audit-clean" \
  || fail "matching synthetic audit did not report success"
[[ "$source_hash_before" == $(/usr/bin/shasum -a 256 "$codex_log" | /usr/bin/awk '{print $1}') ]] \
  || fail "audit modified a source log"
[[ "$ledger_hash_before" == $(/usr/bin/shasum -a 256 "$ledger_path" | /usr/bin/awk '{print $1}') ]] \
  || fail "audit modified the ledger"

expect_status 64 /usr/bin/env \
  -u TOKENBOARD_CLAUDE_AUDIT_ROOT \
  -u TOKENBOARD_CODEX_AUDIT_ROOT \
  -u TOKENBOARD_LEDGER_AUDIT_PATH \
  "$repository_root/Scripts/audit-local-usage.sh"
/usr/bin/grep -q 'set TOKENBOARD_CLAUDE_AUDIT_ROOT' "$test_root/stderr" \
  || fail "missing-input audit refusal was not actionable"

unsafe_log="$claude_root/unsafe.jsonl"
print -r -- '{"type":"assistant","sessionId":"synthetic-session","requestId":"synthetic-request","timestamp":"2026-08-26T12:00:00Z","message":{"id":"synthetic-message","model":"unsafe/model","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}' > "$unsafe_log"
/bin/chmod 0600 "$unsafe_log"
expect_status 65 /usr/bin/env \
  TOKENBOARD_CLAUDE_AUDIT_ROOT="$claude_root" \
  TOKENBOARD_CODEX_AUDIT_ROOT="$codex_root" \
  TOKENBOARD_LEDGER_AUDIT_PATH="$ledger_path" \
  "$repository_root/Scripts/audit-local-usage.sh"
/usr/bin/grep -q 'Unsupported or unsafe model identifier' "$test_root/stderr" \
  || fail "unsafe-model audit refusal was not generic"
if /usr/bin/grep -R -q 'unsafe/model' "$test_root/stdout" "$test_root/stderr"; then
  fail "unsafe model identifier leaked into audit output"
fi

print "Tooling contracts verified"
