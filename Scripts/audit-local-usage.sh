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
if [[ "$TOKENBOARD_CLAUDE_AUDIT_ROOT" != /* \
    || "$TOKENBOARD_CODEX_AUDIT_ROOT" != /* \
    || "$TOKENBOARD_LEDGER_AUDIT_PATH" != /* \
    || ! -d "$TOKENBOARD_CLAUDE_AUDIT_ROOT" \
    || ! -r "$TOKENBOARD_CLAUDE_AUDIT_ROOT" \
    || ! -d "$TOKENBOARD_CODEX_AUDIT_ROOT" \
    || ! -r "$TOKENBOARD_CODEX_AUDIT_ROOT" \
    || ! -f "$TOKENBOARD_LEDGER_AUDIT_PATH" \
    || ! -r "$TOKENBOARD_LEDGER_AUDIT_PATH" ]]; then
    print -u2 "audit inputs must be readable absolute roots and a readable ledger file"
    exit 64
fi

umask 077
audit_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/tokenboard-audit.XXXXXX")
cleanup() {
    /bin/rm -rf -- "$audit_root"
}
trap cleanup EXIT

if ! /usr/bin/find "$TOKENBOARD_CLAUDE_AUDIT_ROOT" -type f -name '*.jsonl' -exec jq -c '
    select(.type == "assistant" and (.message.usage | type) == "object")
    | select((.sessionId // .session_id // "") != "")
    | select((.message.id // "") != "" and (.message.model // "") != "")
    | (.message.usage) as $u
    | select([
        ($u.input_tokens // 0),
        ($u.cache_creation_input_tokens // 0),
        ($u.cache_read_input_tokens // 0),
        ($u.output_tokens // 0),
        ($u.cache_creation.ephemeral_5m_input_tokens // 0),
        ($u.cache_creation.ephemeral_1h_input_tokens // 0)
      ] | all(type == "number" and . >= 0 and floor == .))
    | {
        key: [
          (.sessionId // .session_id),
          ((if .requestId == null then "" else (.requestId + ":") end) + .message.id)
        ],
        model: .message.model,
        usage: $u
      }
' {} + >"$audit_root/claude-records.jsonl" 2>"$audit_root/claude-errors"; then
    print -u2 "Claude audit input could not be parsed"
    exit 65
fi

if ! jq -cs '
    sort_by(.key) | unique_by(.key)[]
    | (.usage.cache_creation.ephemeral_5m_input_tokens // 0) as $w5
    | (.usage.cache_creation.ephemeral_1h_input_tokens // 0) as $w1
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
    | select(.quantity > 0)
' "$audit_root/claude-records.jsonl" >"$audit_root/claude.jsonl" 2>"$audit_root/claude-normalize-errors"; then
    print -u2 "Claude audit records could not be normalized"
    exit 65
fi

if ! /usr/bin/find "$TOKENBOARD_CODEX_AUDIT_ROOT" -type f -name '*.jsonl' -exec jq -cs '
    reduce .[] as $record ({session:null,model:null,lastKey:null,rows:[]};
      if $record.type == "session_meta" then
        .session = ($record.payload.id // $record.payload.session_id)
      elif $record.type == "turn_context" then
        .model = $record.payload.model
      elif ($record.type == "event_msg"
            and $record.payload.type == "token_count"
            and $record.payload.info.last_token_usage != null
            and (.session | type) == "string"
            and .session != ""
            and (.model | type) == "string"
            and .model != "") then
        ($record.payload.info.last_token_usage) as $u
        | ($record.payload.info.total_token_usage // null) as $total
        | (if $total == null then null else [($record.timestamp // ""), ($total.total_tokens // 0)] end) as $key
        | if ($key != null and $key == .lastKey) then .
          elif (([
              $u.input_tokens,
              $u.cached_input_tokens,
              $u.output_tokens,
              $u.total_tokens,
              ($u.cache_write_input_tokens // 0),
              ($u.reasoning_output_tokens // 0)
            ] | all(type == "number" and . >= 0 and floor == .))
            and ($total == null or ([
              $total.input_tokens,
              $total.cached_input_tokens,
              $total.output_tokens,
              $total.total_tokens,
              ($total.cache_write_input_tokens // 0),
              ($total.reasoning_output_tokens // 0)
            ] | all(type == "number" and . >= 0 and floor == .)))) then
            (($u.cached_input_tokens // 0) + ($u.cache_write_input_tokens // 0)) as $sub
            | .rows += (
                (if $sub <= ($u.input_tokens // 0) then [
                  {provider:"codex",model:.model,metric:"input_uncached",quantity:(($u.input_tokens // 0) - $sub)},
                  {provider:"codex",model:.model,metric:"input_cache_read",quantity:($u.cached_input_tokens // 0)},
                  {provider:"codex",model:.model,metric:"input_cache_write",quantity:($u.cache_write_input_tokens // 0)}
                ] else [
                  {provider:"codex",model:.model,metric:"input_unclassified",quantity:($u.input_tokens // 0)}
                ] end)
                + [{provider:"codex",model:.model,metric:"output",quantity:($u.output_tokens // 0)}]
              )
            | .lastKey = $key
          else . end
      else . end
    ) | .rows[] | select(.quantity > 0)
' {} \; >"$audit_root/codex.jsonl" 2>"$audit_root/codex-errors"; then
    print -u2 "Codex audit input could not be parsed"
    exit 66
fi

if ! jq -S -s '
    group_by([.provider,.model,.metric])
    | map({
        provider:.[0].provider,
        model:.[0].model,
        metric:.[0].metric,
        quantity:(map(.quantity) | add)
      })
    | sort_by(.provider,.model,.metric)
' "$audit_root/claude.jsonl" "$audit_root/codex.jsonl" \
    >"$audit_root/independent.json" 2>"$audit_root/aggregate-errors"; then
    print -u2 "Independent aggregates could not be calculated"
    exit 67
fi

if ! sqlite3 -readonly -json "$TOKENBOARD_LEDGER_AUDIT_PATH" '
    SELECT provider, observed_model_id AS model, metric, SUM(quantity) AS quantity
    FROM daily_usage
    WHERE aggregation = "additive"
    GROUP BY provider, observed_model_id, metric
    ORDER BY provider, observed_model_id, metric;
' >"$audit_root/tokenboard-raw.json" 2>"$audit_root/sqlite-errors"; then
    print -u2 "Tokenboard ledger could not be read"
    exit 68
fi
if ! jq -S . "$audit_root/tokenboard-raw.json" \
    >"$audit_root/tokenboard.json" 2>"$audit_root/tokenboard-normalize-errors"; then
    print -u2 "Tokenboard aggregates could not be normalized"
    exit 68
fi

if /usr/bin/cmp -s "$audit_root/independent.json" "$audit_root/tokenboard.json"; then
    print "Independent local aggregate matches Tokenboard"
    exit 0
fi

print -u2 "Independent local aggregate differs from Tokenboard"
if ! jq -n \
    --slurpfile independent "$audit_root/independent.json" \
    --slurpfile tokenboard "$audit_root/tokenboard.json" '
      ($independent[0] - $tokenboard[0]) as $independentOnly
      | ($tokenboard[0] - $independent[0]) as $tokenboardOnly
      | {independent_only:$independentOnly,tokenboard_only:$tokenboardOnly}
    ' 2>"$audit_root/difference-errors"; then
    print -u2 "Aggregate differences could not be rendered"
    exit 67
fi
exit 1
