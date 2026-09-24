# Discord companion artwork

Discord's large activity image follows the selected companion, today's starter
family, and the same twelve daily token stages. It uses a shared still at the
start of each stage (the completed frame for stage twelve), scenery `0`, seed
`0`, and the scene renderer's resting composition. The installation's seed,
scenery choices, progress between milestones, and animated frames stay local.
`None`, unpublished artwork, and an application-ID mismatch use `tokenboard`.

## Reproduce the artwork

From the repository root, with the full Xcode toolchain selected:

```zsh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  Scripts/export-discord-assets.sh .build/discord-assets
```

Choose a new output directory on each run; the exporter refuses to overwrite an
existing directory and publishes its completed output atomically. The debug-only
export command exits before constructing AppDelegate: it never starts the app,
opens a ledger, reads preferences or source folders, or connects to Discord.

The output contains:

- `images/`: 228 square 1024px PNGs, named with their exact Discord asset keys.
- `previews/`: matching 128px PNGs, plus the existing Tokenboard icon.
- `catalog.json`: theme, starter family, zero-based stage, tooltip, and SHA-256
  hashes for both sizes of every companion image.
- `review/`: contact sheets covering all themes, starter families, and stages.

After reviewing a changed export, copy its `previews/` and `catalog.json` here.
Only these small previews, this README, and the publication manifest ship with
Tokenboard; the full upload images and contact sheets remain development output.
`swift test` checks catalog coverage, preview hashes and dimensions, distinct
stages, square composition, and recorded rights status for published themes.

To render the actual Settings preview component in light and dark appearances
after copying the previews, run:

```zsh
swift run TokenboardApp --review-discord-preview .build/discord-assets/review
```

This debug-only command also exits before app startup and refuses to overwrite
existing review images. It renders synthetic examples, without enabling sharing.

The published 228-image companion catalog plus `tokenboard` occupies 229 of
Discord's 300 asset slots. Every theme is available, including all twelve
Pokémon starter families and their twelve stages. Asset keys begin `tb_v1_`;
keep them immutable once published.
Change the artwork version prefix for a deliberate replacement and account for
the remaining asset slots before retaining two complete versions.

## Publish and activate

1. Review `Resources/Companions/rights-manifest.json` and keep its status and
   evidence accurate. Forest and Village are cleared original artwork. The
   remaining themes were explicitly requested for Discord publication on
   2026-09-11; their rights records remain pending. Publication does not change
   those records or count as clearance evidence.
2. In the Discord Developer Portal, open application `1543692689571192862`,
   then Rich Presence → Art Assets. Upload the selected PNGs from `images/`,
   using each filename without `.png` as the exact key. Retain `tokenboard`.
3. Verify the saved names and images in that application. Using isolated
   synthetic usage, verify an initial stage, a later stage, and the reset for
   each uploaded theme in Discord. A successful IPC write alone does not prove
   Discord resolved an asset.
4. Add only verified keys to `published-assets.json`, keeping `applicationID`
   aligned with the public build configuration. The list currently enables all
   228 companion images. Their saved names and CDN downloads, plus the
   `tokenboard` fallback, were verified on 2026-09-11; every downloaded PNG exactly
   matches its source file. Discord client rendering was not observed because
   desktop control was unavailable. Tests reject unknown keys,
   duplicate keys, and published themes without a recorded rights status.
5. Rebuild Tokenboard. Settings previews the exact resolved image. Users with
   older sharing consent must reconfirm version 3; choosing another companion
   later uses that same consent. Disabling sharing or quitting clears activity.

Publication is a development/release operation. Tokenboard never uploads images,
downloads artwork, authenticates a Discord account, or accepts custom image URLs.
The publication list is bundled release configuration, not a watched file or
user-editable importer. Builds with another Discord application ID fall back to
the Tokenboard icon until their own keys are explicitly configured and verified.

Discord documents image uploads, asset keys, recommended 1024px resolution, and
the 300-asset limit in its [Rich Presence asset guide](https://docs.discord.com/developers/game-development/how-to-get-your-game-seen#uploading-assets).
