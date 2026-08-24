#!/bin/zsh
# Development-time downloader for the raw companion source material.
#
# Usage: Scripts/fetch-companion-assets.sh <raw-root>
#
# Downloads every third-party source image the companion feature is baked
# from, into <raw-root>, using the layout expected by
# Scripts/bake-companion-assets.swift. Tokenboard itself never downloads
# anything at runtime; the baked results are bundled by Scripts/build-app.sh.
#
# Sources and rights are documented in Resources/Companions/README.md.
set -euo pipefail

if (( $# != 1 )); then
  print -u2 "usage: Scripts/fetch-companion-assets.sh <raw-root>"
  exit 64
fi
raw_root=${1:A}

fetch_asset() {
  local source_url=$1
  local destination="$raw_root/$2"
  local temporary_path="${destination}.download"
  mkdir -p "${destination:h}"
  curl \
    --location \
    --fail \
    --silent \
    --show-error \
    --retry 3 \
    --user-agent 'Tokenboard companion asset bundler (local development)' \
    "$source_url" \
    --output "$temporary_path"
  mv "$temporary_path" "$destination"
}

# --- Pokémon -----------------------------------------------------------------
# Location vistas: official Pokémon: Let's Go, Pikachu!/Let's Go, Eevee!
# location renders served by the Bulbagarden Archives.
fetch_asset 'https://archives.bulbagarden.net/media/upload/4/45/Pallet_Town_PE.png' 'pokemon/backgrounds/01-pallet-town.png'
fetch_asset 'https://archives.bulbagarden.net/media/upload/a/a2/Viridian_Forest_PE.png' 'pokemon/backgrounds/02-viridian-forest.png'
fetch_asset 'https://archives.bulbagarden.net/media/upload/1/11/Pewter_City_PE.png' 'pokemon/backgrounds/03-pewter-city.png'
fetch_asset 'https://archives.bulbagarden.net/media/upload/4/4f/Cerulean_City_PE.png' 'pokemon/backgrounds/04-cerulean-city.png'
fetch_asset 'https://archives.bulbagarden.net/media/upload/2/2c/Vermilion_City_PE.png' 'pokemon/backgrounds/05-vermilion-city.png'
fetch_asset 'https://archives.bulbagarden.net/media/upload/3/3e/Lavender_Town_PE.png' 'pokemon/backgrounds/06-lavender-town.png'
fetch_asset 'https://archives.bulbagarden.net/media/upload/b/b6/Celadon_City_PE.png' 'pokemon/backgrounds/07-celadon-city.png'
fetch_asset 'https://archives.bulbagarden.net/media/upload/2/2d/Saffron_City_PE.png' 'pokemon/backgrounds/08-saffron-city.png'
fetch_asset 'https://archives.bulbagarden.net/media/upload/5/5e/Fuchsia_City_PE.png' 'pokemon/backgrounds/09-fuchsia-city.png'
fetch_asset 'https://archives.bulbagarden.net/media/upload/5/5d/Cinnabar_Island_PE.png' 'pokemon/backgrounds/10-cinnabar-island.png'
fetch_asset 'https://archives.bulbagarden.net/media/upload/8/8c/Victory_Road_PE.png' 'pokemon/backgrounds/11-victory-road.png'
fetch_asset 'https://archives.bulbagarden.net/media/upload/3/34/Indigo_Plateau_PE.png' 'pokemon/backgrounds/12-indigo-plateau.png'

# Official artwork renders for the generation 1-4 starter families, from the
# PokéAPI sprites repository (see Pokemon/POKEAPI-LICENCE.txt).
for identifier in 1 2 3 4 5 6 7 8 9 \
    152 153 154 155 156 157 158 159 160 \
    252 253 254 255 256 257 258 259 260 \
    387 388 389 390 391 392 393 394 395; do
  fetch_asset \
    "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/other/official-artwork/${identifier}.png" \
    "pokemon/artwork/${identifier}.png"
done

# --- Old School RuneScape ----------------------------------------------------
# Full-resolution location scapes and equipped-armour renders served by the
# Old School RuneScape Wiki.
fetch_asset 'https://oldschool.runescape.wiki/images/Lumbridge.png' 'osrs/backgrounds/01-lumbridge.png'
fetch_asset 'https://oldschool.runescape.wiki/images/Al_Kharid.png' 'osrs/backgrounds/02-al-kharid.png'
fetch_asset 'https://oldschool.runescape.wiki/images/Varrock.png' 'osrs/backgrounds/03-varrock.png'
fetch_asset 'https://oldschool.runescape.wiki/images/Karamja.png' 'osrs/backgrounds/04-karamja.png'
fetch_asset 'https://oldschool.runescape.wiki/images/Grand_Exchange.png' 'osrs/backgrounds/05-grand-exchange.png'
fetch_asset 'https://oldschool.runescape.wiki/images/Falador.png' 'osrs/backgrounds/06-falador.png'
fetch_asset 'https://oldschool.runescape.wiki/images/Seers_Village.png' 'osrs/backgrounds/07-seers-village.png'
fetch_asset 'https://oldschool.runescape.wiki/images/East_Ardougne.png' 'osrs/backgrounds/08-east-ardougne.png'
fetch_asset 'https://oldschool.runescape.wiki/images/Canifis.png' 'osrs/backgrounds/09-canifis.png'
fetch_asset 'https://oldschool.runescape.wiki/images/God_Wars_Dungeon_Entrance.png' 'osrs/backgrounds/10-god-wars.png'
fetch_asset 'https://oldschool.runescape.wiki/images/Prifddinas_-_Ithell_district.png' 'osrs/backgrounds/11-prifddinas.png'
fetch_asset 'https://oldschool.runescape.wiki/images/Tombs_of_Amascut_-_Nexus_room.png' 'osrs/backgrounds/12-tombs-of-amascut.png'

fetch_asset 'https://oldschool.runescape.wiki/images/Leather_armour_equipped.png' 'osrs/characters/01-leather.png'
fetch_asset 'https://oldschool.runescape.wiki/images/Frog-leather_armour_equipped.png' 'osrs/characters/02-frog-leather.png'
fetch_asset 'https://oldschool.runescape.wiki/images/Studded_leather_armour_equipped.png' 'osrs/characters/03-studded-leather.png'
fetch_asset 'https://oldschool.runescape.wiki/images/Snakeskin_armour_equipped.png' 'osrs/characters/04-snakeskin.png'
fetch_asset 'https://oldschool.runescape.wiki/images/Green_d%27hide_armour_equipped.png' 'osrs/characters/05-green-dhide.png'
fetch_asset 'https://oldschool.runescape.wiki/images/Blue_d%27hide_armour_equipped.png' 'osrs/characters/06-blue-dhide.png'
fetch_asset 'https://oldschool.runescape.wiki/images/Red_d%27hide_armour_equipped.png' 'osrs/characters/07-red-dhide.png'
fetch_asset 'https://oldschool.runescape.wiki/images/Black_d%27hide_armour_equipped.png' 'osrs/characters/08-black-dhide.png'
fetch_asset 'https://oldschool.runescape.wiki/images/Karil%27s_armour_equipped_male.png' 'osrs/characters/09-karils.png'
fetch_asset 'https://oldschool.runescape.wiki/images/Armadyl_armour_equipped_male.png' 'osrs/characters/10-armadyl.png'
fetch_asset 'https://oldschool.runescape.wiki/images/Crystal_armour_equipped_male.png' 'osrs/characters/11-crystal.png'
fetch_asset 'https://oldschool.runescape.wiki/images/Masori_armour_equipped_male.png' 'osrs/characters/12-masori.png'

# --- Age of Empires II -------------------------------------------------------
# Definitive Edition architecture-set renders (one arrangement per age, the
# shared Dark Age set plus the West European set) served by the Age of
# Empires Series Wiki. `format=original` requests true PNGs.
fetch_asset 'https://static.wikia.nocookie.net/ageofempires/images/1/12/Dark_Age_arch_set_AoE2DE.png/revision/latest?format=original' 'aoe2/dark-age-set.png'
fetch_asset 'https://static.wikia.nocookie.net/ageofempires/images/5/5c/Arch_set_West_European_Feudal_Age_AoE2DE.png/revision/latest?format=original' 'aoe2/feudal-age-set.png'
fetch_asset 'https://static.wikia.nocookie.net/ageofempires/images/e/e6/Arch_set_West_European_Castle_Age_AoE2DE.png/revision/latest?format=original' 'aoe2/castle-age-set.png'
fetch_asset 'https://static.wikia.nocookie.net/ageofempires/images/6/6b/Arch_set_West_European_Imperial_Age_AoE2DE.png/revision/latest?format=original' 'aoe2/imperial-age-set.png'

# --- Minecraft ---------------------------------------------------------------
# Biome, structure, and dimension screenshots plus the canonical player and
# armor-set renders, served by the Minecraft Wiki.
fetch_asset 'https://minecraft.wiki/images/Plains.png' 'minecraft/backgrounds/01-plains.png'
fetch_asset 'https://minecraft.wiki/images/Forest.png' 'minecraft/backgrounds/02-forest.png'
fetch_asset 'https://minecraft.wiki/images/Plains_Village_Scene.jpg' 'minecraft/backgrounds/03-village.jpg'
fetch_asset 'https://minecraft.wiki/images/Lush_Caves.png' 'minecraft/backgrounds/04-lush-caves.png'
fetch_asset 'https://minecraft.wiki/images/Jagged_Peaks.png' 'minecraft/backgrounds/05-jagged-peaks.png'
fetch_asset 'https://minecraft.wiki/images/Ancient_City.png' 'minecraft/backgrounds/06-ancient-city.png'
fetch_asset 'https://minecraft.wiki/images/Nether_Wastes.png' 'minecraft/backgrounds/07-nether-wastes.png'
fetch_asset 'https://minecraft.wiki/images/Crimson_Forest.png' 'minecraft/backgrounds/08-crimson-forest.png'
fetch_asset 'https://minecraft.wiki/images/Nether_fortress_seen_from_the_Basalt_Deltas.png' 'minecraft/backgrounds/09-nether-fortress.png'
fetch_asset 'https://minecraft.wiki/images/Stronghold1.png' 'minecraft/backgrounds/10-stronghold.png'
fetch_asset 'https://minecraft.wiki/images/The_End.png' 'minecraft/backgrounds/11-the-end.png'
fetch_asset 'https://minecraft.wiki/images/End_City.png' 'minecraft/backgrounds/12-end-city.png'

fetch_asset 'https://minecraft.wiki/images/Steve_JE5.png' 'minecraft/characters/steve.png'
fetch_asset 'https://minecraft.wiki/images/Leather_Armor_JE5_BE3.png' 'minecraft/characters/leather.png'
fetch_asset 'https://minecraft.wiki/images/Golden_Armor_JE2_BE2.png' 'minecraft/characters/golden.png'
fetch_asset 'https://minecraft.wiki/images/Chainmail_Armor_JE2_BE2.png' 'minecraft/characters/chainmail.png'
fetch_asset 'https://minecraft.wiki/images/Iron_Armor_JE2_BE2.png' 'minecraft/characters/iron.png'
fetch_asset 'https://minecraft.wiki/images/Diamond_Armor_JE2_BE2.png' 'minecraft/characters/diamond.png'
fetch_asset 'https://minecraft.wiki/images/Netherite_Armor_JE2.png' 'minecraft/characters/netherite.png'

print "Raw companion source material downloaded to $raw_root"
print "Bake it with: swift Scripts/bake-companion-assets.swift $raw_root"
