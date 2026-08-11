# Product

## Register

product

## Users

Tokenboard is for macOS developers who use Claude Code or Codex and want a quick, private view of their token usage. They check it at a glance from the menu bar, open the rich popover for an exact total and recent trend, then use History only when they want to inspect the number more deeply.

## Product Purpose

Tokenboard locally scans user-approved Claude Code and Codex history folders, reduces usage to deletion-resistant daily token aggregates, and shows token totals or estimated public API-equivalent value for Today, This Week, This Month, This Year, or All Time. Cached 7D, 30D, and 90D trends explain change and provider share without querying on popover open. USD remains the canonical pricing currency, with optional display conversion to a locally selected currency. Success means the value is fast to read, historically defensible, explicit about unpriced usage, and effectively idle between local filesystem events.

## Brand Personality

Simple, clean, mean. Quietly confident and direct, with precise language and no decorative product theater.

## Anti-references

- SaaS dashboards, analytics portals, and oversized metric cards
- Electron or web-shaped controls that feel foreign on macOS
- Web-shaped dashboard chrome, floating cards, and controls that ignore macOS behavior
- Opaque telemetry, silent network access, or background activity the user did not request
- Language that presents API-equivalent estimates as an actual bill
- Gamification, ornamental motion, and color used without meaning

## Design Principles

1. Earn the glance: put one compact, trustworthy value in the menu bar and keep detail one click away.
2. Make local behavior inspectable: permission, import, pricing, and recovery actions are explicit and name their effects.
3. Use the platform: prefer standard AppKit and SwiftUI controls, menus, shortcuts, focus behavior, and system appearance.
4. Separate fact from estimate: exact token totals, API-equivalent estimates, and unpriced quantities remain visibly distinct.
5. Stay quiet at rest: refresh from local events and user actions, with no decorative timers, polling, or hidden helpers.
6. Keep scope visible: the exact summary period and recent-trend range are independent controls and must always be clearly labeled.

## Primary Surfaces

- Use the `350 × 430` transient rich popover for the one-click summary, recent trend, provider shares, and primary navigation.
- Use a standard resizable History window for exploration, selectable days, and provider/model/token-type disclosures.
- Keep durable display preferences in General Settings; the popover owns only the summary period and session-only trend range.
- Share one visual grammar across popover and History. The detailed contract lives in [DESIGN.md](DESIGN.md).

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
