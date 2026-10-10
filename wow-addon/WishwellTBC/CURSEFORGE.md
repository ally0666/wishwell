# Wishwell TBC

A loot database and helper for **The Burning Crusade Anniversary**, in the game. See what drops anywhere, try it on your character, mark what you want, and get told the moment it drops. Ask Wisp, the little helper in the window, where anything is. Works solo at any level; nobody else needs it installed.

Type `/ww` or click the minimap button.

## What it does

**Ask Wisp**
- Type a question and get an answer as a chat: where an item drops and how often, who sells it, where an NPC stands, what a boss or creature drops, what a quest needs.
- It also knows what is skinned, pickpocketed, fished up, found in chests, crafted, or sold for reputation.
- Ask about yourself: "check my stats", "am I in best-in-slot gear?", or **Check me** for a look over your talents, stats and gear.
- Ask how the game works: "how does mount speed work?", "what is the hit cap?", "how do heroics work?".
- "Why do I pull so much threat?" is answered from your own talents, spells and gear, quoting their tooltips.
- Wisp is a look-up that works offline, not an AI. When it has no answer it says so and offers a Send button so you can tell the author what you asked.

**What next?**
- One screen for "what should I do now?": the best quest where you are, the zones with the most quest XP, what your spells will cost, a dungeon for your level, and your wishlist.

**Loot and wishlist**
- Every TBC and Classic raid and dungeon, by boss, with normal and heroic lists. Walk into a dungeon and its list opens.
- Click an item to see it on your character. Click **Wish** on what you want.
- When a wishlist item drops or comes up for a roll you get a message, a sound and a chat line. A small tracker keeps your wishlist on screen.
- Item sets by class, with their bonuses.

**Upgrade tips everywhere**
- Hover any item in the game (bags, vendors, loot, the auction house): the tooltip says whether it is an upgrade for your build, what changes stat by stat, and why.
- Loot rolls and quest reward choices are labelled the same way.

**Quests**
- Every quest from level 1 to 70 by zone, for your class and race, best XP first, with a map pin on the quest giver.
- **Guide me** opens a small window that walks you through your quests, nearest stop first.

**Your character**
- **Talents:** your three trees with a build for your role, and a button that spends your points in order when you say yes.
- **Training:** what you can learn at each level and what it costs.
- **Professions:** the recipes that will raise your skill and whether you have the materials.
- **Pinned recipes:** pin a recipe from the profession window and its materials stay on screen while you shop at the auction house.
- **Characters:** level, XP, gold and wishlist for every character you play.

**What Wishwell will not do**
- It never rolls, picks or equips anything. The one thing it does for you is spend talent points, and only when you click the button and confirm.
- Nothing is sent anywhere. It reads only what the game gives every addon.

## Install

The zip holds two folders. Put both in `Interface\AddOns\` inside your TBC Anniversary game folder (`_anniversary_`):

- `WishwellTBC`
- `WishwellTBC_World` (the data behind Wisp; it only loads when you ask something)

## Commands

| Command | What it does |
|---|---|
| `/ww` | Open or close the window |
| `/ww ask where is Hogger` | Ask Wisp a question |
| `/ww settings` | Open the settings |
| `/ww news` | What changed in this version |
| `/ww pins` | Put your pinned recipes away, or bring them back |
| `/ww guide` | Open the quest guide |
| `/ww help` | List every command |

## Where the data comes from

- Loot, item sets, crafting and reputation rewards: [AtlasLootClassic](https://github.com/Hoizame/AtlasLootClassic).
- Quests, NPCs, items, vendors and quest objectives: [Questie](https://github.com/Questie/Questie).
- Talent trees, builds and best-in-slot lists: [wowsims TBC](https://github.com/wowsims/tbc).
- What creatures drop and how often, with skinning, pickpocketing, fishing and chests: the [CMaNGOS TBC database](https://github.com/cmangos/tbc-db). It is a community reconstruction of the loot tables, so the chances are close, not exact.
- Stat priorities follow the Icy Veins TBC Classic guides.
