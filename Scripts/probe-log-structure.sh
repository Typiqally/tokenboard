#!/bin/zsh
set -euo pipefail

# Structure-only diagnostic for the activity-metric parsers. It prints allowlisted record-shape names and
# counts, never prompts, responses, tool content, paths, session IDs, message IDs, or model IDs. Every string it
# prints is a literal from this script (or a digits-only CLI minor version); source-derived identifiers are
# compared inside a private temporary directory that is removed on exit.

if [[ -z "${TOKENBOARD_CLAUDE_PROBE_ROOT:-}" && -z "${TOKENBOARD_CODEX_PROBE_ROOT:-}" ]]; then
    print -u2 "set TOKENBOARD_CLAUDE_PROBE_ROOT and/or TOKENBOARD_CODEX_PROBE_ROOT explicitly"
    exit 64
fi

if ! command -v jq >/dev/null 2>&1; then
    print -u2 "probe requires jq; install it yourself before opting in"
    exit 69
fi
if ! zmodload zsh/system 2>/dev/null \
    || ! zmodload -F zsh/stat b:zstat 2>/dev/null; then
    print -u2 "required macOS file-descriptor checks are unavailable"
    exit 69
fi

validate_root() {
    local root=$1
    if [[ "$root" != /* || ! -d "$root" || ! -r "$root" || -L "$root" ]]; then
        print -u2 "probe roots must be readable absolute directories"
        exit 64
    fi
}
[[ -n "${TOKENBOARD_CLAUDE_PROBE_ROOT:-}" ]] && validate_root "$TOKENBOARD_CLAUDE_PROBE_ROOT"
[[ -n "${TOKENBOARD_CODEX_PROBE_ROOT:-}" ]] && validate_root "$TOKENBOARD_CODEX_PROBE_ROOT"

# Bounded diagnostic, not another ingestion engine.
typeset -r maximum_file_count=50000
typeset -r maximum_file_bytes=$((256 * 1024 * 1024))
typeset -r maximum_total_bytes=$((8 * 1024 * 1024 * 1024))

umask 077
probe_root=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/tokenboard-probe.XXXXXX")
typeset opened_fd=-1
typeset -A opened_stat
cleanup() {
    if (( opened_fd >= 0 )); then
        exec {opened_fd}<&- 2>/dev/null || true
    fi
    /bin/rm -rf -- "$probe_root"
}
trap cleanup EXIT

refuse_input() {
    print -u2 "Unsupported probe input; no report was produced"
    exit 65
}

refuse_limits() {
    print -u2 "Probe input exceeds documented resource limits; no report was produced"
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

stream_bytes() {
    local byte_count=$1
    if (( byte_count == 0 )); then
        return 0
    fi
    /usr/bin/head -c "$byte_count"
}

typeset -r shared_definitions='def allow($names): if type == "string" and (. as $value | $names | any(. == $value)) then . else "other" end;
def flag: if . == true then "true" else "false" end;
def bump($key): .counts[$key] += 1;
def bump($key; $amount): .counts[$key] += $amount;
def text_or_empty: if type == "string" then . else "" end;
def minor_version:
  if type == "string" and test("^[0-9]{1,4}\\.[0-9]{1,4}")
  then capture("^(?<version>[0-9]{1,4}\\.[0-9]{1,4})").version
  else "unknown" end;'

typeset -r claude_filter="$shared_definitions"'
def patch_counts:
  reduce (.[]? | select(type == "object") | .lines[]? | select(type == "string")) as $line
    ({added: 0, removed: 0};
     if ($line | startswith("+")) then .added += 1
     elif ($line | startswith("-")) then .removed += 1
     else . end);
def line_count:
  if type == "string" and length > 0
  then (split("\n") | length) - (if endswith("\n") then 1 else 0 end)
  else 0 end;
reduce (inputs | (try fromjson catch null)) as $record (
  {counts: {}, session: null, firstSidechain: false, firstAgentID: false, pending: false,
   lastUsage: null, seenUsage: {}, toolUseIDs: {}, versions: {}};
  . as $state
  | if ($record | type) != "object" then bump("claude.line.malformed_or_non_object")
  else try (
    ($record.isSidechain == true) as $side
    | (if $side then "sidechain" else "main" end) as $chain
    | ($record.type | allow(["user", "assistant", "system", "summary", "file-history-snapshot",
        "queue-operation", "progress", "attachment", "custom-title"])) as $type
    | bump("claude.record." + $type + "." + $chain)
    | ($record.sessionId // $record.session_id) as $session
    | if .session == null and ($session | type) == "string" and ($session | length) > 0 then
        .session = $session
        | .firstSidechain = $side
        | .firstAgentID = (($record.agentId | type) == "string")
      else . end
    | if ($record.version | type) == "string" then .versions[$record.version | minor_version] = true else . end
    | if $side then bump("claude.sidechain_line.agent_id=" + ((($record.agentId | type) == "string") | flag)) else . end
    | if $type == "user" then
        ($record.message.content) as $content
        | (if $record.isCompactSummary == true then "compact_summary"
           elif $record.isMeta == true then "meta"
           elif ($content | type) == "string" then "string"
           elif ($content | type) == "array" then
             ([$content[] | (if type == "object" then .type else null end)
               | allow(["text", "image", "tool_result", "document"])] | unique | join("+")
              | if . == "" then "empty_array" else . end)
           else "none" end) as $kind
        | bump("claude.user." + $kind + "." + $chain)
        | (($side | not) and ($kind != "compact_summary") and ($kind != "meta") and ($kind != "none")
            and ($kind != "empty_array") and (($kind | contains("tool_result")) | not)) as $prompt
        | if $prompt then
            bump("claude.task.prompt")
            | (if .pending then bump("claude.task.collapsed_into_next") else . end)
            | .pending = true
          else . end
        | if ($record | has("toolUseResult")) then
            ($record.toolUseResult) as $result
            | if ($result | type) == "object" then
                ($result.structuredPatch) as $patch
                | (if ($patch | type) == "array"
                   then (if ($patch | length) > 0 then "nonempty" else "empty" end)
                   else "absent" end) as $patchShape
                | (($result.type // "none") | allow(["create", "update", "text", "image", "none"])) as $resultType
                | bump("claude.tool_result.object.patch=" + $patchShape + ".type=" + $resultType
                    + ".content=" + ((($result.content | type) == "string") | flag) + "." + $chain)
                | if $patchShape == "nonempty" then
                    ($patch | patch_counts) as $lines
                    | bump("claude.lines.added"; $lines.added)
                    | bump("claude.lines.removed"; $lines.removed)
                  elif $resultType == "create" then bump("claude.lines.created"; ($result.content | line_count))
                  else . end
              else bump("claude.tool_result." + ($result | type) + "." + $chain) end
          else . end
      elif $type == "assistant" then
        ($record.message) as $message
        | (($message.usage | type) == "object") as $hasUsage
        | (if $message.model == "<synthetic>" then "synthetic"
           elif ($message.model | type) == "string" then "real"
           else "none" end) as $modelKind
        | bump("claude.assistant.model=" + $modelKind + ".usage=" + ($hasUsage | flag) + "." + $chain)
        | ([$message.content[]? | select(type == "object")]) as $blocks
        | bump("claude.assistant.blocks_per_line="
            + (if ($blocks | length) >= 3 then "3+" else ($blocks | length | tostring) end))
        | reduce $blocks[] as $block (.;
            bump("claude.assistant.block." + ($block.type | allow(["text", "thinking", "redacted_thinking",
              "tool_use", "server_tool_use", "web_search_tool_result", "web_fetch_tool_result",
              "code_execution_tool_result", "mcp_tool_use", "mcp_tool_result", "image"]))))
        | bump("claude.assistant.stop_reason=" + (if $message.stop_reason == null then "null"
            else ($message.stop_reason | allow(["end_turn", "tool_use", "max_tokens", "stop_sequence",
              "pause_turn", "refusal", "model_context_window_exceeded"])) end))
        | (($record.requestId | text_or_empty) + ":" + ($message.id | text_or_empty)) as $usageKey
        | (if ($hasUsage | not) then "no_usage"
           elif $usageKey == .lastUsage then "consecutive_duplicate"
           elif .seenUsage[$usageKey] then "nonconsecutive_duplicate"
           else "unique" end) as $usageKind
        | bump("claude.usage." + $usageKind + "." + $chain)
        | ([$blocks[] | select(.type == "tool_use")] | length) as $toolUses
        | if $toolUses > 0 then
            bump("claude.tool_use.blocks." + $chain; $toolUses)
            | if $usageKind == "consecutive_duplicate"
              then bump("claude.tool_use.on_duplicate_usage_line"; $toolUses) else . end
          else . end
        | reduce ($blocks[] | select(.type == "tool_use") | .id | select(type == "string")) as $id (.;
            if .toolUseIDs[$id] then bump("claude.tool_use.repeated_id") else .toolUseIDs[$id] = true end)
        | if $hasUsage then .seenUsage[$usageKey] = true | .lastUsage = $usageKey else . end
        | if ($side | not) and $hasUsage and $modelKind == "real" and .pending then
            bump("claude.task.counted")
            | (if $usageKind != "unique" then bump("claude.task.carrier_was_duplicate") else . end)
            | .pending = false
          else . end
      else . end
  ) catch ($state | bump("claude.line.unexpected_shape")) end
)
| if .pending then bump("claude.task.pending_at_end_of_file") else . end
| {counts, session, firstSidechain, firstAgentID, versions: (.versions | keys), usageKeys: (.seenUsage | keys)}'

typeset -r codex_filter="$shared_definitions"'
def change_shapes:
  [(.changes // {}) | if type == "object" then .[] else empty end
   | if type == "object" then
       (keys | map(allow(["add", "delete", "update", "type", "content", "unified_diff", "move_path"]))
        | sort | join("+"))
       + (if (.type | type) == "string" then ".type=" + (.type | allow(["add", "delete", "update"])) else "" end)
     else "non_object" end]
  | unique;
def status_name: (. // "absent") | allow(["completed", "failed", "declined", "in_progress", "absent"]);
reduce (inputs | (try fromjson catch null)) as $record (
  {counts: {}, session: null, version: "unknown", automated: false, pending: false, lastKey: null};
  . as $state
  | if ($record | type) != "object" then bump("codex.line.malformed_or_non_object")
  else try (
    ($record.type | allow(["session_meta", "turn_context", "event_msg", "response_item", "compacted"])) as $type
    | bump("codex.record." + $type)
    | if $type == "session_meta" then
        ($record.payload.source) as $source
        | (if ($source | type) == "string" then
             ($source | ascii_downcase | allow(["cli", "vscode", "exec", "mcp", "unknown"]))
           elif ($source | type) == "object" then
             ((($source | keys | first) // "empty") | ascii_downcase
              | allow(["subagent", "sub_agent", "internal", "custom", "empty"]))
           else "absent" end) as $sourceKind
        | .version = ($record.payload.cli_version | minor_version)
        | .automated = ($sourceKind == "subagent" or $sourceKind == "sub_agent" or $sourceKind == "internal")
        | bump("codex.session_meta.source=" + $sourceKind)
        | ($record.payload.id // $record.payload.session_id) as $session
        | if .session == null and ($session | type) == "string" then .session = $session else . end
      elif $type == "event_msg" then
        ($record.payload.type | allow(["token_count", "task_started", "turn_started", "task_complete",
          "turn_complete", "turn_aborted", "user_message", "agent_message", "agent_reasoning",
          "agent_reasoning_raw_content", "patch_apply_end", "item_completed", "context_compacted",
          "mcp_tool_call_end", "web_search_end", "image_generation_end", "entered_review_mode",
          "exited_review_mode", "thread_rolled_back", "thread_goal_updated", "thread_settings_applied",
          "sub_agent_activity"])) as $event
        | bump("codex.event." + $event + ".v" + .version)
        | if ($event == "task_started" or $event == "turn_started") then
            (if ($record.payload.root_turn_id | type) != "string" then "absent"
             elif $record.payload.root_turn_id == $record.payload.turn_id then "equal"
             else "different" end) as $root
            | bump("codex.task_started.root_turn_id=" + $root)
            | if $root != "different" and (.automated | not) then
                bump("codex.task.start")
                | (if .pending then bump("codex.task.collapsed_into_next") else . end)
                | .pending = true
              else . end
          elif $event == "user_message" then
            if (.automated | not) then
              (if .pending then bump("codex.task.collapsed_into_next") else . end) | .pending = true
            else . end
          elif $event == "token_count" then
            ($record.payload.info) as $info
            | if ($info | type) != "object" or ($info.last_token_usage | type) != "object" then
                bump("codex.token_count.without_usage")
              else
                (if $info.total_token_usage == null then null
                 else [$record.timestamp, $info.total_token_usage.total_tokens] end) as $key
                | if $key != null and $key == .lastKey then bump("codex.token_count.consecutive_duplicate")
                  else
                    .lastKey = $key
                    | bump("codex.token_count.usage")
                    | if .pending then bump("codex.task.counted") | .pending = false else . end
                  end
              end
          elif $event == "patch_apply_end" then
            bump("codex.patch_apply_end.status=" + ($record.payload.status | status_name)
              + ".success=" + ($record.payload.success | flag))
            | reduce ($record.payload | change_shapes[]) as $shape (.;
                bump("codex.patch_apply_end.change=" + $shape))
          elif $event == "item_completed" then
            ($record.payload.item) as $item
            | (($item.type // "absent") | allow(["UserMessage", "AgentMessage", "Reasoning", "WebSearch",
                "ImageGeneration", "CommandExecution", "FunctionCallOutput", "Plan", "EnteredReviewMode",
                "ExitedReviewMode", "FileChange", "McpToolCall", "ContextCompaction", "SubAgentActivity",
                "Extension", "absent"])) as $itemType
            | bump("codex.item_completed." + $itemType)
            | if $itemType == "FileChange" then
                bump("codex.item_completed.FileChange.status=" + ($item.status | status_name))
                | reduce ($item | change_shapes[]) as $shape (.;
                    bump("codex.item_completed.FileChange.change=" + $shape))
              else . end
          else . end
      elif $type == "response_item" then
        ($record.payload.type | allow(["message", "agent_message", "reasoning", "function_call",
          "function_call_output", "custom_tool_call", "custom_tool_call_output", "local_shell_call",
          "web_search_call", "tool_search_call", "tool_search_output", "image_generation_call",
          "configuration_update", "compaction", "context_compaction"])) as $item
        | bump("codex.response_item." + $item)
        | if ($item == "function_call" or $item == "custom_tool_call") then
            bump("codex.tool_call." + $item + ".name=" + ($record.payload.name | allow(["apply_patch", "shell",
              "shell_command", "exec_command", "write_stdin", "update_plan", "view_image", "read_file",
              "list_dir", "grep_files", "spawn_agent", "send_input", "wait", "close_agent", "web_search"]))
              + ".v" + .version)
          else . end
      else . end
  ) catch ($state | bump("codex.line.unexpected_shape")) end
)
| if .pending then bump("codex.task.pending_at_end_of_file") else . end
| {counts, session}'

typeset -a probe_paths probe_providers probe_devices probe_inodes probe_sizes
probe_paths=()
probe_providers=()
probe_devices=()
probe_inodes=()
probe_sizes=()
typeset file_count=0
typeset total_bytes=0

discover_root() {
    local provider=$1
    local root=$2
    local manifest="$probe_root/$provider-paths"
    local path size
    if ! /usr/bin/find "$root" -type f -iname '*.jsonl' -print0 2>/dev/null >"$manifest"; then
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
        probe_paths+=("$path")
        probe_providers+=("$provider")
        probe_devices+=("$opened_stat[device]")
        probe_inodes+=("$opened_stat[inode]")
        probe_sizes+=("$opened_stat[size]")
        close_opened
    done <"$manifest"
}

[[ -n "${TOKENBOARD_CLAUDE_PROBE_ROOT:-}" ]] && discover_root claude_code "$TOKENBOARD_CLAUDE_PROBE_ROOT"
[[ -n "${TOKENBOARD_CODEX_PROBE_ROOT:-}" ]] && discover_root codex "$TOKENBOARD_CODEX_PROBE_ROOT"

: >"$probe_root/counts.tsv"
: >"$probe_root/claude-sessions.tsv"
: >"$probe_root/claude-usage-keys.tsv"
: >"$probe_root/codex-sessions.tsv"
typeset index provider location summary="$probe_root/file-summary.json"
typeset claude_files=0 claude_subagent_files=0 codex_files=0 failed_files=0
print -u2 "Probing ${#probe_paths} files; this reads every line and can take a few minutes."
for (( index = 1; index <= ${#probe_paths}; index++ )); do
    open_regular "$probe_paths[$index]"
    if [[ "$opened_stat[device]" != "$probe_devices[$index]" \
        || "$opened_stat[inode]" != "$probe_inodes[$index]" ]]; then
        close_opened
        refuse_input
    fi
    provider=$probe_providers[$index]
    if [[ "$provider" == "claude_code" ]]; then
        claude_files=$((claude_files + 1))
        location=top_level
        if [[ "$probe_paths[$index]" == */subagents/* ]]; then
            location=subagents
            claude_subagent_files=$((claude_subagent_files + 1))
        fi
        if ! stream_bytes "$probe_sizes[$index]" <&$opened_fd \
            | jq -R -n -c "$claude_filter" >"$summary" 2>/dev/null; then
            failed_files=$((failed_files + 1))
            close_opened
            continue
        fi
        jq -r '.counts | to_entries[] | [.key, (.value | tostring)] | @tsv' "$summary" >>"$probe_root/counts.tsv"
        jq -r '.versions[] | ["claude.file.version=" + ., "1"] | @tsv' "$summary" >>"$probe_root/counts.tsv"
        jq -r --arg location "$location" \
            'if .session == null then empty
             else [.session, $location, (.firstSidechain | tostring), (.firstAgentID | tostring)] | @tsv end' \
            "$summary" >>"$probe_root/claude-sessions.tsv"
        jq -r --arg file "$index" '.usageKeys[] | [$file, .] | @tsv' "$summary" >>"$probe_root/claude-usage-keys.tsv"
    else
        codex_files=$((codex_files + 1))
        if ! stream_bytes "$probe_sizes[$index]" <&$opened_fd \
            | jq -R -n -c "$codex_filter" >"$summary" 2>/dev/null; then
            failed_files=$((failed_files + 1))
            close_opened
            continue
        fi
        jq -r '.counts | to_entries[] | [.key, (.value | tostring)] | @tsv' "$summary" >>"$probe_root/counts.tsv"
        jq -r 'if .session == null then empty else [.session] | @tsv end' "$summary" >>"$probe_root/codex-sessions.tsv"
    fi
    close_opened
done

print "Tokenboard log structure probe"
print "Content-safe: allowlisted record shapes and counts only."
print ""
print "Files: $claude_files Claude Code ($claude_subagent_files under subagents/), $codex_files Codex, $failed_files unreadable"
print ""
print "Record shapes:"
/usr/bin/awk -F'\t' '{ sum[$1] += $2 } END { for (key in sum) printf "%12d  %s\n", sum[key], key }' \
    "$probe_root/counts.tsv" | /usr/bin/sort -k2
print ""
print "Cross-file identity:"
/usr/bin/awk -F'\t' '
    { files[$1] += 1; if ($2 == "top_level") top[$1] = 1 }
    $2 == "subagents" { subagent[NR] = $1; if ($3 == "true" && $4 == "true") sidechainAgent += 1 }
    END {
        for (session in files) if (files[session] > 1) shared += 1
        for (row in subagent) if (subagent[row] in top) collide += 1
        printf "%12d  claude.session_ids_shared_by_multiple_files\n", shared
        printf "%12d  claude.subagent_files_sharing_a_top_level_session_id\n", collide
        printf "%12d  claude.subagent_files_starting_with_sidechain_agent_id\n", sidechainAgent
    }' "$probe_root/claude-sessions.tsv"
duplicate_usage=$(( $(/usr/bin/cut -f2- "$probe_root/claude-usage-keys.tsv" | /usr/bin/sort | /usr/bin/uniq -d | /usr/bin/wc -l) ))
printf "%12d  claude.usage_ids_present_in_multiple_files\n" "$duplicate_usage"
duplicate_codex=$(( $(/usr/bin/sort "$probe_root/codex-sessions.tsv" | /usr/bin/uniq -d | /usr/bin/wc -l) ))
printf "%12d  codex.session_ids_shared_by_multiple_files\n" "$duplicate_codex"
