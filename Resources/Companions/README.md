# Companion assets

Everything in this directory is copied into `Tokenboard.app` at build time. Tokenboard never downloads companion artwork at runtime and does not expose an asset importer, configuration file, or watched asset directory.

`Scripts/fetch-companion-assets.sh` records the exact development-time source URL for every downloaded file.

## Sources and rights

- `Pokemon/*.png` contains the 36 generation 1–4 starter-family sprites from the [PokéAPI sprites repository](https://github.com/PokeAPI/sprites). Its upstream notice is bundled as `Pokemon/POKEAPI-LICENCE.txt` and states that image contents are copyright The Pokémon Company.
- `Pokemon/Backgrounds/` contains game-location images served by the [Bulbagarden Archives](https://archives.bulbagarden.net/). Pokémon game imagery and marks remain the property of Nintendo, Game Freak, Creatures, and their respective owners.
- `Tree/growing-tree.png` is Nicolas Bouliane’s [Growing-tree](https://commons.wikimedia.org/wiki/File:Growing-tree.png), licensed CC BY-SA 4.0. `Tree/woodland.jpg` is sourced from [Unsplash](https://unsplash.com/license).
- `Tower/` contains architectural photographs sourced from [Unsplash](https://unsplash.com/license).
- `OldSchoolRuneScape/` contains location and equipped-character images served by the [Old School RuneScape Wiki](https://oldschool.runescape.wiki/). The wiki describes these as copyrighted Jagex game media used with permission; Jagex retains its rights.
- `AgeOfEmpiresII/` contains Age of Empires II game imagery served by the [Age of Empires Series Wiki](https://ageofempires.fandom.com/). Microsoft and the game’s creators retain their rights.

The branded files are suitable for the intended personal local build. Review and clear all third-party rights before redistributing Tokenboard.
