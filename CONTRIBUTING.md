# Contributing to Tokenboard

Tokenboard's main constraints are part of the product: one native macOS process, local-only operation, explicit read-only source grants, content-free persistence, and low idle resource use. A convenient implementation is not acceptable if it weakens those boundaries.

## Development gate

Use macOS 14 or newer with Apple's Swift 6 toolchain. No package install is required by the build or CI.

```zsh
swift test
Scripts/build-app.sh release
Scripts/verify-entitlements.sh .build/release/Tokenboard.app
git diff --check
```

Develop behavior test-first. Parser fixtures must be synthetic and content-free: no copied prompts, responses, tool data, project names, real paths, repository URLs, branches, or real session IDs. Use obviously synthetic stable identifiers only where parser behavior requires them. Every database migration needs an upgrade test from every prior supported schema and must demonstrate that usage and price totals are preserved unless the migration documents a deliberate semantic correction.

Any new entitlement or privacy-boundary change requires an explicit security review. Do not add network APIs or entitlements, helper executables, daemons, XPC services, web views, analytics, telemetry, or third-party runtime dependencies. Pricing entries must cite official first-party provenance URLs and explicit effective dates; uncertainty stays unpriced.

## Optional benchmark

The benchmark creates exactly 5,100 synthetic JSONL files in a temporary directory and imports them through the real scanner and SQLite ledger twice. Running the script is the opt-in action:

```zsh
Scripts/benchmark-import.sh
```

It reports elapsed time and maximum resident set size with `/usr/bin/time -l`. There is intentionally no hard threshold until multiple representative machines establish a baseline. The test itself skips unless `TOKENBOARD_RUN_BENCHMARK=1`.

## Manual native release acceptance

These checks are interactive and must be recorded for a tagged release; merely building the app does not satisfy them.

1. Open the release app, explicitly select test Claude Code and Codex roots, and start a local import.
2. Leave both roots unchanged for five minutes.
3. In Activity Monitor, verify Sandbox is `Yes`, CPU settles to `0.0%` between filesystem events, no child/helper Tokenboard process exists, the Network view attributes zero sent and received bytes to Tokenboard, and memory does not grow during the idle interval.
4. Record initial-import time, incremental-refresh time, and peak resident memory in the release notes.
5. Copy one synthetic fixture into a temporary granted root, import it, delete only that synthetic copy, refresh, and confirm the committed aggregate remains. Never delete or modify real source logs.

Do not claim this five-minute acceptance check was run unless a person completed it in the native UI.

## Explicit local aggregate audit

`Scripts/audit-local-usage.sh` is an optional, read-only, bounded live-source diagnostic. It requires `jq` and `sqlite3`; the script does not install either. A user must first grant/select the real roots in Tokenboard, use Reveal Local Data to identify the ledger, then quit Tokenboard so the main database is checkpointed before explicitly invoking the audit with all three variables:

```zsh
TOKENBOARD_CLAUDE_AUDIT_ROOT="/absolute/granted/claude/root" \
TOKENBOARD_CODEX_AUDIT_ROOT="/absolute/granted/codex/root" \
TOKENBOARD_LEDGER_AUDIT_PATH="/absolute/revealed/ledger.sqlite" \
Scripts/audit-local-usage.sh
```

The script never mutates source logs or the ledger. It opens each discovered path with `nofollow` and `nonblock`, checks the opened descriptor, and parses only that descriptor. It refuses more than 20,000 files, any file over 64 MiB, more than 512 MiB of source data, or a ledger over 1 GiB. It also refuses unsupported or ambiguous shapes, including non-content-safe model identifiers and timestamps outside its strict canonical UTC subset.

Parser bookkeeping lives in a private temporary directory and is removed on exit. A mismatch prints only content-safe provider/model/metric aggregates. `No differences found by the bounded live-source diagnostic` means only that this deliberately narrower comparison found no difference. It is not proof of Tokenboard equivalence: the script does not reproduce full discovery, source probing, checkpoint, replacement, deletion, or already-ingested-history semantics. Deleted or replaced logs and durable history can legitimately produce a mismatch. Never use the result as authorization to rewrite source logs or the Tokenboard ledger.

Agents and automated contributors must not run this audit against real Claude Code or Codex roots, self-grant sandbox access, open the app for a user, or invent results for the manual acceptance checklist.
