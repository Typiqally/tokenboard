# Product

## Register

product

## Users

Tokenboard is for macOS developers who use Claude Code or Codex and want a quick, private view of their token usage. They check it at a glance from the menu bar, then open the menu only when they need an exact total, a calendar range, source health, or pricing context.

## Product Purpose

Tokenboard locally scans user-approved Claude Code and Codex history folders, reduces usage to deletion-resistant daily token aggregates, and shows token totals or estimated public API-equivalent USD for Today, This Week, This Month, This Year, or All Time. Success means the value is fast to read, historically defensible, explicit about unpriced usage, and effectively idle between local filesystem events.

## Brand Personality

Simple, clean, mean. Quietly confident and direct, with precise language and no decorative product theater.

## Anti-references

- SaaS dashboards, analytics portals, and oversized metric cards
- Electron or web-shaped controls that feel foreign on macOS
- Custom popovers where a standard menu or window is clearer
- Opaque telemetry, silent network access, or background activity the user did not request
- Language that presents API-equivalent estimates as an actual bill
- Gamification, ornamental motion, and color used without meaning

## Design Principles

1. Earn the glance: put one compact, trustworthy value in the menu bar and keep detail one click away.
2. Make local behavior inspectable: permission, import, pricing, and recovery actions are explicit and name their effects.
3. Use the platform: prefer standard AppKit and SwiftUI controls, menus, shortcuts, focus behavior, and system appearance.
4. Separate fact from estimate: exact token totals, API-equivalent estimates, and unpriced quantities remain visibly distinct.
5. Stay quiet at rest: refresh from local events and user actions, with no decorative timers, polling, or hidden helpers.

## Accessibility & Inclusion

Use native macOS semantics and keyboard behavior, provide clear VoiceOver labels for status and actions, never encode warning or selection state by color alone, respect increased-contrast and reduced-motion settings, and keep privacy and error copy understandable without technical background.
