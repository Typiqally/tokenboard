# Tokenboard privacy model

Tokenboard is an unsandboxed native app with no privilege entitlements. It performs no remote network requests. Its source layer reads only the Claude Code and Codex folders you explicitly select through macOS. It stores daily and hourly token aggregates, exact model IDs, price history, opaque salted source/checkpoint hashes, skipped-record hashes, the two selected-root bookmarks, optional companion journey preferences, and the Discord Activity toggle and consent version. It does not store prompts, responses, tool content, project metadata, paths below the selected roots, raw session IDs, or per-session totals. Revoking a source stops future reads but intentionally does not erase committed aggregates.

Work Patterns are calculated on-device from those existing hourly aggregates. They do not add event, session, project, or activity-monitoring records. An “active hour” means only that additive usage exists in a local clock-hour bucket; it is not continuous time tracking.

Model IDs that do not meet Tokenboard's strict content-safe identifier rules are represented by an opaque `unknown-…` hash rather than persisted verbatim. Bookmarks necessarily identify the two roots you selected; Tokenboard does not store paths beneath those roots.

## Access and background behavior

- You select each source root with the native macOS folder picker. Tokenboard's source layer limits discovery and reading to those roots and never edits them; because the app is unsandboxed, this boundary is enforced by Tokenboard rather than the App Sandbox.
- Tokenboard never edits or deletes Claude Code or Codex logs.
- Historical import starts only after explicit grants and your Start Historical Import action.
- Filesystem monitoring uses native events plus a periodic, read-only comparison of JSONL paths, sizes, and modification dates. The reconciliation reads no file content. There is no helper process, daemon, or analytics/telemetry channel.
- Launch at Login is off by default and uses the main app only.
- Companion artwork is downloaded only during development and compiled into the app. Theme selection, menu-icon visibility, a random local companion seed, and the last acknowledged milestone (local day plus stage) are stored in `UserDefaults`; stage and progress derive from today's already-stored local aggregates, so no other journey state is persisted. The running app never downloads or uploads artwork or journey state.
- Discord Activity is off by default. On first enable, Tokenboard shows the exact public activity and explains where Discord may display it. If confirmed, Tokenboard publishes only the app name, today's compact token total, today's active-hour bucket count, and one static `View on GitHub` button linking to `https://github.com/Typiqally/tokenboard`. The local RPC protocol also carries Tokenboard's shared public Discord application ID, process ID, and a random per-request nonce to the same-user Discord desktop client's Unix socket. It sends no provider, model, project, path, conversation, cost, timestamps, party data, or secrets. Discord controls how that public activity appears and may process it under Discord's own privacy terms. Disabling the toggle or quitting Tokenboard clears the activity when the client is reachable.

The pricing prompt is copied as plain text. Tokenboard does not launch an agent, browser, or subprocess. If you give that prompt to an external agent, the chosen prompt explicitly identifies its allowed source and whether that agent needs to fetch public pricing; the external agent's permissions and network activity are separate from Tokenboard.

## Retention and deletion

Committed daily and hourly aggregates deliberately survive source-log deletion, a changed source root, and revoked folder access. That is the cache/ledger behavior that lets Tokenboard remember counts after conversations are cleared. Revocation does not erase prior totals.

SQLite schema changes create local pre-migration backups and retain at most the newest two. An explicit database restore preserves a local pre-restore snapshot and retains at most the newest two snapshots. These recovery copies contain the same content-safe ledger classes described above. They live in Tokenboard's Application Support area and are never uploaded.

Pricing catalogs retain effective-dated rate and provenance history so old usage can keep the rate that applied on its day. Unknown or uncovered usage remains unpriced.

Reveal Local Data opens Tokenboard's Application Support directory. Deleting that directory removes the ledger, pricing history, checkpoints, and recovery copies, but it does not remove security-scoped bookmarks or preferences because those live in app `UserDefaults`.

Dismissing the current source warning stores only an opaque SHA-256 signature in app `UserDefaults`. The signature contains no warning message, path, filename, prompt, project, conversation content, or other raw warning component. It survives deletion of Application Support and remains until the warning state changes or resolves, Tokenboard otherwise invalidates it during authoritative reconciliation, or app defaults are reset.

For a safe local-data reset, first revoke both sources in Settings, disable Discord Activity and Launch at Login, then quit Tokenboard, and only then delete the revealed Application Support data. The selected period, menu display mode, historical-import approval preference, companion journey, Discord Activity preference and consent version, and any still-valid dismissed-warning signature remain unless app defaults are separately cleared. To clear those defaults too, after Tokenboard has quit, the explicitly scoped command is `defaults delete com.tokenboard.Tokenboard`. This command is destructive for all Tokenboard preferences and bookmarks; never run an unscoped `defaults delete` command.

The optional `audit-local-usage.sh` contributor tool is a separately invoked, bounded live-source diagnostic. Its temporary directory is private and removed on exit; a non-content-safe model causes a generic refusal before normalized rows are written. A clean diagnostic result is not proof of complete ledger/source equivalence and cannot account for deleted, replaced, or already-ingested histories.

Automated tooling contracts exercise that diagnostic only with generated Claude Code, Codex, and SQLite fixtures. Automated idle-resource verification copies the built app to a private temporary directory, assigns the isolated `com.tokenboard.Tokenboard.ResourceGate` bundle identifier, checks process and socket state, then terminates and removes the temporary copy. Neither gate reads, grants, or modifies the user's real Tokenboard sources or ledger.
