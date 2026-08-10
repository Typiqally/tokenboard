# README Visual Refresh Design

**Date:** 2026-08-10
**Status:** Ready for final review

## Context

Tokenboard's README is factually strong but visually flat. It opens with dense prose, places installation below technical requirements, and offers no immediate picture of the native menu-bar experience. A prospective user must read several paragraphs before understanding what Tokenboard looks like, what they gain, and how to install it.

The refresh should make the product immediately legible and appealing without turning the repository into a SaaS landing page. Tokenboard's existing personality remains the standard: simple, clean, mean; quietly confident; native; precise; and explicit about privacy and estimation.

## Goals

- Show the native menu-bar experience above the fold.
- Optimize the opening for a prospective user deciding whether to install Tokenboard.
- Surface native, local-only, and no-telemetry trust signals immediately.
- Move the Homebrew install path directly below the visual introduction.
- Preserve the README's pricing, privacy, build, and limitation details while making them easier to scan.
- Use a privacy-safe visual with controlled synthetic data rather than publishing live usage.
- Keep every product and privacy claim verifiable against the repository's source documents.

## Non-goals

- Creating a product logo, icon redesign, website, animated demo, video, GIF, or screenshot gallery.
- Adding remote badges, tracking images, analytics, or externally hosted assets.
- Presenting the API-equivalent estimate as a bill or exact spend.
- Adding features, changing app behavior, or modifying the application bundle.
- Replacing detailed privacy, contribution, or release documentation.
- Styling the README like an analytics dashboard or conventional SaaS landing page.

## Selected Visual Direction

The selected direction is the companion's **B1 Graphite Desktop** editorial banner.

Create one self-contained SVG at:

```text
.github/assets/tokenboard-hero.svg
```

The asset uses an approximately `1200 × 420` view box and contains two balanced regions:

1. **Editorial copy on the left**
   - Kicker: `TOKENBOARD FOR MACOS`
   - Headline: `Your local AI usage. One glance away.`
   - Supporting line: `Exact Claude Code and Codex token totals, private on your Mac.`
   - Trust signals: `Native AppKit`, `Local only`, `No telemetry`
2. **Reconstructed native product preview on the right**
   - A restrained graphite desktop/menu-bar context with a muted macOS-style atmospheric glow.
   - A compact menu-bar value.
   - The implemented summary hierarchy, configuration submenus, and action-symbol rail.

The visual is a rebuilt product illustration rather than a screenshot. It must remain faithful to the implemented AppKit menu while using synthetic sample data:

- Menu bar: `1.28M`
- Context: `THIS MONTH`
- Recency: `UPDATED 1 MIN. AGO`
- Primary value: `1,284,930 tokens`
- Secondary value: `≈ €4.68 API equivalent`
- Currency: `EUR`
- Menu-bar metric: `Tokens`

The action rail visually represents Refresh, Pricing, and Settings without relying on nonportable emoji. Quit may be omitted from the cropped preview if necessary to keep the asset balanced, provided the artwork does not imply that the shown rows are the app's complete menu.

The SVG must not use Apple logos, fake analytics, ornamental charts, loud brand gradients, fake window chrome, or claims not present in the product.

## Asset Contract

The SVG is static and self-contained:

- No remote image, stylesheet, font, script, or URL reference.
- No animation or interaction.
- No raster data unless a rendering limitation makes a small embedded texture unavoidable; the preferred implementation is vector-only.
- Use broadly available system-style font fallbacks.
- Include `<title>` and `<desc>` elements describing the product preview.
- Use a baked-in graphite background so the artwork remains consistent on GitHub light and dark themes.
- Preserve sufficient contrast for the headline, supporting text, trust signals, exact token total, and API-equivalent estimate.
- Treat tiny menu labels as supporting visual detail; the README text and alt text must carry all essential meaning.
- Scale proportionally at narrow widths without clipping the headline or menu.

The README includes useful alt text and the caption:

```text
Product preview with sample data.
```

This distinguishes the reconstructed artwork from a literal screenshot and makes clear that the displayed values are not the user's data.

## README Information Architecture

### 1. Opening

- `# Tokenboard`
- One concise product sentence: a fully native macOS menu-bar app for private Claude Code and Codex usage totals.
- The new hero asset.
- The sample-data caption.

Avoid duplicating the banner's full headline in Markdown. The surrounding text should explain the product if the asset is unavailable, while the asset provides the emotional and visual introduction.

### 2. Install

Move the Homebrew install instructions directly below the hero. Preserve both commands:

```zsh
brew install --cask typiqally/tokenboard/tokenboard
xattr -dr com.apple.quarantine /Applications/Tokenboard.app
```

Keep the explicit explanation that Tokenboard is not Apple-notarized, Homebrew verifies the release, removing quarantine does not grant additional permissions, and the app remains sandboxed. Keep upgrade and uninstall commands, but present them compactly after the primary install path.

### 3. At a glance

Use three compact benefit groups rather than long marketing copy:

- **Exact local totals:** durable token totals from approved Claude Code and Codex logs.
- **Honest estimates:** API-equivalent values use public list prices, effective dates, and explicit unpriced coverage.
- **Useful ranges:** Today, This Week, This Month, This Year, and All Time, with supported display currencies.

### 4. Private by construction

Explain the privacy model in concise prose or bullets:

- One sandboxed native process.
- Explicit read-only folder grants through the macOS picker.
- No network entitlement, telemetry, analytics, helper, daemon, or XPC service.
- Filesystem-event monitoring rather than a polling timer.
- Content-free durable aggregates after ingestion.

This section should link to `PRIVACY.md` for the exhaustive boundary rather than duplicating it.

### 5. How it works

Present the normal user journey in three steps:

1. Choose the Claude Code and Codex roots through the native folder picker.
2. Approve the optional historical import for available logs.
3. Read exact totals or API-equivalent estimates from the menu bar and menu while Tokenboard follows future filesystem events.

Preserve the qualification that Tokenboard cannot recover logs deleted or unavailable before the first successful import.

### 6. Understanding API-equivalent value

Retain the current factual distinctions:

- The estimate is not a bill or subscription-spend report.
- It cannot reproduce discounts, credits, batch pricing, negotiated terms, or billing-side classification.
- Pricing is effective-dated, so historical usage keeps the rate covering its usage day.
- Unknown models or uncovered dates remain counted but visibly unpriced.

Use shorter paragraphs without weakening any caveat.

### 7. Updating pricing

Preserve the agent-assisted pricing flow and its boundaries:

- Tokenboard never fetches pricing itself.
- The user explicitly copies the prompt to Claude Code or Codex.
- The external agent reports sources and requests its own access.
- Tokenboard validates and atomically applies the complete local candidate.
- Invalid updates leave the last valid catalog active.

### 8. Build from source

Move contributor requirements and build commands below user-facing product sections. Preserve:

- macOS 14 Sonoma or newer.
- Apple's Swift 6 toolchain and macOS SDK.
- No third-party runtime dependencies.
- Test, build, entitlement-verification, and open commands.
- The existing signing and release explanation.

### 9. Known limits and references

Keep the current known-limit facts, removing only duplicated wording. Finish with direct links to `PRIVACY.md` and `CONTRIBUTING.md`. Preserve the optional audit disclaimer without making it part of the primary product path.

## Voice and Copy Rules

- Direct, specific, and calm; avoid hype such as “revolutionary,” “effortless,” or “unlock.”
- Prefer short paragraphs and concrete headings.
- Say `menu bar`, not `toolbar`.
- Keep `API-equivalent` visibly qualified as an estimate.
- Use `private`, `local`, and `offline` only where supported by the actual entitlement and runtime design.
- Do not claim Apple notarization, exact billing equivalence, deleted-log recovery, or support beyond the documented providers/formats.
- Do not expose real paths, source records, conversations, usage totals, or personal menu-bar contents in the asset.

## Accessibility and Rendering

- The Markdown image has descriptive alt text that explains the menu-bar preview and its sample values.
- The caption states that the visual uses sample data.
- The SVG provides its own `<title>` and `<desc>` metadata.
- Essential product meaning is present in surrounding Markdown, not only inside the image.
- The asset must remain legible when scaled to typical GitHub desktop width and must not create horizontal scrolling at narrow README widths.
- The composition must work against both GitHub light and dark page backgrounds.

## Verification

- Validate the SVG as XML with the local XML tooling available on macOS.
- Confirm the asset contains no remote references, scripts, animation, or tracking URLs.
- Render the final README opening at desktop and narrow widths and inspect the result in the visual companion.
- Check headline, primary value, estimate, context row, and trust signals for clipping and readable contrast.
- Check relative image and document links.
- Compare factual claims with `PRODUCT.md`, `PRIVACY.md`, and `CONTRIBUTING.md`.
- Run the repository's required Swift test and diff checks before committing the implementation.
- Obtain final visual approval in the companion before treating the README refresh as complete.

## Acceptance Criteria

- A visitor can identify Tokenboard as a private native macOS menu-bar usage app without reading below the hero.
- The opening contains a polished visual that accurately resembles the implemented menu and clearly uses sample data.
- Installation is visible immediately below the opening visual.
- Privacy and API-estimate caveats remain accurate and easy to find.
- The README is meaningfully easier to scan without losing current operational detail.
- The hero introduces no remote dependency, tracking request, or private data.
- The final asset and README opening are approved through a rendered visual review.
