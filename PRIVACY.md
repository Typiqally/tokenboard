# Tokenboard privacy model

Tokenboard has no network entitlement and performs no network requests. It reads only the Claude Code and Codex folders selected through macOS. It stores daily token aggregates, exact model IDs, price history, opaque salted source/checkpoint hashes, skipped-record hashes, and the two security-scoped root bookmarks. It does not store prompts, responses, tool content, project metadata, paths below the granted roots, raw session IDs, or per-session totals. Revoking access stops future reads but intentionally does not erase committed aggregates.

Model IDs that do not meet Tokenboard's strict content-safe identifier rules are represented by an opaque `unknown-…` hash rather than persisted verbatim. Bookmarks necessarily identify the two roots you selected; Tokenboard does not store paths beneath those roots.

## Access and background behavior

- You grant each source root with the native macOS folder picker. The App Sandbox grant is app-scoped and read-only.
- Tokenboard never edits or deletes Claude Code or Codex logs.
- Historical import starts only after explicit grants and your Start Historical Import action.
- Filesystem monitoring is event-driven. There is no periodic polling, helper process, daemon, or analytics/telemetry channel.
- Launch at Login is off by default and uses the main app only.

The pricing prompt is copied as plain text. Tokenboard does not launch an agent, browser, or subprocess. If you give that prompt to an external agent, the chosen prompt explicitly identifies its allowed source and whether that agent needs to fetch public pricing; the external agent's permissions and network activity are separate from Tokenboard.

## Retention and deletion

Committed daily aggregates deliberately survive source-log deletion, a changed source root, and revoked folder access. That is the cache/ledger behavior that lets Tokenboard remember counts after conversations are cleared. Revocation does not erase prior totals.

SQLite schema changes create local pre-migration backups and retain at most the newest two. An explicit database restore preserves a local pre-restore snapshot and retains at most the newest two snapshots. These recovery copies contain the same content-safe ledger classes described above. They live in Tokenboard's Application Support area and are never uploaded.

Pricing catalogs retain effective-dated rate and provenance history so old usage can keep the rate that applied on its day. Unknown or uncovered usage remains unpriced.

Reveal Local Data opens Tokenboard's Application Support directory. Deleting that directory removes the ledger, pricing history, checkpoints, and recovery copies, but it does not remove security-scoped bookmarks or preferences because those live in app `UserDefaults`.

Dismissing the current source warning stores only an opaque SHA-256 signature in app `UserDefaults`. The signature contains no warning message, path, filename, prompt, project, conversation content, or other raw warning component. It survives deletion of Application Support and remains until the warning state changes or resolves, Tokenboard otherwise invalidates it during authoritative reconciliation, or app defaults are reset.

For a safe local-data reset, first revoke both source grants in Settings and disable Launch at Login, then quit Tokenboard, and only then delete the revealed Application Support data. The selected period, menu display mode, historical-import approval preference, and any still-valid dismissed-warning signature remain unless app defaults are separately cleared. To clear those defaults too, after Tokenboard has quit, the explicitly scoped command is `defaults delete com.tokenboard.Tokenboard`. This command is destructive for all Tokenboard preferences and bookmarks; never run an unscoped `defaults delete` command.

The optional `audit-local-usage.sh` contributor tool is a separately invoked, bounded live-source diagnostic. Its temporary directory is private and removed on exit; a non-content-safe model causes a generic refusal before normalized rows are written. A clean diagnostic result is not proof of complete ledger/source equivalence and cannot account for deleted, replaced, or already-ingested histories.
