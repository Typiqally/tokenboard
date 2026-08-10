# Native Menu Polish Design

**Date:** 2026-08-10
**Status:** Approved for implementation planning

## Context

Tokenboard's status menu already exposes the right information and actions in a compact native hierarchy. Its first two rows are disabled `NSMenuItem`s, however, so AppKit renders the exact token total and API-equivalent estimate with disabled-text contrast. The menu's most important information is therefore also its quietest information. The separate recency row and surrounding separators add height without adding a distinct interaction.

This design improves the summary hierarchy while preserving Tokenboard's native, local-only, single-process product character. The result remains a real AppKit `NSMenu`; it does not introduce a popover, web view, SwiftUI menu replacement, animation, network behavior, dependency, entitlement, helper, or custom background material.

## Goals

- Make the exact token total the menu's clear focal point.
- Keep the API-equivalent estimate visibly subordinate to the factual token total.
- Group the selected period and update recency with the values they describe.
- Preserve standard AppKit behavior for every interactive menu item and submenu.
- Improve action scanning with restrained, native SF Symbols.
- Preserve existing startup, database-recovery, relaunch, pricing, shortcut, and action behavior.
- Provide useful VoiceOver output and respect system appearance and increased contrast.

## Non-goals

- Changing the menu-bar status title or the meaning of the Menu Bar preference.
- Adding charts, trends, deltas, source health, model breakdowns, or other dashboard content.
- Changing period, currency, pricing, refresh, settings, or quit behavior.
- Turning the summary into an interactive control or copy action.
- Introducing custom menu backgrounds, borders, cards, color accents, motion, or non-system typefaces.
- Changing Tokenboard's local-only, privacy, entitlement, or process boundaries.

## User Flow

The interaction flow stays unchanged:

1. Read the selected compact value in the macOS menu bar.
2. Open Tokenboard's status menu for precise usage and context.
3. Read the exact token total first, then the API-equivalent estimate.
4. Optionally change Period, Currency, or Menu Bar through standard submenus.
5. Optionally invoke Refresh, Pricing, Settings, or Quit through standard menu items.

The redesign does not add a click or decision. It reduces the top-level menu from fourteen items to eleven by replacing two disabled value rows and a separate recency row with one summary item, and by removing the now-redundant separator around the recency row.

## Selected Visual Direction

The selected direction is the companion's focused native header, integrated-context variant, with symbol-guided actions.

The summary is one noninteractive custom view hosted by an `NSMenuItem`. It inherits the menu's system material and uses only AppKit label controls, semantic colors, and system fonts. It contains:

1. A compact context row with the selected period on the left and abbreviated update recency on the right.
2. The full-precision token title in a semibold system font as the primary line.
3. The existing API-equivalent title in a smaller secondary-label style.

Tokens remain primary even when the user selects API Value for the menu-bar title. This preserves the visual distinction between exact usage and an estimated public API-equivalent value.

The action section uses native template SF Symbols:

- Refresh Now: `arrow.clockwise`
- Pricing: `banknote`
- Settings: `gearshape`
- Quit Tokenboard: no image

The three configuration submenus remain image-free. This creates a consistent action rail without competing with the summary or turning every row into an illustrated control.

## AppKit Structure

### Summary content

Introduce a small value type that contains display-ready strings for the custom view:

- period context
- abbreviated visual recency
- full accessibility recency
- exact token title
- API-equivalent title
- combined accessibility summary

This content is presentation-only. It does not calculate usage or currency values and does not reach into the ledger, pricing catalog, or ingestion system.

### Summary view

Introduce a focused AppKit view composed from `NSStackView` and label-style `NSTextField`s. It owns only layout and accessibility presentation. It has no actions, gesture recognizers, timers, background drawing, or model dependency.

The view uses intrinsic sizing with a stable minimum width appropriate for the current menu. Labels use system fonts and semantic colors such as `labelColor`, `secondaryLabelColor`, and `tertiaryLabelColor`. The exact total retains full precision and does not abbreviate. Layout must accommodate every supported period title, the longest supported formatted currency title, and an abbreviated localized relative date without truncating meaningful text.

The view is hosted in a noninteractive `NSMenuItem`. Keyboard navigation continues directly to the first enabled submenu item. The menu item and view expose the summary through native accessibility roles without making the summary appear actionable.

### Menu builder and controller

`NativeMenuBuilder` replaces the first two disabled items and the later Updated item with the summary menu item. `BuiltNativeMenu` returns a reference to the summary view instead of an `updatedItem` reference.

`MenuController` retains a weak reference to the summary view. When the menu opens, it formats the latest successful scan with `RelativeDateTimeFormatter`, updates the visual abbreviated recency, and updates the full VoiceOver wording. No polling or timer is introduced.

The existing standard submenu items, represented objects, selectors, keyboard equivalents, enabled-state rules, and action targets remain unchanged. The action-item helper accepts an optional system symbol name and applies it as a template image.

## States and Copy

### Ready

- Context: selected period and latest successful scan recency.
- Primary: the existing exact token title.
- Secondary: the existing approximate API-equivalent title.

### Not yet updated

The visual context uses a compact equivalent of `Updated never`; the accessibility value uses the full phrase. The menu does not invent a successful update time.

### Starting

Before a published state exists, the header uses a neutral starting context with `Token total unavailable` and `API equivalent unavailable`. Configuration and regular-action enablement remain governed by the existing rules.

### Startup failure

The header uses an unavailable context and the same unavailable value copy. The detailed `Startup paused: …` row remains in its existing diagnostic position so an unbounded error string does not distort the summary layout.

### Database recovery and relaunch dispositions

When a last valid published state exists, the header continues showing that state. Existing action-disabling behavior remains unchanged for restore, relaunch-required, preservation-retry-required, and preservation-failed dispositions.

### Unpriced usage

The summary continues using the existing API-equivalent presentation. The Pricing item continues carrying the explicit unpriced quantity in its title. The new `banknote` image is not a warning indicator and does not replace the textual disclosure.

## Accessibility

- The summary is noninteractive and does not become a keyboard stop.
- VoiceOver receives a combined, natural-language summary containing period, exact tokens, API-equivalent estimate, and full recency.
- Individual visible labels retain appropriate static-text semantics where AppKit exposes them.
- Action images are decorative template images; the existing menu-item titles remain the accessible action names.
- Meaning is never encoded by color or image alone.
- Semantic system colors and fonts adapt to light mode, dark mode, and increased contrast.
- No motion is introduced, so Reduce Motion requires no special path.

## Testing

Develop the change test-first in `TokenboardAppTests`.

Automated coverage must verify:

- Ready summary content uses the selected period, exact token title, and approximate API-equivalent title.
- Tokens remain the primary summary value when Menu Bar is set to API Value.
- Starting, startup-failure, and never-updated fallbacks use explicit copy.
- The summary occupies one top-level menu item and the obsolete Updated row is absent.
- Period, Currency, and Menu Bar submenu ordering, selected state, represented values, targets, and selectors are unchanged.
- Refresh, Pricing, and Settings receive the selected template symbols; Quit and configuration rows do not.
- Existing shortcuts remain unchanged.
- Existing recovery disposition enablement remains unchanged.
- Opening the menu updates both visual and accessibility recency without rebuilding usage data.
- The custom view has a noninteractive accessibility role and exposes the combined summary label.

Verification commands:

```zsh
swift test
Scripts/build-app.sh release
Scripts/verify-entitlements.sh .build/release/Tokenboard.app
git diff --check
```

Manual design verification must inspect the running menu in light and dark appearances, confirm keyboard submenu navigation and shortcuts, inspect increased-contrast rendering, and confirm the header is announced clearly with VoiceOver. The repository's five-minute native release acceptance is not required for this presentation-only change and must not be claimed unless a person explicitly performs it.

## Acceptance Criteria

- Opening the menu reveals one clear, full-precision token focal point with the API-equivalent estimate subordinate to it.
- Period and recency read as context for the summary rather than independent disabled rows.
- All interactive controls remain standard AppKit menu items with unchanged behavior.
- The action image rail matches the selected companion direction and uses only native template symbols.
- The menu remains compact, native in light and dark appearance, keyboard-operable, and understandable through VoiceOver.
- No new entitlement, dependency, process, persistence, network access, or background activity is introduced.
