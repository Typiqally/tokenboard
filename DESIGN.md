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
- With a companion enabled, insert a `350 × 84` horizon band immediately below the headline and expand the popover to `350 × 596`. The band bleeds edge to edge between two hairlines with soft inset shading — a window cut through the popover surface, never a bordered card — and its background is bottom-aligned so the wider crop trims sky, not the ground the subjects stand on. A slim 3-point progress line hugs the band's bottom edge over a soft scrim, showing how far the journey is toward the next stage; beyond that line the artwork carries no title, stage, token count, or caption. `None` renders no placeholder and leaves the `350 × 500` layout unchanged.

### Companion settings

- General Settings uses a one-click visual shelf for `None`, Pokémon, Forest, Village, Old School RuneScape, Age of Empires II, and Minecraft. A checkmark and border identify selection without relying on color alone.
- Show the selected track's larger live scene, stage details outside the artwork, and an off-by-default “Show companion in menu bar” toggle.
- Assets and variant catalogs are built into the executable bundle. There is no file picker, watched asset directory, JSON configuration, or runtime network fetch.
- The daily choice changes on the local calendar day or timezone notification and is deterministic from one local seed. It does not poll.
- The shelf's thumbnails are art-directed scenes, not generic icons: each theme shows a fixed, instantly recognizable stage while Pokémon follows the day's starter family. The larger preview below the shelf reproduces the popover scene's composition, flexing to the form's standard content width so the Companion section card never grows wider than its sibling sections, with journey details beside the artwork, never on it.
- Every scene is baked at development time (`Scripts/fetch-companion-assets.sh`, `Scripts/bake-companion-assets.swift`, `Scripts/generate-companion-artwork.swift`) into a `1240 × 336` plate matching the scene aspect, so nothing is cropped, stretched, or fetched at runtime: official Pokémon artwork renders standing on a painted foreground before Let's Go location vistas, original generated pixel-art Forest and Village plates and sprites, equipped Old School RuneScape characters grounded in full-resolution location scapes, Age of Empires II Definitive Edition West European settlement renders with a matched player color across all twelve stages, and Minecraft biome, structure, and dimension screenshots walked by the canonical player and armor-set renders. Scenes never use generated approximations of branded artwork.
- Pokémon rotates among bundled starter families and gathers the family in its final scene. Forest and Village grow continuously: a deterministic per-install layout keeps planting trees and raising buildings as tokens accrue — subjects appear between milestones and mature through sprite levels (saplings become ancient trees; cottages redevelop into high-rises behind the streetfront) — while twelve distinct plates carry the season and time-of-day arc. Old School RuneScape pairs each equipment tier with its canonical location, Age of Empires II grows one West European settlement from a Dark Age camp to an Imperial capital, and Minecraft takes one survivor from a plains spawn through the Nether to the End, upgrading armor as the game's own progression does.
- Every stage bundles three scenery plates — alternate art-directed vantages of the same place for the photographic themes, and "same place, different day" variants (clouds, birds, stars, flowers, light) for the generated pixel themes. A keyed daily rotation, independent of the starter-family pick and stable within a day, chooses the plate; the shelf thumbnails always show the canonical first plate. Derived vantages anchor the crop's bottom edge so the walkable ground line survives every variant.
- Menu-bar silhouettes derive from each theme's transparent subject artwork; Age of Empires II uses drawn settlement glyphs because its scenes are opaque screenshots. Every stage has a readable `18 × 18` template silhouette and no icon is a rectangular photograph.

### Companion motion

Each world is art-directed separately. There is one shared vocabulary — subject motion, particle fields, sweeping shadow bands, breathing light sources, a whole-scene wash, and a population of inhabitants — but no two themes draw from it the same way, and no effect is shared between two themes.

| World | What is alive | Signature |
| --- | --- | --- |
| Pokémon | The partner breathes on an asymmetric rhythm and hops with anticipation, lift, and a landing squash; its ground shadow shrinks as it leaves the ground. A small visitor glides in, lands in the grass beside it and moves on again — and the partner stands up to watch while it is there. Warm pollen drifts up through the frame and something crosses the sky. Victory Road and the Plateau add sparks in the air. | A creature, idling |
| Forest | Two gust fronts on incommensurate periods cross the canopy; a tree bends in proportion to how tall it has grown, and the wood is genuinely still between gusts. The canopy sheds only where the wind actually is. Birds land in the crowns the layout really grew, deer browse the front of a wood that has closed over, seeds drift, a flock leaves the treeline, and the oldest stages fill with fireflies. | Wind, and what it carries |
| Village | Buildings never sway. The windows the artwork itself painted are read out of the sprites and switch room by room on their own schedules; smoke leaves the roofs the scene actually placed. By day the street carries townsfolk and a stray, a bird keeps returning to the tallest roof, a cloud shadow crosses the fields and birds cross the sky; at night the street empties to a few late walkers, stars twinkle, and headlights and tail lights have the road to themselves. | A town's own life |
| Old School RuneScape | The adventurer changes pose only on a 0.6-second game tick — stand, shift weight, turn around, a hard-cut hop — and nothing interpolates between ticks. Other players stand around on the same tick, one whole tile at a time, and the adventurer turns to face whoever walked past. How many depends on where you are: the Grand Exchange is packed, a god war is empty, and Lumbridge still has its chickens. The weather belongs to the location: cloud shadows and birds outdoors, blowing sand in the desert, mist in the swamp, snow at God Wars, crystal light at Prifddinas, torchlight and dust in the tomb. | The tick |
| Age of Empires II | The one theme with no subject layers moves its camera instead: a slow wander on three incommensurate periods that never returns to the same place. Villagers run the loop they have run since 1999 — out to the trees, chop, carry it home — across the near foreground, where a unit can pass in front of everything behind it, and a herd mills about near the town centre. The settlement gets busier as it ages. Cloud shadows lean along the tile diagonal, sunlit dust hangs in the air, and two flocks cross the map at different heights. | A diorama under a moving sky |
| Minecraft | The survivor idles in whole steps, never deforms, and turns to face the mob nearest to it. Every particle is a hard square, and both the particle and the mob belong to the biome: chickens and pollen on the plains, pigs under the leaves, villagers in the village, bats and glow berries in the lush caves, a goat and snow on the peaks, piglins in the Nether wastes, hoglins in the crimson forest, silverfish and torchlight in the stronghold. The ancient city, the fortress corridor, and the End are silent on purpose. | The biome's own particle |

- The whole scene is one `Canvas`: background plate, subjects, window lights, inhabitants, atmosphere, and wash paint in the artwork's own order, so a lit window can never float over the building in front of it and the weather still passes over the people underneath it.
- Inhabitants are never sprites. Each is a body plan — biped, quadruped, flier — drawn from the same rectangles the worlds are drawn in, plus a route: a patrol with rests, a gatherer's errand, a tile-per-tick pace, a wander that lingers at the ends of its beat, or a flight that lands somewhere the layout actually put a perch. Limbs swing in proportion to how fast the body is really travelling, so something that has stopped genuinely stands still. Pixel worlds snap their people to the plate's own art-pixel grid and give them a hard contact shadow instead of a blur.
- A world's foreground notices what walks through it. Populations that ask to be noticed publish their positions as the frame's attention, and each world answers in its own language: the partner stands up, the adventurer turns on the tick, the survivor turns in whole steps, a building does nothing at all.
- Everything is a pure function of theme, stage, the local companion seed, and elapsed time. Two installs grow different towns, scatter different embers, and send their villagers on different errands; one install looks the same on every launch.
- Motion runs only while the surface is really on screen: the popover must be presented and its window unoccluded, un-miniaturized, and not hidden with the app. The settings shelf's thumbnails are always still — they are a picker, not a scene.
- Reduced Motion, and any paused scene, renders a deliberate still composed at that world's own resting moment rather than a frozen frame or an empty plate: leaves mid-fall, a cloud shadow part-way across, embers through the air, torches lit, subjects at rest, and the town's people mid-errand.
- Amplitudes stay at the scale of an `84`-point band: bends of a few degrees, lifts of a few points, washes under `3%`, people eight to thirteen points tall. The heaviest scene costs well under a millisecond per frame at 30 Hz.

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
- `CompanionTheme` defines the persisted themes and their variant catalog; `CompanionJourney` owns the stage thresholds and progress math; `CompanionDailyRotation` makes every keyed daily pick deterministic; `CompanionDailyTokenSource` reads today's local token total out of the usage snapshot; `CompanionRandom` is the single home for the deterministic PRNG and hash shared with the artwork generator; `CompanionPresentation` assembles the stage, scenery, titles, and accessibility strings the surfaces render. `CompanionAssetCatalog` maps every visible theme and stage to bundle-relative baked scenes and subject placements; `CompanionGrowthScene` is the one builder behind the forest and the village, growing seeded slots each theme parameterizes.
- `CompanionSceneMotion` is the pure motion vocabulary — signatures, particle fields, shadow bands, glows, washes, subject motion, and window lighting — with no AppKit or SwiftUI in it. `CompanionSceneActors` is the equally pure population layer: body plans, routes, and the attention a world's subjects answer to. `CompanionSceneResolver` freezes each plan's seeded constants once per composition and advances frames from them. `CompanionSceneDirection` holds the per-world, per-stage art direction as data. `CompanionSceneView` hosts the scene's timeline, `CompanionSceneComposition` composes a scene once per layout, `CompanionSceneCanvas` draws every frame in one `Canvas`, `CompanionStrip` frames the popover band, and `CompanionAssetImageStore` caches the bundled artwork; `CompanionWindowMap` recovers each village sprite's own window grid from its pixels; `CompanionSceneVisibility` gates motion on the host window really being on screen; `CompanionMenuIcon` renders the menu silhouettes.

## Guardrails

- Do not add network access, telemetry, accounts, or cloud sync to make a surface easier to populate.
- Do not turn the popover into a settings panel; durable preferences belong in Settings.
- Do not add decorative cards, gradients, animation, or accent colors outside the explicitly selected companion scene without semantic purpose.
- Do not hide scope, pricing coverage, loading, empty, or failure states for visual cleanliness.
- Do not add streaks, rewards, restart/prestige loops, companion uploads, configuration files, or runtime asset downloads.
