#!/bin/zsh
set -euo pipefail

if [[ -z "${TOKENBOARD_CLAUDE_AUDIT_ROOT:-}" \
    || -z "${TOKENBOARD_CODEX_AUDIT_ROOT:-}" \
    || -z "${TOKENBOARD_LEDGER_AUDIT_PATH:-}" ]]; then
    print -u2 "set TOKENBOARD_CLAUDE_AUDIT_ROOT, TOKENBOARD_CODEX_AUDIT_ROOT, and TOKENBOARD_LEDGER_AUDIT_PATH explicitly"
    exit 64
fi

if ! command -v jq >/dev/null 2>&1; then
    print -u2 "audit requires jq; install it yourself before opting in"
    exit 69
fi
if ! command -v sqlite3 >/dev/null 2>&1; then
    print -u2 "audit requires sqlite3; install it yourself before opting in"
    exit 69
fi
if ! zmodload zsh/system 2>/dev/null \
    || ! zmodload -F zsh/stat b:zstat 2>/dev/null; then
    print -u2 "required macOS file-descriptor checks are unavailable"
    exit 69
fi

if [[ "$TOKENBOARD_CLAUDE_AUDIT_ROOT" != /* \
    || "$TOKENBOARD_CODEX_AUDIT_ROOT" != /* \
    || "$TOKENBOARD_LEDGER_AUDIT_PATH" != /* \
    || ! -d "$TOKENBOARD_CLAUDE_AUDIT_ROOT" \
    || ! -r "$TOKENBOARD_CLAUDE_AUDIT_ROOT" \
    || -L "$TOKENBOARD_CLAUDE_AUDIT_ROOT" \
    || ! -d "$TOKENBOARD_CODEX_AUDIT_ROOT" \
    || ! -r "$TOKENBOARD_CODEX_AUDIT_ROOT" \
    || -L "$TOKENBOARD_CODEX_AUDIT_ROOT" \
    || ! -r "$TOKENBOARD_LEDGER_AUDIT_PATH" ]]; then
    print -u2 "audit inputs must be readable absolute roots and a readable ledger file"
    exit 64
fi

# This is intentionally a bounded diagnostic, not another ingestion engine.
typeset -r maximum_file_count=20000
typeset -r maximum_file_bytes=$((64 * 1024 * 1024))
typeset -r maximum_total_bytes=$((512 * 1024 * 1024))
typeset -r maximum_ledger_bytes=$((1024 * 1024 * 1024))
typeset -r manifest_limit_status=75

umask 077
audit_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/tokenboard-audit.XXXXXX")
typeset opened_fd=-1
typeset ledger_fd=-1
typeset -A opened_stat ledger_stat
cleanup() {
    if (( opened_fd >= 0 )); then
        exec {opened_fd}<&- 2>/dev/null || true
    fi
    if (( ledger_fd >= 0 )); then
        exec {ledger_fd}<&- 2>/dev/null || true
    fi
    /bin/rm -rf -- "$audit_root"
}
trap cleanup EXIT

refuse_input() {
    print -u2 "Unsupported audit input; no comparison was made"
    exit 65
}

refuse_model() {
    print -u2 "Unsupported or unsafe model identifier; no comparison was made"
    exit 65
}

refuse_limits() {
    print -u2 "Audit input exceeds documented resource limits; no comparison was made"
    exit 65
}

close_opened() {
    if (( opened_fd >= 0 )); then
        exec {opened_fd}<&-
        opened_fd=-1
    fi
}

open_regular() {
    local path=$1
    opened_fd=-1
    opened_stat=()
    if ! sysopen -r -o cloexec,nofollow,nonblock -u opened_fd -- "$path" 2>/dev/null; then
        refuse_input
    fi
    if ! zstat -f "$opened_fd" -H opened_stat 2>/dev/null; then
        close_opened
        refuse_input
    fi
    if (( (opened_stat[mode] & 8#170000) != 8#100000 || opened_stat[size] < 0 )); then
        close_opened
        refuse_input
    fi
}

typeset -a audit_paths audit_providers audit_devices audit_inodes audit_sizes audit_mtimes audit_ctimes
audit_paths=()
audit_providers=()
audit_devices=()
audit_inodes=()
audit_sizes=()
audit_mtimes=()
audit_ctimes=()
typeset file_count=0
typeset total_bytes=0

write_bounded_manifest() {
    local maximum_entries=$1
    local path
    local accepted_entries=0
    while IFS= read -r -d '' path; do
        accepted_entries=$((accepted_entries + 1))
        if (( accepted_entries > maximum_entries )); then
            return "$manifest_limit_status"
        fi
        print -rn -- "$path"$'\0'
    done
}

stream_validated_bytes() {
    local byte_count=$1
    if (( byte_count == 0 )); then
        return 0
    fi
    /usr/bin/head -c "$byte_count"
}

discover_root() {
    local provider=$1
    local root=$2
    local manifest=$3
    local path size remaining_entries
    typeset -a discovery_status
    remaining_entries=$((maximum_file_count - file_count))
    set +e
    /usr/bin/find "$root" -iname '*.jsonl' -print0 2>/dev/null \
        | write_bounded_manifest "$remaining_entries" >"$manifest"
    discovery_status=("${pipestatus[@]}")
    set -e
    # The capped consumer is authoritative; find may receive SIGPIPE after it closes.
    if (( discovery_status[2] == manifest_limit_status )); then
        refuse_limits
    fi
    if (( discovery_status[1] != 0 || discovery_status[2] != 0 )); then
        refuse_input
    fi
    while IFS= read -r -d '' path; do
        file_count=$((file_count + 1))
        if (( file_count > maximum_file_count )); then
            refuse_limits
        fi
        open_regular "$path"
        size=$opened_stat[size]
        if (( size > maximum_file_bytes || size > maximum_total_bytes - total_bytes )); then
            close_opened
            refuse_limits
        fi
        total_bytes=$((total_bytes + size))
        audit_paths+=("$path")
        audit_providers+=("$provider")
        audit_devices+=("$opened_stat[device]")
        audit_inodes+=("$opened_stat[inode]")
        audit_sizes+=("$opened_stat[size]")
        audit_mtimes+=("$opened_stat[mtime]")
        audit_ctimes+=("$opened_stat[ctime]")
        close_opened
    done <"$manifest"
}

discover_root claude_code "$TOKENBOARD_CLAUDE_AUDIT_ROOT" "$audit_root/claude-paths"
discover_root codex "$TOKENBOARD_CODEX_AUDIT_ROOT" "$audit_root/codex-paths"

open_regular "$TOKENBOARD_LEDGER_AUDIT_PATH"
if (( opened_stat[size] > maximum_ledger_bytes )); then
    close_opened
    refuse_limits
fi
ledger_fd=$opened_fd
opened_fd=-1
ledger_stat=("${(@kv)opened_stat}")

typeset -r model_validator='def safe_model:
  if type != "string" then false
  elif . == "<synthetic>" then true
  else (utf8bytelength >= 1 and utf8bytelength <= 256
        and test("^[A-Za-z0-9]") and (test("[^A-Za-z0-9._-]") | not))
  end;
all(.[];
  if (.type == "assistant" and .message.usage != null) then (.message.model | safe_model)
  elif (.type == "turn_context" and .payload.model != null) then (.payload.model | safe_model)
  else true
  end)'

typeset -r claude_filter='def maximum_exact_integer: 9007199254740991;
def safe_integer: type == "number" and floor == . and . >= 0 and . <= maximum_exact_integer;
def safe_identifier: type == "string" and utf8bytelength >= 1 and utf8bytelength <= 4096;
def safe_model:
  if type != "string" then false
  elif . == "<synthetic>" then true
  else (utf8bytelength >= 1 and utf8bytelength <= 256
        and test("^[A-Za-z0-9]") and (test("[^A-Za-z0-9._-]") | not))
  end;
def valid_timestamp:
  type == "string"
  and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$")
  and ((try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null) != null);
[
  .[]
  | if type != "object" then error("unsupported")
    elif (.type == "assistant" and .message.usage != null) then
      . as $record
      | (.sessionId // .session_id) as $session
      | .message.usage as $usage
      | ($usage.cache_creation // {}) as $cache
      | if (($record.message | type) == "object"
            and ($usage | type) == "object"
            and ($cache | type) == "object"
            and ($session | safe_identifier)
            and ($record.message.id | safe_identifier)
            and ($record.message.model | safe_model)
            and ($record.requestId == null or ($record.requestId | safe_identifier))
            and ($record.timestamp | valid_timestamp)
            and ($usage.input_tokens // 0 | safe_integer)
            and ($usage.cache_creation_input_tokens // 0 | safe_integer)
            and ($usage.cache_read_input_tokens // 0 | safe_integer)
            and ($usage.output_tokens // 0 | safe_integer)
            and ($cache.ephemeral_5m_input_tokens // 0 | safe_integer)
            and ($cache.ephemeral_1h_input_tokens // 0 | safe_integer)) then
          {
            key:[$session, ((if $record.requestId == null then "" else ($record.requestId + ":") end) + $record.message.id)],
            model:$record.message.model,
            usage:$usage,
            cache:$cache
          }
        else error("unsupported") end
    else empty end
]
| sort_by(.key)
| unique_by(.key)[]
| (.cache.ephemeral_5m_input_tokens // 0) as $w5
| (.cache.ephemeral_1h_input_tokens // 0) as $w1
| if ($w5 > maximum_exact_integer - $w1) then error("overflow") else . end
| [
    {provider:"claude_code",model:.model,metric:"input_uncached",quantity:(.usage.input_tokens // 0)},
    {provider:"claude_code",model:.model,metric:"input_cache_read",quantity:(.usage.cache_read_input_tokens // 0)},
    (if ($w5 + $w1) > 0 then
      {provider:"claude_code",model:.model,metric:"input_cache_write_5m",quantity:$w5},
      {provider:"claude_code",model:.model,metric:"input_cache_write_1h",quantity:$w1}
     else
      {provider:"claude_code",model:.model,metric:"input_cache_write",quantity:(.usage.cache_creation_input_tokens // 0)}
     end),
    {provider:"claude_code",model:.model,metric:"output",quantity:(.usage.output_tokens // 0)}
  ][]
| select(.quantity > 0)'

typeset -r codex_filter='def maximum_exact_integer: 9007199254740991;
def safe_integer: type == "number" and floor == . and . >= 0 and . <= maximum_exact_integer;
def safe_identifier: type == "string" and utf8bytelength >= 1 and utf8bytelength <= 4096;
def safe_model:
  if type != "string" then false
  elif . == "<synthetic>" then true
  else (utf8bytelength >= 1 and utf8bytelength <= 256
        and test("^[A-Za-z0-9]") and (test("[^A-Za-z0-9._-]") | not))
  end;
def valid_timestamp:
  type == "string"
  and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$")
  and ((try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null) != null);
def valid_snapshot:
  type == "object"
  and (.input_tokens | safe_integer)
  and (.cached_input_tokens | safe_integer)
  and (.output_tokens | safe_integer)
  and (.total_tokens | safe_integer)
  and (.cache_write_input_tokens // 0 | safe_integer)
  and (.reasoning_output_tokens // 0 | safe_integer);
reduce .[] as $record ({session:null,model:null,lastKey:null,rows:[]};
  if ($record | type) != "object" then error("unsupported")
  elif $record.type == "session_meta" then
    ($record.payload.id // $record.payload.session_id) as $session
    | if ($session | safe_identifier) then .session = $session else error("unsupported") end
  elif $record.type == "turn_context" then
    if ($record.payload.model | safe_model)
    then .model = $record.payload.model else error("unsupported") end
  elif ($record.type == "event_msg" and $record.payload.type == "token_count") then
    $record.payload.info.last_token_usage as $usage
    | ($record.payload.info.total_token_usage // null) as $total
    | if (.session == null or .model == null
          or ($record.timestamp | valid_timestamp | not)
          or ($usage | valid_snapshot | not)
          or ($total != null and ($total | valid_snapshot | not))) then error("unsupported")
      elif ($usage.input_tokens > maximum_exact_integer - $usage.output_tokens
            or $usage.total_tokens != ($usage.input_tokens + $usage.output_tokens)
            or ($usage.reasoning_output_tokens // 0) > $usage.output_tokens
            or ($usage.cached_input_tokens > maximum_exact_integer - ($usage.cache_write_input_tokens // 0))) then error("unsupported")
      else
        ($usage.cached_input_tokens + ($usage.cache_write_input_tokens // 0)) as $subtotals
        | (if $total == null then null else [$record.timestamp, $total.total_tokens] end) as $key
        | if ($key != null and $key == .lastKey) then .
          else .model as $model
          | .rows += (
              (if $subtotals <= $usage.input_tokens then [
                {provider:"codex",model:$model,metric:"input_uncached",quantity:($usage.input_tokens - $subtotals)},
                {provider:"codex",model:$model,metric:"input_cache_read",quantity:$usage.cached_input_tokens},
                {provider:"codex",model:$model,metric:"input_cache_write",quantity:($usage.cache_write_input_tokens // 0)}
              ] else [
                {provider:"codex",model:$model,metric:"input_unclassified",quantity:$usage.input_tokens}
              ] end)
              + [{provider:"codex",model:$model,metric:"output",quantity:$usage.output_tokens}]
            )
          | .lastKey = $key
          end
      end
  else . end
)
| .rows[]
| select(.quantity > 0)'

: >"$audit_root/live-usage.jsonl"
typeset index provider
for (( index = 1; index <= ${#audit_paths}; index++ )); do
    open_regular "$audit_paths[$index]"
    if [[ "$opened_stat[device]" != "$audit_devices[$index]" \
        || "$opened_stat[inode]" != "$audit_inodes[$index]" \
        || "$opened_stat[size]" != "$audit_sizes[$index]" \
        || "$opened_stat[mtime]" != "$audit_mtimes[$index]" \
        || "$opened_stat[ctime]" != "$audit_ctimes[$index]" ]]; then
        close_opened
        refuse_input
    fi

    if ! stream_validated_bytes "$audit_sizes[$index]" <&$opened_fd \
        | jq -e -s "$model_validator" >/dev/null 2>/dev/null; then
        close_opened
        refuse_model
    fi
    if ! sysseek -u "$opened_fd" 0 2>/dev/null; then
        close_opened
        refuse_input
    fi
    provider=$audit_providers[$index]
    if [[ "$provider" == "claude_code" ]]; then
        if ! stream_validated_bytes "$audit_sizes[$index]" <&$opened_fd \
            | jq -c -s "$claude_filter" \
            >>"$audit_root/live-usage.jsonl" 2>/dev/null; then
            close_opened
            refuse_input
        fi
    else
        if ! stream_validated_bytes "$audit_sizes[$index]" <&$opened_fd \
            | jq -c -s "$codex_filter" \
            >>"$audit_root/live-usage.jsonl" 2>/dev/null; then
            close_opened
            refuse_input
        fi
    fi
    opened_stat=()
    if ! zstat -f "$opened_fd" -H opened_stat 2>/dev/null \
        || [[ "$opened_stat[device]" != "$audit_devices[$index]" \
        || "$opened_stat[inode]" != "$audit_inodes[$index]" \
        || "$opened_stat[size]" != "$audit_sizes[$index]" \
        || "$opened_stat[mtime]" != "$audit_mtimes[$index]" \
        || "$opened_stat[ctime]" != "$audit_ctimes[$index]" ]]; then
        close_opened
        refuse_input
    fi
    close_opened
done

typeset -r aggregate_filter='def maximum_exact_integer: 9007199254740991;
def checked_sum:
  reduce .[] as $quantity (0;
    if ($quantity | type) != "number" or $quantity < 0 or ($quantity | floor) != $quantity
       or $quantity > maximum_exact_integer - . then error("overflow")
    else . + $quantity end);
group_by([.provider,.model,.metric])
| map({
    provider:.[0].provider,
    model:.[0].model,
    metric:.[0].metric,
    quantity:(map(.quantity) | checked_sum)
  })
| sort_by(.provider,.model,.metric)'

if ! jq -S -s "$aggregate_filter" "$audit_root/live-usage.jsonl" \
    >"$audit_root/live-aggregate.json" 2>/dev/null; then
    refuse_input
fi

typeset -r ledger_filter='def maximum_exact_integer: 9007199254740991;
def safe_integer: type == "number" and floor == . and . >= 0 and . <= maximum_exact_integer;
def safe_model:
  if type != "string" then false
  elif . == "<synthetic>" then true
  else (utf8bytelength >= 1 and utf8bytelength <= 256
        and test("^[A-Za-z0-9]") and (test("[^A-Za-z0-9._-]") | not))
  end;
if length == 0 then []
elif length == 1 and (.[0] | type) == "array" then .[0]
else error("unsupported") end
| if all(.[ ];
    (.provider == "claude_code" or .provider == "codex")
    and (.model | safe_model)
    and (.metric | IN("input_uncached","input_cache_read","input_cache_write","input_cache_write_5m","input_cache_write_1h","input_unclassified","output"))
    and (.quantity | safe_integer))
  then sort_by(.provider,.model,.metric)
  else error("unsupported") end'

if ! sqlite3 -readonly -json /dev/fd/0 '
    SELECT provider, observed_model_id AS model, metric, SUM(quantity) AS quantity
    FROM daily_usage
    WHERE aggregation = "additive"
    GROUP BY provider, observed_model_id, metric
    ORDER BY provider, observed_model_id, metric;
' <&$ledger_fd 2>/dev/null \
    | jq -S -s "$ledger_filter" >"$audit_root/ledger-aggregate.json" 2>/dev/null; then
    refuse_input
fi

opened_stat=()
if ! zstat -f "$ledger_fd" -H opened_stat 2>/dev/null \
    || [[ "$opened_stat[device]" != "$ledger_stat[device]" \
    || "$opened_stat[inode]" != "$ledger_stat[inode]" \
    || "$opened_stat[size]" != "$ledger_stat[size]" \
    || "$opened_stat[mtime]" != "$ledger_stat[mtime]" \
    || "$opened_stat[ctime]" != "$ledger_stat[ctime]" ]]; then
    refuse_input
fi

if /usr/bin/cmp -s "$audit_root/live-aggregate.json" "$audit_root/ledger-aggregate.json"; then
    print "No differences found by the bounded live-source diagnostic"
    exit 0
fi

print -u2 "Bounded live-source diagnostic found aggregate differences"
if ! jq -n \
    --slurpfile live "$audit_root/live-aggregate.json" \
    --slurpfile ledger "$audit_root/ledger-aggregate.json" '
      ($live[0] - $ledger[0]) as $liveOnly
      | ($ledger[0] - $live[0]) as $ledgerOnly
      | {live_source_only:$liveOnly,ledger_only:$ledgerOnly}
    ' 2>/dev/null; then
    refuse_input
fi
exit 1
