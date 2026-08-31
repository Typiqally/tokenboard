# Contributing to Tokenboard

Tokenboard's main constraints are part of the product: one native macOS process, local-only operation, explicit read-only source grants, content-free persistence, and low idle resource use. A convenient implementation is not acceptable if it weakens those boundaries.

## Automated verification gate

Use macOS 14 or newer with Apple's Swift 6 toolchain. No package install is required by the build or CI.

```zsh
swift test
Scripts/benchmark-import.sh
Scripts/verify-asset-rights.sh development
Scripts/test-tooling-contracts.sh
TOKENBOARD_DISCORD_APPLICATION_ID=<public-app-id> Scripts/build-app.sh release universal
Scripts/verify-entitlements.sh .build/release/Tokenboard.app
Scripts/verify-runtime-resources.sh .build/release/Tokenboard.app
git diff --check
```

These commands are the release-quality gate and are owned by automation. The import benchmark enforces a 10-second and 512-MiB ceiling for a synthetic 5,100-file import. The runtime gate launches an isolated copy of the built app under a separate bundle identifier and enforces idle CPU, peak and growth RSS, file-descriptor, thread, child-process, network-socket, and shutdown limits. Thresholds can be tightened through the documented environment variables in each script, but a release must not weaken them to obtain a pass.

Opening the app for a quick visual smoke check is useful but optional. It is never evidence for performance, resource, security, or release acceptance, and the user is not responsible for those gates.

Develop behavior test-first. Parser fixtures must be synthetic and content-free: no copied prompts, responses, tool data, project names, real paths, repository URLs, branches, or real session IDs. Use obviously synthetic stable identifiers only where parser behavior requires them. Every database migration needs an upgrade test from every prior supported schema and must demonstrate that usage and price totals are preserved unless the migration documents a deliberate semantic correction.

Any new entitlement or privacy-boundary change requires an explicit security review. Tokenboard is intentionally unsandboxed for same-user Discord IPC, but must remain signed without privilege entitlements. Do not add remote-network APIs, helper executables, daemons, XPC services, web views, analytics, telemetry, or third-party runtime dependencies. IPC code must accept only same-user Unix sockets, keep payload fields allowlisted, and never add Discord authentication. Pricing entries must cite official first-party provenance URLs and explicit effective dates; uncertainty stays unpriced.

CI and tagged releases read the same public ID from the `TOKENBOARD_DISCORD_APPLICATION_ID` GitHub Actions repository variable. It is public configuration, not a secret. Keep the variable aligned with Tokenboard's shared Discord application and its `tokenboard` Rich Presence asset.

## Public release packaging

`Scripts/package-release.sh <version>` builds the universal app, verifies its entitlements, and publishes a new zip plus SHA-256 sidecar without overwriting an existing artifact. Asset-manifest coverage remains part of development builds and CI. Run `Scripts/verify-asset-rights.sh release` explicitly when a strict rights-clearance check is needed; tagged release packaging does not invoke it automatically.

## Manual native release acceptance

These checks are interactive and must be recorded for a tagged release; merely building the app does not satisfy them.

1. Open the release app, explicitly select test Claude Code and Codex roots, and start a local import.
2. Leave both roots unchanged for five minutes.
3. In Activity Monitor, verify Sandbox is `No`, CPU settles to `0.0%` between filesystem events, no child/helper Tokenboard process exists, the Network view attributes zero sent and received internet bytes to Tokenboard, and memory does not grow during the idle interval.
4. Record initial-import time, incremental-refresh time, and peak resident memory in the release notes.
5. Copy one synthetic fixture into a temporary granted root, import it, delete only that synthetic copy, refresh, and confirm the committed aggregate remains. Never delete or modify real source logs.
6. With synthetic usage only, enable Discord Activity, confirm the alert matches the Settings preview, verify the activity in Discord, then disable it and confirm it clears. Repeat with Discord closed to verify the recoverable status and Retry path.

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

Agents and automated contributors must not run this audit against real Claude Code or Codex roots, self-grant sandbox access, or open the app for a user. Automated verification must use only its checked-in synthetic fixtures and isolated app identity.
