#!/bin/zsh
# Development-time downloader for the raw companion source material.
#
# Usage: Scripts/fetch-companion-assets.sh <raw-root>
#        TOKENBOARD_FETCH_ACTORS_ONLY=1 Scripts/fetch-companion-assets.sh <raw-root>
#        TOKENBOARD_FETCH_PREFIX=banished Scripts/fetch-companion-assets.sh <raw-root>
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
script_dir=${0:A:h}
hash_manifest="$script_dir/companion-source-hashes.sha256"
verify_manifest_only=${TOKENBOARD_VERIFY_ASSET_MANIFEST_ONLY:-0}
fetch_actors_only=${TOKENBOARD_FETCH_ACTORS_ONLY:-0}
fetch_prefix=${TOKENBOARD_FETCH_PREFIX:-}
typeset -A requested_assets

fetch_asset() {
  local source_url=$1
  local relative_path=$2
  local destination="$raw_root/$relative_path"
  if [[ -n ${requested_assets[$relative_path]-} ]]; then
    print -u2 "duplicate source asset request: $relative_path"
    exit 65
  fi
  requested_assets[$relative_path]=1
  local expected_hash=$(/usr/bin/awk -v path="$relative_path" '$2 == path { print $1 }' "$hash_manifest")
  if [[ ! "$expected_hash" =~ '^[0-9a-f]{64}$' ]]; then
    print -u2 "missing or invalid source hash: $relative_path"
    exit 65
  fi
  if [[ "$verify_manifest_only" == "1" ]]; then
    return
  fi
  if [[ -n "$fetch_prefix" && "$relative_path" != "$fetch_prefix"/* ]]; then
    return
  fi
  if [[ "$fetch_actors_only" == "1" && "$relative_path" != */actors/* ]]; then
    return
  fi
  mkdir -p "${destination:h}"
  if [[ -e "$destination" ]]; then
    local existing_hash=$(/usr/bin/shasum -a 256 "$destination" | /usr/bin/awk '{ print $1 }')
    if [[ "$existing_hash" == "$expected_hash" ]]; then
      return
    fi
    print -u2 "refusing to replace mismatched existing asset: $relative_path"
    exit 73
  fi
  local temporary_path=$(/usr/bin/mktemp "${destination:h}/.${destination:t}.XXXXXX")
  curl \
    --location \
    --fail \
    --silent \
    --show-error \
    --retry 3 \
    --proto '=https' \
    --tlsv1.2 \
    --max-time 120 \
    --user-agent 'Tokenboard companion asset bundler (local development)' \
    "$source_url" \
    --output "$temporary_path" || {
      /bin/rm -f -- "$temporary_path"
      return 1
    }
  local actual_hash=$(/usr/bin/shasum -a 256 "$temporary_path" | /usr/bin/awk '{ print $1 }')
  if [[ "$actual_hash" != "$expected_hash" ]]; then
    /bin/rm -f -- "$temporary_path"
    print -u2 "source hash mismatch: $relative_path"
    exit 65
  fi
  /bin/chmod 0644 "$temporary_path"
  /bin/ln -- "$temporary_path" "$destination"
  /bin/rm -f -- "$temporary_path"
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

# The route visitor uses PokéAPI's preserved animated battle sprite. The baker
# turns its GIF frames into a compact horizontal PNG strip for Canvas drawing.
fetch_asset \
  'https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/other/showdown/16.gif' \
  'pokemon/actors/pidgey.gif'

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

# Recognizable NPC renders for the ambient population.
fetch_asset 'https://oldschool.runescape.wiki/images/Man_%28blue%29.png?d82a7' 'osrs/actors/man-blue.png'
fetch_asset 'https://oldschool.runescape.wiki/images/Man_%28red%29.png?91a46' 'osrs/actors/man-red.png'
fetch_asset 'https://oldschool.runescape.wiki/images/Man_%28pink%29.png?a7e97' 'osrs/actors/man-pink.png'
fetch_asset 'https://oldschool.runescape.wiki/images/Chicken_%281%29.png?a7258' 'osrs/actors/chicken.png'
fetch_asset 'https://oldschool.runescape.wiki/images/Seagull.png?4a534' 'osrs/actors/seagull.png'

# --- Age of Empires II -------------------------------------------------------
# Definitive Edition architecture-set renders (one arrangement per age, the
# shared Dark Age set plus the West European set) served by the Age of
# Empires Series Wiki. `format=original` requests true PNGs.
fetch_asset 'https://static.wikia.nocookie.net/ageofempires/images/1/12/Dark_Age_arch_set_AoE2DE.png/revision/latest?format=original' 'aoe2/dark-age-set.png'
fetch_asset 'https://static.wikia.nocookie.net/ageofempires/images/5/5c/Arch_set_West_European_Feudal_Age_AoE2DE.png/revision/latest?format=original' 'aoe2/feudal-age-set.png'
fetch_asset 'https://static.wikia.nocookie.net/ageofempires/images/e/e6/Arch_set_West_European_Castle_Age_AoE2DE.png/revision/latest?format=original' 'aoe2/castle-age-set.png'
fetch_asset 'https://static.wikia.nocookie.net/ageofempires/images/6/6b/Arch_set_West_European_Imperial_Age_AoE2DE.png/revision/latest?format=original' 'aoe2/imperial-age-set.png'

# Original animated unit sprites and animal renders. `format=original` avoids
# Fandom's content-negotiated WebP derivative so the pinned bytes stay stable.
fetch_asset 'https://static.wikia.nocookie.net/ageofempires/images/d/df/Villager_m_walkanim_aoe2.gif/revision/latest?format=original' 'aoe2/actors/villager-m-walk.gif'
fetch_asset 'https://static.wikia.nocookie.net/ageofempires/images/f/f3/Villager_f_walkanim_aoe2.gif/revision/latest?format=original' 'aoe2/actors/villager-f-walk.gif'
fetch_asset 'https://static.wikia.nocookie.net/ageofempires/images/2/2f/Sheep_aoe2de.png/revision/latest?format=original' 'aoe2/actors/sheep.png'
fetch_asset 'https://static.wikia.nocookie.net/ageofempires/images/5/52/Hawk_anim_aoe2.gif/revision/latest?format=original' 'aoe2/actors/hawk.gif'

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

# Current Java Edition entity renders; animated wiki GIFs are retained where
# the source offers them and baked into strips alongside the still renders.
fetch_asset 'https://minecraft.wiki/images/Chicken_JE2_BE2.png?30245' 'minecraft/actors/chicken.png'
fetch_asset 'https://minecraft.wiki/images/Pig_JE2_BE1.png?6e6d8' 'minecraft/actors/pig.png'
fetch_asset 'https://minecraft.wiki/images/Plains_Villager_Base_JE2.png?a2fcc' 'minecraft/actors/villager.png'
fetch_asset 'https://minecraft.wiki/images/Bat_JE4_BE3.gif?db68c' 'minecraft/actors/bat.gif'
fetch_asset 'https://minecraft.wiki/images/Goat_%28two_horns%29_JE1_BE1.png?a5c0c' 'minecraft/actors/goat.png'
fetch_asset 'https://minecraft.wiki/images/Piglin_JE1.png?a498e' 'minecraft/actors/piglin.png'
fetch_asset 'https://minecraft.wiki/images/Hoglin_JE3.png?65eaa' 'minecraft/actors/hoglin.png'
fetch_asset 'https://minecraft.wiki/images/Silverfish_JE1_BE1.gif?d40a7' 'minecraft/actors/silverfish.gif'

# --- Banished ----------------------------------------------------------------
# Seasonal settlement screenshots and the original citizen-model sheet,
# hosted by developer Shining Rock Software. The baker crops these into the
# fixed scene plates and transparent citizen sprites used at runtime.
fetch_asset 'https://shiningrocksoftware.com/wp-content/uploads/2012/03/HunterOrchard.jpg' 'banished/backgrounds/01-first-shelter.jpg'
fetch_asset 'https://shiningrocksoftware.com/wp-content/uploads/2021/06/x03.jpg' 'banished/backgrounds/02-gatherers-clearing.jpg'
fetch_asset 'https://shiningrocksoftware.com/wp-content/uploads/2021/06/s06.jpg' 'banished/backgrounds/03-first-harvest.jpg'
fetch_asset 'https://shiningrocksoftware.com/wp-content/uploads/2021/06/s02.jpg' 'banished/backgrounds/04-pasture-raised.jpg'
fetch_asset 'https://shiningrocksoftware.com/wp-content/uploads/2013/04/PavedRoads.jpg' 'banished/backgrounds/05-roads-laid.jpg'
fetch_asset 'https://shiningrocksoftware.com/wp-content/uploads/2021/06/s08.jpg' 'banished/backgrounds/06-river-crossing.jpg'
fetch_asset 'https://shiningrocksoftware.com/wp-content/uploads/2021/06/s03.jpg' 'banished/backgrounds/07-trading-post.jpg'
fetch_asset 'https://shiningrocksoftware.com/wp-content/uploads/2021/06/s05.jpg' 'banished/backgrounds/08-market-town.jpg'
fetch_asset 'https://shiningrocksoftware.com/wp-content/uploads/2021/06/x09.jpg' 'banished/backgrounds/09-stone-village.jpg'
fetch_asset 'https://shiningrocksoftware.com/wp-content/uploads/2021/06/s10.jpg' 'banished/backgrounds/10-first-hard-winter.jpg'
fetch_asset 'https://shiningrocksoftware.com/wp-content/uploads/2021/06/x06.jpg' 'banished/backgrounds/11-winter-endured.jpg'
fetch_asset 'https://shiningrocksoftware.com/wp-content/uploads/2021/06/x01.jpg' 'banished/backgrounds/12-thriving-township.jpg'
fetch_asset 'https://shiningrocksoftware.com/wp-content/uploads/2011/06/Thumb_Citizens.jpg' 'banished/actors/citizens.jpg'

manifest_count=0
while read -r source_hash source_path; do
  if [[ ! "$source_hash" =~ '^[0-9a-f]{64}$' || -z "$source_path" ]]; then
    print -u2 "invalid companion source hash manifest entry"
    exit 65
  fi
  if [[ -z ${requested_assets[$source_path]-} ]]; then
    print -u2 "unused companion source hash: $source_path"
    exit 65
  fi
  (( manifest_count += 1 ))
done < "$hash_manifest"
if (( manifest_count != ${#requested_assets} )); then
  print -u2 "companion source request count does not match hash manifest"
  exit 65
fi

if [[ "$verify_manifest_only" == "1" ]]; then
  print "Companion source manifest verified"
  exit 0
fi

if [[ "$fetch_actors_only" == "1" ]]; then
  print "Raw companion actor sources downloaded to $raw_root"
  print "Bake them with: swift Scripts/bake-companion-assets.swift --actors-only $raw_root"
else
  print "Raw companion source material downloaded to $raw_root"
  print "Bake it with: swift Scripts/bake-companion-assets.swift $raw_root"
fi
