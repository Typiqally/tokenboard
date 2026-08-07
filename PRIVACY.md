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

Use Settings to revoke a source grant or Reveal Local Data. Deleting Tokenboard's revealed local-data directory removes committed history, pricing history, checkpoints, recovery copies, and saved grants; do this only while Tokenboard is not running and only if you intend to reset all history.
