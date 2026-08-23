#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repository_root=${script_dir:h}
asset_root="$repository_root/Resources/Companions"

fetch_asset() {
  local source_url=$1
  local destination=$2
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

fetch_asset 'https://archives.bulbagarden.net/media/upload/4/45/Pallet_Town_PE.png' "$asset_root/Pokemon/Backgrounds/01-pallet-town.png"
fetch_asset 'https://archives.bulbagarden.net/media/upload/a/a2/Viridian_Forest_PE.png' "$asset_root/Pokemon/Backgrounds/02-viridian-forest.png"
fetch_asset 'https://archives.bulbagarden.net/media/upload/4/4f/Cerulean_City_PE.png' "$asset_root/Pokemon/Backgrounds/03-cerulean-city.png"
fetch_asset 'https://archives.bulbagarden.net/media/upload/2/2c/Vermilion_City_PE.png' "$asset_root/Pokemon/Backgrounds/04-vermilion-city.png"
fetch_asset 'https://archives.bulbagarden.net/media/upload/b/b6/Celadon_City_PE.png' "$asset_root/Pokemon/Backgrounds/05-celadon-city.png"
fetch_asset 'https://archives.bulbagarden.net/media/upload/5/5e/Fuchsia_City_PE.png' "$asset_root/Pokemon/Backgrounds/06-fuchsia-city.png"
fetch_asset 'https://archives.bulbagarden.net/media/upload/5/5d/Cinnabar_Island_PE.png' "$asset_root/Pokemon/Backgrounds/07-cinnabar-island.png"
fetch_asset 'https://archives.bulbagarden.net/media/upload/3/34/Indigo_Plateau_PE.png' "$asset_root/Pokemon/Backgrounds/08-indigo-plateau.png"

fetch_asset 'https://upload.wikimedia.org/wikipedia/commons/1/11/Growing-tree.png' "$asset_root/Tree/growing-tree.png"
fetch_asset 'https://images.unsplash.com/photo-1441974231531-c6227db76b6e?auto=format&fit=crop&w=900&q=82' "$asset_root/Tree/woodland.jpg"

fetch_asset 'https://images.unsplash.com/photo-1564013799919-ab600027ffc6?auto=format&fit=crop&w=900&q=82' "$asset_root/Tower/01-house.jpg"
fetch_asset 'https://images.unsplash.com/photo-1600585154340-be6161a56a0c?auto=format&fit=crop&w=900&q=82' "$asset_root/Tower/02-townhouse.jpg"
fetch_asset 'https://images.unsplash.com/photo-1545324418-cc1a3fa10c00?auto=format&fit=crop&w=900&q=82' "$asset_root/Tower/03-apartments.jpg"
fetch_asset 'https://images.unsplash.com/photo-1511818966892-d7d671e672a2?auto=format&fit=crop&w=900&q=82' "$asset_root/Tower/04-mid-rise.jpg"
fetch_asset 'https://images.unsplash.com/photo-1486406146926-c627a92ad1ab?auto=format&fit=crop&w=900&q=82' "$asset_root/Tower/05-high-rise.jpg"
fetch_asset 'https://images.unsplash.com/photo-1477959858617-67f85cf4f1df?auto=format&fit=crop&w=900&q=82' "$asset_root/Tower/06-skyline.jpg"
fetch_asset 'https://images.unsplash.com/photo-1522083165195-3424ed129620?auto=format&fit=crop&w=900&q=82' "$asset_root/Tower/07-city-tower.jpg"
fetch_asset 'https://images.unsplash.com/photo-1512453979798-5ea266f8880c?auto=format&fit=crop&w=900&q=82' "$asset_root/Tower/08-skyscraper.jpg"

fetch_asset 'https://oldschool.runescape.wiki/images/thumb/Lumbridge.png/600px-Lumbridge.png?22482' "$asset_root/OldSchoolRuneScape/Backgrounds/01-lumbridge.png"
fetch_asset 'https://oldschool.runescape.wiki/images/thumb/Varrock.png/600px-Varrock.png?620c5' "$asset_root/OldSchoolRuneScape/Backgrounds/02-varrock.png"
fetch_asset 'https://oldschool.runescape.wiki/images/thumb/Falador.png/600px-Falador.png?75619' "$asset_root/OldSchoolRuneScape/Backgrounds/03-falador.png"
fetch_asset 'https://oldschool.runescape.wiki/images/thumb/Seers_Village.png/600px-Seers_Village.png?c6011' "$asset_root/OldSchoolRuneScape/Backgrounds/04-seers-village.png"
fetch_asset 'https://oldschool.runescape.wiki/images/thumb/Karamja.png/600px-Karamja.png?d1c25' "$asset_root/OldSchoolRuneScape/Backgrounds/05-karamja.png"
fetch_asset 'https://oldschool.runescape.wiki/images/thumb/Canifis.png/600px-Canifis.png?e6f64' "$asset_root/OldSchoolRuneScape/Backgrounds/06-canifis.png"
fetch_asset 'https://oldschool.runescape.wiki/images/thumb/God_Wars_Dungeon_Entrance.png/600px-God_Wars_Dungeon_Entrance.png?8b0f5' "$asset_root/OldSchoolRuneScape/Backgrounds/07-god-wars.png"
fetch_asset 'https://oldschool.runescape.wiki/images/thumb/Tombs_of_Amascut.png/600px-Tombs_of_Amascut.png?f9992' "$asset_root/OldSchoolRuneScape/Backgrounds/08-tombs-of-amascut.png"

fetch_asset 'https://oldschool.runescape.wiki/images/Leather_armour_equipped.png?5eeb1' "$asset_root/OldSchoolRuneScape/Characters/01-leather.png"
fetch_asset 'https://oldschool.runescape.wiki/images/Studded_leather_armour_equipped.png?74625' "$asset_root/OldSchoolRuneScape/Characters/02-studded-leather.png"
fetch_asset 'https://oldschool.runescape.wiki/images/Green_d%27hide_armour_equipped.png?e0e94' "$asset_root/OldSchoolRuneScape/Characters/03-green-dhide.png"
fetch_asset 'https://oldschool.runescape.wiki/images/Blue_d%27hide_armour_equipped.png?3b21e' "$asset_root/OldSchoolRuneScape/Characters/04-blue-dhide.png"
fetch_asset 'https://oldschool.runescape.wiki/images/Red_d%27hide_armour_equipped.png?6d7b0' "$asset_root/OldSchoolRuneScape/Characters/05-red-dhide.png"
fetch_asset 'https://oldschool.runescape.wiki/images/Black_d%27hide_armour_equipped.png?bb246' "$asset_root/OldSchoolRuneScape/Characters/06-black-dhide.png"
fetch_asset 'https://oldschool.runescape.wiki/images/Armadyl_armour_equipped_male.png?2f1c4' "$asset_root/OldSchoolRuneScape/Characters/07-armadyl.png"
fetch_asset 'https://oldschool.runescape.wiki/images/Masori_armour_equipped_male.png?0771a' "$asset_root/OldSchoolRuneScape/Characters/08-masori.png"

fetch_asset 'https://static.wikia.nocookie.net/ageofempires/images/c/c2/TCDarkAge.png/revision/latest?cb=20170630003805' "$asset_root/AgeOfEmpiresII/01-dark-age.webp"
fetch_asset 'https://static.wikia.nocookie.net/ageofempires/images/3/35/AoE2DE_Dark_Age_Town_Center.png/revision/latest/scale-to-width-down/800?cb=20230922131204' "$asset_root/AgeOfEmpiresII/02-growing-camp.webp"
fetch_asset 'https://static.wikia.nocookie.net/ageofempires/images/c/c3/FedualTCOriginalDE.png/revision/latest/scale-to-width-down/800?cb=20210415061431' "$asset_root/AgeOfEmpiresII/03-feudal-age.webp"
fetch_asset 'https://static.wikia.nocookie.net/ageofempires/images/f/f5/CastleTCOriginalDE.png/revision/latest/scale-to-width-down/800?cb=20210415061329' "$asset_root/AgeOfEmpiresII/05-castle-age.webp"
fetch_asset 'https://static.wikia.nocookie.net/ageofempires/images/f/ff/ImperialTCOriginalDE.png/revision/latest/scale-to-width-down/800?cb=20210415061505' "$asset_root/AgeOfEmpiresII/07-imperial-age.webp"
fetch_asset 'https://static.wikia.nocookie.net/ageofempires/images/e/e7/DarkageDE.png/revision/latest?cb=20200223092842' "$asset_root/AgeOfEmpiresII/Icons/dark-age.webp"
fetch_asset 'https://static.wikia.nocookie.net/ageofempires/images/8/85/FeudalageDE.png/revision/latest?cb=20200223093147' "$asset_root/AgeOfEmpiresII/Icons/feudal-age.webp"
fetch_asset 'https://static.wikia.nocookie.net/ageofempires/images/d/de/CastleageDE.png/revision/latest?cb=20200223093258' "$asset_root/AgeOfEmpiresII/Icons/castle-age.webp"
fetch_asset 'https://static.wikia.nocookie.net/ageofempires/images/3/36/ImperialageDE.png/revision/latest?cb=20200223093355' "$asset_root/AgeOfEmpiresII/Icons/imperial-age.webp"

print "Bundled companion artwork under $asset_root"
