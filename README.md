# Wishwell: overview for a reviewer

A map of the Wishwell addons for someone reading the project cold: what they are, what has been built, how the code is laid out, where the data comes from, and the decisions behind it.

Repository: https://github.com/ally0666/wishwell. This is a copy of the Wishwell addons on their own. They are developed in the `wishwell` branch of https://github.com/ally0666/raid-night, alongside other projects.

## The addons

| Addon | Game | Folder | Main file |
|---|---|---|---|
| **Wishwell TBC** | WoW TBC Anniversary (Interface 20506) | `wow-addon/WishwellTBC/` | `WishwellTBC.lua` (about 10,900 lines) |
| Wishwell TBC: World data | same, loads only when Wisp is asked something | `wow-addon/WishwellTBC_World/` | `Data.lua` (3.5 MB, generated) |
| **Wishwell** | WoW Forever beta (Interface 16001) | `wow-addon/Wishwell/` | `Wishwell.lua` (about 10,500 lines) |

Each addon is standalone: its own folder, saved variables (`WishwellTBCDB`, `WishwellDB`) and data. Neither shares code with Raid Night, Raid Night Forever or Chalkboard, which are separate projects kept in the raid-night repository.

Both are at version 1.2.0. Release zips are in `wow-addon/` (`WishwellTBC-1.2.0.zip`, `Wishwell-1.2.0.zip`).

## Where to read

Raw links open as plain text, which is easier for a tool to read than the GitHub page.

- Feature descriptions: [WishwellTBC/README.md](https://raw.githubusercontent.com/ally0666/wishwell/main/wow-addon/WishwellTBC/README.md), [Wishwell/README.md](https://raw.githubusercontent.com/ally0666/wishwell/main/wow-addon/Wishwell/README.md)
- What changed in each version: [WishwellTBC/CHANGELOG.md](https://raw.githubusercontent.com/ally0666/wishwell/main/wow-addon/WishwellTBC/CHANGELOG.md), [Wishwell/CHANGELOG.md](https://raw.githubusercontent.com/ally0666/wishwell/main/wow-addon/Wishwell/CHANGELOG.md)
- Code: [WishwellTBC.lua](https://raw.githubusercontent.com/ally0666/wishwell/main/wow-addon/WishwellTBC/WishwellTBC.lua), [Wishwell.lua](https://raw.githubusercontent.com/ally0666/wishwell/main/wow-addon/Wishwell/Wishwell.lua)
- Tests: [scripts/check-addon.mjs](https://raw.githubusercontent.com/ally0666/wishwell/main/scripts/check-addon.mjs)
- Store page text for Forever: [Wishwell/CURSEFORGE.md](https://raw.githubusercontent.com/ally0666/wishwell/main/wow-addon/Wishwell/CURSEFORGE.md)
- Browse everything: https://github.com/ally0666/wishwell/tree/main/wow-addon

The generated data files (`Data.lua`, `DataQuests.lua`, `DataTalents.lua`, `DataBis.lua`, and the world `Data.lua`) are large tables. Read the build scripts below to see what is in them.

## What it does

The idea: one window that answers "what should I do, and what gear should I want?" for a player at any level, alone or in a group.

- **Loot database.** Every raid and dungeon drop (TBC: normal and heroic lists), item sets filtered by class, a try-on character model, preloading so items show at once.
- **Wishlist.** Mark what you want; an alert when it drops or comes up for a roll; a movable on-screen tracker; optional sharing with group members who run Wishwell; optional line in party or raid chat.
- **Upgrade advice.** Item tooltips anywhere say whether an item is an upgrade and why, by stat priority for the build. Advice on loot rolls and quest reward choices. Wishwell only advises; it never rolls, picks or equips.
- **Wisp.** A chat-style question box. It is an offline look-up with a conversational voice, not an AI. It answers:
  - where an item drops, who sells it, what a boss or creature drops (with chances), where an NPC is, what a quest needs;
  - questions about the player: stat check against caps, best-in-slot check (TBC), "Check me" audit of talents, stats and gear;
  - how the game works (TBC): mount speed, caps, rested XP, heroic keys and so on;
  - mechanics questions ("why do I pull so much threat?") from the player's own talent, spell, gear and buff tooltips, quoted word for word;
  - abbreviations ("what is SSC?" asks "do you mean the raid?"), small talk, follow-ups and yes/no.
- **What next?** One page: best quest here, zones with the most quest XP, training costs, a dungeon for your level.
- **Quests.** Quest lists with XP, a quest guide window (TBC), map pins.
- **Me.** Talent builds with a tree view and a button that spends points in order (TBC), spell training costs, professions with what gives skill, alts, and on Forever a Legacy page.
- **Pinned recipes.** A Pin recipe button on the profession window keeps a recipe and its materials on screen for auction house shopping.
- **Look.** Smooth dark rounded panels with custom art, five grouped tabs, a welcome page, window size in four steps, settings in four sections, minimap button, closes in combat.

Forever has less data than TBC: raid and dungeon loot, the Classic quest list and item sets. It has no NPC locations, vendors, crafting, talents, best-in-slot lists or how-it-works answers yet.

## How the code is laid out

Each addon is one Lua file made of modules, each a local table in a `do ... end` block. In `WishwellTBC.lua`, in order:

`Places`, `Items`, `Sets`, `Compare` (stat weights and upgrade verdicts), `Wish` (wishlist and drop alerts), `Quests`, `Train`, `Chars`, `Prof`, `MapPin`, `Talents`, `Settings`, `Home` (What next?), `Ask` (Wisp), then the window (`UI`), `Toast` (the wisp's speech bubble), `Watch` (loot and kill tracking), `Advice`, `Guide`, `Tracker`, `Pins`, and the event handler and slash commands at the end.

Inside `Ask`: `Norm`/`Fit`/`Close` (matching, including fuzzy), `Search`, `AboutItem`/`AboutNpc`/`AboutQuest`/`AboutZone`, `StatCheck`, `BisCheck`, `Audit`, `Mechanics` (tooltip reading), `HOW` (how-it-works topics), `Meanings` (abbreviations), `Guess` (keyword intent), `SmallTalk`, and `Ask.Answer`, which decides which of those handles a question.

`Wishwell.lua` (Forever) was produced by a three-way merge from the TBC file and then adjusted: level cap 60, a Legacy page, no talents, guide, world data or best-in-slot lists, and its own pinned recipes code for that game's profession window.

## Where the data comes from

| Data | Source | Build script |
|---|---|---|
| TBC loot and item sets | AtlasLootClassic | `scripts/build-wishwell-tbc.mjs` |
| Quests, NPCs, items, vendors, quest objectives | Questie v10.5.1 | `scripts/build-wishwell-tbc.mjs`, `scripts/build-wishwell-tbc-world.mjs` |
| Crafting and reputation rewards | AtlasLootClassic | `scripts/build-wishwell-tbc-world.mjs` |
| Creature drop chances and world drops | CMaNGOS TBC database (community reconstruction) | `scripts/build-wishwell-tbc-world.mjs` |
| Talent trees and builds | see script | `scripts/build-wishwell-tbc-talents.mjs` |
| Best-in-slot lists | wowsims gear presets | `scripts/build-wishwell-tbc-bis.mjs` |
| Stat priorities | Icy Veins TBC Classic guides | in `WishwellTBC.lua` (`Compare`) |
| Forever loot | wowtbc.gg loot tables | `scripts/fetch-forever-loot.mjs`, `scripts/build-forever-data.mjs` |
| Forever quests | Questie Classic Era tables | `scripts/fetch-forever-quests.mjs` |
| Art (rounded panels, wisp icon) | generated | `scripts/make-wishwell-tbc-art.mjs` |

## Tests and build scripts

The scripts in `scripts/` are here to read. They were written to run inside the raid-night repository: the build scripts read source data from its `src/data/` folder, and `check-addon.mjs` also tests the Raid Night addons, so it stops when it cannot find them here.

`node scripts/check-addon.mjs` (after `npm i --no-save fengari`) runs the real Lua files in a Lua interpreter against a fake WoW API and checks behaviour for every addon in the repository. All checks pass at the time of writing. The fake is not the game: things that depend on the real client's API (tooltips, the profession window) are checked by playing.

## Decisions and limits

- **Terms of use.** No memory reading, no input automation. The addon reads only what the addon API gives and never acts for the player in combat, rolls or equipping.
- **No internet from inside the game.** An addon cannot make web requests. A companion desktop app to bridge to an AI was considered and rejected as too much for an addon. Wisp therefore answers from bundled data and the player's own tooltips. TBC item, NPC and quest answers include a Wowhead link to copy; a question Wisp cannot answer does not redirect there.
- **Verified information.** Mechanics answers quote the game's own tooltips. Guesses from forums are not used. Two exceptions are stated in the addon's own text: drop chances come from a community reconstruction, and the how-it-works topics are written summaries of long-settled TBC rules.
- **Left out on purpose:** attunement chains, riding prices, dual spec, arena and honor (no source considered reliable for Anniversary); Wrath of the Lich King data.

## Open items

- Forever: how-it-works answers with level 60 numbers; stat priorities reviewed for a level 60 game.
- TBC: loot from skinning, pickpocketing, fishing, chests and disenchanting is in the source database but not built in.
- Whether talent tooltips fill on the Anniversary client for the threat answer and the tree hover has a fallback but is unconfirmed.

---

# Starting a new WoW addon from this project

This part is for an AI agent using Wishwell as the template for a new addon. It gives the files every addon needs, the patterns that held up here, and the mistakes that cost time.

## The files

An addon is a folder in `Interface\AddOns\` whose name matches its `.toc` file.

**`MyAddon/MyAddon.toc`** lists the files in load order. Data files go before the code that reads them.

```
## Interface: 20506
## Title: My Addon
## Notes: One sentence on what it does.
## Author: Name
## Version: 1.0.0
## SavedVariables: MyAddonDB
## IconTexture: Interface\Icons\INV_Misc_Note_02

Data.lua
MyAddon.lua
```

`## Interface` must match the client: 20506 for TBC Anniversary, 16001 for the WoW Forever beta. Read it off an addon that already loads on that client.

**A big data set goes in its own load-on-demand addon**, so the game only reads it when it is needed. Wishwell TBC does this with 3.5 MB of world data:

```
## Interface: 20506
## Title: My Addon: World data
## Dependencies: MyAddon
## LoadOnDemand: 1

Data.lua
```

The main addon loads it with `C_AddOns.LoadAddOn("MyAddon_World")` (or `LoadAddOn` on older clients) the first time it is wanted.

**`MyAddon/MyAddon.lua`**, the smallest useful shape:

```lua
local ADDON = ...
local db

-- Some values the game hands over cannot be read by addons. Treat those as missing.
local function Plain(value)
  if issecretvalue and issecretvalue(value) then return nil end
  return value
end

local function Print(text)
  DEFAULT_CHAT_FRAME:AddMessage("|cffffd100My Addon:|r " .. text)
end

-- One module per job, each in its own block so its locals stay private.
local Things = {}
do
  function Things.Count()
    return #(db.things or {})
  end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:SetScript("OnEvent", function(_, event, name)
  if event == "ADDON_LOADED" and name == ADDON then
    MyAddonDB = type(MyAddonDB) == "table" and MyAddonDB or {}
    db = MyAddonDB
  elseif event == "PLAYER_REGEN_DISABLED" then
    -- A fight has started: put windows away.
  end
end)

SLASH_MYADDON1 = "/my"
SlashCmdList.MYADDON = function(msg)
  msg = strlower(strtrim(msg or ""))
  if msg == "count" then Print(Things.Count() .. " things.") return end
  Print("/my count")
end
```

**Generated data** is a plain global table written by a build script, never by hand:

```lua
-- Generated by scripts/build-my-data.mjs. Do not edit by hand.
MyAddonData = {
  -- [id] = { name, level, { dropped by }, how many drop it }
  items = {
    [31336] = { "Blade of Wizardry", 100, { 25363, 25367 }, 674 },
  },
}
```

Rows are arrays, not named fields: at tens of thousands of rows it keeps the file and memory small. Put what each position means in a comment above the table and in the build script.

**Also in the folder:** `README.md` (what it does, how to install, where the data comes from), `CHANGELOG.md` (one section per version, newest first), any `.tga` art and `.ogg` sounds.

## Writing code that survives different clients

The Classic clients do not agree on their API. The same job has different function names on different clients, and a function can exist but do nothing.

- **Ask before you call.** `local count = (C_Item and C_Item.GetItemCount) or GetItemCount`, then check it is not nil.
- **Wrap doubtful calls in `pcall`** and check the result did something. A tooltip call can succeed and leave the tooltip empty, so count its lines afterwards and fall back (for a talent: `SetTalent`, then `SetHyperlink(GetTalentLink(...))`).
- **Run everything from the game through `Plain()`** before comparing or doing arithmetic on it.
- **Professions are the clearest split.** TBC uses `GetTradeSkillInfo`, `GetTradeSkillSelectionIndex` and a separate `CraftFrame` for Enchanting. The Forever client uses `C_TradeSkillUI` and `ProfessionsFrame`. A feature that reads the profession window is written twice.
- **Item names and icons arrive late.** `GetItemInfo` returns nil for an item the client has not seen. Ask once in the background to preload, and redraw on `GET_ITEM_INFO_RECEIVED`.
- **Frames with a backdrop** need `BackdropTemplateMixin and "BackdropTemplate" or nil` as the template.
- **Never show, hide or move a protected frame in combat.** Wishwell closes its own window when a fight starts, which avoids the whole class of problem.
- **Esc to close:** `tinsert(UISpecialFrames, "MyAddonFrame")`. Opening the world map over it will close it too, so give the user a button back.

## What an addon may not do

- No reading game memory, no automating key presses or clicks, no acting for the player in combat. Advise; let the player act.
- No web requests. Anything the addon knows ships with it or comes from the game's API.
- Chat to SAY, YELL and public channels needs a real key press or click. PARTY and RAID do not, but make any message other players see a setting that starts off.

## Testing without the game

`scripts/check-addon.mjs` runs the real Lua files in fengari (Lua 5.3 in Node) against a fake WoW API, then asserts on what the addon did. Copy this pattern on day one; it is what let features land without breaking earlier ones.

```js
const game = makeGame({ addon: { name: 'MyAddon', files: ['Data.lua', 'MyAddon.lua'] } })
const run = (lua, label) => game.run(lua, label)          // run Lua in the addon's world
const ev = (code) => run(`return ${code}`, 'check')       // read a value back
run(`SlashCmdList.MYADDON("count")`, 'count')
check('it says how many', /0 things/.test(ev(`table.concat(Fake.printed, "|")`)))
```

The fake keeps every frame it creates in `Fake.frames`, records `SetText`, `Show`, `SetScale` and the like as plain fields, and fires events with `Fake.Fire("EVENT", ...)`. Tests click things by calling `frame.scripts.OnClick()`.

Limits to remember:

- The game is Lua 5.1 and fengari is 5.3. `strupper`, `strbyte` and `math.atan2` are missing in the fake; use `string.upper`, `string.byte` and `(math.atan2 or math.atan)`.
- `tonumber(tip:NumLines())` breaks when the fake returns nothing. Write `tonumber((tip:NumLines()))`.
- In the fake, `SetText` on an edit box does not fire `OnTextChanged`, and `Show()` does not fire `OnShow`. Fire them from the test.
- Tests share state. A test that reads "the first shown row" breaks when an earlier test leaves rows behind; match on the row's name.
- The fake proves logic, not the client. Say which parts you could not check, once, and ask the user one specific question about them.

## The working loop

1. Make the change with a small Node script that replaces exact text and **fails unless the text matches exactly once**. On a 10,000-line file this is safer than hand edits, and the same script can patch two sister addons in one go.
2. Write that script to a file. Shell heredocs break on Lua's quotes and backticks.
3. If a script that patches several files fails part-way, the first files are already changed. Finish with a second script for the rest; do not rerun the first.
4. Keep Lua files on LF line endings.
5. Run `node scripts/check-addon.mjs`, and add a check for the new behaviour in the same change.
6. Copy the changed files into the game's `Interface\AddOns\` folder. The user types `/reload`. A new file in the `.toc`, or a `.toc` change, needs the game restarted.
7. Rebuild the release zip with the addon folder at its top level: `tar.exe -a -c -f MyAddon-1.0.0.zip MyAddon`.
8. Commit and push only when the user asks. Keep each addon's files apart from other projects in the same repository.

## Getting data

- Build from open data sets with a script, cache the downloads in the temp folder, and commit the generated Lua. Sources used here: AtlasLootClassic (loot, sets, crafting, reputation), Questie (quests, NPCs, items, objects), wowsims (gear presets), CMaNGOS (creature loot tables with chances).
- Questie's and AtlasLoot's files are Lua tables: run them through fengari and print rows out, instead of parsing Lua with regular expressions.
- CMaNGOS ships as a SQL dump. Loot tables point at shared "reference" tables; flatten those to get an item's real chance, and treat an item that many creatures can drop as a world drop described by levels and zones, not a list of names.
- Check the result against items you know before wiring it in. This is how it was found that Questie has no world drops.
- Say in the README where each kind of data comes from and how sure it is.
- A filter that lives in the download step does nothing until the cache is refreshed.

## A question box without an AI

Wisp reads as conversational with no model behind it. The parts, in the order `Ask.Answer` tries them:

1. Clean the text: lower case, punctuation off.
2. Yes or no to something just offered (`Ask.pending` holds the question to run on "yes").
3. Small talk and greetings.
4. Strip filler words off both ends to find the subject: "what does attumen the huntsman drop" becomes "attumen the huntsman".
5. Special cases by keyword: best-in-slot check, abbreviations, how-it-works topics, stat check, questions about the player.
6. Search names for the subject: exact, starts-with, contains, all words present, then fuzzy matching for typos. Try plurals as singulars.
7. Keyword scoring for intent when nothing matched by name.
8. Only then say it found nothing, with examples to click.

What made it feel good: colour for who, where and what; a line about the player's own character wherever the game will give it; remembering the last topic so "where is he?" works; offering a follow-up; and never changing its remarks on every redraw (put them on a timer).

What went wrong and the rule that fixed it: a single common word in a question matched a quest or item with that word in its name. Check for question intent ("why", "how", "work") before falling back to fewer words, and test both directions: the question that should match a topic, and the look-up that contains the same word and should not.

## Working with the user

- She plays the real game with the addon loaded while it is being built. Do not recommend a play-test or repeat that something is unverified in the client.
- Do not take control of her screen while she is playing.
- Requests arrive as a screenshot and a sentence. Do the thing, say what changed in plain words, and name anything left out and why.
- When a request can be read two ways and both are cheap, build both as separate settings and say so.
- Anything other players will see starts switched off.
- Version bumps and pushes are hers to call.
