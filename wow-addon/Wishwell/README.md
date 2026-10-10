# Wishwell Forever (WoW addon)

A loot database for WoW Forever, in the game. Browse what drops anywhere, try it on your character, mark what you want, and get told when it drops. Works solo at any level.

This is its own addon. It shares nothing with Raid Night or Raid Night Forever.

## Install

1. Unzip so you have, inside WoW Forever's game folder:

   `Interface\AddOns\Wishwell\`

   That folder must contain `Wishwell.toc`.

2. Restart WoW.
3. Type `/ww` (or `/wishwell`), or click the minimap button.

## What it does

The window is Wishwell's own: dark, with rounded corners. Your character is on the left, the list on the right, and five tabs run down the right edge: **Wisp**, **Next**, **Gear** (Loot, Wishlist, Sets), **Quests** and **Me** (Training, Professions, Legacy, Characters). Gear and Me show their pages as buttons in the header. Settings has a "Smooth look" switch if you prefer the game's own window art.

**Wisp** (the first tab, or the Ask box at the top of the window, or `/ww ask ...`)

- Type a question and Wisp answers from Wishwell's own data, as a chat: where an item drops, what a boss drops, a dungeon or raid, a quest, an item set. It is a look-up, not an AI, and it works offline.
- It knows this game's raid and dungeon loot, its quests and its item sets. It does not know where NPCs stand or who sells what.

**What next? tab** (the first tab)
- One screen for "what should I do now?": the best quest where you are, the zones with the most quest XP waiting, what your spells will cost and whether you can afford them, a dungeon for your level with how many upgrades it has for you, and your wishlist.
- Click any line to go straight to it.

**Upgrade tips everywhere**
- Hover any item anywhere in the game (bags, vendors, the auction house, loot) and the tooltip says whether it is an upgrade for you and what changes.
- When a loot roll starts on an upgrade, chat tells you it is worth a Need roll.
- When a quest offers a choice of rewards, Wishwell labels the best one for you. If none improves your gear, it says which sells for the most.
- It says why: for example "The 16 Spirit you gain is worth more to a Mage than the 3 Intellect you lose", with a warning when you give up a key stat and a note when a stat does nothing for your class.
- Wishwell only advises. It never rolls, picks or equips anything.

**Level-up pop-up and first-time tips**
- When you level, the wisp shows what just opened up: new spells and their cost, quests you can now take, a dungeon now in range, and where the most quest XP is.
- The first time you see a loot roll, a reward choice or a trainer, the wisp explains it once.

**Drop rates**
- Item rows show the Classic drop chance where one is known. Hover an item to see how many runs that means on average.
- Wishwell also counts every boss kill it sees and what dropped. After ten kills of a boss it shows your own count ("seen 3 of 12 kills") and plans with that.
- What next? names the run with the best odds of a wishlist drop.
- Classic rates are a guide: WoW Forever may have changed them.

**Gold goals**
- What next? shows what you are saving for and how far along you are. Under level 40 it suggests a first mount at the Classic price.
- Click the line, or type `/ww goal 100 Epic mount`, to set your own. `/ww goal off` removes it.
- After half an hour of play it estimates how long the rest will take at today's pace.

**Professions tab**
- Open a profession window once. Wishwell reads the recipes you know and lists the ones that will raise your skill, in the game's own colours: orange always gives a point, yellow usually does.
- Each recipe shows its materials and how many you can make from your bags. Hover it to see what you are short of.
- Nothing is shipped for this, so it is always exactly what your character knows.

**Characters tab**
- Every character that has logged in with Wishwell: level, XP needed for the next level, gold, wishlist size and spells waiting to be trained, with the gold total across them.

**Group wishlists**
- When you walk into a raid or dungeon, group members who have Wishwell see what you want there, and you see what they want.
- The loot list marks items "Wanted by <name>", and a wishlist alert says if someone else wants the item too. `/ww share` turns sharing off.

**Legacy tab**
- Your Legacy challenges, read from the game: how many are done, how many Legacy points you have to spend, and every unfinished challenge with the ones nearest to done at the top. Hover one for its steps and reward.

**Settings**
- The **Settings** button in the top-right corner lists every switch: pop-ups, the wisp, sounds, upgrade tips, first-time tips, wishlist sharing and the minimap button. Window size steps through four sizes. Wishlist drop alert turns the message for a wishlist drop on or off, and Tell my group also says it in party or raid chat.

**Run summary**
- When you leave a raid or dungeon after killing a boss, a pop-up sums up the run: bosses down, wishlist items you got, ones that dropped but got away, and new drops added to the loot list.

**Chat links**
- Shift-click any item row to put its link in the chat box. `/ww link` puts your wishlist for the dungeon you are in there, ready to send.

**Loot tab**
- Pick any raid or dungeon, then a boss. When you walk into a dungeon the list jumps to it.
- Type in the search box to search every raid and dungeon at once. Shift-click any item link into the box (or type an item ID) to look up something that isn't listed.
- Filter by **zone**, **class** (your own, any other, or all), **rarity** and **slot**. Picking a zone shows every dungeon in it. **Clear filters** puts everything back. Item names are coloured by rarity, the same colours the game uses.
- Click a row to try the item on your character. Drag the character to turn it. **Reset** under the character puts your own gear back.
- Click **Wish** on a row to add it to your wishlist.
- Items better than what you are wearing are marked **Upgrade**, and the best one for each slot **Best upgrade**. Hover an item to see exactly which stats you would gain and lose against your current piece. Tick **Upgrades first** to sort by how much each item improves your gear.
- The stat differences are the game's own numbers. The upgrade verdict is a rule of thumb based on what each class usually values, not a simulation.

**My wishlist tab**
- Everything you want, from every raid and dungeon.
- **Try on wishlist** dresses your character in all of it at once. **Reset** puts your real gear back.
- **Clear wishlist** empties the list (it asks first).

**Item sets tab**
- Tier sets, dungeon sets, PvP sets and the new WoW Forever sets: 197 in all, filtered to what your class can wear.
- Type to find a set by name. Hover a set to see its pieces and set bonuses.
- Click a set to put the whole thing on your character and list its pieces. Click **Wish** on the pieces you want, or **Wish all** for the whole set. **< Back to all sets** goes back, and so does clicking the Item sets tab again.
- For a few new sets the piece list is not known yet. The addon asks the game for those when you open them.

**Quests tab**
- Every Classic quest your character can do, by zone, with the XP it gives at your level. The best XP is at the top.
- **Where I am** follows the zone you are standing in. You can also pick any zone, **Everywhere**, class quests or profession quests.
- Class-only and race-only quests are shown only to characters who can take them, and say who they are for.
- **Only what I can do now** hides quests you are too low for or that need another quest first. Untick it to plan ahead; each row says what it is waiting for.
- Quests you have outlevelled show the smaller XP they would really give now. Finished quests drop off the list.
- New WoW Forever quests are added as you pick them up, with their real XP, and then show for every character on the account. Until then the list is Classic's, with Classic XP values.

**Spell training tab**
- Visit your class trainer once. The addon reads the trainer's list, so the spells and prices are exactly what the game charges you.
- Spells you can train now are grouped at the top with their total cost. Below that, each upcoming level lists its spells and what that level will cost.
- The top line shows ready-now, the next level, and everything left to train.
- When you level up, chat tells you how many new spells there are and the total.
- Visit the trainer again to refresh the list (for example after a patch, or when your prices change).
- If the tab stays empty after a visit, stand at the trainer with its window open and type `/ww trainer`. It prints what the addon can see.

**Alerts**
- When a wishlist item drops or comes up for a roll, you get a message on screen, a sound and a chat line.
- When you loot it, it comes off the list.
- Each time you enter a raid or dungeon, a small pop-up shows what drops there for your class, wishlist items first. Upgrades are counted and listed right after wishlist items. Click it to open the loot list; it fades by itself. The Raid Night wisp drifts around it (`/ww wisp` hides the wisp).

## Where the loot list comes from

- **Shipped lists.** Dungeon loot and dungeon quest rewards come from the WoW Forever loot tables at [wowtbc.gg](https://wowtbc.gg/warcraftforever/loot-tables/), which track what has been seen in the game.
- **Classic loot, not confirmed.** Items nobody has seen in Forever yet show their Classic loot as a stand-in, marked on each row.
- **Seen dropping.** The addon remembers what it sees drop (rare or better, plus green drops from dungeon bosses) and shares it with group members who have the addon. A raid or dungeon it has never heard of is added the first time you step inside. Rares and bosses out in the world are recorded under **World bosses and rares**.

To update the shipped lists: `node scripts/fetch-forever-loot.mjs`, `node scripts/fetch-forever-sets.mjs`, `node scripts/fetch-forever-droprates.mjs` and `node scripts/fetch-forever-quests.mjs`, then `node scripts/build-forever-data.mjs`.

## Commands

| Command | What it does |
| --- | --- |
| `/ww` | Open / close the window |
| `/ww next` | Open on the What next? tab |
| `/ww loot` | Open on the Loot tab |
| `/ww sets` | Open on the Item sets tab |
| `/ww train` | Open on the Spell training tab |
| `/ww quests` | Open on the Quests tab |
| `/ww clear` | Empty your wishlist (asks first) |
| `/ww popup` | Turn the dungeon pop-up on or off |
| `/ww wisp` | Hide or show the wisp on the pop-up |
| `/ww prof` | Open on the Professions tab |
| `/ww legacy` | Open on the Legacy tab |
| `/ww settings` | Open the settings |
| `/ww pins` | Put your pinned recipes away, or bring them back |
| `/ww link` | Put your wishlist in the chat box |
| `/ww alts` | Open on the Characters tab |
| `/ww goal 100 Epic mount` | Set a gold goal (`/ww goal off` removes it) |
| `/ww share` | Turn group wishlist sharing on or off |
| `/ww tips` | Turn upgrade tips on tooltips, rolls and quest rewards on or off |
| `/ww hints` | Turn the wisp's first-time tips on or off |
| `/ww sound` | Turn the alert sound on or off |
| `/ww minimap` | Hide or show the minimap button |

## Credits

- Dungeon loot, quest rewards and set bonuses: the WoW Forever loot tables at [wowtbc.gg](https://wowtbc.gg/warcraftforever/loot-tables/).
- Classic stand-in loot and Classic set pieces: [AtlasLootClassic](https://github.com/Hoizame/AtlasLootClassic).
- Classic drop rates: [AtlasLootClassic](https://github.com/Hoizame/AtlasLootClassic).
- Quest list and quest XP: the Classic tables from [Questie](https://github.com/Questie/Questie).
- Wisp character: original art made for Raid Night.

## Planned

Gear swapping for situational gear, an Undermine Reel tracker, and camping objects in the Professions tab.

## CurseForge upload

1. Zip the **Wishwell** folder (the zip should contain `Wishwell/Wishwell.toc`, not loose files).
2. Log into [CurseForge](https://authors.curseforge.com/) → **Create project** → World of Warcraft.
3. Name: **Wishwell Forever**. Category: **Bags & Inventory** (and **Tooltip** or **Class** if it lets you pick more). Supported game: **Forever**.
4. Project image: `logo-400.png`. Redraw it with `node scripts/make-wishwell-logo.mjs`.
5. Paste the text from `CURSEFORGE.md` as the long description, and `CHANGELOG.md` as the file's changelog.
6. Upload `Wishwell-<version>.zip`.

You have to upload from your own CurseForge account.
