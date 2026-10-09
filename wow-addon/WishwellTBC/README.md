# Wishwell TBC (WoW addon)

A loot database for The Burning Crusade Anniversary, in the game. Browse what drops anywhere, try it on your character, mark what you want, and get told when it drops. Works solo at any level.

This is its own addon. It shares nothing with Wishwell (the WoW Forever addon) or with Raid Night: its own folder, its own saved settings, its own data.

## Install

1. Unzip so you have, inside the TBC Anniversary game folder (`_anniversary_`):

   `Interface\AddOns\WishwellTBC\`

   That folder must contain `WishwellTBC.toc`. The zip also holds `WishwellTBC_World`; put it beside it in `AddOns`. It is the data behind the Ask box and only loads when you ask something.

2. Restart WoW.
3. Type `/ww` (or `/wishwell`), or click the minimap button.

## What it does

The window looks like the character window: your character on the left, the item list on the right, five tabs down the right edge: Wisp, Next, Gear (Loot, Wishlist, Sets), Quests and Me (Talents, Training, Professions, Characters). Gear and Me show their pages as buttons in the header. On Talents, Spell training, Quests and Professions the left side shows a summary of the tab instead of the character. The window is drawn a little smaller than the game's own; Settings has a switch for full size.

- **What next?** One screen for "what should I do now?": the best quest where you are, the zones with the most quest XP, what your spells will cost, a dungeon for your level, and your wishlist.
- **My wishlist.** Mark the items you want. Wishwell tells you when one drops, and group members with the addon see what you want.
- **Loot.** Every TBC and Classic raid and dungeon, by boss. Normal and heroic dungeons have their own lists: pick one under Dungeons or Heroic dungeons. Walk into a dungeon and Wishwell loads its loot and opens the right list for you. Filter by class, rarity, slot and zone, or search everything at once. Click an item to try it on.
- **Item sets.** Tier, dungeon and PvP sets. Open one to see it on your character.
- **Spell training.** Visit your trainer once: Wishwell lists what you can learn at each level and what it costs.
- **Talents.** The tab opens on your three talent trees, full width, with a menu to pick a build and buttons to spend your next point or all of them. Order list shows the same build as a list. Pick damage, tank or healing. Wishwell reads the talents you already have and lists the rest in the order to take them, with the level each point arrives at. The builds are the standard level 70 builds; every one is checked against the talent trees. The left side draws your three talent trees: each talent shows points placed over points the build wants (green done, yellow to fill, red not in the build). A Spend points button puts the points you have free into the build for you, in order; it asks first, because taking talents back costs gold.
- **Ask Wisp.** The Ask box at the top of the window, the Ask Wisp tab, or `/ww ask where is Hogger`, answers questions from Wishwell's own data: where an item drops or who sells it, where an NPC stands, what a boss drops, where a quest starts, what it asks and where to hand it in, the nearest innkeeper, repairer or flight master, and your stat priority. It is a look-up, not an AI, and it works offline.
- **Quest guide.** Click Guide me on the Quests tab (or type `/ww guide`) for a small window that stays up while you play. It walks you through your quests, nearest stop first: what a quest in your log still needs you to kill or collect (with the game's own count), who to hand a finished quest in to, and quest givers with something new. It says how far each is and which way, and moves on as you go.
- **Quests.** Every quest from level 1 to 70, Outland included, by zone, for your class and race (Blood Elves and Draenei too), best XP first. Click a quest (or its Map button) to open the world map with a pin on the quest giver. Close the map, or click Back to Wishwell on it, and you are back on the quest list.
- **Professions.** Open a profession window once: Wishwell lists the recipes that will raise your skill and whether you have the materials. Enchanting works too.
- **Pinned recipes.** Open a profession window and the wisp sits above it with a Pin recipe button. A pinned recipe stays on screen with what you have and need of each material, so you can close the window and shop. Click a material to put its name in the auction house search.
- **Characters.** Every character that has logged in: level, XP to the next level, gold and wishlist size.
- **Upgrade tips.** Hover any item anywhere (bags, vendors, loot): the tooltip compares it with what you are wearing, stat by stat, and says whether it is an upgrade and why. Gear is judged for your talent build (the one picked on the Talents tab, or the tree with the most points), and each stat is ranked in the order the Icy Veins TBC Classic guide for that build gives. The number after a stat, such as (#2), is its place on that list. The Wishwell window does not need to be open. Loot rolls and quest rewards get the same advice.
- **Long text.** If a line in any list ends in "...", click the row to open it out and read all of it. Click again to close it.
- **Settings.** The corner button, or `/ww settings`. Window size steps through four sizes. Wishlist drop alert turns the message for a wishlist drop on or off, and Tell my group also says it in party or raid chat.

Wishwell never rolls, picks or equips anything. The one thing it will do for you is spend talent points, and only when you click the button and say yes.

## Commands

`/ww` opens the window. `/ww help` lists the rest.

## Where the data comes from

- Loot, drop rates and item sets: [AtlasLootClassic](https://github.com/Hoizame/AtlasLootClassic).
- Quests, quest XP and where quests start: [Questie](https://github.com/Questie/Questie).
- Talent trees, builds and the best-in-slot gear lists: [wowsims TBC](https://github.com/wowsims/tbc) (MIT licence). It has no lists for healers.
- NPCs, items, vendors and quest objectives for the Ask box: [Questie](https://github.com/Questie/Questie)'s TBC database (Classic and TBC).
- What creatures drop and how often, world drops included: the [CMaNGOS TBC database](https://github.com/cmangos/tbc-db), a community reconstruction of the loot tables, so the chances are close rather than exact.
- What is crafted (profession, skill, reagents) and what each reputation sells: [AtlasLootClassic](https://github.com/Hoizame/AtlasLootClassic).
- Stat priority for each build: the [Icy Veins TBC Classic](https://www.icy-veins.com/tbc-classic/) class guides.

Drop rates are known for most Classic items and only a few TBC items. Wishwell also counts the boss kills it sees, and after ten kills of a boss it shows your own numbers.

## Rebuilding the data

```
npm i --no-save fengari
node scripts/build-wishwell-tbc.mjs --refresh
node scripts/build-wishwell-tbc-talents.mjs --refresh
node scripts/build-wishwell-tbc-world.mjs --refresh
node scripts/build-wishwell-tbc-bis.mjs --refresh
```
