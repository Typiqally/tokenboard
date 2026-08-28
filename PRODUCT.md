# Product

## Register

product

## Users

Tokenboard is for macOS developers who use Claude Code or Codex and want a quick, private view of their token usage. They check it at a glance from the menu bar, open the rich popover for an exact total and recent trend, then use History only when they want to inspect the number more deeply.

## Product Purpose

Tokenboard locally scans user-approved Claude Code and Codex history folders, reduces usage to deletion-resistant daily token aggregates, and shows token totals or estimated public API-equivalent value for Today, This Week, This Month, This Year, or All Time. Cached 7D, 30D, and 90D trends explain change and provider share without querying on popover open. USD remains the canonical pricing currency, with optional display conversion to a locally selected currency. Success means the value is fast to read, historically defensible, explicit about unpriced usage, and effectively idle between local filesystem events.

## Brand Personality

Simple, clean, mean. Quietly confident and direct, with precise language and no decorative product theater. Optional companions can add personality, but the default experience remains the undecorated usage tool.

## Anti-references

- SaaS dashboards, analytics portals, and oversized metric cards
- Electron or web-shaped controls that feel foreign on macOS
- Web-shaped dashboard chrome, floating cards, and controls that ignore macOS behavior
- Opaque telemetry, silent network access, or background activity the user did not request
- Language that presents API-equivalent estimates as an actual bill
- Competitive gamification, streak pressure, rewards, ornamental motion, and color used without meaning

## Design Principles

1. Earn the glance: put one compact, trustworthy value in the menu bar and keep detail one click away.
2. Make local behavior inspectable: permission, import, pricing, and recovery actions are explicit and name their effects.
3. Use the platform: prefer standard AppKit and SwiftUI controls, menus, shortcuts, focus behavior, and system appearance.
4. Separate fact from estimate: exact token totals, API-equivalent estimates, and unpriced quantities remain visibly distinct.
5. Stay quiet at rest: refresh from local events and user actions, with no decorative timers, polling, or hidden helpers.
6. Keep scope visible: the exact summary period and recent-trend range are independent controls and must always be clearly labeled.
7. Make delight optional: ambient companion growth is a private visualization of usage, never a score, reward, streak, or prompt to spend more.

## Primary Surfaces

- Use the `350 × 500` transient rich popover for the one-click summary, recent trend, provider shares, and primary navigation. A selected companion expands it to `350 × 596`; `None` remains the default.
- Use a standard resizable History window for exploration, selectable days, and provider/model/token-type disclosures.
- Keep durable display preferences in General Settings; the popover owns only the summary period and session-only trend range.
- Share one visual grammar across popover and History. The detailed contract lives in [DESIGN.md](DESIGN.md).

## Companion Journey

- Offer `None`, Pokémon, Forest, Village, Old School RuneScape, Age of Empires II, and Minecraft as built-in choices. Do not expose file imports, asset folders, configuration files, or runtime downloads.
- Derive stage and progress solely from today's local token total. The journey resets at local midnight; no baseline, accumulated total, or other journey state is stored.
- Share the one daily journey across themes. Hiding with `None` changes nothing underneath — reselecting any theme shows exactly where today's usage stands. There is no restart control.
- Use twelve stages spread linearly at 0, then 90M steps to 900M, and a 1B summit of tokens earned today. Completion stops at stage twelve without prestige loops.
- Pick one deterministic Pokémon starter family per local calendar day; every starter family appears once per cycle before the order repeats. Forest and Village grow one coherent place continuously — more trees and buildings keep arriving and maturing between milestones, laid out deterministically from the local seed — Old School RuneScape upgrades one adventurer through canonical gear tiers and locations, and Age of Empires II grows one West European settlement through its four ages.
- Use authentic source artwork or original generated artwork, baked and bundled at build time, with every stage visually distinct without text. The popover scene carries no text — only a slim progress line along its bottom edge showing progress toward the next stage; journey labels and details remain in Settings.
- Bundle three scenery plates per stage — the same place from a different vantage or on a different day — and rotate them deterministically per local calendar day, independent of the starter-family rotation, so the scene never repeats two days running while every plate still reads unmistakably as its stage.
- Keep the menu-bar silhouette off by default. Loading and failure symbols always take precedence.
- Reveal a newly reached milestone once on the next popover open with a quiet crossfade; respect Reduced Motion.
- Make the selected scene a place that is genuinely living while it is on screen, art-directed per world rather than one idle applied six times. The life belongs inside the scene — a partner breathing and hopping, a gust crossing a canopy and shaking leaves loose, a town's windows switching on and off room by room while smoke leaves its chimneys and traffic runs its street, an adventurer moving only on the game's own tick under the weather of the place they are standing in, an isometric map under travelling cloud shadows and circling birds, and the particle each Minecraft biome actually emits.
- Populate every world with inhabitants who are busy with something that world would actually have them doing: villagers gathering and carrying it home while a herd grazes, townsfolk and a stray working the street by day and a few late walkers after dark, birds landing in crowns and on roofs the scene actually built, deer browsing a wood that has closed over, other players standing around on the tick with Lumbridge's chickens beside them, and the mob each Minecraft biome spawns. Leave the places whose character is emptiness — an ancient city, a fortress corridor, the End — deliberately unpopulated.
- Let the foreground notice what walks past it: the partner stands up for a visitor at its feet, the adventurer turns on the tick, the survivor turns in whole steps, a building does nothing at all.
- Vary the life by stage where the journey genuinely changes place: fireflies only once a forest is old, a desert's blowing sand, a dungeon's torchlight, a snowfield's snow, embers in the Nether, motes in the End.
- Animate only while the popover or the Settings preview is really on screen — a covered, miniaturized, or hidden window animates nothing — and never open a network connection, download, or configuration surface to do it.
- Under Reduced Motion, and whenever a scene is paused, compose a deliberate still instead of freezing a frame: the atmosphere and its inhabitants stay — leaves mid-fall, a cloud shadow part-way across, embers spread through the air, torches lit, people mid-errand — and nothing moves.

## Currency Conversion

### Scope

- Support USD, EUR, JPY, GBP, and CNY initially.
- Keep token pricing and API-equivalent calculations canonically denominated in USD.
- Convert only the final known USD value for display. Do not apply historical daily FX conversion.
- Persist one preferred display currency locally. Default to USD so existing behavior is unchanged.
- Use the latest approved local exchange-rate snapshot until the user approves a replacement. Do not expire rates automatically or fetch them in the app.

### Pricing Candidate

- One atomic pricing candidate contains the historical model-price ledger, model aliases, and one recent FX snapshot.
- The catalog-only agent prompt may use only Tokenboard's repository catalog, including the FX data published there.
- The official-sites agent prompt may research OpenAI and Anthropic model pricing plus official European Central Bank reference rates.
- Each FX snapshot records USD as its base, USD exactly equal to 1, positive decimal units per USD, an effective date, a verification date, and provenance.
- When ECB data is quoted against EUR, derive all USD cross-rates from one same-dated ECB snapshot. Never combine rates from different dates.
- Catalog schema version 2 carries FX data. Version 1 catalogs remain valid and provide USD-only display.
- Applying a candidate updates model pricing and FX data together. Any invalid model rate or FX field rejects the complete candidate and leaves active data unchanged.

### Pricing Tab

- Show a native Display currency picker for USD, EUR, JPY, GBP, and CNY.
- Show an active model-rate summary sorted by provider and model. Each model lists its available USD input, output, and cache prices per million tokens.
- Show the active USD conversion rates and the date they were checked.
- Keep provenance URLs out of the main summary. Show provenance and old-versus-new model and FX values in candidate review before approval.
- Keep the catalog-only and official-sites prompt buttons as direct, independent copy actions.
- If a currency has no approved rate, leave it unavailable and explain that pricing must be updated. Never estimate or silently substitute another rate.

### Storage and Formatting

- Add FX storage through a forward-only SQLite migration. Retain prior approved snapshots for auditability, while display conversion uses the latest approved snapshot.
- Use Decimal for model pricing, FX rates, and conversion. Do not use binary floating point for monetary calculations.
- Format USD, EUR, GBP, and CNY with two fractional digits and JPY with none.
- Preserve the approximation marker for every API-equivalent value in any currency.
- Keep the app network entitlement absent. Agents perform any explicitly requested research and write only the local candidate file for Tokenboard validation and approval.

### Verification

- Test schema version 1 compatibility and version 2 FX validation.
- Test the SQLite migration and preservation of prior snapshots.
- Test Decimal conversion, currency-specific fraction digits, and missing-rate behavior.
- Test both agent prompt source policies, including the ECB restriction for official FX research.
- Test candidate preview, atomic apply, rejection, rollback, and relaunch persistence for model and FX data together.
- Test the Pricing tab summary and menu-bar presentation for every supported currency.

## Accessibility & Inclusion

Use native macOS semantics and keyboard behavior, provide clear VoiceOver labels for status and actions, never encode warning or selection state by color alone, respect increased-contrast and reduced-motion settings, and keep privacy and error copy understandable without technical background.
