# Install Discovery and Pricing Guidance Design

**Date:** 2026-08-10
**Status:** Approved design, pending implementation planning

## Context

Tokenboard is a menu-bar-only macOS app. The Homebrew cask already installs the real `Tokenboard.app` bundle into `/Applications`, and its bundle metadata already lets macOS index it as an application named Tokenboard. Because `LSUIElement` is enabled, Tokenboard does not remain in the Dock after launch. That native behavior is intentional, but the install instructions do not currently tell users how to find and launch the app with Spotlight or what to expect after it opens.

Tokenboard also ships with a local starter pricing catalog. API-equivalent estimates are therefore enabled immediately for covered models, while token totals continue to work independently of pricing. Tokenboard has no network access, so it cannot discover new models, provider price changes, or current exchange rates by itself. Settings already exposes a pricing-update prompt, but the copy does not clearly distinguish the included starter catalog from the occasions when a user should run the prompt.

## Goals

- Preserve a standard `/Applications/Tokenboard.app` installation that macOS can discover by display name through Spotlight (`Command-Space`).
- Tell users exactly how to launch Tokenboard after installation and why it subsequently appears only in the menu bar.
- Keep API-equivalent pricing enabled with the bundled starter catalog; do not add a required setup step or manual price-entry form.
- Explain that token totals do not depend on pricing.
- Make the agent prompt the clear update path when usage is unpriced or the user believes model prices or exchange rates may be outdated.
- Preserve Tokenboard's offline, local-validation, privacy, and atomic catalog-update boundaries.

## Non-goals

- Adding a Dock icon, launcher helper, daemon, login item by default, or separate Spotlight integration.
- Automatically fetching pricing or exchange rates.
- Automatically declaring a catalog stale based only on age.
- Requiring pricing configuration during onboarding.
- Asking users to type model prices or exchange rates into a form.
- Changing how API-equivalent values are calculated or how unpriced tokens are counted.

## Design

### 1. Native installation and Spotlight discovery

The Homebrew cask remains a standard app installation using:

```ruby
app "Tokenboard.app"
```

This places the bundle at `/Applications/Tokenboard.app`. The application bundle remains a native macOS application with these identity fields:

- `CFBundleDisplayName`: `Tokenboard`
- `CFBundleName`: `Tokenboard`
- `CFBundlePackageType`: `APPL`
- `CFBundleIdentifier`: `com.tokenboard.Tokenboard`
- `LSUIElement`: `true`

The first four fields establish a named application bundle that Launch Services and Spotlight can discover. `LSUIElement` preserves the menu-bar-only experience after launch.

Build and release validation will explicitly assert the display name, bundle name, package type, identifier, executable, minimum macOS version, and agent-only flag. This guards the discoverability contract without relying on a timing-sensitive Spotlight database query in CI.

The README install section and Homebrew caveat will provide the same concise launch instruction:

> Press Command-Space, type **Tokenboard**, then press Return. Tokenboard appears in the menu bar and does not stay in the Dock.

The README will retain the quarantine-removal explanation and put the launch instruction immediately after the install commands. The Homebrew caveat will make the instruction visible at the end of installation. A release acceptance check will install the public cask, confirm `/Applications/Tokenboard.app`, confirm its metadata with `mdls`, and launch it by application name. CI will not promise instantaneous Spotlight indexing on every machine.

### 2. Pricing remains enabled with a starter catalog

The bundled `Resources/tokenboard-pricing.json` catalog remains installed and active. Covered models continue to show API-equivalent estimates without any pricing setup. Missing aliases, missing effective-date coverage, or missing exchange rates continue to remain explicit rather than guessed.

The Pricing settings page will lead with a short explanation equivalent to:

> Tokenboard includes a starter pricing catalog, so estimates work immediately for covered models. Token totals never depend on pricing.

This text establishes that pricing is optional estimate metadata rather than a prerequisite for local token tracking.

### 3. Clear prompt guidance for missing or outdated pricing

The update section will be titled **Update missing or outdated pricing**. Its copy will explain both triggers and the exact workflow:

> Run this update when usage appears as unpriced, a provider changes model prices, or exchange rates may be out of date. Copy the prompt and paste it into Claude Code or Codex. The agent researches public sources and writes a complete candidate catalog; Tokenboard validates it locally and applies valid changes automatically.

Supporting copy will retain the privacy boundary: the prompt includes missing model identifiers needed for coverage, but never token amounts, conversation content, or other private usage data. It will also retain the network boundary: Tokenboard itself makes no network requests.

The existing **Copy Pricing Update Prompt** button remains the sole update action. The prompt continues to request a complete, evidence-backed catalog rather than a partial patch, report its sources and uncertainties, and write through the watched local pricing inbox. An invalid candidate continues to leave the last valid catalog active.

The UI will not claim that a catalog is definitively current. The existing exchange-rate verification date and visible unpriced-usage list give the user honest signals, while provider announcements or other external knowledge may also motivate an update.

### 4. README workflow

The README pricing section will become a numbered workflow:

1. Use the bundled starter catalog for covered models; no setup is required.
2. Open **Settings → Pricing** when the menu reports unpriced usage, when a provider changes prices, or when exchange rates may be outdated.
3. Choose **Copy Pricing Update Prompt** and paste the prompt into Claude Code or Codex.
4. Let the agent research allowed public sources and write the candidate catalog.
5. Return to Tokenboard; a valid catalog applies automatically, while an invalid catalog leaves the previous one active.

The section will explicitly repeat that token totals are unaffected by missing or outdated pricing and that API-equivalent values are estimates, not bills.

## Testing and verification

Implementation will add or update tests for:

- `Resources/Info.plist` application identity: display name, bundle name, package type, identifier, executable, deployment target, and `LSUIElement`.
- `Scripts/verify-entitlements.sh` rejecting an app whose application identity or menu-bar policy differs from the release contract.
- Pricing settings copy naming the starter catalog, token-total independence, missing/outdated update triggers, supported agent workflow, automatic local application, and privacy/network boundaries.
- README and cask content containing the `/Applications` installation and Spotlight launch instructions.
- Existing prompt-builder, pricing validation, atomic update, and no-network tests continuing to pass.

Manual release acceptance for the patch release will verify:

1. A clean Homebrew install creates `/Applications/Tokenboard.app`.
2. `mdls` identifies the installed bundle as a Tokenboard application.
3. `Command-Space`, typing `Tokenboard`, and pressing Return launches the app.
4. The app appears in the menu bar without staying in the Dock.
5. Settings → Pricing visibly explains the starter catalog and when/how to run the update prompt.
6. Copying the prompt produces instructions that cover missing and potentially outdated pricing without exposing private usage data.

## Release and compatibility

This is an additive copy and release-contract improvement with no data migration. It will ship as a `0.2.1` patch release rather than mutating the published `0.2.0` artifact. After the public release asset is verified, the Homebrew cask will be updated to `0.2.1` and its caveat will include the Spotlight launch instruction.

Existing preferences, ledger data, folder grants, pricing catalogs, and install/upgrade commands remain compatible.

## Acceptance criteria

- Homebrew installs a standard Tokenboard application in `/Applications` and the release contract verifies Spotlight-relevant bundle metadata.
- Install-facing documentation tells users to launch with Command-Space and explains the menu-bar-only result.
- Pricing is enabled immediately for covered models through the bundled starter catalog.
- The UI and README state that token totals work regardless of pricing coverage.
- The UI and README tell users to copy and run the agent prompt for unpriced usage, provider price changes, or potentially outdated exchange rates.
- No automatic network access, mandatory pricing onboarding, or manual pricing form is introduced.
- Valid updates continue to apply automatically and invalid updates continue to preserve the last valid catalog.
