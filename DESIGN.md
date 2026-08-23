# Tokenboard Design

## Product feel

Tokenboard should feel simple, transparent, beautiful, native, and lightweight. The menu-bar value earns attention by being useful at a glance; every deeper surface explains where its number came from without turning the app into an analytics dashboard.

The approved visual direction is the **rich popover**. Its companion History window uses the same typography, spacing, charts, dividers, glyphs, and language at a wider scale. See the durable [surface-family mockup](docs/design/rich-popover-family.svg).

## Surface model

### Menu bar

- Shows one compact value using the display metric chosen in General Settings.
- Shows an activity symbol instead of `0` while the first local records are still being parsed.
- Uses a real `0` only after an import has completed with no usage in the selected summary period.
- Can show an opt-in `18 × 18` template silhouette before the value. It reflects the current companion stage and that day's local variant; loading and failure symbols override it.

### Rich popover

- Native transient `NSPopover`, `350 × 500`; opens without an entrance animation and dismisses when clicking outside or pressing Escape.
- The quiet header menu controls the exact summary period: Today, This Week, This Month, This Year, or All Time.
- The headline and API-equivalent subtitle always use that summary period.
- The segmented `TODAY / 7D / 30D / 90D` control is independent. It controls only the chart, comparison, and provider shares, defaults to 30D on launch, and changes instantly from cached local snapshots. Today uses hourly points; longer ranges use daily points.
- Provider rows open History filtered to that provider and preserve the selected trend range.
- The footer contains direct History and Settings navigation. Pricing remains in Settings.
- The range control spans the full 310-point content column with four equal native segments.
- The 52-point footer keeps its two navigation actions easy to target without reading as a separate toolbar.
- The 16-point top inset and 4-point spacing rhythm keep the header compact while preserving clear content groups.
- The recency label is also the explicit local refresh action. It disables immediately and shows `Refreshing…` with a native activity indicator until the local scan finishes.
- Quit is a quiet power icon beside Refresh in the header, with a tooltip, accessibility label, and `⌘Q` shortcut.
- With a companion enabled, insert a visual-only `310 × 84` scene immediately below the headline and expand the popover to `350 × 596`. The scene contains no title, stage, token count, progress bar, or caption. `None` renders no placeholder and leaves the `350 × 500` layout unchanged.

### Companion settings

- General Settings uses a one-click visual shelf for `None`, Pokémon, Tree, Tower, Old School RuneScape, and Age of Empires II. A checkmark and border identify selection without relying on color alone.
- Show the selected track's larger live scene, stage details outside the artwork, and an off-by-default “Show companion in menu bar” toggle.
- Assets and variant catalogs are built into the executable bundle. There is no file picker, watched asset directory, JSON configuration, or runtime network fetch.
- The daily choice changes on the local calendar day or timezone notification and is deterministic from one local seed. It does not poll.
- Every scene uses downloaded source artwork bundled into the executable: canonical Pokémon sprites over game locations, a licensed tree-growth asset over woodland, architectural photography, equipped Old School RuneScape characters over game locations, and Age of Empires II building imagery. Scenes never fetch at runtime and never use generated approximations.
- Pokémon rotates among bundled starter families. Tree and Tower grow one subject, Old School RuneScape pairs each equipment tier with a suitable location, and Age of Empires II advances real Town Center imagery through the four ages.

### History

- Standard resizable macOS window, initially `760 × 580`, minimum `680 × 520`.
- Opens on the same trend range as the popover and optionally with a provider filter.
- Uses the same header, headline, segmented control, chart, comparison language, dividers, and disclosure typography as the popover.
- Initially summarizes the whole range. Selecting a chart bar scopes the headline and disclosures to that local hour or day; “Show whole range” or Escape clears the selection.
- “Why this number?” explains additive totals and why reasoning output is not double-counted.
- Provider, model, and token-type disclosures start collapsed with summary labels, expand on demand, and remain plain rows separated by dividers—never cards nested inside cards.

## Shared visual grammar

| Element | Popover | History |
| --- | --- | --- |
| Eyebrow | 11 pt semibold uppercase, quiet tracking | Same |
| Primary number | Rounded system face, semibold, tabular digits | Same face at a larger working-window scale |
| Secondary value | 14 pt secondary label | Same |
| Range control | Native segmented picker | Same component |
| Chart | Neutral native bars and subtle dashed grid | Same component with selectable bars and axis labels |
| Separation | System dividers | Same |
| Provider identity | Official local OpenAI and Claude marks in compact rounded squares | Same mark and name |
| Color | Meaning only: range selection, provider identity, positive/negative comparison, warnings | Same |

System appearance, increased contrast, reduced motion, Dynamic Type behavior, keyboard focus, and VoiceOver semantics take precedence over a pixel-perfect screenshot match.

## Number semantics

- Summary period and trend range are intentionally separate. Their labels remain visible so the user never has to infer the scope.
- Only additive usage contributes to totals.
- Input combines uncached and unclassified input.
- Cache combines cache reads and every cache-write duration.
- Output is output tokens. Detailed reasoning output is an informational subset and is never added again.
- Opaque local model identifiers are presented as “Unknown model.”
- API-equivalent value is an estimate from the effective-dated local pricing catalog, never a bill.
- Unpriced tokens stay in the token total and remain visibly distinguishable from priced coverage.

## State behavior

- **Starting:** activity indicator with language about opening local data.
- **First import:** activity indicator and “Importing usage…”; never a misleading zero.
- **Ready with usage:** exact total, estimate, chart, comparison, and provider shares.
- **Ready with zero:** explicit `0 tokens` plus a quiet empty-range explanation.
- **History refresh:** keep a valid cached snapshot visible while replacing it.
- **Failure:** explain that the local summary or trend is unavailable and provide Settings or Retry as appropriate.
- **Milestone:** show one quiet “reached” label on the next popover open, then acknowledge it locally. Reduced Motion removes the crossfade.

## Implementation map

- `RichPopoverController` owns the status item and transient popover.
- `RichUsagePopoverView` composes the compact surface.
- `HistoryWindowController`, `HistoryViewModel`, and `UsageHistoryView` own the on-demand working window.
- `UsageSurfaceComponents` contains the shared range control, chart, provider row, typography, and disclosure row.
- `UsageQueryService.history` produces deterministic local snapshots; `AppModel` refreshes and caches Today, 7D, 30D, and 90D snapshots after ingestion and pricing changes.
- `CompanionJourney` owns milestones, permanent delta accumulation, and deterministic Pokémon starter variants. `CompanionAssetCatalog` maps every visible theme and stage to bundle-relative resources; `CompanionArtwork` composes those local images and menu silhouettes. `SQLiteLedger.lifetimeAdditiveTokenTotal` supplies an additive-only observation without a schema change.

## Guardrails

- Do not add network access, telemetry, accounts, or cloud sync to make a surface easier to populate.
- Do not turn the popover into a settings panel; durable preferences belong in Settings.
- Do not add decorative cards, gradients, animation, or accent colors outside the explicitly selected companion scene without semantic purpose.
- Do not hide scope, pricing coverage, loading, empty, or failure states for visual cleanliness.
- Do not add streaks, rewards, restart/prestige loops, companion uploads, configuration files, or runtime asset downloads.
