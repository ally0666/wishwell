// Runs the addon's Lua against a small fake WoW and checks the WoW Forever loot learning.
//   npm i --no-save fengari   (once)
//   node scripts/check-addon.mjs
import { existsSync, readFileSync } from 'node:fs'
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
let fengari
try {
  fengari = require('fengari')
} catch {
  console.error('fengari is not installed. Run: npm i --no-save fengari')
  process.exit(1)
}
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = fengari

// Two separate addons: the TBC one must keep working untouched, the Forever one is where new work goes.
const TBC = { name: 'RaidNight', files: ['Data.lua', 'RaidNight.lua'] }
const FOREVER = { name: 'RaidNightForever', files: ['DataForever.lua', 'RaidNightForever.lua'] }
const WISHLIST = { name: 'Wishwell', files: ['DataForever.lua', 'DataQuests.lua', 'Wishwell.lua'] }
// Wishwell for TBC Anniversary: a separate addon with its own data and saved settings.
const WISHTBC = { name: 'WishwellTBC', files: ['Data.lua', 'DataQuests.lua', 'DataTalents.lua', 'DataBis.lua', 'WishwellTBC.lua'] }
const folder = (addon) => new URL(`../wow-addon/${addon.name}/`, import.meta.url)

// A fake WoW written in Lua: just enough of the game for the addon to load and run.
const FAKE_WOW = String.raw`
strmatch, strlower, strsub, strfind, gsub, gmatch, strrep, strlen, format =
  string.match, string.lower, string.sub, string.find, string.gsub, string.gmatch, string.rep, string.len, string.format
tinsert, tremove = table.insert, table.remove
unpack = unpack or table.unpack
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function strsplit(sep, text, limit)
  local out, start = {}, 1
  while true do
    if limit and #out == limit - 1 then out[#out + 1] = text:sub(start) break end
    local i = text:find(sep, start, true)
    if not i then out[#out + 1] = text:sub(start) break end
    out[#out + 1] = text:sub(start, i - 1)
    start = i + 1
  end
  return unpack(out)
end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end

Fake = { toc = TOC or 16001, build = BUILD or "1.60.1", now = 100, timers = {}, sent = {}, printed = {},
  instance = { "Onyxia's Lair", "raid", 1, "", 40, 0, false, 249 }, group = 0, leader = true,
  tried = {}, quality = {}, facts = {}, cached = {}, tooltips = {}, names = {} }

function GetBuildInfo() return Fake.build, "1", "now", Fake.toc end
function GetTime() return Fake.now end
C_Timer = { After = function(delay, fn) tinsert(Fake.timers, { at = Fake.now + delay, fn = fn }) end }
function Fake.Advance(seconds)
  local target = Fake.now + seconds
  while true do
    local best
    for i, t in ipairs(Fake.timers) do
      if t.at <= target and (not best or t.at < Fake.timers[best].at) then best = i end
    end
    if not best then break end
    local t = tremove(Fake.timers, best)
    Fake.now = math.max(Fake.now, t.at)
    t.fn()
  end
  Fake.now = target
end

-- Any widget: every method exists and returns another widget (or a number where one is needed).
local widgetMeta = {}
local function Widget() return setmetatable({ scripts = {}, events = {} }, widgetMeta) end
local numeric = { GetValue = 0, GetWidth = 100, GetHeight = 20, GetLeft = 0, GetTop = 0, GetStringWidth = 50,
  GetStringHeight = 12, GetEffectiveScale = 1, GetNumPoints = 0, GetCenter = 0, GetBottom = 0, GetRight = 0, GetScale = 1 }
widgetMeta.__index = function(self, key)
  if key == "SetScript" or key == "HookScript" then return function(w, name, fn) w.scripts[name] = fn end end
  if key == "GetScript" then return function(w, name) return w.scripts[name] end end
  if key == "RegisterEvent" then return function(w, ev) w.events[ev] = true end end
  if key == "IsShown" or key == "IsVisible" then return function(w) return rawget(w, "shown") == true end end
  if key == "Show" then return function(w) rawset(w, "shown", true) end end
  if key == "SetShown" then return function(w, on) rawset(w, "shown", on and true or false) end end
  if key == "Hide" then return function(w) rawset(w, "shown", false) end end
  if key == "SetText" then return function(w, text) rawset(w, "text", text) end end
  if key == "SetScale" then return function(w, value) rawset(w, "scale", value) end end
  if key == "SetAttribute" then return function(w, name, value) w.attrs = rawget(w, "attrs") or {} rawget(w, "attrs")[name] = value end end
  if key == "SetTextColor" then return function(w, r, g, b) rawset(w, "color", format("%.2f,%.2f,%.2f", r, g, b)) end end
  if key == "GetText" then return function(w) return rawget(w, "text") or "" end end
  if key == "GetName" then return function(w) return rawget(w, "name") or "FakeWidget" end end
  if key == "ScrollBar" then return nil end
  if key == "TryOn" then return function(w, what) tinsert(Fake.tried, what) end end
  if key == "Dress" then return function() Fake.tried = {} end end
  if numeric[key] then return function() return numeric[key] end end
  if type(key) == "string" and (key:match("^Create") or key:match("^Get")) then
    return function() return Widget() end
  end
  if type(key) == "string" and key:match("^%u") then return function() end end
  return nil
end
Fake.frames = {}
Fake.templates = {} -- Blizzard templates this fake game "has"; see the native-look test
local NATIVE = { ButtonFrameTemplate = true, InsetFrameTemplate = true, LargeSideTabButtonTemplate = true, SearchBoxTemplate = true }
function CreateFrame(kind, name, parent, template)
  if template and NATIVE[template] and not Fake.templates[template] then
    error("Couldn't find inherited node: " .. template)
  end
  local w = Widget()
  if template == "ButtonFrameTemplate" then
    rawset(w, "Inset", Widget())
    rawset(w, "SetTitle", function(self, text) rawset(self, "title", text) end)
    rawset(w, "SetPortraitToAsset", function(self, tex) rawset(self, "portrait", tex) end)
  elseif template == "LargeSideTabButtonTemplate" then
    rawset(w, "Icon", Widget())
    rawset(w, "SetCustomOnMouseUpHandler", function(self, fn) rawset(self, "mouseUp", fn) end)
    rawset(w, "SetChecked", function(self, on) rawset(self, "checked", on and true or false) end)
  end
  rawset(w, "template", template)
  rawset(w, "name", name)
  if name then _G[name] = w end
  tinsert(Fake.frames, w)
  return w
end
UIParent, Minimap, GameTooltip, DEFAULT_CHAT_FRAME = Widget(), Widget(), Widget(), Widget()
DEFAULT_CHAT_FRAME.AddMessage = function(_, msg) tinsert(Fake.printed, msg) end
SlashCmdList = {}
StaticPopupDialogs = {}
UISpecialFrames = {}
function StaticPopup_Show() end
function UIDropDownMenu_SetWidth() end
function UIDropDownMenu_SetText(w, text) rawset(w, "text", text) end
function UIDropDownMenu_CreateInfo() return {} end
Fake.menu = {}
function UIDropDownMenu_AddButton(info, level) tinsert(Fake.menu, { text = info.text, level = level or 1, arrow = info.hasArrow, func = info.func }) end
function UIDropDownMenu_Initialize(w, fn) rawset(w, "init", fn) end
function FauxScrollFrame_Update() end
function FauxScrollFrame_GetOffset() return 0 end
function FauxScrollFrame_SetOffset() end
function FauxScrollFrame_OnVerticalScroll() end
function PlaySound() end
function PlaySoundFile() return true end
function hooksecurefunc() end
function GetCursorPosition() return 0, 0 end
function IsShiftKeyDown() return false end
function CloseDropDownMenus() end

function UnitName(unit) if unit == "player" then return "Tester" end return Fake.targetName end
function UnitClass() return "Mage", "MAGE" end
function UnitRace() return "Gnome", "Gnome" end
function UnitExists(unit) return Fake.targetName ~= nil end
function UnitIsDead() return true end
function UnitClassification() return Fake.targetClass or "normal" end
function UnitLevel() return 60 end
function UnitIsGroupLeader(unit) return unit == "player" and Fake.leader end
function IsInRaid() return Fake.group > 0 end
function IsInGroup() return Fake.group > 0 end
function GetNumGroupMembers() return Fake.group end
function GetRaidRosterInfo(i)
  if i == 1 then return "Tester", Fake.leader and 2 or 0, 1, 60, "Mage", "MAGE" end
  if i == 2 then return "Leaderguy", Fake.leader and 0 or 2, 1, 60, "Warrior", "WARRIOR" end
  return "Raider" .. i, 0, 1, 60, "Priest", "PRIEST"
end
function GetInstanceInfo() return unpack(Fake.instance) end

C_ChatInfo = {
  RegisterAddonMessagePrefix = function() return true end,
  SendAddonMessage = function(prefix, payload, channel) tinsert(Fake.sent, payload) return 0 end,
  SendChatMessage = function() end,
  InChatMessagingLockdown = function() return Fake.lockdown == true end,
}
Enum = { SendAddonMessageResult = { AddOnMessageLockdown = 11 } }
C_Item = {
  GetItemNameByID = function(id) return Fake.names[id] end,
  GetItemIconByID = function() return 134400 end,
  GetItemQualityByID = function(id) return Fake.quality[id] end,
  RequestLoadItemDataByID = function() end,
  IsItemDataCachedByID = function(id) return Fake.cached[id] ~= false end,
  GetItemInfoInstant = function(id)
    local f = Fake.facts[id] or {}
    return id, "", "", f.equipLoc or "", 134400, f.classID, f.subclassID
  end,
}
C_TooltipInfo = { GetItemByID = function(id) return { lines = Fake.tooltips[id] or { { leftText = "Item" } } } end }
ITEM_CLASSES_ALLOWED = "Classes: %s"
ITEM_RACES_ALLOWED = "Races: %s"
LOOT_ITEM = "%s receives loot: %s."
LOOT_ITEM_SELF = "You receive loot: %s."
LOOT_ITEM_PUSHED_SELF = "You receive item: %s."
LOOT_ITEM_PUSHED = "%s receives item: %s."
LOOT_ITEM_CREATED_SELF = "You create: %s."
LOOT_ITEM_CREATED = "%s creates: %s."

function Fake.Fire(event, ...)
  for _, w in ipairs(Fake.frames) do
    if w.events[event] and w.scripts.OnEvent then w.scripts.OnEvent(w, event, ...) end
  end
end
function Fake.Link(id, color, name) return "|c" .. color .. "|Hitem:" .. id .. "::::::::60:::::|h[" .. name .. "]|h|r" end
`

function makeGame({ addon, also, toc, build, saved }) {
  const L = lauxlib.luaL_newstate()
  lualib.luaL_openlibs(L)
  const run = (code, name) => {
    if (lauxlib.luaL_loadbuffer(L, to_luastring(code), null, to_luastring(name)) || lua.lua_pcall(L, 0, 1, 0)) {
      throw new Error(`${name}: ${to_jsstring(lua.lua_tostring(L, -1))}`)
    }
    const type = lua.lua_type(L, -1)
    let value
    if (type === lua.LUA_TSTRING) value = to_jsstring(lua.lua_tostring(L, -1))
    else if (type === lua.LUA_TNUMBER) value = lua.lua_tonumber(L, -1)
    else if (type === lua.LUA_TBOOLEAN) value = lua.lua_toboolean(L, -1)
    lua.lua_pop(L, 1)
    return value
  }
  run(`TOC = ${toc}; BUILD = "${build}"; ${saved || ''}`, 'setup')
  run(FAKE_WOW, 'fake-wow')
  const loaded = also ? [also, addon] : [addon]
  for (const one of loaded) {
    for (const file of one.files) run(readFileSync(new URL(file, folder(one)), 'utf8'), file)
    run(`Fake.Fire("ADDON_LOADED", "${one.name}")`, 'loaded')
  }
  run(`Fake.Fire("PLAYER_LOGIN"); Fake.Advance(10)`, 'login')
  return run
}

let failed = 0
function check(label, ok) {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${label}`)
  if (!ok) failed++
}

// ---- WoW Forever -----------------------------------------------------------
{
  const run = makeGame({ addon: FOREVER, toc: 16001, build: '1.60.1' })
  const ev = (code) => run(`return ${code}`, 'check')

  check('Forever loads the full raid and dungeon list', ev(`#RaidNightForeverData.instances`) >= 30)
  check('Onyxia stand-in loot is present', ev(`(function() for _, i in ipairs(RaidNightForeverData.items) do if i.id == 17068 and i.raid == "onyxia" and i.standin then return true end end end)()`) === true)

  // Boss dies in Onyxia's Lair, then loot shows up three different ways.
  run(`Fake.group = 5
    Fake.Fire("ENCOUNTER_END", 1084, "Onyxia", 9, 40, 1)
    Fake.quality[266200] = 4
    Fake.Fire("CHAT_MSG_LOOT", "Raider3 receives loot: " .. Fake.Link(266200, "ffa335ee", "New Forever Helm") .. ".")
    Fake.Fire("CHAT_MSG_LOOT", "Raider3 receives loot: |cnIQ4:|Hitem:266201::::|h[New Ring]|h|r.")
    GetLootRollItemLink = function() return Fake.Link(266202, "ff0070dd", "Blue Boots") end
    Fake.Fire("START_LOOT_ROLL", 1)
    GetNumLootItems = function() return 2 end
    GetLootSlotLink = function(slot) return slot == 1 and Fake.Link(266203, "ffa335ee", "Scale") or Fake.Link(266204, "ff1eff00", "Green Junk") end
    GetLootSourceInfo = function() return "Creature-0-1-2-3-10184-0" end
    Fake.Fire("LOOT_OPENED")`, 'drops')
  check('drop from chat is filed under the boss', ev(`RaidNightForeverDB.learned.onyxia[266200]`) === 'Onyxia')
  check('new-style quality link is understood', ev(`RaidNightForeverDB.learned.onyxia[266201]`) === 'Onyxia')
  check('group-loot roll is recorded', ev(`RaidNightForeverDB.learned.onyxia[266202]`) === 'Onyxia')
  check('loot window is recorded', ev(`RaidNightForeverDB.learned.onyxia[266203]`) === 'Onyxia')
  check('green items are ignored', ev(`RaidNightForeverDB.learned.onyxia[266204] == nil`) === true)

  run(`Fake.Fire("CHAT_MSG_LOOT", "You receive item: " .. Fake.Link(266210, "ffa335ee", "Quest Reward") .. ".")
    Fake.Fire("CHAT_MSG_LOOT", "Raider3 creates: " .. Fake.Link(266211, "ffa335ee", "Crafted Thing") .. ".")
    Fake.facts[266212] = { classID = 7 }
    Fake.Fire("CHAT_MSG_LOOT", "Raider3 receives loot: " .. Fake.Link(266212, "ff0070dd", "Brilliant Shard") .. ".")`, 'not-drops')
  check('quest rewards, crafts and disenchant shards are not recorded',
    ev(`RaidNightForeverDB.learned.onyxia[266210] == nil and RaidNightForeverDB.learned.onyxia[266211] == nil and RaidNightForeverDB.learned.onyxia[266212] == nil`) === true)

  run(`Fake.Advance(30)`, 'share')
  const sent = ev(`table.concat(Fake.sent, "\\n")`)
  check('new drops are shared with the group', /^L:onyxia:[\d,]*266200[\d,]*:Onyxia$/m.test(sent))
  check('every shared message fits in one addon message', sent.split('\n').every((line) => line.length <= 255))

  // Loot long after the kill counts as trash.
  run(`Fake.Advance(400)
    Fake.Fire("CHAT_MSG_LOOT", "Raider3 receives loot: " .. Fake.Link(266220, "ffa335ee", "Trash Epic") .. ".")`, 'trash')
  check('late loot is filed under Trash', ev(`RaidNightForeverDB.learned.onyxia[266220]`) === 'Trash')

  // A raid the addon has never heard of.
  run(`Fake.instance = { "The Brand New Raid", "raid", 1, "", 20, 0, false, 3456 }
    Fake.Fire("ENCOUNTER_END", 9001, "Lord: Newguy|cff", 9, 20, 1)
    Fake.Fire("CHAT_MSG_LOOT", "Raider3 receives loot: " .. Fake.Link(270001, "ffa335ee", "Shiny") .. ".")`, 'new-raid')
  check('an unknown raid is added on the spot', ev(`RaidNightForeverDB.madeUp.m3456 and RaidNightForeverDB.madeUp.m3456.name`) === 'The Brand New Raid')
  check('its loot is recorded with a cleaned boss name', ev(`RaidNightForeverDB.learned.m3456[270001]`) === 'Lord Newguy cff')

  // A failed pull must not name the boss.
  run(`Fake.instance = { "Hyjal Summit", "raid", 1, "", 20, 0, false, 3500 }
    Fake.Fire("ENCOUNTER_END", 9002, "Bandalar", 9, 20, 0)
    Fake.Fire("CHAT_MSG_LOOT", "Raider3 receives loot: " .. Fake.Link(270010, "ffa335ee", "Wipe Loot") .. ".")`, 'wipe')
  check('a wipe does not credit the boss', ev(`RaidNightForeverDB.learned.fhyjal[270010]`) === 'Trash')

  // World boss outdoors, and ordinary outdoor loot.
  run(`Fake.instance = { "Kalimdor", "none", 0, "", 0, 0, false, 1 }
    Fake.Fire("CHAT_MSG_LOOT", "You receive loot: " .. Fake.Link(270020, "ffa335ee", "Random World Epic") .. ".")
    Fake.Fire("ENCOUNTER_END", 9003, "Big Outdoor Dragon", 0, 40, 1)
    Fake.Fire("CHAT_MSG_LOOT", "Raider3 receives loot: " .. Fake.Link(270021, "ffa335ee", "Dragon Loot") .. ".")`, 'world')
  check('ordinary outdoor loot is ignored', ev(`RaidNightForeverDB.learned.world == nil or RaidNightForeverDB.learned.world[270020] == nil`) === true)
  check('world boss loot is recorded', ev(`RaidNightForeverDB.learned.world[270021]`) === 'Big Outdoor Dragon')

  // Messages from other players.
  run(`Fake.leader = false
    Fake.Fire("CHAT_MSG_ADDON", "RaidNightForever", "L:barrow:266300,266301:Elder Tangleclaw", "RAID", "Raider3-Realm")
    Fake.Fire("CHAT_MSG_ADDON", "RaidNightForever", "L:nosuchplace:266302:Boss", "RAID", "Raider3-Realm")
    Fake.Fire("CHAT_MSG_ADDON", "RaidNightForever", "N:m7777:raid:Raid: From A Friend", "RAID", "Raider3-Realm")
    Fake.Fire("CHAT_MSG_ADDON", "RaidNightForever", "N:m8888:raid:Leader's New Raid", "RAID", "Leaderguy-Realm")
    Fake.Fire("CHAT_MSG_ADDON", "RaidNightForever", "N:evil:raid:Bad Id", "RAID", "Leaderguy-Realm")`, 'messages')
  check('drops shared by a raider are learned', ev(`RaidNightForeverDB.learned.barrow[266300]`) === 'Elder Tangleclaw' && ev(`RaidNightForeverDB.learned.barrow[266301]`) === 'Elder Tangleclaw')
  check('drops for an unknown place are ignored', ev(`RaidNightForeverDB.learned.nosuchplace == nil`) === true)
  check('only the leader can add a raid', ev(`RaidNightForeverDB.madeUp.m7777 == nil`) === true && ev(`RaidNightForeverDB.madeUp.m8888.name`) === "Leader's New Raid")
  check('a made-up id that is not m<number> is refused', ev(`RaidNightForeverDB.madeUp.evil == nil`) === true)

  // Raider hears the sheet start and reports how much it knows; leader fills in the rest.
  run(`Fake.sent = {}
    Fake.Fire("CHAT_MSG_ADDON", "RaidNightForever", "R:onyxia:2:0", "RAID", "Leaderguy-Realm")
    Fake.Advance(5)`, 'sheet')
  check('raider tells the leader how many drops it knows', /^K:onyxia:\d+$/m.test(ev(`table.concat(Fake.sent, "\\n")`)))
  run(`Fake.leader = true
    Fake.sent = {}
    RaidNightForeverDB.shared = true
    RaidNightForeverDB.instanceId = "onyxia"
    Fake.Fire("CHAT_MSG_ADDON", "RaidNightForever", "K:onyxia:0", "RAID", "Raider3-Realm")
    Fake.Advance(60)`, 'fill')
  const filled = ev(`table.concat(Fake.sent, "\\n")`)
  check('leader sends its list to a raider who knows less', /^L:onyxia:.*:Onyxia$/m.test(filled) && /^L:onyxia:.*:Trash$/m.test(filled))

  // Messages wait during a boss fight.
  run(`Fake.sent = {}
    Fake.lockdown = true
    Fake.instance = { "Onyxia's Lair", "raid", 1, "", 40, 0, false, 249 }
    Fake.Fire("CHAT_MSG_LOOT", "Raider3 receives loot: " .. Fake.Link(266230, "ffa335ee", "Mid Fight") .. ".")
    Fake.Advance(20)`, 'lockdown')
  check('nothing is sent while the game blocks addon messages', !/266230/.test(ev(`table.concat(Fake.sent, "\\n")`)))
  run(`Fake.lockdown = false; Fake.Advance(20)`, 'unlock')
  check('it goes out once the fight is over', /266230/.test(ev(`table.concat(Fake.sent, "\\n")`)))

  // The window: list, labels, class and race filtering.
  run(`Fake.facts[16963] = { classID = 4, subclassID = 4, equipLoc = "INVTYPE_HEAD" }   -- plate helm
    Fake.facts[16914] = { classID = 4, subclassID = 1, equipLoc = "INVTYPE_HEAD" }      -- cloth helm
    Fake.tooltips[16914] = { { leftText = "Netherwind Crown" }, { leftText = "Classes: Mage" } }
    Fake.facts[16921] = { classID = 4, subclassID = 1, equipLoc = "INVTYPE_HEAD" }      -- cloth, priest only
    Fake.tooltips[16921] = { { leftText = "Halo of Transcendence" }, { leftText = "Classes: Priest" } }
    Fake.facts[17078] = { classID = 4, subclassID = 1, equipLoc = "INVTYPE_CLOAK" }
    Fake.tooltips[266200] = { { leftText = "New Forever Helm" }, { leftText = "Races: Dwarf, Skyborne" } }
    Fake.names[266203] = "Scale of Somebody"
    SlashCmdList.RAIDNIGHTFOREVER("")`, 'open-window')
  const shown = `(function(id) for i = 1, 400 do local b = _G["RaidNightItemProbe"] end
    for _, w in ipairs(Fake.frames) do local it = rawget(w, "item") if it and it.id == id then return rawget(w.meta, "text") or "?" end end return nil end)`
  const listed = (id) => ev(`(function() RaidNightForeverDB.showAll = false RaidNightForever_Refresh()
    for _, w in ipairs(Fake.frames) do local it = rawget(w, "item") if it and it.id == ${id} then return true end end return false end)()`)
  check('mage sees the mage tier helm', listed(16914) === true)
  check('mage does not see the plate helm', listed(16963) === false)
  check('mage does not see the priest-only helm', listed(16921) === false)
  check('gnome does not see a race-locked item', listed(266200) === false)
  check('stand-in label is shown', ev(`${shown}(16914)`) === 'Head · Onyxia · Classic loot, not confirmed')
  run(`Fake.Fire("CHAT_MSG_ADDON", "RaidNightForever", "L:onyxia:16914:Onyxia", "RAID", "Raider3-Realm")`, 'confirm')
  check('stand-in item seen dropping is marked', (listed(16914), ev(`${shown}(16914)`)) === 'Head · Onyxia · Seen dropping')

  // Raid picker: raids on top, dungeons in a submenu.
  run(`Fake.menu = {} rawget(RaidNightForeverInstanceDrop, "init")(RaidNightForeverInstanceDrop, 1)`, 'menu1')
  const top = ev(`(function() local t = {} for _, m in ipairs(Fake.menu) do t[#t + 1] = m.text end return table.concat(t, "|") end)()`)
  check('raid picker lists raids and a Dungeons entry', top.startsWith("The Barrow Deeps|Hyjal Summit|Onyxia's Lair|World bosses") && top.endsWith('Dungeons') && !top.includes('Stratholme'))
  run(`Fake.menu = {} rawget(RaidNightForeverInstanceDrop, "init")(RaidNightForeverInstanceDrop, 2, "dungeons")`, 'menu2')
  const sub = ev(`(function() local t = {} for _, m in ipairs(Fake.menu) do t[#t + 1] = m.text end return table.concat(t, "|") end)()`)
  check('Dungeons submenu has new and old dungeons', sub.includes('Hall of Thanes') && sub.includes('Stratholme') && !sub.includes('Hyjal'))
  check('no Lua errors were printed', !/error/i.test(ev(`table.concat(Fake.printed, "\\n")`)))
}

// ---- Saved data survives a reload -------------------------------------------
{
  const run = makeGame({ addon: FOREVER,
    toc: 16001,
    build: '1.60.1',
    saved: `RaidNightForeverDB = { instanceId = "m3456", madeUp = { m3456 = { name = "The Brand New Raid", kind = "raid" }, bad = { name = "x" } },
      learned = { m3456 = { [270001] = "Lord Newguy" }, gone = { [1] = "x" }, onyxia = "junk" }, picks = { m3456 = { 270001 } } }`,
  })
  const ev = (code) => run(`return ${code}`, 'check')
  check('a raid added in game is still there after a reload', ev(`RaidNightForeverDB.instanceId`) === 'm3456' && ev(`RaidNightForeverDB.learned.m3456[270001]`) === 'Lord Newguy')
  check('picks for it are kept', ev(`RaidNightForeverDB.picks.m3456[1]`) === 270001)
  check('broken saved data is cleaned up', ev(`RaidNightForeverDB.learned.gone == nil and RaidNightForeverDB.learned.onyxia == nil and RaidNightForeverDB.madeUp.bad == nil`) === true)
}

// ---- TBC Anniversary is unchanged ---------------------------------------------
{
  const run = makeGame({ addon: TBC, toc: 20506, build: '2.5.6' })
  const ev = (code) => run(`return ${code}`, 'check')
  check('TBC window and slash command exist', ev(`type(SlashCmdList.RAIDNIGHT) == "function" and type(RaidNight_Toggle) == "function"`) === true)
  check('TBC still uses the TBC raid list', ev(`RaidNightData.instances[1].id`) === 'karazhan' && ev(`#RaidNightData.instances`) === 9)
  run(`Fake.instance = { "Karazhan", "raid", 1, "", 10, 0, false, 532 }
    Fake.group = 5
    Fake.Fire("ENCOUNTER_END", 652, "Attumen", 3, 10, 1)
    Fake.Fire("CHAT_MSG_LOOT", "Raider3 receives loot: " .. Fake.Link(99999, "ffa335ee", "Thing") .. ".")
    Fake.Fire("CHAT_MSG_ADDON", "RaidNight", "L:karazhan:99999:Attumen", "RAID", "Raider3-Realm")
    Fake.Advance(30)
    SlashCmdList.RAIDNIGHT("")`, 'tbc')
  check('TBC records nothing', ev(`RaidNightDB.learned == nil`) === true)
  const meta = ev(`(function() for _, w in ipairs(Fake.frames) do local it = rawget(w, "item") if it and it.id == 28507 then return rawget(w.meta, "text") end end end)()`)
  check('TBC item rows look the same as before', meta === 'Hands · Attumen')
  check('TBC window opens with items', ev(`(function() local n = 0 for _, w in ipairs(Fake.frames) do if rawget(w, "item") then n = n + 1 end end return n end)()`) > 0)
}

// ---- Raid Night Forever window: three tabs, real Forever loot --------------------
{
  const run = makeGame({ addon: FOREVER, toc: 16001, build: '1.60.1' })
  const ev = (code) => run(`return ${code}`, 'check')
  run(`SlashCmdList.RAIDNIGHTFOREVER("")`, 'open')
  check('Raid Night Forever has three tabs and no wishlist',
    ev(`(function() local t = RaidNightForeverFrame.tabs return t.picks and t.group and t.raid and t.wish == nil and true end)()`) === true
      && ev(`RaidNightForeverDB.page`) === 'picks' && ev(`RaidNightForeverDB.wish == nil`) === true)
  check('every Forever raid and dungeon is in its data', ev(`#RaidNightForeverData.instances`) === 32 && ev(`#RaidNightForeverData.items`) > 1700)
  run(`Fake.instance = { "Hall of Thanes", "party", 1, "", 5, 0, false, 9001 }
    Fake.Fire("PLAYER_ENTERING_WORLD") Fake.Advance(5)`, 'enter')
  check('the window follows you into a dungeon when no sheet is running', ev(`RaidNightForeverDB.instanceId`) === 'thanes')
  const rows = ev(`(function() RaidNightForever_Refresh() local t = {} for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it then t[#t + 1] = it.id .. "=" .. (rawget(w.meta, "text") or "") end end return table.concat(t, "|") end)()`)
  check('loot seen in Forever shows with no "not confirmed" label', /270227=Neck · Faldrim Anvilmar(\||$)/.test(rows))
  run(`Fake.group = 5 Fake.leader = true
    RaidNightForeverDB.shared = true`, 'sheet')
  const first = ev(`(function() for _, w in ipairs(Fake.frames) do local it = rawget(w, "item") if it then return it.id end end end)()`)
  run(`for _, w in ipairs(Fake.frames) do local it = rawget(w, "item") if it and w.scripts.OnClick then w.scripts.OnClick(w, "LeftButton") break end end`, 'click')
  check('a click reserves', ev(`RaidNightForeverDB.picks.thanes[1]`) === first)
  check('no Lua errors were printed', !/error/i.test(ev(`table.concat(Fake.printed, "\\n")`)))
}

// ---- Wishwell: its own addon ----------------------------------------------
{
  const run = makeGame({ addon: WISHLIST, toc: 16001, build: '1.60.1' })
  const ev = (code) => run(`return ${code}`, 'check')
  const printed = () => ev(`table.concat(Fake.printed, "\\n")`)
  const wish = (id) => ev(`WishwellDB.wish and WishwellDB.wish["Tester-"] and WishwellDB.wish["Tester-"][${id}]`)
  const rowsText = () => ev(`(function() local t = {} for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") then t[#t + 1] = it.id .. "=" .. (rawget(w.meta, "text") or "") end end return table.concat(t, "|") end)()`)
  const rowDo = (id, what) => run(`for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and it.id == ${id} and rawget(w, "shown") then
      if "${what}" == "wish" then rawget(w, "wish").scripts.OnClick() else w.scripts.OnClick(w, "LeftButton") end
      break
    end end`, 'row')

  check('it has its own saved settings and data', ev(`type(WishwellDB) == "table" and RaidNightForeverDB == nil and RaidNightDB == nil`) === true)
  check('it ships every Forever raid and dungeon', ev(`#WishwellData.instances`) === 32 && ev(`#WishwellData.items`) > 1700)

  // Walk into a dungeon, open the window.
  run(`WishwellDB.popped = nil Fake.instance = { "Hall of Thanes", "party", 1, "", 5, 0, false, 9001 }
    Fake.Fire("PLAYER_ENTERING_WORLD") Fake.Advance(5)
    SlashCmdList.WISHWELL("")`, 'enter')
  check('the window opens on the welcome page', ev(`WishwellDB.page`) === 'hub' && ev(`rawget(WishwellHub, "shown")`) === true)
  run(`SlashCmdList.WISHWELL("loot")`, 'loot')
  const toastText = () => ev(`(function() local t = WishwellToast if not t or not rawget(t, "shown") then return "" end
    local out = { rawget(t.title, "text") or "", rawget(t.sub, "text") or "" }
    for _, line in ipairs(t.lines) do if rawget(line.text, "shown") then out[#out + 1] = rawget(line.text, "text") or "" end end
    out[#out + 1] = rawget(t.foot, "text") or ""
    return table.concat(out, " // ") end)()`).replace(/\|c[0-9a-f]{8}|\|r/g, '')
  check('walking in shows a pop-up with the dungeon and its drops', /^Hall of Thanes \/\/ \d+ drops for your class/.test(toastText()) && /Faldrim Anvilmar/.test(toastText()))
  check('the pop-up shows five items and says how many more', toastText().split(' // ').length === 8 && /\+\d+ more\. Click to see them all\./.test(toastText()))
  check('the Loot tab is pointed at the dungeon you are in', ev(`WishwellDB.page`) === 'browse' && ev(`WishwellDB.browseId`) === 'thanes')
  check('the list shows that dungeon with real Forever items', /270227=Neck · Faldrim Anvilmar(\||$)/.test(rowsText()))
  check('the wishlist and the loot list are pages of the Gear tab', ev(`WishwellFrame.tabs.gear ~= nil and WishwellFrame.tabs.me ~= nil and WishwellFrame.tabs.wish == nil`) === true)

  // Character preview.
  rowDo(270227, 'click')
  check('clicking a row tries the item on the character', ev(`Fake.tried[#Fake.tried]`) === 'item:270227')
  check('clicking a row does not add it to the wishlist', wish(270227) === undefined)

  // Wish button.
  rowDo(270227, 'wish')
  check('the Wish button adds to the wishlist', wish(270227) === 'thanes')
  rowDo(271096, 'wish')
  run(`Wishwell_Toggle("wish")`, 'tab')
  check('the My wishlist tab lists what you want, with the dungeon name', /270227=Hall of Thanes · Neck · Faldrim Anvilmar/.test(rowsText()) && rowsText().split('|').length === 2)
  rowDo(271096, 'wish')
  check('the Wish button takes it off again', wish(271096) === undefined && rowsText().split('|').length === 1)
  run(`Fake.tried = {}
    for _, w in ipairs(Fake.frames) do if rawget(w, "text") == "Try on wishlist" and w.scripts.OnClick then w.scripts.OnClick() end end`, 'try-all')
  check('Try on wishlist dresses the character in everything on the list', ev(`table.concat(Fake.tried, ",")`) === 'item:270227')

  // Database search across every raid and dungeon.
  run(`Wishwell_Toggle("browse")
    for _, w in ipairs(Fake.frames) do if rawget(w, "name") == "WishwellSearch" then rawset(w, "text", "deathbringer") end end
    WishwellDB.popped = nil Fake.instance = { "Hall of Thanes", "party", 1, "", 5, 0, false, 9001 }`, 'search')
  run(`for _, w in ipairs(Fake.frames) do if rawget(w, "name") == "WishwellSearch" then w.scripts.OnTextChanged() end end`, 'search2')
  check('search looks through every raid and dungeon', /17068=Onyxia's Lair · .*Onyxia · .*Classic loot, not confirmed/.test(rowsText()))
  run(`for _, w in ipairs(Fake.frames) do if rawget(w, "name") == "WishwellSearch" then rawset(w, "text", "") w.scripts.OnTextChanged() end end`, 'clear')

  // Class, race and faction filtering.
  run(`UnitFactionGroup = function() return "Horde", "Horde" end
    Fake.facts[271098] = { classID = 4, subclassID = 3, equipLoc = "INVTYPE_CHEST" }   -- mail chest
    Wishwell_Toggle("browse")`, 'filters')
  const filtered = rowsText()
  check('a mage does not see mail armor', !/271098=/.test(filtered) && /270227=/.test(filtered))

  // Drops and alerts.
  run(`Fake.printed = {}
    Fake.quality[270227] = 3
    Fake.quality[279999] = 2
    Fake.group = 5
    Fake.Fire("ENCOUNTER_END", 1, "Faldrim Anvilmar", 1, 5, 1)
    GetLootRollItemLink = function() return Fake.Link(270227, "ff0070dd", "Ephemeral Choker") end
    Fake.Fire("START_LOOT_ROLL", 1)
    Fake.Fire("CHAT_MSG_LOOT", "Raider3 receives loot: " .. Fake.Link(279999, "ff1eff00", "New Green") .. ".")
    Fake.Advance(30)`, 'drops')
  check('a wishlist item on a roll gets an alert', /Wishlist item up for a roll: .*Ephemeral Choker/.test(printed()))
  check('new drops are learned under the boss', ev(`WishwellDB.learned.thanes[279999]`) === 'Faldrim Anvilmar')
  check('and shared with the group', /^L:thanes:[\d,]*279999[\d,]*:Faldrim Anvilmar$/m.test(ev(`table.concat(Fake.sent, "\\n")`)))
  run(`Fake.Fire("CHAT_MSG_ADDON", "Wishwell", "L:thanes:266300:Faldrim Anvilmar", "RAID", "Raider3-Realm")
    Fake.Fire("CHAT_MSG_ADDON", "Wishwell", "L:barrow:266301:Elder Tangleclaw", "RAID", "Raider3-Realm")`, 'recv')
  check('drops shared by others are learned for the place you are in', ev(`WishwellDB.learned.thanes[266300]`) === 'Faldrim Anvilmar')
  check('but not for a place you are not in', ev(`WishwellDB.learned.barrow == nil or WishwellDB.learned.barrow[266301] == nil`) === true)
  run(`Fake.Fire("CHAT_MSG_LOOT", "You receive loot: " .. Fake.Link(270227, "ff0070dd", "Ephemeral Choker") .. ".")`, 'got')
  check('looting a wishlist item takes it off the list', wish(270227) === undefined && /You got .*Ephemeral Choker/.test(printed()))

  // Coming back reminds you.
  run(`WishwellDB.wish["Tester-"][271096] = "thanes"
    WishwellDB.popped = nil
    Fake.printed = {}
    Fake.instance = { "Eastern Kingdoms", "none", 0, "", 0, 0, false, 0 }
    Fake.Fire("ZONE_CHANGED_NEW_AREA") Fake.Advance(5)
    WishwellDB.popped = nil Fake.instance = { "Hall of Thanes", "party", 1, "", 5, 0, false, 9001 }
    Fake.Fire("PLAYER_ENTERING_WORLD") Fake.Advance(5)`, 're-enter')
  check('coming back lists your wishlist items there', /Hall of Thanes: 1 wishlist item here - Aetherwisp Bracers\./.test(printed()))
  check('the pop-up puts wishlist items first', /1 on your wishlist \/\/ Wish  Aetherwisp Bracers/.test(toastText()))
  run(`WishwellToast.scripts.OnClick(WishwellToast, "LeftButton")`, 'toast-click')
  check('clicking the pop-up opens the loot list for that dungeon', ev(`WishwellDB.page`) === 'browse' && ev(`rawget(WishwellToast, "shown")`) === false)

  // Switch the pop-up off: a chat line instead.
  run(`SlashCmdList.WISHWELL("popup")
    Fake.printed = {}
    Fake.instance = { "Eastern Kingdoms", "none", 0, "", 0, 0, false, 0 }
    Fake.Fire("ZONE_CHANGED_NEW_AREA") Fake.Advance(5)
    WishwellDB.popped = nil Fake.instance = { "The Deadmines", "party", 1, "", 5, 0, false, 36 }
    Fake.Fire("PLAYER_ENTERING_WORLD") Fake.Advance(5)`, 'popup-off')
  check('/ww popup turns it off and gives a chat line instead', ev(`rawget(WishwellToast, "shown")`) === false && /Type \/ww to see what drops in The Deadmines/.test(printed()))

  // Clear the whole wishlist, with a question first.
  run(`WishwellDB.wish["Tester-"][270229] = "thanes"
    StaticPopup_Show = function(which, n) Fake.asked = which .. ":" .. tostring(n) end
    SlashCmdList.WISHWELL("clear")`, 'ask-clear')
  check('clearing the wishlist asks first', ev(`Fake.asked`) === 'WISHWELL_CLEAR:2' && wish(271096) === 'thanes')
  run(`StaticPopupDialogs.WISHWELL_CLEAR.OnAccept()`, 'clear')
  check('saying yes empties it', wish(271096) === undefined && wish(270229) === undefined && /Wishlist cleared \(2 items\)/.test(printed()))
  check('no Lua errors were printed', !/error/i.test(printed()))
}

// ---- Wishwell: item sets ------------------------------------------------
{
  const run = makeGame({ addon: WISHLIST, toc: 16001, build: '1.60.1' })
  const ev = (code) => run(`return ${code}`, 'check')
  const rows = () => ev(`(function() local t = {} for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") then t[#t + 1] = (it.name or it.id) .. "=" .. (rawget(w.meta, "text") or "") end end return table.concat(t, "|") end)()`)
  const search = (text) => run(`for _, w in ipairs(Fake.frames) do if rawget(w, "name") == "WishwellSearch" then
    rawset(w, "text", "${text}") w.scripts.OnTextChanged() end end`, 'search')
  const clickRow = (name) => run(`for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") and it.name == "${name}" then w.scripts.OnClick(w, "LeftButton") break end end`, 'click')

  check('Classic and new Forever sets ship with the addon, without Season of Discovery sets',
    ev(`#WishwellData.sets`) === 197
      && ev(`(function() for _, s in ipairs(WishwellData.sets) do if s.id >= 1000 and s.id < 2098 then return false end end return true end)()`) === true)

  run(`UnitClass = function() return "Warrior", "WARRIOR" end
    Fake.facts[16866] = { classID = 4, subclassID = 4, equipLoc = "INVTYPE_HEAD" }      -- Helm of Might, plate
    Fake.facts[280455] = { classID = 4, subclassID = 1, equipLoc = "INVTYPE_HEAD" }     -- Manaflare, cloth
    Fake.tooltips[280455] = { { leftText = "Manaflare piece" }, { leftText = "Classes: Mage" } }
    Fake.Fire("PLAYER_LOGIN")
    SlashCmdList.WISHWELL("sets")`, 'open')
  check('/ww sets opens the Item sets tab', ev(`WishwellDB.page`) === 'sets' && ev(`rawget(WishwellPage_sets, "shown")`) === true)

  search('might')
  check('searching finds a set by name', /Battlegear of Might=8 pieces · 3 set bonuses/.test(rows()))
  search('manaflare')
  check('a warrior does not see a mage-only set', !/Manaflare Regalia/.test(rows()))
  search('might')

  run(`Fake.tried = {}`, 'reset')
  clickRow('Battlegear of Might')
  check('clicking a set puts every piece on the character', ev(`#Fake.tried`) === 8 && ev(`Fake.tried[1]`) === 'item:16866')
  check('and lists its eight pieces', rows().split('|').length === 8)
  check('the class menu steps aside for Back and Wish all while a set is open', ev(`rawget(WishwellClassDrop, "shown")`) === false)
  check('the header shows the set name with a way back', ev(`(function() for _, w in ipairs(Fake.frames) do if rawget(w, "text") == "< Back to all sets" then return rawget(w, "shown") end end end)()`) === true)

  // Wish a piece from the set view.
  run(`for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") and it.id == 16866 then rawget(w, "wish").scripts.OnClick() break end end`, 'wish')
  check('pieces can be added to the wishlist from the set', ev(`WishwellDB.wish["Tester-"][16866] ~= nil`) === true)

  run(`for _, w in ipairs(Fake.frames) do if rawget(w, "text") == "< Back to all sets" and w.scripts.OnClick then w.scripts.OnClick() end end`, 'back')
  check('All sets goes back to the list', /Battlegear of Might=8 pieces/.test(rows()))

  // A set whose pieces are not shipped: ask the game.
  run(`C_LootJournal = { GetItemSetItems = function(id) if id == 2130 then return { { itemID = 290001 }, { itemID = 290002 }, { itemID = 290003 } } end return {} end }
    WishwellDB.classFilter = "ALL"
    Fake.tried = {}`, 'api')
  search('rider of the plaguelands')
  check('a set with no shipped piece ids says so', /Rider of the Plaguelands=3 pieces/.test(rows()))
  clickRow('Rider of the Plaguelands')
  check('and the game is asked for its pieces when opened', ev(`table.concat(Fake.tried, ",")`) === 'item:290001,item:290002,item:290003')
  check('no Lua errors were printed', !/error/i.test(ev(`table.concat(Fake.printed, "\\n")`)))
}

// ---- Wishwell: spell training ---------------------------------------------
{
  const run = makeGame({ addon: WISHLIST, toc: 16001, build: '1.60.1' })
  const ev = (code) => run(`return ${code}`, 'check')
  const strip = (text) => String(text).replace(/\|c[0-9a-f]{8}|\|r/g, '')
  const rows = () => strip(ev(`(function() local t = {} for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") and (it.header or it.train) then t[#t + 1] = (rawget(w.name, "text") or "") .. " = " .. (rawget(w.meta, "text") or "") end end
    return table.concat(t, " | ") end)()`))
  const status = () => strip(ev(`rawget(WishwellFrame.status, "text")`))

  // A fake class trainer. The player is level 10 and only ticks "available" in the filter.
  run(`Fake.level = 10
    UnitLevel = function() return Fake.level end
    Fake.trainer = {
      { "Fireball", "Rank 1", "used", 1, 10 },
      { "Fireball", "Rank 2", "available", 6, 100 },
      { "Frost Nova", "Rank 1", "available", 10, 600 },
      { "Fireball", "Rank 3", "unavailable", 12, 900 },
      { "Arcane Explosion", "Rank 1", "unavailable", 14, 1500 },
      { "Polymorph", "Rank 2", "unavailable", 20, 22000 },
      { "Mage", "", "header", 0, 0 },
    }
    Fake.filter = { available = true, unavailable = false, used = false }
    Fake.atTrainer = false
    local function visible()
      local t = {}
      if not Fake.atTrainer then return t end
      for _, row in ipairs(Fake.trainer) do if row[3] == "header" or Fake.filter[row[3]] then t[#t + 1] = row end end
      return t
    end
    GetNumTrainerServices = function() return #visible() end
    GetTrainerServiceInfo = function(i) local r = visible()[i] return r[1], r[2], r[3] end
    GetTrainerServiceLevelReq = function(i) return visible()[i][4] end
    GetTrainerServiceCost = function(i) return visible()[i][5], 0, 0 end
    GetTrainerServiceIcon = function() return 135812 end
    GetTrainerServiceTypeFilter = function(kind) return Fake.filter[kind] end
    SetTrainerServiceTypeFilter = function(kind, on) Fake.filter[kind] = on end
    IsTradeskillTrainer = function() return false end
    SlashCmdList.WISHWELL("train")`, 'setup')
  check('/ww train opens the Spell training tab', ev(`WishwellDB.page`) === 'train' && ev(`rawget(WishwellPage_train, "shown")`) === true)
  check('before a trainer visit it says to visit one', /Visit your class trainer once/.test(status()))

  run(`Fake.atTrainer = true Fake.Fire("TRAINER_SHOW") Fake.Advance(2)`, 'visit')
  check('the trainer list is read, including spells for later levels', ev(`WishwellDB.train["Tester-"].spells["Polymorph|Rank 2"].level`) === 20)
  const list = rows()
  check('spells you can train now are grouped with their total', /Ready to train now = 2 spells · total 7s \|/.test(list))
  check('upcoming levels each show their spells and total', /Level 12 = 1 spell · total 9s/.test(list) && /Level 14 = 1 spell · total 15s/.test(list) && /Level 20 = 1 spell · total 2g 20s/.test(list))
  check('each spell shows its rank and price', /Fireball  Rank 3 = 9s/.test(list))
  check('spells already known are left out', !/Rank 1 = 10c/.test(list))
  check('the summary gives ready-now, next level and everything left',
    /Ready now: 2 for 7s/.test(status()) && /Next at level 12: 1 for 9s/.test(status()) && /Everything left: 2g 51s/.test(status()))

  run(`Fake.Fire("TRAINER_CLOSED")`, 'close')
  check('your own trainer filters are put back afterwards', ev(`Fake.filter.unavailable == false and Fake.filter.used == false and Fake.filter.available == true`) === true)

  // Train one spell, then level up.
  run(`Fake.trainer[2][3] = "used"
    Fake.Fire("TRAINER_SHOW") Fake.Advance(2) Fake.Fire("TRAINER_CLOSED")
    Fake.printed = {}
    Fake.level = 12
    Fake.Fire("PLAYER_LEVEL_UP", 12)`, 'level')
  check('training a spell takes it off the list', !/Fireball  Rank 2/.test(rows()))
  check('levelling up says what is new and what it costs', /Level 12: 1 new spell to train, 9s in all\./.test(strip(ev(`table.concat(Fake.printed, "\\n")`))))
  check('and those spells move to Ready to train now', /Ready to train now = 2 spells · total 15s/.test(rows()))

  // Profession trainers are ignored.
  run(`IsTradeskillTrainer = function() return true end
    Fake.trainer = { { "Apprentice Cooking", "", "available", 1, 10 } }
    Fake.Fire("TRAINER_SHOW") Fake.Advance(2) Fake.Fire("TRAINER_CLOSED")`, 'profession')
  check('profession trainers are ignored', ev(`WishwellDB.train["Tester-"].spells["Apprentice Cooking|"] == nil`) === true)

  // Other tabs still show item rows with their Wish button.
  run(`WishwellDB.browseId = "thanes"
    Wishwell_Toggle("browse")`, 'back')
  check('other tabs are unaffected', ev(`(function() for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") and it.id then return rawget(rawget(w, "wish"), "shown") ~= false end end end)()`) === true)
  check('no Lua errors were printed', !/error/i.test(ev(`table.concat(Fake.printed, "\\n")`)))
}

// ---- Wishwell: filters, rarity colours, Wish all, slow-loading previews ----
{
  const run = makeGame({ addon: WISHLIST, toc: 16001, build: '1.60.1' })
  const ev = (code) => run(`return ${code}`, 'check')
  const ids = () => ev(`(function() local t = {} for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") and it.id then t[#t + 1] = it.id end end return table.concat(t, ",") end)()`)
  const pick = (drop, text) => run(`Fake.menu = {} rawget(${drop}, "init")(${drop}, 1)
    for _, m in ipairs(Fake.menu) do if m.text == "${text}" then m.func() end end`, 'pick')
  const colorOf = (id) => ev(`(function() for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") and it.id == ${id} then return rawget(w.name, "color") end end end)()`)

  run(`WishwellDB.browseId = "thanes"
    Fake.facts[271098] = { classID = 4, subclassID = 3, equipLoc = "INVTYPE_CHEST" }   -- mail chest
    Fake.facts[270229] = { classID = 4, subclassID = 3, equipLoc = "INVTYPE_FEET" }    -- mail boots
    SlashCmdList.WISHWELL("loot")`, 'open')
  check('by default the list is filtered to your own class', !/271098/.test(ids()) && /270227/.test(ids()))

  pick('WishwellClassDrop', 'Hunter')
  check('the class filter can show another class', /271098/.test(ids()) && ev(`WishwellDB.classFilter`) === 'HUNTER')
  pick('WishwellClassDrop', 'All classes')

  check('rarity ships with the data', ev(`(function() for _, i in ipairs(WishwellData.items) do if i.id == 270227 then return i.q end end end)()`) === 3)
  pick('WishwellRarityDrop', 'Uncommon')
  check('the rarity filter keeps only that rarity', /279899/.test(ids()) && !/270227/.test(ids()))
  check('uncommon items are green', colorOf(279899) === '0.12,1.00,0.00')
  pick('WishwellRarityDrop', 'Rare')
  check('rare items are blue', colorOf(270227) === '0.00,0.44,0.87')
  pick('WishwellRarityDrop', 'All rarities')

  pick('WishwellSlotDrop', 'Neck')
  check('the slot filter keeps only that slot', ids() === '270227')
  pick('WishwellSlotDrop', 'All slots')
  check('filters are remembered', ev(`WishwellDB.slot == "ALL" and WishwellDB.rarity == 0 and WishwellDB.classFilter == "ALL"`) === true)

  // A set whose items the game has not loaded yet.
  run(`for id = 16861, 16868 do Fake.cached[id] = false end
    Fake.tried = {}
    SlashCmdList.WISHWELL("sets")
    for _, w in ipairs(Fake.frames) do if rawget(w, "name") == "WishwellSearch" then rawset(w, "text", "battlegear of might") w.scripts.OnTextChanged() end end
    for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
      if it and rawget(w, "shown") and it.name == "Battlegear of Might" then w.scripts.OnClick(w, "LeftButton") break end end`, 'slow-set')
  check('pieces the game has not loaded yet are not tried on blind', ev(`#Fake.tried`) === 0)
  run(`for id = 16861, 16868 do Fake.cached[id] = true Fake.Fire("GET_ITEM_INFO_RECEIVED", id, true) end`, 'loaded')
  check('they go on the character as soon as they load', ev(`#Fake.tried`) === 8)

  run(`for _, w in ipairs(Fake.frames) do if rawget(w, "text") == "Wish all" and w.scripts.OnClick then w.scripts.OnClick() end end`, 'wish-all')
  check('Wish all adds every piece of the set to the wishlist', ev(`(function() local n = 0 for id = 16861, 16868 do
    if WishwellDB.wish["Tester-"][id] ~= nil then n = n + 1 end end return n end)()`) === 8)
  check('and says so once', /8 pieces of Battlegear of Might added to your wishlist/.test(ev(`table.concat(Fake.printed, "\\n")`)))
  check('no Lua errors were printed', !/error/i.test(ev(`table.concat(Fake.printed, "\\n")`)))
}

// ---- Wishwell: trainer on the newer game call, zone filter, Reset, Back -----
{
  const run = makeGame({ addon: WISHLIST, toc: 16001, build: '1.60.1' })
  const ev = (code) => run(`return ${code}`, 'check')
  const strip = (text) => String(text).replace(/\|c[0-9a-f]{8}|\|r/g, '')
  const trainRows = () => strip(ev(`(function() local t = {} for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") and (it.header or it.train) then t[#t + 1] = (rawget(w.name, "text") or "") .. " = " .. (rawget(w.meta, "text") or "") end end
    return table.concat(t, " | ") end)()`))
  const rows = () => ev(`(function() local t = {} for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") then t[#t + 1] = (it.name or it.id) .. "=" .. (rawget(w.meta, "text") or "") end end return table.concat(t, "|") end)()`)
  const pick = (drop, text) => run(`Fake.menu = {} rawget(${drop}, "init")(${drop}, 1)
    for _, m in ipairs(Fake.menu) do if m.text == "${text}" then m.func() end end`, 'pick')
  const press = (text) => run(`for _, w in ipairs(Fake.frames) do if rawget(w, "text") == "${text}" and w.scripts.OnClick then w.scripts.OnClick() break end end`, 'press')

  // The newer shape of the trainer call: name, kind, icon, level. No rank, no level function.
  run(`UnitLevel = function() return 10 end
    Fake.trainer = {
      { "Fireball", "used", 135812, 1, 10 },
      { "Fireball", "available", 135812, 6, 100 },
      { "Fireball", "unavailable", 135812, 12, 900 },
      { "Blink", "unavailable", 135736, 20, 20000 },
    }
    GetNumTrainerServices = function() return #Fake.trainer end
    GetTrainerServiceInfo = function(i) local r = Fake.trainer[i] return r[1], r[2], r[3], r[4] end
    GetTrainerServiceCost = function(i) return Fake.trainer[i][5] end
    GetTrainerServiceLevelReq = nil
    Fake.Fire("TRAINER_SHOW") Fake.Advance(2)
    SlashCmdList.WISHWELL("train")`, 'newer')
  const list = trainRows()
  check('the trainer list is read on the newer game call too', /Ready to train now = 1 spell · total 1s/.test(list) && /Level 20 = 1 spell · total 2g/.test(list))
  check('two ranks of one spell stay separate without a rank name', /Level 12 = 1 spell · total 9s/.test(list))
  run(`Fake.printed = {} SlashCmdList.WISHWELL("trainer")`, 'report')
  check('/ww trainer reports what the addon can see', /lines understood as spells: 4/.test(ev(`table.concat(Fake.printed, "\\n")`)))

  // Zone filter.
  run(`WishwellDB.classFilter = "ALL"
    SlashCmdList.WISHWELL("loot")`, 'loot')
  check('every raid and dungeon with a known location has a zone', ev(`(function() local n = 0 for _, r in ipairs(WishwellData.instances) do if r.zone then n = n + 1 end end return n end)()`) === 29)
  pick('WishwellZoneDrop', 'The Barrens')
  const barrens = rows()
  check('the zone filter shows every dungeon in that zone', /Wailing Caverns · /.test(barrens) && !/Hall of Thanes/.test(barrens)
    && ev(`rawget(WishwellPlaceDrop, "text")`) === 'All in The Barrens')
  run(`Fake.menu = {} rawget(WishwellPlaceDrop, "init")(WishwellPlaceDrop, 2, "dungeons")
    for _, m in ipairs(Fake.menu) do if m.text == "Hall of Thanes" then m.func() end end`, 'place')
  check('picking one dungeon turns the zone filter off', ev(`WishwellDB.zone`) === 'ALL' && /Faldrim Anvilmar/.test(rows()))

  pick('WishwellZoneDrop', 'Westfall')
  pick('WishwellRarityDrop', 'Rare')
  press('Clear filters')
  check('Clear filters puts every filter back', ev(`WishwellDB.zone == "ALL" and WishwellDB.rarity == 0 and WishwellDB.slot == "ALL" and WishwellDB.classFilter == "MINE"`) === true)

  // Reset and Back on the Sets tab.
  run(`WishwellDB.classFilter = "ALL"
    SlashCmdList.WISHWELL("sets")
    for _, w in ipairs(Fake.frames) do if rawget(w, "name") == "WishwellSearch" then rawset(w, "text", "battlegear of might") w.scripts.OnTextChanged() end end
    for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
      if it and rawget(w, "shown") and it.name == "Battlegear of Might" then w.scripts.OnClick(w, "LeftButton") break end end`, 'open-set')
  check('a set is on the character', ev(`#Fake.tried`) === 8)
  press('Reset')
  check('Reset puts your own gear back', ev(`#Fake.tried`) === 0)
  check('a Back button is showing while a set is open', ev(`(function() for _, w in ipairs(Fake.frames) do if rawget(w, "text") == "< Back to all sets" then return rawget(w, "shown") end end end)()`) === true)
  press('< Back to all sets')
  check('Back returns to the set list', /Battlegear of Might=8 pieces/.test(rows()))
  run(`for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
      if it and rawget(w, "shown") and it.name == "Battlegear of Might" then w.scripts.OnClick(w, "LeftButton") break end end
    Wishwell_Toggle("sets")`, 'tab-again')
  check('clicking the Sets tab again also goes back, with the search cleared',
    ev(`(function() for _, w in ipairs(Fake.frames) do if rawget(w, "name") == "WishwellSearch" then return rawget(w, "text") end end end)()`) === ''
      && rows().split('|').length === 9)
  check('no Lua errors were printed', !/error/i.test(ev(`table.concat(Fake.printed, "\\n")`)))
}

// ---- Wishwell: built on the game's own frames when they exist -------------
{
  const run = makeGame({ addon: WISHLIST, toc: 16001, build: '1.60.1' })
  const ev = (code) => run(`return ${code}`, 'check')
  run(`Fake.templates = { ButtonFrameTemplate = true, InsetFrameTemplate = true, LargeSideTabButtonTemplate = true, SearchBoxTemplate = true }
    WishwellDB.browseId = "thanes"
    WishwellDB.smooth = false -- the game's own window art, not Wishwell's rounded look
    SlashCmdList.WISHWELL("loot")`, 'open')
  check('the window uses the game frame, title and portrait', ev(`rawget(WishwellFrame, "template")`) === 'ButtonFrameTemplate'
    && ev(`rawget(WishwellFrame, "title")`) === 'Wishwell Forever' && ev(`rawget(WishwellFrame, "portrait") ~= nil`) === true)
  check('the tabs are the game side tabs, with the current one lit', ev(`rawget(WishwellFrame.tabs.gear, "template")`) === 'LargeSideTabButtonTemplate'
    && ev(`rawget(WishwellFrame.tabs.gear, "checked")`) === true && ev(`rawget(WishwellFrame.tabs.me, "checked")`) === false)
  run(`rawget(WishwellFrame.tabs.me, "mouseUp")(WishwellFrame.tabs.me, "LeftButton", true)`, 'tab')
  check('clicking a game side tab switches page', ev(`WishwellDB.page`) === 'train' && ev(`rawget(WishwellFrame.tabs.me, "checked")`) === true)
  run(`rawget(WishwellFrame.tabs.gear, "mouseUp")(WishwellFrame.tabs.gear, "RightButton", true)`, 'right')
  check('other mouse buttons do nothing', ev(`WishwellDB.page`) === 'train')
  check('the search box is the game search box', ev(`rawget(WishwellSearch, "template")`) === 'SearchBoxTemplate')
  check('no Lua errors were printed', !/error/i.test(ev(`table.concat(Fake.printed, "\\n")`)))
}

// ---- Wishwell: gear comparison and the wisp --------------------------------
{
  const run = makeGame({ addon: WISHLIST, toc: 16001, build: '1.60.1' })
  const ev = (code) => run(`return ${code}`, 'check')
  const strip = (text) => String(text).replace(/\|c[0-9a-f]{8}|\|r/g, '')
  const metaOf = (id) => strip(ev(`(function() for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") and it.id == ${id} then return rawget(w.meta, "text") end end end)()`))
  const order = () => ev(`(function() local t = {} for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") and it.id then t[#t + 1] = it.id end end return table.concat(t, ",") end)()`)

  // A mage wearing a weak neck and a strong cloth chest. Hall of Thanes has a neck, a
  // staff and a cloth chest for them.
  run(`ITEM_MOD_STAMINA_SHORT = "Stamina" ITEM_MOD_INTELLECT_SHORT = "Intellect" ITEM_MOD_SPIRIT_SHORT = "Spirit"
    Fake.stats = {
      [270227] = { ITEM_MOD_SPIRIT_SHORT = 5, ITEM_MOD_INTELLECT_SHORT = 4 },   -- Ephemeral Choker (drop)
      [900001] = { ITEM_MOD_SPIRIT_SHORT = 2, ITEM_MOD_STAMINA_SHORT = 1 },     -- worn neck
      [270261] = { ITEM_MOD_INTELLECT_SHORT = 3 },                               -- Robes of the Disgraced Thane (drop)
      [900005] = { ITEM_MOD_INTELLECT_SHORT = 9, ITEM_MOD_STAMINA_SHORT = 4 },   -- worn chest
      [270228] = { ITEM_MOD_INTELLECT_SHORT = 8, ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 12.4 }, -- Golemheart Stave (drop)
    }
    Fake.facts[270227] = { classID = 4, subclassID = 0, equipLoc = "INVTYPE_NECK" }
    Fake.facts[270261] = { classID = 4, subclassID = 1, equipLoc = "INVTYPE_ROBE" }
    Fake.facts[270228] = { classID = 2, subclassID = 10, equipLoc = "INVTYPE_2HWEAPON" }
    Fake.equipped = { [2] = 900001, [5] = 900005 }
    Fake.names[900001] = "Old Necklace" Fake.names[900005] = "Fancy Robe"
    GetItemInfo = function(id) return Fake.names[id] or ("Item " .. id), "|cffffffff|Hitem:" .. id .. "::::|h[" .. (Fake.names[id] or ("Item " .. id)) .. "]|h|r" end
    GetItemStats = function(link) return Fake.stats[tonumber(link:match("item:(%d+)"))] or {} end
    GetInventoryItemLink = function(unit, slot) local id = Fake.equipped[slot] if id then return select(2, GetItemInfo(id)) end end
    WishwellDB.browseId = "thanes"
    SlashCmdList.WISHWELL("loot")`, 'setup')
  check('an item better than what you wear is marked as the best upgrade for its slot', /^Best upgrade · Neck/.test(metaOf(270227)))
  run(`WishwellDB.slot = "Chest" Wishwell_Toggle("browse")`, 'chest-only')
  check('an item worse than what you wear is not marked', /^Chest · /.test(metaOf(270261)))
  run(`WishwellDB.slot = "ALL" Wishwell_Toggle("browse")`, 'all-slots-again')
  check('an empty slot counts as an upgrade', /^Best upgrade · Two-Hand/.test(metaOf(270228)))

  // The tooltip says what would change.
  run(`Fake.tip = {}
    GameTooltip.AddLine = function(_, text) Fake.tip[#Fake.tip + 1] = text end
    GameTooltip.SetText = function(_, text) Fake.tip[#Fake.tip + 1] = text end
    for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
      if it and rawget(w, "shown") and it.id == 270227 then w.scripts.OnEnter(w) break end end`, 'tooltip')
  const tip = strip(ev(`table.concat(Fake.tip, " // ")`))
  check('the tooltip names what you are wearing and gives a verdict', /Looks like an upgrade for you \/\/ (?:[^/]+ \/\/ )?Compared with Old Necklace:/.test(tip))
  check('it lists each stat you gain and lose', /\+4 Int/.test(tip) && /\+3 Spi/.test(tip) && /-1 Stam/.test(tip))
  run(`Fake.tip = {}
    WishwellDB.slot = "Chest" Wishwell_Toggle("browse")
    for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
      if it and rawget(w, "shown") and it.id == 270261 then w.scripts.OnEnter(w) break end end`, 'tooltip2')
  run(`WishwellDB.slot = "ALL" Wishwell_Toggle("browse")`, 'all-slots')
  check('a downgrade says so', /Not an upgrade for you \/\/ (?:[^/]+ \/\/ )?Compared with Fancy Robe:/.test(strip(ev(`table.concat(Fake.tip, " // ")`))))

  // Upgrades first.
  run(`WishwellBestFirst.scripts.OnClick(setmetatable({}, { __index = function() return function() return true end end }))`, 'best-first')
  check('Upgrades first puts the biggest improvements at the top', /^270228,270227,/.test(order()) && ev(`WishwellDB.bestFirst`) === true)

  // Changing gear changes the verdict.
  run(`Fake.equipped[2] = 270227
    Fake.Fire("PLAYER_EQUIPMENT_CHANGED", 2)`, 'equip')
  check('putting the item on stops it being an upgrade', !/upgrade/i.test(metaOf(270227)))

  // The pop-up counts upgrades, lists them first, and has the wisp.
  run(`Fake.equipped[2] = 900001
    Fake.Fire("PLAYER_EQUIPMENT_CHANGED", 2)
    WishwellDB.popped = nil Fake.instance = { "Hall of Thanes", "party", 1, "", 5, 0, false, 9001 }
    Fake.Fire("PLAYER_ENTERING_WORLD") Fake.Advance(5)`, 'toast')
  const toast = strip(ev(`(function() local t = WishwellToast
    return (rawget(t.sub, "text") or "") .. " // " .. (rawget(t.lines[1].text, "text") or "") .. " // " .. (rawget(t.lines[2].text, "text") or "") end)()`))
  check('the pop-up counts the upgrades and lists them first', /2 upgrades/.test(toast) && /\/\/ Upgrade  Golemheart Stave.*\/\/ Upgrade  Ephemeral Choker/.test(toast))
  check('the wisp is on the pop-up and looks happy when there is something for you',
    ev(`rawget(WishwellToast.wisp, "shown")`) === true && ev(`WishwellToast.wisp.happy`) === true)
  run(`WishwellToast.wisp.scripts.OnUpdate(WishwellToast.wisp, 0.5)`, 'wisp-tick')
  run(`SlashCmdList.WISHWELL("wisp")
    Fake.instance = { "Eastern Kingdoms", "none", 0, "", 0, 0, false, 0 }
    Fake.Fire("ZONE_CHANGED_NEW_AREA") Fake.Advance(5)
    WishwellDB.popped = nil Fake.instance = { "Hall of Thanes", "party", 1, "", 5, 0, false, 9001 }
    Fake.Fire("PLAYER_ENTERING_WORLD") Fake.Advance(5)`, 'wisp-off')
  check('/ww wisp hides it', ev(`rawget(WishwellToast.wisp, "shown")`) === false)
  check('no Lua errors were printed', !/error/i.test(ev(`table.concat(Fake.printed, "\\n")`)))
}

// ---- Wishwell: quests by zone, class and race, best XP first --------------------------
{
  const run = makeGame({ addon: WISHLIST, toc: 16001, build: '1.60.1' })
  const ev = (code) => run(`return ${code}`, 'check')
  const strip = (text) => String(text).replace(/\|c[0-9a-f]{8}|\|r/g, '')
  const rows = () => strip(ev(`(function() local t = {} for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") and it.questRow then t[#t + 1] = (rawget(w.name, "text") or "") .. " = " .. (rawget(w.meta, "text") or "") end end
    return table.concat(t, " | ") end)()`))
  const status = () => strip(ev(`rawget(WishwellFrame.status, "text")`))
  const pickZone = (group, text) => run(`Fake.menu = {} rawget(WishwellQuestZoneDrop, "init")(WishwellQuestZoneDrop, ${group ? 2 : 1}, ${group ? '"' + group + '"' : 'nil'})
    for _, m in ipairs(Fake.menu) do if m.text == "${text}" then m.func() end end`, 'zone')

  check('the quest list ships with zones', ev(`#WishwellData.quests`) > 2500 && ev(`WishwellData.questZones[40][1]`) === 'Westfall')

  // A level 12 gnome mage standing in Westfall.
  run(`Fake.level = 12
    UnitLevel = function() return Fake.level end
    UnitRace = function() return "Gnome", "Gnome", 7 end
    UnitFactionGroup = function() return "Alliance", "Alliance" end
    GetRealZoneText = function() return Fake.zone end
    Fake.zone = "Westfall"
    Fake.done, Fake.log = {}, {}
    C_QuestLog = { IsQuestFlaggedCompleted = function(id) return Fake.done[id] == true end, IsOnQuest = function(id) return Fake.log[id] == true end }
    SlashCmdList.WISHWELL("quests")`, 'setup')
  check('/ww quests opens the Quests tab on the zone you are in', ev(`WishwellDB.page`) === 'quests' && /^Westfall: \d+ quests you can do now, [\d,]+ XP in all\. Best: /.test(status()))
  const first = rows()
  check('quests are listed with their level and XP, best XP first', /^\[\d+\] .+ = [\d,]+ XP/.test(first)
    && (() => { const xp = [...first.matchAll(/= ([\d,]+) XP/g)].map((m) => Number(m[1].replace(/,/g, ''))); return xp.length > 3 && xp.every((v, i) => i === 0 || v <= xp[i - 1]) })())
  check('a quest whose earlier step is not done is left out of "what I can do now"',
    ev(`(function() local n = 0 for _, it in ipairs({}) do end
      for _, w in ipairs(Fake.frames) do end
      local found = 0
      for _, q in ipairs(WishwellData.quests) do if q[1] == 13 then found = 1 end end
      return found end)()`) === 1 && !/\[14\] The People's Militia/.test(first))

  // Search narrows by name; unticking shows what is not ready yet.
  run(`for _, w in ipairs(Fake.frames) do if rawget(w, "name") == "WishwellSearch" then rawset(w, "text", "people's militia") w.scripts.OnTextChanged() end end`, 'search')
  check('search finds quests by name', /^\[12\] The People's Militia = [\d,]+ XP$/.test(rows()))
  run(`WishwellQuestNow.scripts.OnClick(setmetatable({}, { __index = function() return function() return false end end }))`, 'untick')
  const all = rows()
  check('unticking shows the later steps and what they wait for', /\[14\] The People's Militia = [\d,]+ XP · After: The People's Militia/.test(all) && /\[17\] The People's Militia = .*After:/.test(all))

  // Finish the first step: the next one opens up.
  run(`Fake.done[12] = true
    Fake.Fire("QUEST_TURNED_IN", 12)`, 'turn-in')
  const after = rows()
  check('finished quests disappear and the next step opens', !/^\[12\] /.test(after) && /\[14\] The People's Militia = [\d,]+ XP( \||$)/.test(after))
  run(`Fake.log[13] = true
    Fake.Fire("QUEST_ACCEPTED", 13)`, 'accept')
  check('a quest you have picked up says so', /\[14\] The People's Militia = [\d,]+ XP · In your log/.test(rows()))
  run(`WishwellQuestNow.scripts.OnClick(setmetatable({}, { __index = function() return function() return true end end }))
    for _, w in ipairs(Fake.frames) do if rawget(w, "name") == "WishwellSearch" then rawset(w, "text", "") w.scripts.OnTextChanged() end end`, 'reset')

  // Outlevelled quests pay less.
  run(`for _, w in ipairs(Fake.frames) do if rawget(w, "name") == "WishwellSearch" then rawset(w, "text", "the killing fields") w.scripts.OnTextChanged() end end`, 'kf')
  check('a quest at your level pays full XP', /^\[15\] The Killing Fields = 1,050 XP$/.test(rows()))
  run(`Fake.level = 25 Fake.Fire("PLAYER_LEVEL_UP", 25)`, 'level')
  check('ten levels over it, the same quest pays a tenth', /^\[15\] The Killing Fields = 110 XP$/.test(rows()))
  run(`Fake.level = 12 Fake.Fire("PLAYER_LEVEL_UP", 12)
    for _, w in ipairs(Fake.frames) do if rawget(w, "name") == "WishwellSearch" then rawset(w, "text", "") w.scripts.OnTextChanged() end end`, 'level-back')

  // Faction, race and class.
  pickZone('Kalimdor', 'Durotar')
  check('the other faction\'s zone has nothing for you', /nothing to pick up right now/.test(status()) && rows() === '')
  pickZone('Other', 'Class quests')
  const classRows = rows()
  check('class quests show only your class', classRows.length > 0 && classRows.split(' | ').every((r) => /Mage/.test(r)) && !/Warrior only|Rogue only/.test(classRows))
  run(`UnitClass = function() return "Warlock", "WARLOCK" end Fake.Fire("PLAYER_LOGIN")`, 'warlock')
  pickZone('Other', 'Class quests')
  check('a different class sees its own class quests', rows().split(' | ').every((r) => /Warlock/.test(r)))

  // Everywhere, and following you between zones.
  pickZone(null, 'Everywhere')
  check('Everywhere names the zone on each row', /= [\d,]+ XP · [A-Z][A-Za-z' ]+/.test(rows().split(' | ')[0]) && /^Everywhere: /.test(status()))
  pickZone(null, 'Where I am')
  run(`Fake.zone = "Loch Modan" Fake.Fire("ZONE_CHANGED_NEW_AREA") Fake.Advance(5)`, 'move')
  check('"Where I am" follows you to the next zone', /^Loch Modan: /.test(status()))
  check('no Lua errors were printed', !/error/i.test(ev(`table.concat(Fake.printed, "\\n")`)))
}

// ---- Wishwell: upgrade advice on tooltips, loot rolls and quest rewards -----------------
{
  const run = makeGame({ addon: WISHLIST, toc: 16001, build: '1.60.1' })
  const ev = (code) => run(`return ${code}`, 'check')
  const strip = (text) => String(text).replace(/\|c[0-9a-f]{8}|\|r/g, '').replace(/\|Hitem:[^|]*\|h|\|h/g, '')
  const printed = () => strip(ev(`table.concat(Fake.printed, "\\n")`))

  // A mage with a weak neck and a strong chest, as in the comparison test.
  run(`ITEM_MOD_STAMINA_SHORT = "Stamina" ITEM_MOD_INTELLECT_SHORT = "Intellect" ITEM_MOD_SPIRIT_SHORT = "Spirit"
    Fake.stats = {
      [270227] = { ITEM_MOD_SPIRIT_SHORT = 5, ITEM_MOD_INTELLECT_SHORT = 4 },
      [900001] = { ITEM_MOD_SPIRIT_SHORT = 2, ITEM_MOD_STAMINA_SHORT = 1 },
      [270261] = { ITEM_MOD_INTELLECT_SHORT = 3 },
      [900005] = { ITEM_MOD_INTELLECT_SHORT = 9, ITEM_MOD_STAMINA_SHORT = 4 },
      [900007] = { ITEM_MOD_STAMINA_SHORT = 9 },
    }
    Fake.facts[270227] = { classID = 4, subclassID = 0, equipLoc = "INVTYPE_NECK" }
    Fake.facts[900001] = { classID = 4, subclassID = 0, equipLoc = "INVTYPE_NECK" }
    Fake.facts[270261] = { classID = 4, subclassID = 1, equipLoc = "INVTYPE_ROBE" }
    Fake.facts[900007] = { classID = 4, subclassID = 4, equipLoc = "INVTYPE_CHEST" }   -- plate: not for a mage
    Fake.equipped = { [2] = 900001, [5] = 900005 }
    Fake.names[900001] = "Old Necklace" Fake.names[900005] = "Fancy Robe" Fake.names[270227] = "Ephemeral Choker"
    Fake.names[270261] = "Robes of the Disgraced Thane" Fake.names[900007] = "Plate Thing"
    Fake.price = { [270227] = 1200, [270261] = 5300, [900007] = 9900 }
    Fake.LinkOf = function(id) return "|cffffffff|Hitem:" .. id .. "::::|h[" .. (Fake.names[id] or ("Item " .. id)) .. "]|h|r" end
    GetItemInfo = function(what)
      local id = tonumber(what) or tonumber(tostring(what):match("item:(%d+)"))
      return Fake.names[id] or ("Item " .. id), Fake.LinkOf(id), 3, 20, 10, "Armor", "Cloth", 1, "", 134400, Fake.price[id] or 0
    end
    GetItemStats = function(link) return Fake.stats[tonumber(link:match("item:(%d+)"))] or {} end
    GetInventoryItemLink = function(unit, slot) local id = Fake.equipped[slot] if id then return Fake.LinkOf(id) end end
    Fake.tip = {}
    GameTooltip.AddLine = function(_, text) Fake.tip[#Fake.tip + 1] = text end
    Fake.Hover = function(id)
      Fake.tip = {}
      GameTooltip.GetItem = function() return Fake.names[id], Fake.LinkOf(id) end
      GameTooltip.scripts.OnTooltipSetItem(GameTooltip)
      return table.concat(Fake.tip, " // ")
    end`, 'setup')
  check('item tooltips are hooked at login', ev(`type(GameTooltip.scripts.OnTooltipSetItem)`) === 'function')
  const up = strip(ev(`Fake.Hover(270227)`))
  check('an upgrade in your bags or at a vendor says so, with what changes', /^ +\/\/ Wishwell: upgrade for you \/\/ Why: [^/]+ \/\/ Compared with Old Necklace: \/\/ \+4 Int  a key stat for you \/\/ \+3 Spi  useful to you \/\/ -1 Stam  useful to you$/.test(up))
  check('and explains why in one sentence', /Why: The 4 Int and 3 Spi you gain are worth more to a Mage than the 1 Stam you lose\. \/\/ /.test(up))
  check('a downgrade says so, why, and what you would lose', /^ +\/\/ Wishwell: not an upgrade for you \/\/ Why: You lose 6 Int and 4 Stam and gain nothing a Mage needs\. \/\/ Compared with Fancy Robe: \/\/ -6 Int  a key stat for you \/\/ -4 Stam  useful to you$/.test(strip(ev(`Fake.Hover(270261)`))))
  check('the item you are wearing gets no verdict', ev(`Fake.Hover(900001)`) === '')
  check('gear your class cannot use gets no verdict', ev(`Fake.Hover(900007)`) === '')
  run(`WishwellDB.wish = { ["Tester-"] = { [270261] = "thanes" } }`, 'wish')
  check('wishlist items are flagged on any tooltip', /^Wishwell: on your wishlist/.test(strip(ev(`Fake.Hover(270261)`))))

  // Loot roll.
  run(`Fake.printed = {}
    GetLootRollItemLink = function() return Fake.LinkOf(270227) end
    Fake.Fire("START_LOOT_ROLL", 1)`, 'roll')
  check('a roll on an upgrade tells you it is worth a Need roll', /Upgrade for you on this roll: \[Ephemeral Choker\] \(\+4 Int  \+3 Spi  -1 Stam\)\. Worth a Need roll\./.test(printed()))
  run(`Fake.printed = {}
    GetLootRollItemLink = function() return Fake.LinkOf(900007) end
    Fake.Fire("START_LOOT_ROLL", 2)`, 'roll2')
  check('a roll on something you cannot use says nothing', !/Upgrade for you/.test(printed()))

  // Quest reward choice.
  run(`Fake.printed = {}
    Fake.choices = { 270261, 270227, 900007 }
    GetNumQuestChoices = function() return #Fake.choices end
    GetQuestItemLink = function(kind, i) return Fake.LinkOf(Fake.choices[i]) end
    Fake.rewardButtons = {}
    QuestInfoFrame = { rewardsFrame = {} }
    QuestInfo_GetRewardButton = function(_, i) Fake.rewardButtons[i] = Fake.rewardButtons[i] or CreateFrame("Button") return Fake.rewardButtons[i] end
    Fake.Fire("QUEST_COMPLETE") Fake.Advance(1)`, 'rewards')
  check('a quest reward choice names the best one for you', /Best reward for you: \[Ephemeral Choker\] \(\+4 Int/.test(printed()))
  check('and labels it on the reward button', strip(ev(`rawget(Fake.rewardButtons[2].WishwellMark, "text")`)) === 'Best for you' && ev(`rawget(Fake.rewardButtons[2].WishwellMark, "shown")`) === true)
  run(`Fake.Fire("QUEST_FINISHED")`, 'closed')
  check('the label is cleared when the quest window closes', ev(`rawget(Fake.rewardButtons[2].WishwellMark, "shown")`) === false)
  run(`Fake.printed = {}
    Fake.choices = { 270261, 900007 }
    Fake.Fire("QUEST_COMPLETE") Fake.Advance(1)`, 'rewards2')
  check('when nothing is an upgrade it says which sells for the most', /None of these rewards improves your gear\. \[Plate Thing\] sells for the most \(99s\)\./.test(printed()))

  // Off switch.
  run(`SlashCmdList.WISHWELL("tips")`, 'off')
  check('/ww tips turns the advice off', ev(`Fake.Hover(270227)`) === '')
  check('no Lua errors were printed', !/error/i.test(printed()))
}

// ---- Wishwell: What next?, level-up pop-up and first-time tips -------------------------
{
  const run = makeGame({ addon: WISHLIST, toc: 16001, build: '1.60.1' })
  const ev = (code) => run(`return ${code}`, 'check')
  const strip = (text) => String(text).replace(/\|c[0-9a-f]{8}|\|r/g, '')
  const printed = () => strip(ev(`table.concat(Fake.printed, "\\n")`))
  const rows = () => strip(ev(`(function() local t = {} for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") and it.advice then t[#t + 1] = (rawget(w.name, "text") or "") .. " = " .. (rawget(w.meta, "text") or "") end end
    return table.concat(t, " | ") end)()`))
  const go = (title) => run(`for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") and it.advice and it.title:find("${title}", 1, true) then w.scripts.OnClick(w, "LeftButton") break end end`, 'go')
  const toast = () => strip(ev(`(function() local t = WishwellToast if not t or not rawget(t, "shown") then return "" end
    local out = { rawget(t.title, "text") or "", rawget(t.sub, "text") or "" }
    for _, line in ipairs(t.lines) do if rawget(line.text, "shown") then out[#out + 1] = rawget(line.text, "text") or "" end end
    return table.concat(out, " // ") end)()`))

  check('a first-time welcome tip is shown once, in chat and as a pop-up',
    /Tip: Type \/ww or click the minimap button/.test(printed()) && /^A tip from the wisp \/\/ Type \/ww/.test(toast()))

  // A level 13 gnome mage in Westfall with 50 silver, who has been to the trainer.
  run(`Fake.level = 13
    UnitLevel = function() return Fake.level end
    UnitRace = function() return "Gnome", "Gnome", 7 end
    UnitFactionGroup = function() return "Alliance", "Alliance" end
    GetRealZoneText = function() return "Westfall" end
    GetMoney = function() return Fake.money end
    Fake.money = 5000
    Fake.done, Fake.log = {}, {}
    C_QuestLog = { IsQuestFlaggedCompleted = function(id) return Fake.done[id] == true end, IsOnQuest = function(id) return Fake.log[id] == true end }
    WishwellDB.train = { ["Tester-"] = { scanned = true, spells = {
      a = { name = "Fireball", rank = "Rank 3", level = 12, cost = 900 },
      b = { name = "Frost Nova", rank = "Rank 1", level = 10, cost = 600 },
      c = { name = "Arcane Explosion", rank = "Rank 1", level = 14, cost = 1500 },
      d = { name = "Blink", level = 14, cost = 2000 },
    } } }
    Fake.stats = { [270227] = { ITEM_MOD_INTELLECT_SHORT = 4 } }
    Fake.facts[270227] = { classID = 4, subclassID = 0, equipLoc = "INVTYPE_NECK" }
    Fake.equipped = {}
    GetItemInfo = function(id) return "Item " .. id, "|cffffffff|Hitem:" .. id .. "::::|h[Item " .. id .. "]|h|r" end
    GetItemStats = function(link) return Fake.stats[tonumber(link:match("item:(%d+)"))] or {} end
    GetInventoryItemLink = function() return nil end
    Fake.printed = {}
    SlashCmdList.WISHWELL("next")`, 'setup')
  const home = rows()
  check('What next? leads with the best quest where you are', /^Best quest here: .+ = [\d,]+ XP\. \d+ quests to do in Westfall, [\d,]+ XP in all\./.test(home))
  check('it suggests where to go next for quest XP', /Go next: [A-Z][A-Za-z' ]+ = \d+ quests you can do, [\d,]+ XP in all\./.test(home) && !/Go next: Westfall/.test(home))
  check('it says what training costs and whether you can afford it', /Train 2 spells at your class trainer = Costs 15s\. You have 50s, so you can afford all of it\./.test(home))
  check('it picks a dungeon for your level and counts the upgrades', /Dungeon for your level: Hall of Thanes \(13-18\) = 1 upgrade for you\./.test(home))
  check('it invites you to start a wishlist', /Start a wishlist = /.test(home))

  run(`Fake.money = 500 Wishwell_Toggle("home")`, 'poor')
  check('when you cannot afford training it says how much you are short', /Costs 15s\. You have 5s, 10s short\./.test(rows()))

  go('Dungeon for your level')
  check('clicking the dungeon line opens the Loot tab on that dungeon', ev(`WishwellDB.page`) === 'browse' && ev(`WishwellDB.browseId`) === 'thanes')
  run(`Wishwell_Toggle("home")`, 'back')
  go('Go next:')
  check('clicking a zone line opens the Quests tab on that zone', ev(`WishwellDB.page`) === 'quests' && ev(`type(WishwellDB.questZone)`) === 'number')
  run(`Wishwell_Toggle("home")`, 'back2')
  go('Train 2 spells')
  check('clicking the training line opens Spell training', ev(`WishwellDB.page`) === 'train')

  // Level up: the game announces level 14 a moment before UnitLevel says so.
  run(`Fake.printed = {}
    Fake.Fire("PLAYER_LEVEL_UP", 14)`, 'ding')
  const ding = toast()
  check('levelling up shows a pop-up with what opened up', /^Level 14! \/\/ Here is what just opened up\./.test(ding))
  check('it lists new spells with their cost, and new quests', /2 new spells to train  35s/.test(ding) && /\d+ quests? you can now pick up/.test(ding))
  check('it says where the most quest XP is', /Most quest XP: [A-Z][A-Za-z' ]+  [\d,]+ XP/.test(ding))
  run(`WishwellToast.scripts.OnClick(WishwellToast, "LeftButton")`, 'click')
  check('clicking it opens What next?', ev(`WishwellDB.page`) === 'home')
  run(`Fake.level = 18 Fake.Fire("PLAYER_LEVEL_UP", 18)`, 'ding18')
  check('a dungeon coming into range is mentioned', /The Deadmines is now in your level range/.test(toast()))

  // First-time tips appear once each.
  run(`Fake.printed = {}
    GetLootRollItemLink = function() return Fake.Link(1, "ffffffff", "Thing") end
    Fake.Fire("START_LOOT_ROLL", 1)
    Fake.Fire("START_LOOT_ROLL", 2)`, 'roll-tip')
  check('the first loot roll explains Need and Greed, once', printed().split('Tip: Rolling on loot').length === 2)
  run(`Fake.Advance(60)
    Fake.printed = {}
    WishwellDB.tipsSeen = nil
    SlashCmdList.WISHWELL("hints")
    Fake.Fire("START_LOOT_ROLL", 3)`, 'hints-off')
  check('/ww hints turns the tips off', !/Tip:/.test(printed()))
  check('no Lua errors were printed', !/error/i.test(printed()))
}

// ---- Wishwell: drop rates, runs needed and the best run for a wishlist ------------------
{
  const run = makeGame({ addon: WISHLIST, toc: 16001, build: '1.60.1' })
  const ev = (code) => run(`return ${code}`, 'check')
  const strip = (text) => String(text).replace(/\|c[0-9a-f]{8}|\|r/g, '')
  const metaOf = (id) => strip(ev(`(function() for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") and it.id == ${id} then return rawget(w.meta, "text") end end end)()`))
  const hover = (id) => strip(ev(`(function() Fake.tip = {}
    GameTooltip.AddLine = function(_, text) Fake.tip[#Fake.tip + 1] = text end
    for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
      if it and rawget(w, "shown") and it.id == ${id} then w.scripts.OnEnter(w) break end end
    return table.concat(Fake.tip, " // ") end)()`))
  const homeRows = () => strip(ev(`(function() local t = {} for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") and it.advice then t[#t + 1] = (rawget(w.name, "text") or "") .. " = " .. (rawget(w.meta, "text") or "") end end
    return table.concat(t, " | ") end)()`))

  check('Classic drop rates ship with the loot list', ev(`(function() for _, i in ipairs(WishwellData.items) do if i.id == 872 and i.raid == "deadmines" then return i.rate end end end)()`) === 3.91)

  run(`WishwellDB.classFilter = "ALL"
    WishwellDB.browseId = "deadmines"
    SlashCmdList.WISHWELL("loot")
    for _, w in ipairs(Fake.frames) do if rawget(w, "name") == "WishwellSearch" then rawset(w, "text", "rockslicer") w.scripts.OnTextChanged() end end`, 'open')
  check('a row shows the Classic drop chance', /· 3\.9%/.test(metaOf(872)))
  check('the tooltip gives the chance and how many runs that means', /Drop chance: 3\.91% \(Classic rate\) \/\/ On average about 26 runs to see it\./.test(hover(872)))

  // Watch Rhahk'Zor die twelve times; Rockslicer drops on three of them.
  run(`WishwellDB.popped = nil Fake.instance = { "The Deadmines", "party", 1, "", 5, 0, false, 36 }
    Fake.quality[872] = 3
    Fake.quality[5187] = 2
    for kill = 1, 12 do
      Fake.Advance(60)
      Fake.Fire("ENCOUNTER_END", 1, "Rhahk'Zor", 1, 5, 1)
      Fake.Fire("BOSS_KILL", 1, "Rhahk'Zor")                -- the game reports the same kill twice
      Fake.Fire("CHAT_MSG_LOOT", "Raider3 receives loot: " .. Fake.Link(5187, "ff1eff00", "Rhahk'Zor's Hammer") .. ".")
      if kill % 4 == 0 then
        GetLootRollItemLink = function() return Fake.Link(872, "ff0070dd", "Rockslicer") end
        Fake.Fire("START_LOOT_ROLL", kill)
        Fake.Fire("CHAT_MSG_LOOT", "Raider3 receives loot: " .. Fake.Link(872, "ff0070dd", "Rockslicer") .. ".")   -- same drop, reported again
      end
    end
    Fake.Advance(10)`, 'kills')
  check('each boss kill is counted once', ev(`WishwellDB.kills.deadmines["Rhahk'Zor"]`) === 12)
  check('each drop is counted once per kill', ev(`WishwellDB.seen.deadmines[872]`) === 3 && ev(`WishwellDB.seen.deadmines[5187]`) === 12)
  check('after ten kills the row shows what you have seen', /· seen 3 of 12 kills/.test(metaOf(872)))
  const tip = hover(872)
  check('the tooltip shows both, and plans with your own count', /Drop chance: 3\.91% \(Classic rate\)/.test(tip)
    && /You have seen it drop 3 times in 12 kills of Rhahk'Zor\./.test(tip) && /On average about 4 runs to see it\./.test(tip))

  // A boss with no fight event: looting its corpse counts the kill.
  run(`Fake.Advance(600)
    Fake.targetName = "Miner Johnson" Fake.targetClass = "rare"
    Fake.quality[5443] = 2
    GetNumLootItems = function() return 1 end
    GetLootSlotLink = function() return Fake.Link(5443, "ff1eff00", "Gold-plated Buckler") end
    GetLootSourceInfo = function() return "Creature-0-1-2-3-3586-0" end
    Fake.Fire("LOOT_OPENED")
    Fake.Fire("LOOT_OPENED")`, 'corpse')
  check('looting a boss corpse counts as one kill, even if opened twice', ev(`WishwellDB.kills.deadmines["Miner Johnson"]`) === 1 && ev(`WishwellDB.seen.deadmines[5443]`) === 1)

  // The best run for a wishlist.
  run(`WishwellDB.wish = { ["Tester-"] = { [872] = "deadmines", [5187] = "deadmines", [17068] = "onyxia" } }
    Fake.instance = { "Kalimdor", "none", 0, "", 0, 0, false, 1 }
    SlashCmdList.WISHWELL("next")`, 'plan')
  check('What next? names the run with the best odds for your wishlist',
    /Best run for your wishlist: The Deadmines = 2 wishlist items there\. Most runs should drop at least one\./.test(homeRows()))
  run(`WishwellDB.wish = { ["Tester-"] = { [872] = "deadmines" } }
    Wishwell_Toggle("home")`, 'plan2')
  check('and says how many runs when the odds are long', /Best run for your wishlist: The Deadmines = 1 wishlist item there\. About 1 run in 4 drops at least one\./.test(homeRows()))
  check('no Lua errors were printed', !/error/i.test(strip(ev(`table.concat(Fake.printed, "\\n")`))))
}

// ---- Wishwell: gold goals, characters and group wishlists --------------------------------
{
  const run = makeGame({ addon: WISHLIST, toc: 16001, build: '1.60.1',
    saved: `WishwellDB = { chars = { ["Bankalt-"] = { name = "Bankalt", class = "ROGUE", level = 5, money = 250000 } },
      wish = { ["Bankalt-"] = { [872] = "deadmines", [5187] = "deadmines" } },
      train = { ["Bankalt-"] = { scanned = true, spells = { a = { name = "Gouge", level = 4, cost = 100 }, b = { name = "Sprint", level = 10, cost = 300 } } } } }` })
  const ev = (code) => run(`return ${code}`, 'check')
  const strip = (text) => String(text).replace(/\|c[0-9a-f]{8}|\|r/g, '').replace(/\|Hitem:[^|]*\|h|\|h/g, '')
  const printed = () => strip(ev(`table.concat(Fake.printed, "\\n")`))
  const rows = (kind) => strip(ev(`(function() local t = {} for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") and it["${kind}"] then t[#t + 1] = (rawget(w.name, "text") or "") .. " = " .. (rawget(w.meta, "text") or "") end end
    return table.concat(t, " | ") end)()`))

  // A level 12 mage with 12 gold.
  run(`Fake.level = 12
    UnitLevel = function() return Fake.level end
    GetMoney = function() return Fake.money end
    Fake.money = 120000
    WishwellDB.chars["Tester-"].level = 12   -- the fake game said 60 at login
    Fake.Fire("PLAYER_MONEY")
    SlashCmdList.WISHWELL("next")`, 'setup')
  check('a character under 40 is shown a first-mount goal with their progress',
    /Saving for: First mount at level 40 = 12g of 100g \(12%\)\. 88g to go\. \(Classic price\. Click to set your own goal\.\)/.test(rows('advice')))

  run(`SlashCmdList.WISHWELL("goal 20 Riding lessons")`, 'goal')
  check('/ww goal sets your own goal', /Saving for: riding lessons = 12g of 20g \(60%\)\. 8g to go\./i.test(rows('advice')))
  run(`Fake.Advance(3600)
    Fake.money = 160000
    Fake.Fire("PLAYER_MONEY")`, 'earn')
  check('after a while it estimates how long at today\'s pace', /16g of 20g \(80%\)\. 4g to go\. About an hour at today's pace\./.test(rows('advice')))
  run(`Fake.money = 210000 Fake.Fire("PLAYER_MONEY")`, 'reach')
  check('reaching the goal says so', /Saving for: riding lessons = You have 21g\. That is enough!/i.test(rows('advice')))
  run(`SlashCmdList.WISHWELL("goal off")`, 'off')
  check('/ww goal off removes it', !/Saving for/.test(rows('advice')))

  // Characters.
  run(`SlashCmdList.WISHWELL("alts")`, 'alts')
  const alts = rows('alt')
  check('the Characters tab lists this character first', /^Tester  Level 12 Mage  \(this character\) = 21g · 0 on wishlist/.test(alts))
  check('and other characters with their gold, wishlist and training', /Bankalt  Level 5 Rogue = 25g · 2 on wishlist · 1 spell to train \(1s\)/.test(alts))
  check('the top line totals the gold', /2 characters on this account have used Wishwell\. 46g between them\./.test(strip(ev(`rawget(WishwellFrame.status, "text")`))))

  // Group wishlists inside a dungeon.
  run(`WishwellDB.wish["Tester-"] = { [872] = "deadmines", [5187] = "deadmines" }
    WishwellDB.classFilter = "ALL"
    Fake.group = 5
    Fake.sent = {}
    WishwellDB.popped = nil Fake.instance = { "The Deadmines", "party", 1, "", 5, 0, false, 36 }
    Fake.Fire("PLAYER_ENTERING_WORLD") Fake.Advance(15)`, 'enter')
  check('walking in tells the group what you want there', /^W:deadmines:872,5187$/m.test(ev(`table.concat(Fake.sent, "\\n")`)))
  run(`Fake.printed = {}
    Fake.Fire("CHAT_MSG_ADDON", "Wishwell", "W:deadmines:872,5195", "PARTY", "Raider3-Realm")
    SlashCmdList.WISHWELL("loot")
    for _, w in ipairs(Fake.frames) do if rawget(w, "name") == "WishwellSearch" then rawset(w, "text", "rockslicer") w.scripts.OnTextChanged() end end`, 'peer')
  check('you are told when a group member has a wishlist here', /Raider3 has 2 wishlist items in The Deadmines\./.test(printed()))
  check('the loot list shows who else wants an item', /Wanted by Raider3/.test(rows('id')))
  run(`Fake.printed = {}
    Fake.quality[872] = 3
    GetLootRollItemLink = function() return Fake.Link(872, "ff0070dd", "Rockslicer") end
    Fake.Fire("START_LOOT_ROLL", 1)`, 'roll')
  check('the roll alert mentions it', /Wishlist item up for a roll: \[Rockslicer\]\. Don't forget to roll! Raider3 wants it too\./.test(printed()))
  run(`Fake.printed = {} Fake.said = {} Fake.Advance(400)
    SendChatMessage = function(text, channel) Fake.said[#Fake.said + 1] = channel .. ": " .. text end
    Fake.Fire("START_LOOT_ROLL", 1)`, 'roll, default settings')
  check('nothing is said to the group unless that is switched on', ev(`#Fake.said`) === 0 && /Wishlist item up for a roll/.test(printed()))
  run(`Fake.printed = {} Fake.Advance(400) WishwellDB.dropSay = true WishwellDB.dropAlert = false
    Fake.Fire("START_LOOT_ROLL", 1)`, 'roll, told to the group')
  check('Tell my group says it in group chat', /^(RAID|PARTY): .*Rockslicer.* is on my wishlist\.$/.test(ev(`Fake.said[1] or ""`)))
  check('with the drop alert off there is no message of your own', !/Wishlist item/.test(printed()))
  run(`WishwellDB.dropSay = nil WishwellDB.dropAlert = nil`, 'defaults again')
  run(`Fake.sent = {}
    SlashCmdList.WISHWELL("share")
    Fake.Fire("GROUP_ROSTER_UPDATE") Fake.Advance(15)`, 'share-off')
  check('/ww share stops sending your wishlist', !/^W:/m.test(ev(`table.concat(Fake.sent, "\\n")`)))
  check('no Lua errors were printed', !/error/i.test(printed()))
}

// ---- Wishwell: professions, XP to next level, and switching character ------------------
{
  const run = makeGame({ addon: WISHLIST, toc: 16001, build: '1.60.1',
    saved: `WishwellDB = { chars = { ["Bankalt-"] = { name = "Bankalt", class = "ROGUE", level = 5, money = 250000, xp = 300, xpMax = 2800 } } }` })
  const ev = (code) => run(`return ${code}`, 'check')
  const strip = (text) => String(text).replace(/\|c[0-9a-f]{8}|\|r/g, '')
  const rows = () => strip(ev(`(function() local t = {} for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") then t[#t + 1] = (rawget(w.name, "text") or "") .. " = " .. (rawget(w.meta, "text") or "") end end
    return table.concat(t, " | ") end)()`))
  const colorOf = (name) => ev(`(function() for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") and rawget(w.name, "text") == "${name}" then return rawget(w.name, "color") end end end)()`)

  // A character with Blacksmithing 40/75 and Mining 12/75.
  run(`GetProfessions = function() return 1, 2 end
    GetProfessionInfo = function(i) if i == 1 then return "Blacksmithing", 136241, 40, 75 end return "Mining", 136248, 12, 75 end
    Fake.bags = { [2840] = 9, [2835] = 3 }       -- 9 copper bars, 3 rough stones
    GetItemCount = function(id) return Fake.bags[id] or 0 end
    Fake.names[2840] = "Copper Bar" Fake.names[2835] = "Rough Stone" Fake.names[2589] = "Linen Cloth"
    Fake.recipes = {
      [101] = { name = "Copper Chain Belt", learned = true, relativeDifficulty = 0, icon = 1, reagents = { { 2840, 6 } } },
      [102] = { name = "Rough Sharpening Stone", learned = true, relativeDifficulty = 3, icon = 2, reagents = { { 2835, 1 } } },
      [103] = { name = "Copper Bracers", learned = true, relativeDifficulty = 1, icon = 3, reagents = { { 2840, 2 } } },
      [104] = { name = "Runed Copper Belt", learned = true, relativeDifficulty = 0, icon = 4, reagents = { { 2840, 10 }, { 2589, 2 } } },
      [105] = { name = "Not Learned Yet", learned = false, relativeDifficulty = 0, icon = 5, reagents = {} },
    }
    C_TradeSkillUI = {
      IsTradeSkillReady = function() return true end,
      IsTradeSkillLinked = function() return Fake.linked == true end,
      GetChildProfessionInfo = function() return { professionName = "Classic Blacksmithing", parentProfessionName = "Blacksmithing", skillLevel = 40, maxSkillLevel = 75 } end,
      GetAllRecipeIDs = function() return { 101, 102, 103, 104, 105 } end,
      GetRecipeInfo = function(id) local r = Fake.recipes[id] return { recipeID = id, name = r.name, learned = r.learned, relativeDifficulty = r.relativeDifficulty, icon = r.icon } end,
      GetRecipeSchematic = function(id)
        local slots = {}
        for _, reagent in ipairs(Fake.recipes[id].reagents) do slots[#slots + 1] = { reagents = { { itemID = reagent[1] } }, quantityRequired = reagent[2], required = true } end
        return { reagentSlotSchematics = slots }
      end,
    }
    SlashCmdList.WISHWELL("prof")`, 'setup')
  const before = rows()
  check('/ww prof lists your professions with their skill', /^Blacksmithing = Skill 40 of 75 \| /.test(before) && /Mining = Skill 12 of 75/.test(before))
  check('before the window has been opened it asks you to open it', /Open your Blacksmithing window once and Wishwell lists what to make for skill\./.test(before))

  run(`Fake.Fire("TRADE_SKILL_SHOW") Fake.Fire("TRADE_SKILL_LIST_UPDATE") Fake.Advance(2)`, 'open')
  const after = rows()
  check('opening the window reads your learned recipes', ev(`WishwellDB.prof["Tester-"].Blacksmithing.count`) === 4)
  check('recipes that give skill are listed, orange first, the ones you can make on top',
    /Blacksmithing = Skill 40 of 75 \| Copper Chain Belt = You can make 1 · 6x Copper Bar \| Runed Copper Belt = 10x Copper Bar, 2x Linen Cloth \| Copper Bracers = You can make 4 · 2x Copper Bar \| Mining/.test(after))
  check('recipes that no longer give skill are left out', !/Rough Sharpening Stone/.test(after) && !/Not Learned Yet/.test(after))
  check('they use the game skill-up colours', colorOf('Copper Chain Belt') === '1.00,0.50,0.25' && colorOf('Copper Bracers') === '1.00,1.00,0.00')

  run(`Fake.bags[2840] = 20 Fake.Fire("BAG_UPDATE_DELAYED")`, 'mats')
  check('new materials in your bags update what you can make', /Copper Chain Belt = You can make 3/.test(rows()))
  run(`Fake.linked = true
    Fake.recipes[101].relativeDifficulty = 3
    Fake.Fire("TRADE_SKILL_LIST_UPDATE") Fake.Advance(2)`, 'linked')
  check('someone else\'s linked profession is not read as yours', /Copper Chain Belt/.test(rows()))

  // How the game works, by the level 60 rules.
  const said = (question) => (run(`SlashCmdList.WISHWELL("ask ${question}")`, 'ask'), strip(ev(`(function() local last for _, e in ipairs(WishwellChat.order) do if e.kind == "a" then last = e.text end end return last end)()`)))
  check('Wisp explains mount speed by the level 60 rules', /^Mount speed\n[\s\S]*Journeyman \(150\), from level 60, for epic mounts[\s\S]*There is no flying\.[\s\S]*It is in beta, so some may change\./.test(said('how does mount speed work')))
  check('the mount sets the speed and Riding only decides which mounts, with Spurs at +4%', (() => {
    const text = said('how does mount speed work')
    return /The mount sets how fast you go: a normal mount is \+60%, an epic mount \+100%\./.test(text) && /only decides which mounts you can ride/.test(text)
      && /Mithril Spurs \+4%/.test(text) && !/not the mount itself/.test(text)
  })())
  run(`GetNumSkillLines = function() return 1 end GetSkillLineInfo = function() return "Riding", false, false, 75 end`, 'riding 75')
  check('with Riding 75 it says you can ride normal mounts, not that the skill gives the speed', /Your Riding skill is 75: you can ride normal mounts \(\+60%\), and epic ones at 150\./.test(said('how does mount speed work')))
  run(`GetNumSkillLines, GetSkillLineInfo = nil, nil`, 'riding gone')
  check('and talents: 51 points', /^Talents\n[\s\S]*51 points at level 60/.test(said('how many talent points do i get')))
  run(`SlashCmdList.WISHWELL("prof")`, 'back to professions')

  // Pinned recipes, read from this game's profession window.
  const pins = () => strip(ev(`(function() if not WishwellPins or not rawget(WishwellPins, "shown") then return "hidden" end
    local t = {} for _, h in ipairs(WishwellPins.heads) do if rawget(h, "shown") then t[#t + 1] = rawget(h.name, "text") .. " " .. rawget(h.count, "text") end end
    for _, l in ipairs(WishwellPins.lines) do if rawget(l, "shown") then t[#t + 1] = rawget(l.text, "text") end end return table.concat(t, " | ") end)()`))
  run(`Fake.linked = false ProfessionsFrame = { IsShown = function() return true end, CraftingPage = { SchematicForm = {} } }
    Fake.Fire("TRADE_SKILL_SHOW")`, 'profession window')
  check('opening the profession window brings the wisp with a Pin recipe button', ev(`rawget(WishwellPinPrompt, "shown")`) === true && ev(`rawget(WishwellPinButton, "text")`) === 'Pin recipe')
  run(`Fake.printed = {} WishwellPinButton.scripts.OnClick()`, 'pin nothing')
  check('with no recipe open it says to pick one', /Click a recipe in the list first/.test(ev(`table.concat(Fake.printed, "|")`)) && pins() === 'hidden')
  run(`ProfessionsFrame.CraftingPage.SchematicForm.currentRecipeInfo = { recipeID = 104 } WishwellPinButton.scripts.OnClick()`, 'pin')
  check('the open recipe is pinned with what you have of each material', pins() === 'Runed Copper Belt x1 | 20/10  Copper Bar | 0/2  Linen Cloth')
  run(`WishwellPins.heads[1].more.scripts.OnClick() Fake.bags[2589] = 4 Fake.Fire("BAG_UPDATE_DELAYED")`, 'more and bags')
  check('making more and new materials update it', pins() === 'Runed Copper Belt x2 | 20/20  Copper Bar | 4/4  Linen Cloth')
  run(`SlashCmdList.WISHWELL("pins")`, 'put away')
  check('/ww pins puts them away', pins() === 'hidden')
  run(`SlashCmdList.WISHWELL("pins") WishwellPins.heads[1].drop.scripts.OnClick() ProfessionsFrame = nil Fake.bags[2589] = nil`, 'unpin')
  check('unpinning the last one hides the box', pins() === 'hidden')

  // Characters: XP to the next level, and switching.
  run(`Fake.level = 12
    UnitLevel = function() return Fake.level end
    UnitXP = function() return 3800 end
    UnitXPMax = function() return 10000 end
    GetMoney = function() return 50000 end
    WishwellDB.chars["Tester-"].level = 12
    Fake.Fire("PLAYER_XP_UPDATE")
    SlashCmdList.WISHWELL("alts")`, 'alts')
  const alts = rows()
  check('the Characters tab shows XP needed for the next level', /^Tester  Level 12 Mage  \(this character\) = 6,200 XP to level 13 \(38% there\) · 5g/.test(alts))
  check('and for other characters, from when they last played', /Bankalt  Level 5 Rogue = 2,500 XP to level 6 \(10% there\) · 25g/.test(alts))
  check('no row has a Switch button, and nothing offers to log you out', ev(`(function() for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") and it.alt and rawget(rawget(w, "wish"), "shown") then return false end end return true end)()`) === true
    && ev(`WishwellSwitchBox == nil and WishwellSwitchLogout == nil`) === true)
  check('no Lua errors were printed', !/error/i.test(strip(ev(`table.concat(Fake.printed, "\\n")`))))
}

// ---- Wishwell: closing with Esc without tainting the game menu ---------------------------
{
  const run = makeGame({ addon: WISHLIST, toc: 16001, build: '1.60.1' })
  const ev = (code) => run(`return ${code}`, 'check')
  run(`Fake.keys = {}
    Fake.fighting = false
    InCombatLockdown = function() return Fake.fighting end
    SlashCmdList.WISHWELL("loot")
    WishwellFrame.SetPropagateKeyboardInput = function(_, on) Fake.keys[#Fake.keys + 1] = on end
    WishwellFrame.EnableKeyboard = function(_, on) Fake.keyboard = on end`, 'open')
  check('the window is not added to the game list that taints the Esc menu', ev(`#UISpecialFrames`) === 0)
  run(`WishwellFrame.scripts.OnKeyDown(WishwellFrame, "W")`, 'w')
  check('other keys pass straight through to the game', ev(`Fake.keys[#Fake.keys]`) === true && ev(`rawget(WishwellFrame, "shown")`) === true)
  run(`WishwellFrame.scripts.OnKeyDown(WishwellFrame, "ESCAPE")`, 'esc')
  check('Esc closes the window and is not passed on to open the game menu', ev(`rawget(WishwellFrame, "shown")`) === false && ev(`Fake.keys[#Fake.keys]`) === false)
  run(`Fake.Advance(1)`, 'tick')
  check('afterwards keys pass through again', ev(`Fake.keys[#Fake.keys]`) === true)
  run(`SlashCmdList.WISHWELL("loot")
    Fake.fighting = true
    Fake.Fire("PLAYER_REGEN_DISABLED") Fake.Advance(1)`, 'combat')
  check('in combat the window lets go of the keyboard entirely', ev(`Fake.keyboard`) === false)
  run(`local before = #Fake.keys
    WishwellFrame.scripts.OnKeyDown(WishwellFrame, "ESCAPE")
    Fake.touched = #Fake.keys ~= before`, 'combat-key')
  check('and never changes key handling during a fight', ev(`Fake.touched`) === false)
  run(`Fake.fighting = false Fake.Fire("PLAYER_REGEN_ENABLED") Fake.Advance(1)`, 'out')
  check('after the fight it listens for Esc again', ev(`Fake.keyboard`) === true)
}

// ---- Wishwell: settings, new quests, Legacy, chat links and the run summary -------------
{
  const run = makeGame({ addon: WISHLIST, toc: 16001, build: '1.60.1' })
  const ev = (code) => run(`return ${code}`, 'check')
  const strip = (text) => String(text).replace(/\|c[0-9a-f]{8}|\|r/g, '')
  const printed = () => strip(ev(`table.concat(Fake.printed, "\\n")`))
  const rows = () => strip(ev(`(function() local t = {} for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") then t[#t + 1] = (rawget(w.name, "text") or "") .. " = " .. (rawget(w.meta, "text") or "")
      .. ((rawget(rawget(w, "wish"), "shown") ~= false) and (" [" .. (rawget(rawget(w, "wish"), "text") or "") .. "]") or "") end end
    return table.concat(t, " | ") end)()`))
  const clickRow = (label) => run(`for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") and rawget(w.name, "text") == "${label}" then rawget(w, "wish").scripts.OnClick() break end end`, 'click')
  const toast = () => strip(ev(`(function() local t = WishwellToast if not t or not rawget(t, "shown") then return "" end
    local out = { rawget(t.title, "text") or "", rawget(t.sub, "text") or "" }
    for _, line in ipairs(t.lines) do if rawget(line.text, "shown") then out[#out + 1] = rawget(line.text, "text") or "" end end
    return table.concat(out, " // ") end)()`))

  // Settings.
  run(`SlashCmdList.WISHWELL("settings")`, 'settings')
  check('/ww settings opens on the Window section, every switch on to begin with',
    /^Minimap button = .* \[On\] \| Window size = .* \[Medium\] \| Welcome page = .* \[On\] \| Smooth look = .* \[On\] \| Close in combat = .* \[On\]$/.test(rows()))
  clickRow('Minimap button')
  run(`WishwellSettings_popups.scripts.OnClick()`, 'popups')
  check('the Pop-ups section has the pop-up switches and the tracker', /^Pop-ups = .* \[On\] \| Dungeon loot pop-up = .* \| The wisp = .* \| Pin recipe button = .* \| Wishlist tracker = .* \[On\]$/.test(rows()))
  clickRow('Pop-ups')
  check('clicking a switch turns it off', ev(`WishwellDB.popup`) === false && ev(`WishwellDB.minimapHidden`) === true && /Pop-ups = .* \[Off\]/.test(rows()))
  check('the minimap switch hides the button straight away', ev(`rawget(WishwellMinimapButton, "shown")`) === false)
  clickRow('Pop-ups')
  run(`WishwellSettings_window.scripts.OnClick()`, 'window')
  clickRow('Minimap button')
  check('clicking again turns it back on', ev(`WishwellDB.popup`) === true && ev(`WishwellDB.minimapHidden`) === false)

  // A new WoW Forever quest the shipped list has never heard of.
  run(`Fake.level = 14
    UnitLevel = function() return Fake.level end
    UnitFactionGroup = function() return "Alliance", "Alliance" end
    GetRealZoneText = function() return "Zephras Isle" end
    Fake.done, Fake.log = {}, { [990001] = true }
    C_QuestLog = {
      IsQuestFlaggedCompleted = function(id) return Fake.done[id] == true end,
      IsOnQuest = function(id) return Fake.log[id] == true end,
      GetTitleForQuestID = function(id) if id == 990001 then return "Wings Over Zephras" end end,
      GetQuestDifficultyLevel = function() return 14 end,
    }
    GetQuestLogRewardXP = function(id) return id == 990001 and 1350 or 0 end
    Fake.Fire("QUEST_ACCEPTED", 990001) Fake.Advance(3)
    SlashCmdList.WISHWELL("quests")`, 'new-quest')
  check('a quest the list does not know is remembered when you accept it', ev(`WishwellDB.quests[990001].n`) === 'Wings Over Zephras' && ev(`WishwellDB.quests[990001].x`) === 1350)
  check('it shows on the Quests tab under its new zone, with its real XP', /^Zephras Isle: 1 quest you can do now/.test(strip(ev(`rawget(WishwellFrame.status, "text")`)))
    && /\[14\] Wings Over Zephras = 1,350 XP · In your log/.test(rows()))
  check('a Classic quest is not learned twice', (run(`Fake.Fire("QUEST_ACCEPTED", 12) Fake.Advance(3)`, 'known'), ev(`WishwellDB.quests[12] == nil`)) === true)

  // Legacy challenges, read from the game's achievements.
  run(`Fake.ach = {
      { 501, "Mage to 25", false, "Reach level 25 on a mage.", { { "Level 25", false, 14, 25 } } },
      { 502, "Skinning to 150", false, "Reach 150 skinning.", { { "Skinning", false, 135, 150 } } },
      { 503, "Explorer", true, "Explore the world.", { { "Everywhere", true, 1, 1 } } },
    }
    GetCategoryList = function() return { 7 } end
    GetCategoryInfo = function() return "Classes", -1 end
    GetCategoryNumAchievements = function() return #Fake.ach, 1, 2 end
    GetAchievementInfo = function(cat, i) local a = Fake.ach[i] return a[1], a[2], 1, a[3], nil, nil, nil, a[4], 0, 136116, "1 Legacy point" end
    local function find(id) for _, a in ipairs(Fake.ach) do if a[1] == id then return a end end end
    GetAchievementNumCriteria = function(id) return #find(id)[5] end
    GetAchievementCriteriaInfo = function(id, i) local c = find(id)[5][i] return c[1], 0, c[2], c[3], c[4] end
    Constants = { LegacyConsts = { LEGACY_TREE_PROFESSIONS_ID = 1187 } }
    C_Traits = { GetConfigIDByTreeID = function() return 9 end, GetTreeCurrencyInfo = function() return { { quantity = 2, spent = 5 } } end }
    SlashCmdList.WISHWELL("legacy")`, 'legacy')
  const legacy = rows()
  check('/ww legacy sums up your challenges and points', /^1 of 3 challenges done\. 2 Legacy points to spend, 5 spent on this character\. = /.test(legacy))
  check('unfinished challenges are listed nearest-to-done first', /Skinning to 150 = 90% done · Classes · Reach 150 skinning\. \| Mage to 25 = 56% done/.test(legacy) && !/Explorer/.test(legacy))

  // Shift-click a loot row to link it in chat.
  run(`Fake.linked = {}
    ChatEdit_InsertLink = function(link) Fake.linked[#Fake.linked + 1] = link return true end
    GetItemInfo = function(id) return "Item " .. id, "|cffffffff|Hitem:" .. id .. "::::|h[Item " .. id .. "]|h|r" end
    WishwellDB.classFilter = "ALL"
    WishwellDB.browseId = "thanes"
    SlashCmdList.WISHWELL("loot")
    Fake.tried = {}
    IsShiftKeyDown = function() return true end
    for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
      if it and rawget(w, "shown") and it.id == 270227 then w.scripts.OnClick(w, "LeftButton") break end end
    IsShiftKeyDown = function() return false end`, 'link')
  check('Shift-click puts an item link in the chat box instead of trying it on', /item:270227/.test(ev(`Fake.linked[1] or ""`)) && ev(`#Fake.tried`) === 0)
  run(`WishwellDB.wish = { ["Tester-"] = { [270227] = "thanes", [271096] = "thanes" } }
    Fake.linked = {}
    SlashCmdList.WISHWELL("link")`, 'link-cmd')
  check('/ww link puts your wishlist in the chat box', ev(`#Fake.linked`) === 2)

  // A dungeon run, then leaving.
  run(`Fake.Advance(60)
    Fake.quality[270227] = 3 Fake.quality[271096] = 3 Fake.quality[279998] = 3
    WishwellDB.popped = nil Fake.instance = { "Hall of Thanes", "party", 1, "", 5, 0, false, 9001 }
    Fake.Fire("PLAYER_ENTERING_WORLD") Fake.Advance(5)
    Fake.Fire("ENCOUNTER_END", 1, "Faldrim Anvilmar", 1, 5, 1)
    Fake.Fire("CHAT_MSG_LOOT", "You receive loot: " .. Fake.Link(270227, "ff0070dd", "Ephemeral Choker") .. ".")
    Fake.Fire("CHAT_MSG_LOOT", "Raider3 receives loot: " .. Fake.Link(271096, "ff0070dd", "Aetherwisp Bracers") .. ".")
    Fake.Fire("CHAT_MSG_LOOT", "Raider3 receives loot: " .. Fake.Link(279998, "ff0070dd", "Brand New Blue") .. ".")
    Fake.Advance(60)
    Fake.instance = { "Eastern Kingdoms", "none", 0, "", 0, 0, false, 0 }
    Fake.Fire("ZONE_CHANGED_NEW_AREA") Fake.Advance(5)`, 'run')
  const summary = toast()
  check('leaving a dungeon shows a run summary', /^Hall of Thanes: run summary \/\/ 1 boss down  ·  3 drops seen/.test(summary))
  check('it says which wishlist item you got and which got away', /Got it: (Ephemeral Choker|Item 270227)/.test(summary) && /Dropped, still on your list: (Aetherwisp Bracers|Item 271096)/.test(summary))
  check('and how many new drops were learned', /1 new drop added to the loot list/.test(summary) && /1 wishlist item still to get here/.test(summary))
  run(`WishwellToast:Hide()
    WishwellDB.popped = nil Fake.instance = { "Hall of Thanes", "party", 1, "", 5, 0, false, 9001 }
    Fake.Fire("PLAYER_ENTERING_WORLD") Fake.Advance(5)
    WishwellToast:Hide()
    Fake.instance = { "Eastern Kingdoms", "none", 0, "", 0, 0, false, 0 }
    Fake.Fire("ZONE_CHANGED_NEW_AREA") Fake.Advance(5)`, 'empty-run')
  check('stepping in and out without a kill shows no summary', toast() === '')
  check('no Lua errors were printed', !/error/i.test(printed()))
}

// ---- Wishwell: saying why something is or is not an upgrade ------------------------------
{
  const run = makeGame({ addon: WISHLIST, toc: 16001, build: '1.60.1' })
  const ev = (code) => run(`return ${code}`, 'check')
  const strip = (text) => String(text).replace(/\|c[0-9a-f]{8}|\|r/g, '')
  // A mage. Worn: a ring with Intellect and Stamina, a chest with a lot of Intellect.
  run(`ITEM_MOD_STAMINA_SHORT = "Stamina" ITEM_MOD_INTELLECT_SHORT = "Intellect" ITEM_MOD_SPIRIT_SHORT = "Spirit"
    ITEM_MOD_STRENGTH_SHORT = "Strength" ITEM_MOD_AGILITY_SHORT = "Agility"
    Fake.stats = {
      [1] = { ITEM_MOD_INTELLECT_SHORT = 10, ITEM_MOD_STAMINA_SHORT = 4 },                             -- worn chest
      [2] = { ITEM_MOD_INTELLECT_SHORT = 7, ITEM_MOD_SPIRIT_SHORT = 16, ITEM_MOD_STRENGTH_SHORT = 5 }, -- trade Int for Spirit, plus useless Strength
      [7] = { ITEM_MOD_INTELLECT_SHORT = 7, ITEM_MOD_SPIRIT_SHORT = 12 },                               -- the same trade, but it only breaks even
      [3] = { ITEM_MOD_INTELLECT_SHORT = 10, ITEM_MOD_STAMINA_SHORT = 4, ITEM_MOD_AGILITY_SHORT = 9 }, -- same but with Agility
      [4] = { ITEM_MOD_STAMINA_SHORT = 6, ITEM_MOD_INTELLECT_SHORT = 8 },                               -- less Int, a little more Stamina
      [5] = { ITEM_MOD_INTELLECT_SHORT = 14, ITEM_MOD_STAMINA_SHORT = 5 },                              -- more of everything
    }
    for id = 1, 5 do Fake.facts[id] = { classID = 4, subclassID = 1, equipLoc = "INVTYPE_ROBE" } Fake.names[id] = "Robe " .. id end
    Fake.facts[7] = { classID = 4, subclassID = 1, equipLoc = "INVTYPE_ROBE" } Fake.names[7] = "Robe 7"
    Fake.facts[6] = { classID = 4, subclassID = 0, equipLoc = "INVTYPE_NECK" } Fake.names[6] = "Neck"
    Fake.stats[6] = { ITEM_MOD_INTELLECT_SHORT = 3 }
    Fake.equipped = { [5] = 1 }
    Fake.LinkOf = function(id) return "|cffffffff|Hitem:" .. id .. "::::|h[" .. Fake.names[id] .. "]|h|r" end
    GetItemInfo = function(what) local id = tonumber(what) or tonumber(tostring(what):match("item:(%d+)")) return Fake.names[id], Fake.LinkOf(id) end
    GetItemStats = function(link) return Fake.stats[tonumber(link:match("item:(%d+)"))] or {} end
    GetInventoryItemLink = function(unit, slot) local id = Fake.equipped[slot] if id then return Fake.LinkOf(id) end end
    Fake.Hover = function(id)
      Fake.tip = {}
      GameTooltip.AddLine = function(_, text) Fake.tip[#Fake.tip + 1] = text end
      GameTooltip.GetItem = function() return Fake.names[id], Fake.LinkOf(id) end
      GameTooltip.scripts.OnTooltipSetItem(GameTooltip)
      return table.concat(Fake.tip, " // ")
    end`, 'setup')
  const why = (id) => (strip(ev(`Fake.Hover(${id})`)).match(/Why: (.*?)(?: \/\/ |$)/) || [])[1]
  check('a trade that comes out ahead names what tips it, warns about the key stat lost, and what is not counted',
    why(2) === 'The 16 Spi you gain is worth more to a Mage than the 3 Int and 4 Stam you lose. You do give up 3 Int, a key stat, so check you can spare it. (Str does nothing for a Mage, so it is not counted.)')
  check('a trade that only breaks even is not called an upgrade or a downgrade', /Wishwell: about the same as what you have \/\/ .*Compared with /.test(strip(ev(`Fake.Hover(7)`))) && !/upgrade for you/.test(strip(ev(`Fake.Hover(7)`))))
  check('a stat your class cannot use does not make something an upgrade', /^Wishwell: upgrade/.test(strip(ev(`Fake.Hover(3)`))) === false)
  check('a trade that comes out behind says which loss outweighs the gain',
    why(4) === 'The 2 Int you lose is worth more to a Mage than the 2 Stam you gain.')
  check('a plain improvement says nothing is lost', why(5) === 'You gain 4 Int and 1 Stam and lose nothing a Mage needs.')
  check('an empty slot is explained as all gain', why(6) === 'That slot is empty, so the 3 Int is all gain.')

  // Inside the Wishwell window each stat line says how much it matters.
  run(`WishwellDB.classFilter = "ALL"
    WishwellDB.browseId = "thanes"
    Fake.stats[270261] = { ITEM_MOD_INTELLECT_SHORT = 7, ITEM_MOD_SPIRIT_SHORT = 16, ITEM_MOD_STRENGTH_SHORT = 5 }
    Fake.facts[270261] = { classID = 4, subclassID = 1, equipLoc = "INVTYPE_ROBE" }
    Fake.names[270261] = "Robes of the Disgraced Thane"
    WishwellDB.slot = "Chest"
    SlashCmdList.WISHWELL("loot")
    Fake.tip = {}
    GameTooltip.AddLine = function(_, text) Fake.tip[#Fake.tip + 1] = text end
    for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
      if it and rawget(w, "shown") and it.id == 270261 then w.scripts.OnEnter(w) break end end`, 'window')
  const tip = strip(ev(`table.concat(Fake.tip, " // ")`))
  check('in the Wishwell window the reason sits under the verdict', /Looks like an upgrade for you \/\/ The 16 Spi you gain is worth more to a Mage/.test(tip))
  check('and each stat line says how much it matters to you',
    /\+16 Spi  useful to you/.test(tip) && /-3 Int  a key stat for you/.test(tip) && /\+5 Str  no use to you/.test(tip))
  check('no Lua errors were printed', !/error/i.test(strip(ev(`table.concat(Fake.printed, "\\n")`))))
}

// ---- All three addons installed in WoW Forever -----------------------------------
{
  const run = makeGame({ addon: WISHLIST, also: FOREVER, toc: 16001, build: '1.60.1' })
  const ev = (code) => run(`return ${code}`, 'check')
  run(`SlashCmdList.WISHWELL("")
    SlashCmdList.RAIDNIGHTFOREVER("")`, 'both')
  check('Wishwell and Raid Night Forever run side by side', ev(`WishwellFrame ~= nil and RaidNightForeverFrame ~= nil and WishwellDB ~= RaidNightForeverDB`) === true)
  check('no Lua errors with both open', !/error/i.test(ev(`table.concat(Fake.printed, "\\n")`)))
}

// ---- Both addons installed in WoW Forever -------------------------------------
{
  const run = makeGame({ addon: FOREVER, also: TBC, toc: 16001, build: '1.60.1' })
  const ev = (code) => run(`return ${code}`, 'check')
  run(`Fake.group = 5
    Fake.Fire("ENCOUNTER_END", 1084, "Onyxia", 9, 40, 1)
    Fake.Fire("CHAT_MSG_LOOT", "Raider3 receives loot: " .. Fake.Link(266200, "ffa335ee", "New Forever Helm") .. ".")
    Fake.Advance(30)
    SlashCmdList.RAIDNIGHTFOREVER("")`, 'both')
  check('the Forever addon works with the TBC addon also installed', ev(`RaidNightForeverDB.learned.onyxia[266200]`) === 'Onyxia')
  check('Raid Night 1.6.10 still loads beside it, with its own saved settings', ev(`type(RaidNightDB) == "table" and RaidNightDB ~= RaidNightForeverDB and RaidNightDB.learned == nil`) === true)
  check('/rnf always opens the Forever addon', ev(`SLASH_RAIDNIGHTFOREVER3`) === '/rnf')
  check('no Lua errors with both installed', !/error/i.test(ev(`table.concat(Fake.printed, "\\n")`)))
}

// ---- Wishwell (WoW Forever): the newer layout, with what this game has ------------------------
{
  const run = makeGame({ addon: WISHLIST, toc: 16001, build: '1.60.1' })
  const ev = (code) => run(`return ${code}`, 'check')
  const strip = (text) => String(text).replace(/\|c[0-9a-f]{8}|\|r/g, '')
  run(`SlashCmdList.WISHWELL("")`, 'open')
  check('there are five tabs', ev(`(function() local n = 0 for _ in pairs(WishwellFrame.tabs) do n = n + 1 end return n end)()`) === 5)
  run(`WishwellFrame.tabs.me.scripts.OnClick()`, 'me')
  check('Me holds Training, Professions, Legacy and Characters, and no Talents page yet',
    ev(`WishwellDB.page`) === 'train' && ev(`rawget(WishwellPage_legacy, "shown") and rawget(WishwellPage_prof, "shown") and rawget(WishwellPage_alts, "shown")`) === true
    && ev(`WishwellPage_talents == nil`) === true)
  run(`WishwellPage_legacy.scripts.OnClick()`, 'legacy')
  check('Legacy is still there, as a page of Me', ev(`WishwellDB.page`) === 'legacy')
  check('the window is the rounded one, with the wisp icon on its tab', ev(`rawget(WishwellFrame, "template")`) !== 'ButtonFrameTemplate' && ev(`WishwellFrame.tabs.ask ~= nil and WishwellAskBar ~= nil`) === true)
  // Wisp answers from the loot lists, the quest list and the item sets.
  const rows = () => strip(ev(`(function() local order, from = WishwellChat.order or {}, 1
    for i, e in ipairs(order) do if e.kind == "q" then from = i + 1 end end
    local t = {} for i = from, #order do local e = order[i]
      t[#t + 1] = e.text .. " = " .. (e.meta or "") .. (e.button and (" [" .. e.button .. "]") or "") end
    return table.concat(t, " | ") end)()`))
  run(`SlashCmdList.WISHWELL("ask")`, 'ask')
  check('Wisp opens on examples drawn from this game', /^Where an item drops = where does .+ drop \[Ask\] \| What a boss drops = what does .+ drop \[Ask\] \| A dungeon or raid = /.test(rows()))
  const example = ev(`WishwellChat.order[2].meta`)
  run(`SlashCmdList.WISHWELL("ask " .. WishwellChat.order[2].meta)`, 'boss')
  check('it says where a boss is and lists what it drops', /^.+ is in .+\. Drops \d+ things? I know of, listed below\.[\s\S]* =  \| .+ \[Wish\]/.test(rows()))
  run(`SlashCmdList.WISHWELL("ask where is zzyzx")`, 'nothing')
  check('and says so when it finds nothing', /^I couldn't find anything called .zzyzx.. Check the spelling.* I know this game\'s raid and dungeon loot, its quests and its item sets\./.test(rows()))
  check('there is no quest guide button without quest giver locations', ev(`rawget(WishwellGuideButton, "shown")`) !== true)
  check('no Lua errors were printed', !/error/i.test(strip(ev(`table.concat(Fake.printed, "\\n")`))))
}

// ---- Wishwell TBC: a separate addon for TBC Anniversary ------------------------------------
{
  const run = makeGame({ addon: WISHTBC, toc: 20506, build: '2.5.6' })
  const ev = (code) => run(`return ${code}`, 'check')
  const strip = (text) => String(text).replace(/\|c[0-9a-f]{8}|\|r/g, '')
  const printed = () => strip(ev(`table.concat(Fake.printed, "\\n")`))
  const status = () => strip(ev(`rawget(WishwellTBCFrame.status, "text")`))
  const rows = () => strip(ev(`(function() local t = {} for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") then t[#t + 1] = (rawget(w.name, "text") or "") .. " = " .. (rawget(w.meta, "text") or "") end end
    return table.concat(t, " | ") end)()`))
  const search = (text) => run(`for _, w in ipairs(Fake.frames) do if rawget(w, "name") == "WishwellTBCSearch" then
    rawset(w, "text", "${text}") w.scripts.OnTextChanged() end end`, 'search')
  const tbcData = JSON.parse(readFileSync(new URL('../src/data/tbc.json', import.meta.url), 'utf8'))

  check('it has its own saved settings and data, nothing shared with Wishwell or Raid Night',
    ev(`type(WishwellTBCDB) == "table" and WishwellDB == nil and WishwellData == nil and RaidNightDB == nil and WishwellFrame == nil`) === true)
  check('it ships the TBC and Classic raids and dungeons', ev(`#WishwellTBCData.instances`) === 52 && ev(`#WishwellTBCData.items`) > 3900)
  check('it ships item sets and the quest list with Outland', ev(`#WishwellTBCData.sets`) > 300 && ev(`#WishwellTBCData.quests`) > 4000
    && ev(`WishwellTBCData.questZones[3483][1]`) === 'Hellfire Peninsula' && ev(`WishwellTBCData.questZones[3483][2]`) === 'Outland')

  // Walk into Karazhan and open the loot list.
  run(`Fake.instance = { "Karazhan", "raid", 1, "", 10, 0, false, 532 }
    Fake.Fire("PLAYER_ENTERING_WORLD") Fake.Advance(5)
    SlashCmdList.WISHWELLTBC("")`, 'enter')
  check('the window opens on the welcome page', ev(`WishwellTBCDB.page`) === 'hub' && ev(`rawget(WishwellTBCHub, "shown")`) === true)
  check('it greets a new player by name', ev(`rawget(WishwellTBCHub.hello, "text")`) === 'Welcome to Wishwell, Tester!' && /^Level \d+ /.test(ev(`rawget(WishwellTBCHub.sub, "text")`)))
  check('it has a tile for each part of Wishwell, each with a line about what is there',
    ev(`(function() local t = {} for _, tile in ipairs(WishwellTBCHub.tiles) do t[#t + 1] = rawget(tile.name, "text") .. (((rawget(tile.tease, "text") or "") ~= "") and "+" or "-") end return table.concat(t, " ") end)()`) === 'Wisp+ Next+ Gear+ Quests+ Me+')
  run(`WishwellTBCHubTile3.scripts.OnClick()`, 'gear tile')
  check('a tile opens its part', ev(`WishwellTBCDB.page`) === 'browse' && ev(`rawget(WishwellTBCHub, "shown")`) === false)
  run(`WishwellTBCFrame:Hide() SlashCmdList.WISHWELLTBC("")`, 'reopen')
  check('the list from the page before does not show through the welcome page', ev(`(function() local n = 0 for _, w in ipairs(Fake.frames) do if rawget(w, "item") and rawget(w, "shown") and rawget(w, "wish") then n = n + 1 end end return n end)()`) === 0)
  const wispSays = () => ev(`rawget(WishwellTBCHub.say, "text") .. " / " .. rawget(WishwellTBCHub.tiles[1].tease, "text")`)
  const firstSaid = wispSays()
  run(`for i = 1, 5 do Fake.Fire("GET_ITEM_INFO_RECEIVED", 1, true) Fake.Advance(0.5) end WishwellTBCHub:Fill() WishwellTBCHub:Fill()`, 'redraws')
  check('the wisp holds its line while the window redraws, so it can be read', wispSays() === firstSaid)
  run(`Fake.Advance(13) WishwellTBCHub.wisp.scripts.OnUpdate(WishwellTBCHub.wisp, 0.1)`, 'later')
  check('and says something new after a while', wispSays() !== firstSaid)
  check('opening again shows the welcome page, as a welcome back', ev(`WishwellTBCDB.page`) === 'hub' && ev(`rawget(WishwellTBCHub.hello, "text")`) === 'Welcome back, Tester!')
  run(`WishwellTBCDB.hub = false WishwellTBCFrame:Hide() SlashCmdList.WISHWELLTBC("")`, 'hub off')
  check('with the welcome page switched off it opens where you left off', ev(`WishwellTBCDB.page`) === 'browse')
  run(`WishwellTBCHomeButton.scripts.OnClick()`, 'home button')
  check('the name at the top of the window still goes there', ev(`WishwellTBCDB.page`) === 'hub')
  run(`WishwellTBCDB.hub = nil WishwellTBCFrame:Hide() SlashCmdList.WISHWELLTBC("")`, 'hub on')
  run(`WishwellTBCDB.classFilter = "ALL" SlashCmdList.WISHWELLTBC("loot")`, 'loot')
  check('the Loot tab is pointed at the raid you are in', ev(`WishwellTBCDB.page`) === 'browse' && ev(`WishwellTBCDB.browseId`) === 'kara')
  check('it lists Karazhan loot by boss', / = Item · Attumen the Huntsman/.test(rows()))
  check('TBC loot is not labelled as unconfirmed', !/not confirmed/.test(rows()))

  // Heroic-only dungeon drops say so.
  const heroic = tbcData.items.ramps.find((item) => item.heroic && item.name && !/'/.test(item.name))
  search(heroic.name.toLowerCase())
  check('heroic-only dungeon drops are labelled', new RegExp('^' + heroic.name + ' = Hellfire Ramparts · Item · .* · Heroic only').test(rows()))
  search('')

  // Quests know Draenei and Blood Elves and the Outland zones.
  run(`Fake.level = 61
    UnitLevel = function() return Fake.level end
    UnitRace = function() return Fake.race[1], Fake.race[1], Fake.race[2] end
    UnitFactionGroup = function() return Fake.side, Fake.side end
    GetRealZoneText = function() return Fake.zone end
    Fake.race, Fake.side, Fake.zone = { "Draenei", 11 }, "Alliance", "Hellfire Peninsula"
    Fake.done, Fake.log = {}, {}
    C_QuestLog = { IsQuestFlaggedCompleted = function(id) return Fake.done[id] == true end, IsOnQuest = function(id) return Fake.log[id] == true end }
    SlashCmdList.WISHWELLTBC("quests")`, 'quests')
  const draenei = status()
  check('/ww quests opens on the Outland zone you are in', /^Hellfire Peninsula: \d\d+ quests you can do now, [\d,]+ XP in all\. Best: /.test(draenei))
  run(`Fake.race, Fake.side = { "Blood Elf", 10 }, "Horde" WishwellTBC_Toggle("quests") WishwellTBC_Toggle("quests")`, 'horde')
  const bloodElf = status()
  check('a Blood Elf gets the Horde quests instead', /^Hellfire Peninsula: \d\d+ quests you can do now/.test(bloodElf) && bloodElf !== draenei)
  run(`Fake.level, Fake.zone = 6, "Eversong Woods" WishwellTBC_Toggle("quests") WishwellTBC_Toggle("quests")`, 'eversong')
  check('Blood Elf starting quests are in the list', /^Eversong Woods: \d\d+ quests you can do now/.test(status()))
  run(`Fake.race, Fake.side = { "Gnome", 7 }, "Alliance" WishwellTBC_Toggle("quests") WishwellTBC_Toggle("quests")`, 'gnome')
  check('and an Alliance character is not offered them', !/^Eversong Woods: \d\d+ quests you can do now/.test(status()))

  // Professions come from the Skills list and the TBC profession windows.
  run(`Fake.skills = { { "Professions", true }, { "Blacksmithing", false, 40, 75 }, { "Enchanting", false, 12, 75 }, { "Weapon Skills", true }, { "Staves", false, 300, 350 } }
    GetNumSkillLines = function() return #Fake.skills end
    GetSkillLineInfo = function(i) local s = Fake.skills[i] return s[1], s[2], true, s[3] or 0, 0, 0, s[4] or 0 end
    Fake.bags = { [2840] = 9, [2835] = 3, [10940] = 2 }
    GetItemCount = function(id) return Fake.bags[id] or 0 end
    Fake.names[2840] = "Copper Bar" Fake.names[2835] = "Rough Stone" Fake.names[2589] = "Linen Cloth" Fake.names[10940] = "Strange Dust"
    Fake.trade = {
      { "Daily Use", "header" },
      { "Copper Chain Belt", "optimal", { { 2840, 6 } } },
      { "Rough Sharpening Stone", "trivial", { { 2835, 1 } } },
      { "Copper Bracers", "medium", { { 2840, 2 } } },
      { "Runed Copper Belt", "optimal", { { 2840, 10 }, { 2589, 2 } } },
    }
    Fake.tradeName = "Blacksmithing"
    GetTradeSkillLine = function() return Fake.tradeName or "UNKNOWN", 40, 75 end
    GetNumTradeSkills = function() return Fake.tradeName and #Fake.trade or 0 end
    GetTradeSkillInfo = function(i) return Fake.trade[i][1], Fake.trade[i][2], 0, true end
    GetTradeSkillIcon = function(i) return 134400 end
    GetTradeSkillNumReagents = function(i) return #(Fake.trade[i][3] or {}) end
    GetTradeSkillReagentInfo = function(i, j) return "x", 134400, Fake.trade[i][3][j][2], 0 end
    GetTradeSkillReagentItemLink = function(i, j) return "|cffffffff|Hitem:" .. Fake.trade[i][3][j][1] .. ":0:0:0|h[x]|h|r" end
    SlashCmdList.WISHWELLTBC("prof")`, 'prof')
  const before = rows()
  check('/ww prof reads your professions from the Skills list', /^Blacksmithing = Skill 40 of 75 \| /.test(before) && /Enchanting = Skill 12 of 75/.test(before) && !/Staves/.test(before))
  run(`Fake.Fire("TRADE_SKILL_SHOW") Fake.Fire("TRADE_SKILL_UPDATE") Fake.Advance(2)`, 'open')
  const after = rows()
  check('opening the profession window reads your recipes', ev(`WishwellTBCDB.prof["Tester-"].Blacksmithing.count`) === 4)
  check('recipes that give skill are listed, orange first, the ones you can make on top',
    /Blacksmithing = Skill 40 of 75 \| Copper Chain Belt = You can make 1 · 6x Copper Bar \| Runed Copper Belt = 10x Copper Bar, 2x Linen Cloth \| Copper Bracers = You can make 4 · 2x Copper Bar \| Enchanting/.test(after))
  check('recipes that no longer give skill are left out', !/Rough Sharpening Stone/.test(after) && !/Daily Use/.test(after))
  run(`Fake.tradeName = nil
    Fake.craft = { { "Enchant Bracer - Minor Health", "optimal", { { 10940, 1 } } } }
    GetCraftDisplaySkillLine = function() return "Enchanting", 12, 75 end
    GetNumCrafts = function() return #Fake.craft end
    GetCraftInfo = function(i) return Fake.craft[i][1], "", Fake.craft[i][2], 0, true end
    GetCraftIcon = function(i) return 134400 end
    GetCraftNumReagents = function(i) return #Fake.craft[i][3] end
    GetCraftReagentInfo = function(i, j) return "x", 134400, Fake.craft[i][3][j][2], 0 end
    GetCraftReagentItemLink = function(i, j) return "|cffffffff|Hitem:" .. Fake.craft[i][3][j][1] .. ":0:0:0|h[x]|h|r" end
    Fake.Fire("CRAFT_SHOW") Fake.Advance(2)`, 'craft')
  check('Enchanting is read from its own window, and closing the other window loses nothing',
    /Enchant Bracer - Minor Health = You can make 2 · 1x Strange Dust/.test(rows()) && /Copper Chain Belt/.test(rows()))

  // Pinned recipes: the wisp offers Pin recipe on the profession window; a pin stays on screen.
  const pins = () => strip(ev(`(function() if not WishwellTBCPins or not rawget(WishwellTBCPins, "shown") then return "hidden" end
    local t = {} for _, h in ipairs(WishwellTBCPins.heads) do if rawget(h, "shown") then t[#t + 1] = rawget(h.name, "text") .. " " .. rawget(h.count, "text") end end
    for _, l in ipairs(WishwellTBCPins.lines) do if rawget(l, "shown") then t[#t + 1] = rawget(l.text, "text") end end return table.concat(t, " | ") end)()`))
  check('opening a profession window brings the wisp with a Pin recipe button', ev(`rawget(WishwellTBCPinPrompt, "shown")`) === true && ev(`rawget(WishwellTBCPinButton, "text")`) === 'Pin recipe')
  check('nothing is pinned to begin with', pins() === 'hidden')
  run(`Fake.tradeName = "Blacksmithing" Fake.picked = 0 Fake.bags = { [2840] = 4 }
    GetTradeSkillSelectionIndex = function() return Fake.picked end
    GetCraftSelectionIndex = function() return 0 end
    GetItemCount = function(id) return Fake.bags[id] or 0 end C_Item.GetItemCount = GetItemCount
    Fake.printed = {} WishwellTBCPinButton.scripts.OnClick()`, 'pin nothing')
  check('with no recipe picked it says to pick one', /Click a recipe in the list first/.test(printed()) && pins() === 'hidden')
  run(`Fake.picked = 5 WishwellTBCPinButton.scripts.OnClick()`, 'pin')
  check('a pinned recipe shows its materials, with what you have of what you need', pins() === 'Runed Copper Belt x1 | 4/10  x | 0/2  x')
  run(`Fake.picked = 2 WishwellTBCPinButton.scripts.OnClick() WishwellTBCPinButton.scripts.OnClick()`, 'pin two')
  check('a second recipe joins it, and pinning the same one twice does not', pins() === 'Runed Copper Belt x1 | Copper Chain Belt x1 | 4/10  x | 0/2  x | 4/6  x' && /already pinned/.test(printed()))
  run(`WishwellTBCPins.heads[2].more.scripts.OnClick() Fake.bags[2840] = 12 Fake.Fire("BAG_UPDATE_DELAYED")`, 'more and bags')
  check('making more asks for more, and the counts follow your bags', pins() === 'Runed Copper Belt x1 | Copper Chain Belt x2 | 12/10  x | 0/2  x | 12/12  x')
  check('they are remembered for the character', ev(`#WishwellTBCDB.pins["Tester-"]`) === 2 && ev(`WishwellTBCDB.pins["Tester-"][2].make`) === 2)
  run(`WishwellTBCPins.heads[1].drop.scripts.OnClick()`, 'unpin')
  check('a recipe can be unpinned', pins() === 'Copper Chain Belt x2 | 12/12  x')
  run(`WishwellTBCPins.close.scripts.OnClick()`, 'put away')
  check('they can be put away, and /ww pins brings them back', pins() === 'hidden' && (run(`SlashCmdList.WISHWELLTBC("pins")`, 'pins'), pins()) === 'Copper Chain Belt x2 | 12/12  x')

  // WoW Forever's Legacy tab does not exist here.
  check('there is no Legacy tab', ev(`WishwellTBCFrame.tabs.legacy == nil and WishwellTBCFrame.tabs.me ~= nil and WishwellTBCFrame.tabs.gear ~= nil`) === true)
  check('no Lua errors were printed', !/error/i.test(printed()))
}

// ---- Wishwell TBC: talent builds ---------------------------------------------------------------
{
  const trees = JSON.parse(readFileSync(new URL('../src/data/tbc-talents.json', import.meta.url), 'utf8'))
  const shipped = readFileSync(new URL('../wow-addon/WishwellTBC/DataTalents.lua', import.meta.url), 'utf8')

  // Replay every build one point at a time, obeying the game's rules at each step.
  const FILE = { DRUID: 'druid', HUNTER: 'hunter', MAGE: 'mage', PALADIN: 'paladin', PRIEST: 'priest', ROGUE: 'rogue', SHAMAN: 'shaman', WARLOCK: 'warlock', WARRIOR: 'warrior' }
  let builds = 0
  const problems = []
  const roles = {}
  let cls = null
  for (const line of shipped.split('\n')) {
    const head = line.match(/^  ([A-Z]+) = \{$/)
    if (head) cls = head[1]
    const m = line.match(/key = "(\w+)", role = "(\w+)", name = "([^"]+)", points = \{ (\d+), (\d+), (\d+) \}, order = "(\d+)"/)
    if (!m) continue
    builds++
    roles[cls] = (roles[cls] || '') + m[2] + ' '
    const order = m[7].match(/.../g)
    const rank = {}
    const spentIn = [0, 0, 0, 0]
    const rowSpent = {}
    if (order.length !== 61) problems.push(`${cls} ${m[3]}: ${order.length} points`)
    for (const code of order) {
      const tab = Number(code[0]), row = Number(code[1]) - 1, col = Number(code[2]) - 1
      const tree = trees[FILE[cls]][tab - 1]
      const talent = tree.talents.find((t) => t.row === row && t.col === col)
      if (!talent) { problems.push(`${cls} ${m[3]}: no talent at ${code}`); break }
      let above = 0
      for (let r = 0; r < row; r++) above += rowSpent[tab + ':' + r] || 0
      if (above < row * 5) problems.push(`${cls} ${m[3]}: ${talent.field} taken with ${above} points above it`)
      if (talent.pre) {
        const need = tree.talents.find((t) => t.row === talent.pre.row && t.col === talent.pre.col)
        if ((rank[tab + ':' + need.field] || 0) < need.max) problems.push(`${cls} ${m[3]}: ${talent.field} before ${need.field}`)
      }
      rank[tab + ':' + talent.field] = (rank[tab + ':' + talent.field] || 0) + 1
      if (rank[tab + ':' + talent.field] > talent.max) problems.push(`${cls} ${m[3]}: too many points in ${talent.field}`)
      rowSpent[tab + ':' + row] = (rowSpent[tab + ':' + row] || 0) + 1
      spentIn[tab]++
    }
    if (spentIn.slice(1).join(',') !== [m[4], m[5], m[6]].join(',')) problems.push(`${cls} ${m[3]}: tree totals do not match`)
  }
  if (problems.length) console.log(problems.slice(0, 8).join('\n'))
  check('every talent build can be taken point by point in the order given, 61 points each', builds === 27 && problems.length === 0)
  check('every class has a damage build, and tanks and healers have theirs',
    Object.keys(roles).length === 9 && Object.values(roles).every((r) => /dps/.test(r))
    && ['DRUID', 'PALADIN', 'WARRIOR'].every((c) => /tank/.test(roles[c])) && ['DRUID', 'PALADIN', 'PRIEST', 'SHAMAN'].every((c) => /heal/.test(roles[c])))

  const run = makeGame({ addon: WISHTBC, toc: 20506, build: '2.5.6' })
  const ev = (code) => run(`return ${code}`, 'check')
  const strip = (text) => String(text).replace(/\|c[0-9a-f]{8}|\|r/g, '')
  const status = () => strip(ev(`rawget(WishwellTBCFrame.status, "text")`))
  const rows = () => strip(ev(`(function() local t = {} for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") then t[#t + 1] = (rawget(w.name, "text") or "") .. " = " .. (rawget(w.meta, "text") or "")
      .. ((rawget(rawget(w, "wish"), "shown") ~= false) and (" [" .. (rawget(rawget(w, "wish"), "text") or "") .. "]") or "") end end
    return table.concat(t, " | ") end)()`))
  const clickRow = (label) => run(`for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") and rawget(w.name, "text") == "${label}" then rawget(w, "wish").scripts.OnClick() break end end`, 'click')

  // A mage (the fake game's class) with the real mage trees.
  const mage = trees.mage.map((tree) => '{' + tree.talents.map((t) => `{ "${t.field}", ${t.row + 1}, ${t.col + 1}, ${t.max} }`).join(', ') + '}').join(', ')
  run(`Fake.tree = { ${mage} }
    Fake.rank = { {}, {}, {} }
    Fake.level = 60
    UnitLevel = function() return Fake.level end
    GetNumTalents = function(tab) return #Fake.tree[tab] end
    GetTalentInfo = function(tab, i) local t = Fake.tree[tab][i] return t[1], 134400, t[2], t[3], Fake.rank[tab][i] or 0, t[4] end
    WishwellTBCDB.talentList = true SlashCmdList.WISHWELLTBC("talents")`, 'talents')
  check('/ww talents lists the builds for your class, the recommended one marked',
    /^Damage: Fire = 46 Fire \/ 13 Frost \/ 2 Arcane · recommended \[Use\] \| Damage: Arcane = 40 Arcane \/ 21 Frost \[Use\] \| Damage: Frost = /.test(rows()))
  check('it asks you to pick how you want to play', /^Pick how you want to play: damage, tank or healing\./.test(status()))

  clickRow('Damage: Fire')
  check('picking a build remembers it for this character', ev(`WishwellTBCDB.talents["Tester-"]`) === 'fire')
  check('with nothing spent, it lists the build from the top with points to spend now',
    /^Damage: Fire = .* \[Change\] \| improvedFireball = Fire · ranks 1 to 5 · spend now/.test(rows())
    && /^Fire: 0 of 61 points placed\. You have 51 points to spend\. Next: improvedFireball\./.test(status()))

  // Level 13 with two points in Improved Fireball: one point free, the rest to come.
  run(`Fake.level = 13 Fake.rank[2][1] = 2 Fake.Fire("CHARACTER_POINTS_CHANGED", -1)`, 'spent')
  check('it picks up from the talents you already have and says when each point arrives',
    /\| improvedFireball = Fire · ranks 3 to 5 · start now, done at level 14 \| /.test(rows())
    && /^Fire: 2 of 61 points placed\. You have 2 points to spend\./.test(status()))
  // The button spends the free points, in order, after asking.
  run(`Fake.learned = {}
    LearnTalent = function(tab, i) Fake.learned[#Fake.learned + 1] = tab .. ":" .. i
      Fake.rank[tab][i] = (Fake.rank[tab][i] or 0) + 1 Fake.Fire("CHARACTER_POINTS_CHANGED", -1) end
    StaticPopup_Show = function(which, text) Fake.asked = which .. "|" .. tostring(text) end
    SlashCmdList.WISHWELLTBC("talents")`, 'apply setup')
  check('with points free there is a button to spend them', ev(`rawget(WishwellTBCTalentApply, "shown")`) === true && ev(`rawget(WishwellTBCTalentApply, "text")`) === 'Spend 2 points')
  run(`WishwellTBCTalentApply.scripts.OnClick()`, 'ask')
  check('it asks first, naming the build, the talents and the cost of undoing it',
    /^WISHWELLTBC_TALENTS\|Spend 2 talent points on Fire\?\n\nimprovedFireball x2\n\nTaking talents back costs gold/.test(ev(`Fake.asked`)) && ev(`#Fake.learned`) === 0)
  run(`StaticPopupDialogs.WISHWELLTBC_TALENTS.OnAccept() Fake.Advance(5)`, 'apply')
  check('saying yes spends exactly the free points, in the build\'s order', ev(`table.concat(Fake.learned, ",")`) === '2:1,2:1' && ev(`Fake.rank[2][1]`) === 4)
  check('and says what it did', /2 talent points spent on Fire\./.test(strip(ev(`table.concat(Fake.printed, "\\n")`))))
  check('with nothing left to spend the button goes away', ev(`rawget(WishwellTBCTalentApply, "shown")`) === false)
  // A point the game refuses does not loop for ever.
  run(`Fake.level = 14 Fake.learned = {} Fake.printed = {}
    LearnTalent = function(tab, i) Fake.learned[#Fake.learned + 1] = tab .. ":" .. i end
    Fake.Fire("CHARACTER_POINTS_CHANGED", 1)
    WishwellTBCTalentApply.scripts.OnClick() StaticPopupDialogs.WISHWELLTBC_TALENTS.OnAccept() Fake.Advance(30)`, 'refused')
  check('if the game refuses a talent it stops and says so', ev(`#Fake.learned`) <= 4 && /No talent points were spent\. The game would not take improvedFireball/.test(strip(ev(`table.concat(Fake.printed, "\\n")`))))
  run(`Fake.level = 13 Fake.printed = {}`, 'back to 13')
  run(`Fake.rank[2][1] = 4 Fake.Fire("CHARACTER_POINTS_CHANGED", -2)`, 'spent-all')
  check('with no points free it names the level of the next one',
    /\| improvedFireball = Fire · rank 5 · at level 14 \| \w+ = Fire · ranks? .* · levels? 15/.test(rows())
    && /^Fire: 4 of 61 points placed\. Next: improvedFireball at level 14\./.test(status()))

  // A point somewhere the build does not go.
  run(`Fake.rank[2][1] = 3 Fake.rank[1][2] = 1 Fake.Fire("CHARACTER_POINTS_CHANGED", 0)`, 'extra')
  check('points outside the build are pointed out', /1 of your points are outside this build\. To follow it exactly, unlearn your talents at a class trainer\./.test(rows()))

  // The left-hand panel draws the three trees with where the points are and where they go.
  const cells = () => ev(`(function() local t = {} for _, c in ipairs(WishwellTBCTree.cells) do
    if rawget(c, "shown") and (rawget(c.text, "text") or "") ~= "" then t[#t + 1] = c.talent.tab .. "." .. c.talent.name .. "=" .. rawget(c.text, "text") end end
    return table.concat(t, " ") end)()`)
  check('the trees are drawn on the left with points placed and points planned',
    ev(`rawget(WishwellTBCTree, "shown")`) === true && strip(cells()).includes('2.improvedFireball=3/5')
    && ev(`rawget(WishwellTBCTree.heads[2].name, "text")`) === 'Fire' && /^3 \/ 46$/.test(ev(`rawget(WishwellTBCTree.heads[2].count, "text")`)))
  check('a point the build does not use shows in red', /\|cffff40401\|r/.test(cells()) && /red below/.test(strip(ev(`rawget(WishwellTBCSide.body, "text")`))))
  check('talents nobody has put points in or planned are greyed out', ev(`(function() local n = 0 for _, c in ipairs(WishwellTBCTree.cells) do
    if rawget(c, "shown") and (rawget(c.text, "text") or "") == "" then n = n + 1 end end return n end)()`) > 10)

  // TBC stops at level 70: with points outside the build, the last ones never arrive.
  run(`Fake.level = 70 Fake.rank[1][2] = 5 Fake.Fire("CHARACTER_POINTS_CHANGED", 0)`, 'seventy')
  // Scroll to the bottom of the list, where the last points of the build are.
  run(`Fake.offset = 500
    FauxScrollFrame_GetOffset = function() return Fake.offset end
    FauxScrollFrame_OnVerticalScroll = function(self, offset, height, fn) fn() end
    WishwellTBCScroll.scripts.OnVerticalScroll(WishwellTBCScroll, 0)`, 'scroll down')
  check('nothing is promised for a level past 70', !/levels? (7[1-9]|[89]\d)|to (7[1-9]|[89]\d)\b/.test(rows()) && /needs a talent reset to fit/.test(rows()))
  run(`Fake.offset = 0 WishwellTBCScroll.scripts.OnVerticalScroll(WishwellTBCScroll, 0)
    FauxScrollFrame_GetOffset = function() return 0 end FauxScrollFrame_OnVerticalScroll = function() end`, 'scroll up')
  run(`Fake.level = 13 Fake.rank[1][2] = 1 Fake.Fire("CHARACTER_POINTS_CHANGED", 0)`, 'thirteen')

  // What next? leads with a waiting talent point.
  run(`Fake.rank[1][2] = 0 Fake.rank[2][1] = 3 SlashCmdList.WISHWELLTBC("next")`, 'home')
  check('What next? says when a talent point is waiting', /^Talent point to spend: improvedFireball = 1 point waiting\. This is next in your Fire build, in the Fire tree\./.test(rows()))

  // Change goes back to the list of builds.
  run(`SlashCmdList.WISHWELLTBC("talents")`, 'back')
  clickRow('Damage: Fire')
  check('Change goes back to the list of builds', ev(`WishwellTBCDB.talents["Tester-"] == nil`) === true && /^Damage: Fire = .* \[Use\] \| Damage: Arcane/.test(rows()))

  // The tree view: the window given over to the three trees, with the build picker and spend buttons.
  const big = () => ev(`(function() local t = {} for _, c in ipairs(WishwellTBCBigTree.cells) do
    if rawget(c, "shown") and (rawget(c.text, "text") or "") ~= "" then t[#t + 1] = c.talent.name .. "=" .. rawget(c.text, "text") .. (c.upNext and "*" or "") end end
    return table.concat(t, " ") end)()`)
  run(`Fake.level = 13 Fake.rank = { {}, { 2 }, {} } Fake.learned = {} Fake.printed = {}
    LearnTalent = function(tab, i) Fake.learned[#Fake.learned + 1] = tab .. ":" .. i
      Fake.rank[tab][i] = (Fake.rank[tab][i] or 0) + 1 Fake.Fire("CHARACTER_POINTS_CHANGED", -1) end
    WishwellTBCToTree = WishwellTBCTalentToTree WishwellTBCToTree.scripts.OnClick()`, 'tree view')
  check('Tree view swaps the list for the three trees', ev(`rawget(WishwellTBCTalentPanel, "shown")`) === true && rows() === ''
    && ev(`WishwellTBCDB.talentList == nil`) === true)
  check('with no build picked it shows your talents as they are', strip(big()) === 'improvedFireball=2' && /as they are now/.test(ev(`rawget(WishwellTBCTalentPanel.next, "text")`)))
  run(`Fake.menu = {} rawget(WishwellTBCBuildDrop, "init")(WishwellTBCBuildDrop, 1)`, 'build menu')
  check('the build menu lists the builds, the recommended one marked',
    ev(`Fake.menu[1].text`) === 'Damage: Fire (recommended)' && ev(`Fake.menu[2].text`) === 'Damage: Arcane' && ev(`Fake.menu[#Fake.menu].text`) === 'No build: just show my talents')
  run(`Fake.menu[1].func()`, 'pick fire')
  check('picking one shows where every point goes, with the next talent marked',
    ev(`WishwellTBCDB.talents["Tester-"]`) === 'fire' && strip(big()).includes('improvedFireball=2/5*') && /^Next: improvedFireball \(now\)/.test(strip(ev(`rawget(WishwellTBCTalentPanel.next, "text")`))))
  check('there are buttons to spend the next point or all of them', ev(`rawget(WishwellTBCTalentOne, "shown")`) === true && ev(`rawget(WishwellTBCTalentAll, "text")`) === 'Spend all 2 points')
  run(`StaticPopup_Show = function(which, text) Fake.asked = which .. "|" .. tostring(text) end
    WishwellTBCTalentOne.scripts.OnClick()`, 'ask one')
  check('Spend next point asks about one point', /\|Spend 1 talent point on Fire\?\n\nimprovedFireball\n\n/.test(ev(`Fake.asked`)))
  run(`StaticPopupDialogs.WISHWELLTBC_TALENTS.OnAccept() Fake.Advance(5)`, 'spend one')
  check('and spends exactly one', ev(`#Fake.learned`) === 1 && ev(`Fake.rank[2][1]`) === 3 && strip(big()).includes('improvedFireball=3/5'))
  run(`WishwellTBCTalentToList.scripts.OnClick()`, 'order list')
  check('Order list goes back to the talents in the order to take them', ev(`WishwellTBCDB.talentList`) === true && /^Damage: Fire = /.test(rows())
    && ev(`rawget(WishwellTBCTalentPanel, "shown")`) === false)
  check('no Lua errors were printed', !/error/i.test(strip(ev(`table.concat(Fake.printed, "\\n")`))))
}

// ---- Wishwell TBC: where a quest starts, on the world map ---------------------------------------
{
  const run = makeGame({ addon: WISHTBC, toc: 20506, build: '2.5.6' })
  const ev = (code) => run(`return ${code}`, 'check')
  const strip = (text) => String(text).replace(/\|c[0-9a-f]{8}|\|r/g, '')
  const firstQuest = () => strip(ev(`(function() for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") and it.questRow then
      return it.quest[1] .. "|" .. it.quest[2] .. "|" .. tostring(rawget(rawget(w, "wish"), "shown")) .. "|" .. tostring(rawget(rawget(w, "wish"), "text")) end end end)()`))

  check('most quests ship with where they start', ev(`(function() local n = 0 for _ in pairs(WishwellTBCData.questStarts) do n = n + 1 end return n end)()`) > 3500
    && ev(`WishwellTBCData.questStarts[783][1]`) === 'Deputy Willem' && ev(`WishwellTBCData.questStarts[783][2]`) === 1429)

  // A level 12 gnome in Westfall, with a world map to open.
  run(`Fake.level = 12
    UnitLevel = function() return Fake.level end
    UnitRace = function() return "Gnome", "Gnome", 7 end
    UnitFactionGroup = function() return "Alliance", "Alliance" end
    GetRealZoneText = function() return "Westfall" end
    Fake.done, Fake.log = {}, {}
    C_QuestLog = { IsQuestFlaggedCompleted = function(id) return Fake.done[id] == true end, IsOnQuest = function(id) return Fake.log[id] == true end }
    C_Map = { GetMapInfo = function(id) return { name = id == 1436 and "Westfall" or "Somewhere" } end }
    WorldMapFrame = CreateFrame("Frame")
    Fake.canvas = CreateFrame("Frame")
    Fake.canvas.GetWidth = function() return 1000 end
    Fake.canvas.GetHeight = function() return 600 end
    WorldMapFrame.GetCanvas = function() return Fake.canvas end
    WorldMapFrame.SetMapID = function(self, id) Fake.mapId = id end
    WorldMapFrame.GetMapID = function() return Fake.mapId end
    WorldMapFrame.OnMapChanged = function() end
    ToggleWorldMap = function() WorldMapFrame:Show() end
    SlashCmdList.WISHWELLTBC("quests")`, 'setup')
  const [id, name, shown, label] = firstQuest().split('|')
  const start = JSON.parse(readFileSync(new URL('../src/data/tbc.json', import.meta.url), 'utf8')).starts[id]
  check('quest rows have a Map button', shown === 'true' && label === 'Map' && Array.isArray(start))

  run(`Fake.printed = {}
    for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
      if it and rawget(w, "shown") and it.questRow and it.quest[1] == ${id} then rawget(w, "wish").scripts.OnClick() break end end`, 'map')
  check('clicking it opens the world map on the right zone', ev(`rawget(WorldMapFrame, "shown")`) === true && ev(`Fake.mapId`) === start[1])
  check('a pin is dropped on the quest giver', ev(`rawget(WishwellTBCMapPin, "shown")`) === true && ev(`WishwellTBCMapPin.x`) === start[2] && ev(`WishwellTBCMapPin.y`) === start[3]
    && ev(`WishwellTBCMapPin.giver`) === start[0])
  check('the Wishwell window steps aside so the map can be seen', ev(`rawget(WishwellTBCFrame, "shown")`) === false)
  check('the map gets a Back to Wishwell button', ev(`rawget(WishwellTBCMapBack, "shown")`) === true && ev(`rawget(WishwellTBCMapBack, "text")`) === 'Back to Wishwell')
  run(`WishwellTBCMapBack.scripts.OnClick() if rawget(WorldMapFrame, "shown") then WorldMapFrame:Hide() end
    WorldMapFrame.scripts.OnHide() Fake.Advance(0.1)`, 'back')
  check('closing the map brings Wishwell back on the Quests tab', ev(`rawget(WorldMapFrame, "shown")`) !== true
    && ev(`rawget(WishwellTBCFrame, "shown")`) === true && ev(`WishwellTBCDB.page`) === 'quests' && ev(`rawget(WishwellTBCMapBack, "shown")`) === false)
  run(`WorldMapFrame:Show() WorldMapFrame:Hide() WorldMapFrame.scripts.OnHide() Fake.Advance(0.1) WishwellTBCFrame:Hide()
    WorldMapFrame:Show() WorldMapFrame:Hide() WorldMapFrame.scripts.OnHide() Fake.Advance(0.1)`, 'own map')
  check('opening and closing the map yourself does not open Wishwell', ev(`rawget(WishwellTBCFrame, "shown")`) === false)
  run(`SlashCmdList.WISHWELLTBC("quests")`, 'quests again')

  // The left-hand panel: a summary on tabs with nothing to try on, the character elsewhere.
  const side = () => ev(`rawget(WishwellTBCSide, "shown") and (rawget(WishwellTBCSide.title, "text") .. " :: " .. rawget(WishwellTBCSide.body, "text")) or "model"`)
  check('the Quests tab shows a summary where the character was', /quests? you can do now/.test(side()) && ev(`rawget(WishwellTBCModel, "shown")`) === false)
  run(`SlashCmdList.WISHWELLTBC("train")`, 'side train')
  check('so does Spell training', /^Spell training :: /.test(side()))
  run(`SlashCmdList.WISHWELLTBC("prof")`, 'side prof')
  check('and Professions', /^Professions :: /.test(side()))
  run(`SlashCmdList.WISHWELLTBC("talents")`, 'side talents')
  check('Talents gives the whole window to the trees', ev(`rawget(WishwellTBCTalentPanel, "shown")`) === true)
  run(`SlashCmdList.WISHWELLTBC("loot")`, 'side loot')
  check('the Loot tab still shows the character', side() === 'model' && ev(`rawget(WishwellTBCModel, "shown")`) === true)

  // The window is a little smaller unless that is switched off in Settings.
  check('the window is drawn a little smaller', ev(`rawget(WishwellTBCFrame, "scale")`) === 0.85)
  run(`SlashCmdList.WISHWELLTBC("settings")
    for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
      if it and rawget(w, "shown") and it.setting and it.entry.key == "size" then w.wish.scripts.OnClick() break end end`, 'full size')
  const switches = () => ev(`(function() local t = {} for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") and it.setting then t[#t + 1] = it.entry.key end end return table.concat(t, ",") end)()`)
  check('Settings opens on the Window section, with a button for each section', switches() === 'minimapHidden,size,hub,smooth,combatClose'
    && ev(`rawget(WishwellTBCSettings_window, "shown") and rawget(WishwellTBCSettings_wisp, "shown") and rawget(WishwellTBCSettings_popups, "shown") and rawget(WishwellTBCSettings_loot, "shown")`) === true)
  run(`WishwellTBCSettings_wisp.scripts.OnClick()`, 'wisp section')
  check('each section lists its own switches, none needing a scroll', switches() === 'sound,hints,chatter')
  run(`WishwellTBCSettings_popups.scripts.OnClick()`, 'popups section')
  check('pop-ups and the tracker are together', switches() === 'popup,lootPopup,wisp,pinPrompt,news,tracker')
  run(`WishwellTBCSettings_loot.scripts.OnClick()`, 'loot section')
  check('and so are the loot switches', switches() === 'tips,share,size' || switches() === 'tips,share,dropAlert,dropSay,preload')
  check('the section buttons go away on other pages', (run(`SlashCmdList.WISHWELLTBC("loot")`, 'away'), ev(`rawget(WishwellTBCSettings_window, "shown")`)) === false)
  check('Settings can put it back to full size', ev(`rawget(WishwellTBCFrame, "scale")`) === 1 && ev(`WishwellTBCDB.size`) === 1)
  run(`WishwellTBCDB.size = nil SlashCmdList.WISHWELLTBC("quests")`, 'quests once more')
  check('chat says who starts it and where', strip(ev(`table.concat(Fake.printed, "\\n")`)).includes(`${name} starts with ${start[0]} in `))

  run(`Fake.mapId = 1 WorldMapFrame.scripts.OnShow()`, 'other-map')
  check('the pin hides on other maps', ev(`rawget(WishwellTBCMapPin, "shown")`) === false)
  run(`Fake.mapId = ${start[1]} WorldMapFrame.scripts.OnShow()`, 'back')
  check('and comes back on its own map', ev(`rawget(WishwellTBCMapPin, "shown")`) === true)
  run(`WishwellTBCMapPin.scripts.OnUpdate(WishwellTBCMapPin, 0.3) WishwellTBCMapPin.scripts.OnClick()`, 'clear')
  check('clicking the pin removes it', ev(`rawget(WishwellTBCMapPin, "shown")`) === false && ev(`WishwellTBCMapPin.map == nil`) === true)

  // The quest guide: a small window that points at the nearest quest giver with something for you.
  run(`CreateVector2D = function(x, y) return { x = x, y = y } end
    C_Map.GetBestMapForUnit = function() return 1436 end
    C_Map.GetPlayerMapPosition = function() return { GetXY = function() return Fake.me[1], Fake.me[2] end } end
    C_Map.GetWorldPosFromMapPos = function(map, v) return 0, { GetXY = function() return -v.y * 1000, -v.x * 1500 end } end
    GetPlayerFacing = function() return 0 end
    Fake.me = { 0.5, 0.5 }
    SlashCmdList.WISHWELLTBC("quests") WishwellTBCGuideButton.scripts.OnClick()`, 'guide')
  const guide = () => strip(ev(`rawget(WishwellTBCGuide.giver, "text") .. " | " .. rawget(WishwellTBCGuide.dist, "text") .. " | " .. rawget(WishwellTBCGuide.count, "text") .. " | " .. rawget(WishwellTBCGuide.quests, "text")`))
  const stops = () => Number((guide().match(/\| (\d+) stops? left/) || [])[1])
  check('Guide me opens a small window and puts the big one away', ev(`rawget(WishwellTBCGuide, "shown")`) === true && ev(`rawget(WishwellTBCFrame, "shown")`) === false
    && ev(`rawget(WishwellTBCGuide.title, "text")`) === 'Westfall')
  check('it names a quest giver, how far and which way, and the quests there',
    /^.+ \| [\d,]+ yd  ·  (ahead|behind you|to your left|to your right) \| \d+ stops? left \| Pick up\n\[\d+\] .+ XP/.test(guide()))
  const yards = (text) => Number(text.match(/\| ([\d,]+) yd/)[1].replace(/,/g, ''))
  const first = guide()
  const before = stops()
  run(`WishwellTBCGuide.skip.scripts.OnClick()`, 'skip')
  check('Skip moves on to the next stop, which is no nearer than the one before', stops() === before - 1 && guide() !== first && yards(guide()) >= yards(first))
  run(`GetPlayerFacing = function() return math.pi end WishwellTBCGuide.scripts.OnUpdate(WishwellTBCGuide, 1)`, 'turn round')
  const way = (text) => text.match(/yd  ·  ([a-z ]+) \|/)[1]
  const flipped = { ahead: 'behind you', 'behind you': 'ahead', 'to your left': 'to your right', 'to your right': 'to your left' }
  const facingNorth = ev(`(function() GetPlayerFacing = function() return 0 end WishwellTBCGuide.scripts.OnUpdate(WishwellTBCGuide, 1) return rawget(WishwellTBCGuide.dist, "text") end)()`)
  const facingSouth = ev(`(function() GetPlayerFacing = function() return math.pi end WishwellTBCGuide.scripts.OnUpdate(WishwellTBCGuide, 1) return rawget(WishwellTBCGuide.dist, "text") end)()`)
  check('turning round flips the direction', flipped[way(strip(facingNorth) + ' |')] === way(strip(facingSouth) + ' |'))
  run(`SlashCmdList.WISHWELLTBC("guide")`, 'guide off')
  check('/ww guide closes it again', ev(`rawget(WishwellTBCGuide, "shown")`) === false && ev(`WishwellTBCDB.guide == nil`) === true)
  check('no Lua errors were printed', !/error/i.test(strip(ev(`table.concat(Fake.printed, "\\n")`))))
}

// ---- Wishwell TBC: normal and heroic dungeons, preloading, rows that open out -----------------
{
  const run = makeGame({ addon: WISHTBC, toc: 20506, build: '2.5.6' })
  const ev = (code) => run(`return ${code}`, 'check')
  const strip = (text) => String(text).replace(/\|c[0-9a-f]{8}|\|r/g, '')
  const rows = () => strip(ev(`(function() local t = {} for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") then t[#t + 1] = (rawget(w.name, "text") or "") .. " = " .. (rawget(w.meta, "text") or "") end end
    return table.concat(t, " | ") end)()`))
  const listed = () => ev(`(function() local t = {} for _, item in ipairs(WishwellTBCData.items) do t[item.id] = item end
    local n, h, o = 0, 0, 0 for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
      if it and rawget(w, "shown") and it.id and t[it.id] then n = n + 1
        if t[it.id].heroic then h = h + 1 end if t[it.id].normalOnly then o = o + 1 end end end
    return n .. ":" .. h .. ":" .. o end)()`)
  const tbcData = JSON.parse(readFileSync(new URL('../src/data/tbc.json', import.meta.url), 'utf8'))
  const ramps = tbcData.items.ramps
  check('the data marks heroic-only and normal-only drops', ramps.some((i) => i.heroic) && ramps.some((i) => i.normalOnly) && ramps.some((i) => !i.heroic && !i.normalOnly))

  // Walking into a normal dungeon loads its loot before the window is ever opened.
  run(`Fake.asked = 0
    C_Item.RequestLoadItemDataByID = function() Fake.asked = Fake.asked + 1 end
    for _, item in ipairs(WishwellTBCData.items) do if item.raid == "ramps" then Fake.cached[item.id] = false end end
    WishwellTBCDB.classFilter = "ALL"
    Fake.instance = { "Hellfire Ramparts", "party", 1, "Normal", 5, 0, false, 543 }
    Fake.Fire("PLAYER_ENTERING_WORLD") Fake.Advance(2.5)`, 'enter normal')
  const normalCount = ramps.filter((i) => !i.heroic).length
  check('walking into a dungeon asks the game for its loot straight away', ev(`Fake.asked`) >= normalCount && ev(`WishwellTBCFrame == nil or not rawget(WishwellTBCFrame, "shown")`) === true)
  check('the pop-up waits a moment for that loot to load', ev(`WishwellTBCToast == nil or rawget(WishwellTBCToast.title, "text") ~= "Hellfire Ramparts"`) === true)
  run(`for id in pairs(Fake.cached) do Fake.cached[id] = true end Fake.Advance(2)`, 'loaded')
  check('then it shows, for the normal dungeon', ev(`rawget(WishwellTBCToast, "shown")`) === true && ev(`rawget(WishwellTBCToast.title, "text")`) === 'Hellfire Ramparts')
  run(`SlashCmdList.WISHWELLTBC("loot")`, 'loot')
  check('a normal dungeon lists only what drops on normal', ev(`WishwellTBCDB.heroic`) === false && /^[1-9]\d*:0:[1-9]\d*$/.test(listed()))
  check('and says so', /^Normal drops/.test(strip(ev(`rawget(WishwellTBCFrame.status, "text")`))) && !/Normal only|Heroic only/.test(rows()))

  // Leave, come back on heroic.
  run(`Fake.instance = { "Outland", "none", 0, "", 0, 0, false, 530 }
    Fake.Fire("PLAYER_ENTERING_WORLD") Fake.Advance(3)
    Fake.instance = { "Hellfire Ramparts", "party", 2, "Heroic", 5, 0, false, 543 }
    Fake.Fire("PLAYER_ENTERING_WORLD") Fake.Advance(3)`, 'enter heroic')
  check('a heroic dungeon is recognised and gets its own list', ev(`WishwellTBCDB.heroic`) === true && /^[1-9]\d*:[1-9]\d*:0$/.test(listed()))
  check('the pop-up and the menu say Heroic', ev(`rawget(WishwellTBCToast.title, "text")`) === 'Heroic: Hellfire Ramparts'
    && /^Heroic drops/.test(strip(ev(`rawget(WishwellTBCFrame.status, "text")`))))

  // The wishlist tracker: your wishlist on screen while you play.
  const tracker = () => strip(ev(`(function() if not WishwellTBCTracker or not rawget(WishwellTBCTracker, "shown") then return "hidden" end
    local t = { rawget(WishwellTBCTracker.count, "text") } for _, l in ipairs(WishwellTBCTracker.lines) do
      if rawget(l, "shown") then t[#t + 1] = rawget(l.name, "text") .. " = " .. rawget(l.meta, "text") end end return table.concat(t, " | ") end)()`))
  check('with nothing wished for there is no tracker', tracker() === 'hidden')
  const kara = tbcData.items.kara.find((i) => i.name && !/'/.test(i.name))
  const rampsHeroic = ramps.find((i) => i.heroic && i.name && !/'/.test(i.name))
  run(`WishwellTBCDB.wish = { ["Tester-"] = { [${kara.id}] = "kara", [${rampsHeroic.id}] = "ramps" } }
    SlashCmdList.WISHWELLTBC("loot")`, 'wish two')
  check('wishing for things brings up the tracker, with what drops here first',
    new RegExp('^\\(2\\) \\| ' + rampsHeroic.name + ' = Drops here · .+ \\| ' + kara.name + ' = .+ · Karazhan').test(tracker()))
  run(`WishwellTBCTrackerFold.scripts.OnClick()`, 'fold')
  check('it folds down to its heading', tracker() === '(2)')
  run(`WishwellTBCTrackerFold.scripts.OnClick() WishwellTBCTrackerClose.scripts.OnClick()`, 'close')
  check('it can be put away', tracker() === 'hidden' && ev(`WishwellTBCDB.tracker`) === false)
  run(`SlashCmdList.WISHWELLTBC("tracker")`, 'tracker on')
  check('and /ww tracker brings it back', tracker().startsWith('(2) | '))
  run(`WishwellTBCDB.wish = {} WishwellTBCFrame:Hide()`, 'unwish')

  // The loot pop-up shows once: not after a death and a run back, and not at all when switched off.
  const toastUp = () => ev(`rawget(WishwellTBCToast, "shown") == true and rawget(WishwellTBCToast.title, "text") or ""`)
  const leave = `Fake.instance = { "Outland", "none", 0, "", 0, 0, false, 530 } Fake.Fire("PLAYER_ENTERING_WORLD") Fake.Advance(3)`
  const enter = `Fake.instance = { "Hellfire Ramparts", "party", 2, "Heroic", 5, 0, false, 543 } Fake.Fire("PLAYER_ENTERING_WORLD") Fake.Advance(4)`
  run(`WishwellTBCToast:Hide() UnitIsDeadOrGhost = function() return Fake.dead == true end
    Fake.dead = true ${leave}`, 'die')
  check('dying and releasing does not pop anything up', toastUp() === '')
  run(`Fake.dead = false ${enter}`, 'run back')
  check('running back in does not show the loot pop-up again', toastUp() === '')
  run(`${leave} WishwellTBCToast:Hide() ${enter}`, 'walk out and in')
  check('nor does walking out and straight back in', toastUp() === '')
  run(`${leave} WishwellTBCToast:Hide() Fake.Advance(31 * 60) WishwellTBCToast:Hide() ${enter}`, 'later')
  check('a new visit later shows it again', toastUp() === 'Heroic: Hellfire Ramparts')
  check('that it was shown is saved, so a /reload in the dungeon does not show it again', ev(`type(WishwellTBCDB.popped["ramps:heroic"])`) === 'number')
  run(`WishwellTBCToast:Hide() SlashCmdList.WISHWELLTBC("loot") UnitAffectingCombat = function() return Fake.fight == true end
    Fake.fight = true WishwellTBCToast:Show() Fake.Fire("PLAYER_REGEN_DISABLED")`, 'pull')
  check('starting a fight closes the window and the pop-up', ev(`rawget(WishwellTBCFrame, "shown")`) === false && ev(`rawget(WishwellTBCToast, "shown")`) === false)
  run(`SlashCmdList.WISHWELLTBC("loot") Fake.Fire("PLAYER_REGEN_DISABLED")`, 'open mid-fight')
  check('a window opened in the middle of a fight stays until it is over', ev(`rawget(WishwellTBCFrame, "shown")`) === true)
  run(`Fake.fight = false Fake.Fire("PLAYER_REGEN_ENABLED") WishwellTBCFrame:Hide()`, 'fight over')
  run(`${leave} WishwellTBCToast:Hide() Fake.Advance(31 * 60) WishwellTBCToast:Hide() WishwellTBCDB.lootPopup = false ${enter}`, 'off')
  check('with the dungeon loot pop-up switched off it never shows', toastUp() === '' && ev(`WishwellTBCDB.heroic`) === true)
  run(`WishwellTBCDB.lootPopup = nil SlashCmdList.WISHWELLTBC("settings") WishwellTBCSettings_popups.scripts.OnClick()`, 'settings')
  check('Settings has a switch for it', ev(`(function() for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") and it.setting and it.entry.key == "lootPopup" then return rawget(w.name, "text") end end end)()`) === 'Dungeon loot pop-up')
  run(`SlashCmdList.WISHWELLTBC("loot")`, 'loot again')

  // The menu: raids, then Dungeons and Heroic dungeons.
  const menu = (level, list) => ev(`(function() Fake.menu = {} rawget(WishwellTBCPlaceDrop, "init")(WishwellTBCPlaceDrop, ${level}, ${list ? `"${list}"` : 'nil'})
    local t = {} for _, m in ipairs(Fake.menu) do t[#t + 1] = m.text end return table.concat(t, "|") end)()`)
  check('the menu has Dungeons and Heroic dungeons', /\|Dungeons\|Heroic dungeons$/.test(menu(1)))
  const heroics = menu(2, 'heroics').split('|')
  check('Heroic dungeons lists the 16 TBC dungeons and no Classic ones', heroics.length === 16 && heroics.includes('The Mechanar') && !heroics.includes('The Deadmines'))
  check('Dungeons lists them all', menu(2, 'dungeons').split('|').includes('The Deadmines') && menu(2, 'dungeons').split('|').includes('The Mechanar'))
  run(`Fake.menu = {} rawget(WishwellTBCPlaceDrop, "init")(WishwellTBCPlaceDrop, 2, "dungeons")
    for _, m in ipairs(Fake.menu) do if m.text == "Magisters' Terrace" then m.func() end end`, 'pick normal')
  check('picking under Dungeons shows the normal list', ev(`WishwellTBCDB.browseId`) === 'mgt' && ev(`WishwellTBCDB.heroic`) === false && /^[1-9]\d*:0:[1-9]\d*$/.test(listed()))
  run(`Fake.menu = {} rawget(WishwellTBCPlaceDrop, "init")(WishwellTBCPlaceDrop, 2, "heroics")
    for _, m in ipairs(Fake.menu) do if m.text == "Magisters' Terrace" then m.func() end end`, 'pick heroic')
  check('picking under Heroic dungeons shows the heroic list', ev(`WishwellTBCDB.heroic`) === true && /^[1-9]\d*:[1-9]\d*:0$/.test(listed()))
  run(`Fake.menu = {} rawget(WishwellTBCPlaceDrop, "init")(WishwellTBCPlaceDrop, 1)
    for _, m in ipairs(Fake.menu) do if m.text == "Karazhan" then m.func() end end`, 'pick raid')
  check('a raid is not split', ev(`WishwellTBCDB.heroic`) === false && /^[1-9]\d*:0:0$/.test(listed()) && /^Click a row/.test(strip(ev(`rawget(WishwellTBCFrame.status, "text")`))))

  // A row whose text is cut off opens out when clicked, and closes on the next click.
  const row = (n) => `(function() local k = 0 for _, w in ipairs(Fake.frames) do if rawget(w, "item") and rawget(w, "shown") and rawget(w, "wish") then k = k + 1 if k == ${n} then return w end end end end)()`
  run(`Fake.row = ${row(2)}
    Fake.tried = Fake.row.item.id
    rawset(Fake.row.name, "GetStringHeight", function() return 13 end)
    rawset(Fake.row.meta, "GetStringHeight", function(w) return rawget(w, "wrap") and 40 or 12 end)
    rawset(Fake.row.meta, "SetWordWrap", function(w, on) rawset(w, "wrap", on) end)
    Fake.row.scripts.OnClick(Fake.row)`, 'plain click')
  check('a row whose text fits does not open out', ev(`Fake.row.open`) === false && ev(`rawget(Fake.row, "height") or 38`) === 38)
  run(`rawset(Fake.row.meta, "IsTruncated", function(w) return not rawget(w, "wrap") end)
    Fake.row.scripts.OnClick(Fake.row)`, 'open')
  check('clicking a row with cut-off text opens it out to show all of it', ev(`Fake.row.open`) === true && ev(`rawget(Fake.row.meta, "wrap")`) === true)
  run(`Fake.row.scripts.OnClick(Fake.row)`, 'close')
  check('clicking it again closes it', ev(`Fake.row.open`) === false && ev(`rawget(Fake.row.meta, "wrap")`) === false)

  // On the quest list the click opens the text; the Map button still shows the map.
  run(`SlashCmdList.WISHWELLTBC("quests")
    Fake.row = ${row(1)}
    rawset(Fake.row.name, "IsTruncated", function() return true end)
    Fake.row.scripts.OnClick(Fake.row)`, 'quest open')
  check('a cut-off quest opens out instead of jumping to the map', ev(`Fake.row.open`) === true && ev(`rawget(WishwellTBCFrame, "shown")`) === true)
  check('nothing offers to log you out any more', ev(`WishwellTBCSwitchBox == nil and WishwellTBCSwitchLogout == nil`) === true)
  check('no Lua errors were printed', !/error/i.test(strip(ev(`table.concat(Fake.printed, "\\n")`))))
}

// ---- Wishwell TBC: gear is judged for your talent build ---------------------------------------
{
  const run = makeGame({ addon: WISHTBC, toc: 20506, build: '2.5.6' })
  const ev = (code) => run(`return ${code}`, 'check')
  const strip = (text) => String(text).replace(/\|c[0-9a-f]{8}|\|r/g, '')
  // A shaman wearing a plain mail chest. Two chests to judge: one for melee, one for casting.
  run(`UnitClass = function() return "Shaman", "SHAMAN" end Fake.Fire("PLAYER_LOGIN")
    ITEM_MOD_STAMINA_SHORT = "Stamina" ITEM_MOD_INTELLECT_SHORT = "Intellect" ITEM_MOD_AGILITY_SHORT = "Agility"
    ITEM_MOD_ATTACK_POWER_SHORT = "Attack Power" ITEM_MOD_SPELL_POWER_SHORT = "Spell Power"
    ITEM_MOD_CRIT_SPELL_RATING_SHORT = "Spell Critical Strike" ITEM_MOD_CRIT_RATING_SHORT = "Critical Strike"
    Fake.stats = {
      [1] = { ITEM_MOD_STAMINA_SHORT = 10 },
      [2] = { ITEM_MOD_STAMINA_SHORT = 10, ITEM_MOD_AGILITY_SHORT = 15, ITEM_MOD_ATTACK_POWER_SHORT = 30, ITEM_MOD_CRIT_RATING_SHORT = 8 },
      [3] = { ITEM_MOD_STAMINA_SHORT = 10, ITEM_MOD_INTELLECT_SHORT = 5, ITEM_MOD_SPELL_POWER_SHORT = 25, ITEM_MOD_CRIT_SPELL_RATING_SHORT = 12 },
      [4] = { ITEM_MOD_STAMINA_SHORT = 10, ITEM_MOD_SPELL_POWER_SHORT = 25, ITEM_MOD_CRIT_SPELL_RATING_SHORT = 12 },
    }
    for id = 1, 4 do Fake.facts[id] = { classID = 4, subclassID = 3, equipLoc = "INVTYPE_CHEST" } Fake.names[id] = "Chest " .. id end
    Fake.equipped = { [5] = 1 }
    Fake.LinkOf = function(id) return "|cffffffff|Hitem:" .. id .. "::::|h[" .. Fake.names[id] .. "]|h|r" end
    GetItemInfo = function(what) local id = tonumber(what) or tonumber(tostring(what):match("item:(%d+)")) return Fake.names[id], Fake.LinkOf(id) end
    GetItemStats = function(link) return Fake.stats[tonumber(link:match("item:(%d+)"))] or {} end
    GetInventoryItemLink = function(unit, slot) local id = Fake.equipped[slot] if id then return Fake.LinkOf(id) end end
    Fake.Hover = function(id)
      Fake.tip = {}
      GameTooltip.AddLine = function(_, text) Fake.tip[#Fake.tip + 1] = text end
      GameTooltip.GetItem = function() return Fake.names[id], Fake.LinkOf(id) end
      GameTooltip.scripts.OnTooltipSetItem(GameTooltip)
      return table.concat(Fake.tip, " // ")
    end
    Fake.tree = { { { "a", 1, 1, 5 } }, { { "b", 1, 1, 5 } }, { { "c", 1, 1, 5 } } }
    Fake.rank = { {}, {}, {} }
    GetNumTalents = function(tab) return #Fake.tree[tab] end
    GetTalentInfo = function(tab, i) local t = Fake.tree[tab][i] return t[1], 134400, t[2], t[3], Fake.rank[tab][i] or 0, t[4] end
    Fake.Fire("CHARACTER_POINTS_CHANGED", -1)`, 'shaman')
  const hover = (id) => strip(ev(`Fake.Hover(${id})`))
  check('with no talents yet a shaman is judged as a bit of everything', /upgrade for you/.test(hover(2)) && /upgrade for you/.test(hover(3)) && / a Shaman /.test(hover(2)))

  // Points in the second tree: Enhancement.
  run(`Fake.rank[2][1] = 5 Fake.Fire("CHARACTER_POINTS_CHANGED", -1)`, 'enh')
  check('an Enhancement shaman sees stats in the Icy Veins order: Attack Power a key stat, Agility useful',
    /Wishwell: upgrade for you/.test(hover(2)) && /\+30 AP  a key stat for you \(#2\)/.test(hover(2)) && /\+15 Agi  useful to you \(#6\)/.test(hover(2))
    && /\+8 Crit  useful to you \(#5\)/.test(hover(2)) && /Enhancement Shaman/.test(hover(2)))
  run(`Fake.stats[5] = { ITEM_MOD_STAMINA_SHORT = 30 } Fake.facts[5] = { classID = 4, subclassID = 3, equipLoc = "INVTYPE_CHEST" } Fake.names[5] = "Chest 5"`, 'stamina chest')
  check('Stamina is low priority for them, not a key stat', /\+20 Stam  low priority for you \(#9\)/.test(hover(5)) && !/Stam  a key stat/.test(hover(5)))
  check('and that spell power does nothing for them', /Spell Dmg  no use to you/.test(hover(4)) && !/Wishwell: upgrade for you/.test(hover(4)))

  // The stat check: your own numbers against the build's list and its caps.
  run(`UnitStat = function(unit, i) local v = ({ 310, 220, 400, 150, 90 })[i] return v, v, 0, 0 end
    UnitAttackPower = function() return 1100, 140, 0 end
    GetCombatRatingBonus = function(id) return ({ [6] = 3.2, [18] = 0 })[id] or 0 end
    GetHitModifier = function() return 0 end
    GetExpertise = function() return 26, 26 end
    GetCritChance = function() return 18.44 end
    SlashCmdList.WISHWELLTBC("ask check my stats")`, 'stat check')
  const said = strip(ev(`(function() local last for _, e in ipairs(WishwellTBCChat.order) do if e.kind == "a" then last = e.text end end return last end)()`))
  check('Wisp checks your stats against your build, in its order', /^Stat check for Enhancement, in the order the Icy Veins guide gives\.\n1\. Expertise 26 of 26 capped\n2\. Strength 310  \/  Attack Power 1,240\n3\. Hit 3\.2% of 9% 5\.8% short\n4\. Haste 0\.0%\n5\. Crit 18\.4%\n6\. Agility 220\n/.test(said))
  check('it says what to work on first and what is already capped', /Work on first: Strength, then Attack Power, then Hit \(5\.8% short\)\./.test(said) && /At its cap, so more is wasted: Expertise\./.test(said))

  // The BiS check: what you are wearing against the list for your build.
  const lastAnswer = () => strip(ev(`(function() local last for _, e in ipairs(WishwellTBCChat.order) do if e.kind == "a" then last = e.text end end return last end)()`))
  const under = () => ev(`(function() local n = 0 for i = #WishwellTBCChat.order, 1, -1 do local e = WishwellTBCChat.order[i] if e.kind ~= "r" then break end n = n + 1 end return n end)()`)
  run(`Fake.names[29040] = "Cyclone Helm" Fake.names[29381] = "Choker of Vile Intent"
    Fake.equipped = { [1] = 29040, [2] = 29381, [5] = 1 }
    SlashCmdList.WISHWELLTBC("ask well im already in bis gear")`, 'bis check')
  check('saying you are in BiS gear gets your gear checked against the list', /^BiS check for Enhancement, phase 1\. You're wearing 2 of 17 pieces from the list\. The 15 you're missing are below, with where each comes from\./.test(lastAnswer()))
  check('the missing pieces are listed under it', under() === 8 && /and 7 more/.test(ev(`(function() for _, r in ipairs(WishwellTBCChat.replies) do local t = rawget(r.text, "text") or "" if t:find("more%.") and rawget(r, "shown") then return t end end return "" end)()`)))
  run(`SlashCmdList.WISHWELLTBC("ask bis phase 2")`, 'bis phase 2')
  check('another phase can be asked for, and is remembered', /^BiS check for Enhancement, phase 2\. You're wearing 0 of 17/.test(lastAnswer()) && ev(`WishwellTBCDB.bisPhase`) === 2)
  run(`local list = WishwellTBCData.bis.SHAMAN.enh[1].items
    Fake.equipped = {} for i, id in ipairs(list) do Fake.equipped[i] = id Fake.names[id] = Fake.names[id] or ("Item " .. id) end
    SlashCmdList.WISHWELLTBC("ask am i bis for phase 1")`, 'full bis')
  check('wearing the whole list says so', /^BiS check for Enhancement, phase 1\. You're wearing 17 of 17 pieces from the list\. That's all of it\./.test(lastAnswer()) && under() === 0)
  run(`SlashCmdList.WISHWELLTBC("ask what is bis")`, 'what is bis')
  check('asking what BiS means explains it and offers the check', /^BIS is short for best in slot: .* Want me to check your gear against the list for your build\?/.test(lastAnswer()))
  run(`SlashCmdList.WISHWELLTBC("ask yes")`, 'yes to bis')
  check('and yes runs it', /^BiS check for Enhancement, phase 1\./.test(lastAnswer()))
  run(`Fake.equipped = { [5] = 1 }`, 'back to the plain chest')

  // "Check me": talents, stats and gear against the build, all at once.
  run(`WishwellTBCChatCheck.scripts.OnClick()`, 'check me')
  check('Check me goes through talents, stats and gear for your build',
    /^Character check for Enhancement, level \d+:\nTalents  going by where your points are, you're Enhancement\.[^\n]*\nStats  Short of the cap: Hit \(5\.8% short\)\. Capped: Expertise\. Work on first: Strength, then Attack Power, then Hit\.\nGear  \d+ of 17 pieces of the phase 1 best-in-slot list\./.test(lastAnswer()))
  check('asking how to do the most damage runs the same check', /^Character check for Enhancement/.test((run(`SlashCmdList.WISHWELLTBC("ask how do i do the most damage")`, 'dmg'), lastAnswer())))
  // Hovering a talent in the tree: the game's description, and the most points it takes.
  run(`SlashCmdList.WISHWELLTBC("talents")
    Fake.tipLines = {}
    rawset(GameTooltip, "SetTalent", function() error("not on this client") end)
    GetTalentLink = function(tab, i) return "|Htalent:" .. tab .. i .. "|h[x]|h" end
    rawset(GameTooltip, "SetHyperlink", function(self, link) Fake.tipLink = link Fake.tipLines = { "name", "what it does" } end)
    rawset(GameTooltip, "NumLines", function() return #Fake.tipLines end)
    rawset(GameTooltip, "AddLine", function(self, text) Fake.tipLines[#Fake.tipLines + 1] = text end)
    rawset(GameTooltip, "SetText", function(self, text) Fake.tipLines = { text } end)
    local cell = WishwellTBCBigTree.cells[1]
    cell.scripts.OnEnter(cell)`, 'hover a talent')
  check('where the talent tooltip will not fill, the talent link is used', /^\|Htalent:/.test(ev(`Fake.tipLink or ""`)))
  check('the tooltip says how many points the talent takes', /Points: \d of \d\. It takes \d at most\./.test(ev(`table.concat(Fake.tipLines, " / ")`)))
  run(`rawset(GameTooltip, "SetTalent", nil) GetTalentLink = nil rawset(GameTooltip, "SetHyperlink", nil) rawset(GameTooltip, "NumLines", nil) rawset(GameTooltip, "AddLine", nil) GameTooltip.SetText = nil`, 'tip back')
  // How the game works, from your own tooltips.
  run(`SlashCmdList.WISHWELLTBC("ask why do i pull so much threat")
    Fake.talentTip = { ["2:1"] = "Requires 5 points in Enhancement\\nReduces all threat generated by your melee attacks by 30%. Also good.", ["1:1"] = "Your Frost Shock causes more threat." }
    rawset(WishwellTBCAskTip, "SetTalent", function(self, tab, i) Fake.tipNow = Fake.talentTip[tab .. ":" .. i] end)
    rawset(WishwellTBCAskTip, "NumLines", function() return Fake.tipNow and 2 or 0 end)
    WishwellTBCAskTipTextLeft2 = { GetText = function() return Fake.tipNow end }
    SlashCmdList.WISHWELLTBC("ask why do i pull so much threat")`, 'threat')
  check('a question about threat is answered from your own talent tooltips, not from a quest with that word in it',
    /^What the game says about threat for an Enhancement Shaman\. Your own tooltips, word for word:\nTalent a \(0\/5, not taken\): "Your Frost Shock causes more threat"\nTalent b \(5\/5\): "Reduces all threat generated by your melee attacks by 30%"\n\nSo, to pull less: use b\.$/.test(lastAnswer()))
  run(`Fake.rank[2][1] = 2 Fake.Fire("CHARACTER_POINTS_CHANGED", 0) Fake.gearTip = "Equip: Reduces the threat you generate by 2%."
    rawset(WishwellTBCAskTip, "SetInventoryItem", function(self, unit, slot) Fake.tipNow = slot == 5 and Fake.gearTip or nil end)
    SlashCmdList.WISHWELLTBC("ask how do i lower my threat")`, 'threat again')
  check('it points at a threat talent that is not maxed, and reads what you are wearing',
    /Worn Chest 1: "Equip: Reduces the threat you generate by 2%"/.test(lastAnswer()) && /So, to pull less: take b \(2\/5\); use b\.$/.test(lastAnswer()))
  run(`Fake.rank[2][1] = 5 Fake.Fire("CHARACTER_POINTS_CHANGED", 0)`, 'maxed again')
  run(`SlashCmdList.WISHWELLTBC("ask how do i get more haste")`, 'haste')
  check('when the tooltips say nothing it says so and adds nothing', /^Nothing an Enhancement Shaman has mentions haste: not your talents, your spells, what you're wearing or what's cast on you\. I only repeat what the game itself says/.test(lastAnswer()))

  // Picking a build on the Talents tab wins over the points spent.
  run(`WishwellTBCDB.talentList = true SlashCmdList.WISHWELLTBC("talents")
    for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
      if it and rawget(w, "shown") and it.build and it.build.key == "resto" then w.wish.scripts.OnClick() break end end`, 'resto')
  check('the build picked on the Talents tab decides', ev(`WishwellTBCDB.talents["Tester-"]`) === 'resto'
    && /Restoration Shaman/.test(hover(3)) && /Wishwell: upgrade for you/.test(hover(3)) && /Agi  no use to you/.test(hover(2)))
  check('no Lua errors were printed', !/error/i.test(strip(ev(`table.concat(Fake.printed, "\\n")`))))
}

// ---- Wishwell TBC: a dungeon is known by the game's number for it, whatever the game calls it ----
{
  // Saved by an older version that took "Coilfang: The Underbog" for a place it had never heard of.
  const run = makeGame({ addon: WISHTBC, toc: 20506, build: '2.5.6',
    saved: `WishwellTBCDB = { browseId = "m546", madeUp = { m546 = { name = "Coilfang The Underbog", kind = "dungeon" } },
      learned = { m546 = { [24465] = "The Black Stalker" } }, kills = { m546 = { Hungarfen = 1 } },
      wish = { ["Tester-"] = { [24465] = "m546" } } }` })
  const ev = (code) => run(`return ${code}`, 'check')
  check('what an older version filed under a made-up dungeon moves to the real one',
    ev(`WishwellTBCDB.madeUp.m546 == nil and WishwellTBCDB.learned.m546 == nil and WishwellTBCDB.kills.ub.Hungarfen`) === 1
    && ev(`WishwellTBCDB.wish["Tester-"][24465]`) === 'ub' && ev(`WishwellTBCDB.browseId`) === 'ub')
  run(`WishwellTBCDB.browseId = "kara"
    Fake.instance = { "Coilfang: The Underbog", "party", 1, "Normal", 5, 0, false, 546 }
    Fake.Fire("PLAYER_ENTERING_WORLD") Fake.Advance(5)`, 'underbog')
  check('"Coilfang: The Underbog" is recognised as The Underbog', ev(`WishwellTBCDB.browseId`) === 'ub' && ev(`next(WishwellTBCDB.madeUp) == nil`) === true
    && ev(`rawget(WishwellTBCToast.title, "text")`) === 'The Underbog')
  run(`Fake.instance = { "Outland", "none", 0, "", 0, 0, false, 530 } Fake.Fire("PLAYER_ENTERING_WORLD") Fake.Advance(3)
    WishwellTBCDB.browseId = "kara"
    Fake.instance = { "Auchindoun: Mana-Tombs", "party", 1, "Normal", 5, 0, false, 0 }
    Fake.Fire("PLAYER_ENTERING_WORLD") Fake.Advance(5)`, 'by name')
  check('without a number, the name after the colon still finds it', ev(`WishwellTBCDB.browseId`) === 'mt')
  // The window gets out of the way when a fight starts.
  run(`SlashCmdList.WISHWELLTBC("loot") Fake.Fire("PLAYER_REGEN_DISABLED")`, 'fight starts')
  check('the window closes when combat starts', ev(`rawget(WishwellTBCFrame, "shown")`) === false)
  run(`Fake.Fire("PLAYER_REGEN_ENABLED") SlashCmdList.WISHWELLTBC("loot")
    WishwellTBCDB.combatClose = false Fake.Fire("PLAYER_REGEN_DISABLED")`, 'setting off')
  check('unless that is switched off in Settings', ev(`rawget(WishwellTBCFrame, "shown")`) === true)
  run(`WishwellTBCDB.combatClose = nil Fake.Fire("PLAYER_REGEN_ENABLED") Fake.Advance(1)`, 'fight over')

  // Item sets: picking a class shows that class's sets only.
  const setRows = () => ev(`(function() local t = {} for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
    if it and rawget(w, "shown") and it.bonus then t[#t + 1] = rawget(w.name, "text") end end return table.concat(t, "|") end)()`)
  run(`Fake.facts[31064] = { classID = 4, subclassID = 1, equipLoc = "INVTYPE_HEAD" }   -- Absolution Regalia: cloth, priests only
    Fake.tooltips[31064] = { { leftText = "Hood of Absolution" }, { leftText = "Classes: Priest" } }
    Fake.facts[23507] = { classID = 4, subclassID = 4, equipLoc = "INVTYPE_CHEST" }  -- Adamantite Battlegear: plate
    Fake.facts[21868] = { classID = 4, subclassID = 1, equipLoc = "INVTYPE_ROBE" }   -- Arcanoweave Vestments: cloth, anyone
    WishwellTBCDB.classFilter = "WARRIOR" SlashCmdList.WISHWELLTBC("sets")`, 'warrior sets')
  check('a warrior sees plate sets, not priest or other cloth sets',
    /Adamantite Battlegear/.test(setRows()) && !/Absolution Regalia/.test(setRows()) && !/Arcanoweave Vestments/.test(setRows()))
  run(`WishwellTBCDB.classFilter = "PRIEST" SlashCmdList.WISHWELLTBC("sets")`, 'priest sets')
  check('a priest sees the priest set and cloth sets, not plate', /Absolution Regalia/.test(setRows()) && /Arcanoweave Vestments/.test(setRows()) && !/Adamantite Battlegear/.test(setRows()))
  run(`WishwellTBCDB.classFilter = "MAGE" SlashCmdList.WISHWELLTBC("sets")`, 'mage sets')
  check('a mage sees cloth sets but not the priest-only one', /Arcanoweave Vestments/.test(setRows()) && !/Absolution Regalia/.test(setRows()))
  // Set bonuses are not in the data: they are read off the tooltip of one of the set's pieces.
  run(`Fake.tipLines = {}
    rawset(GameTooltip, "AddLine", function(self, text) Fake.tipLines[#Fake.tipLines + 1] = text end)
    for _, w in ipairs(Fake.frames) do local it = rawget(w, "item")
      if it and rawget(w, "shown") and it.bonus and w.scripts.OnEnter then
        w.scripts.OnEnter(w)
        rawset(WishwellTBCSetTip, "SetHyperlink", function() end)
        rawset(WishwellTBCSetTip, "NumLines", function() return 4 end)
        WishwellTBCSetTipTextLeft2 = { GetText = function() return "Arcanoweave Vestments (0/3)" end }
        WishwellTBCSetTipTextLeft3 = { GetText = function() return "(2) Set: Reduces the chance your spells are interrupted." end }
        WishwellTBCSetTipTextLeft4 = { GetText = function() return "(3) Set: Increases arcane resistance by 8." end }
        Fake.tipLines = {}
        w.scripts.OnEnter(w)
        break
      end end
    rawset(GameTooltip, "AddLine", nil)`, 'hover a set')
  check('hovering a set shows its bonuses, read from a piece', /\(2\) Set: Reduces the chance your spells are interrupted\. \| \(3\) Set: Increases arcane resistance by 8\./.test(ev(`table.concat(Fake.tipLines, " | ")`)))
  run(`WishwellTBCDB.classFilter = "ALL" SlashCmdList.WISHWELLTBC("sets")`, 'all sets')
  check('All classes still shows everything', /Absolution Regalia\|Adamantite Battlegear/.test(setRows()))
  run(`WishwellTBCDB.classFilter = "MINE"`, 'mine')

  // After logging in, every TBC raid and dungeon drop is loaded in the background, a few at a time.
  run(`Fake.asked = {} Fake.count = 0
    C_Item.RequestLoadItemDataByID = function(id) if not Fake.asked[id] then Fake.asked[id] = true Fake.count = Fake.count + 1 end end
    for _, item in ipairs(WishwellTBCData.items) do Fake.cached[item.id] = false end
    Fake.Fire("PLAYER_LOGIN") Fake.Advance(11)`, 'preload start')
  const first = ev(`Fake.count`)
  check('it starts gently, not all at once', first > 0 && first <= 60)
  run(`InCombatLockdown = function() return true end Fake.Advance(20)`, 'fight')
  check('it waits during a fight', ev(`Fake.count`) === first)
  run(`InCombatLockdown = function() return false end Fake.Advance(600)`, 'preload rest')
  const tbcPlaces = new Set(['kara', 'gruul', 'mag', 'ssc', 'tk', 'hyjal', 'bt', 'za', 'swp', 'ramps', 'bf', 'sp', 'ub', 'mt', 'ac', 'ohf', 'seth', 'sv', 'slabs', 'sh', 'bm', 'mech', 'bot', 'arc', 'mgt'])
  const tbcItems = JSON.parse(readFileSync(new URL('../src/data/tbc.json', import.meta.url), 'utf8')).items
  const wanted = new Set(Object.entries(tbcItems).filter(([place]) => tbcPlaces.has(place)).flatMap(([, list]) => list.map((i) => i.id)))
  check('then loads every TBC raid and dungeon drop', ev(`Fake.count`) === wanted.size && wanted.size > 1500)
  check('and leaves Classic loot until it is looked at', ev(`Fake.asked[16800] == nil`) === true)
  run(`for id in pairs(Fake.cached) do Fake.cached[id] = true end`, 'cached')
  run(`Fake.printed = {} SlashCmdList.WISHWELLTBC("tipcheck")`, 'tipcheck')
  check('/ww tipcheck says how tooltips are hooked', /Tooltip check: hooked by /.test(ev(`table.concat(Fake.printed, " ")`)))
  check('no Lua errors were printed', !/error/i.test(ev(`table.concat(Fake.printed, "\\n")`)))
}

// ---- Wishwell TBC: the Ask box, answering from the world data ----------------------------------
{
  const WORLD = { name: 'WishwellTBC_World', files: ['Data.lua'] }
  const run = makeGame({ addon: WISHTBC, also: WORLD, toc: 20506, build: '2.5.6' })
  const ev = (code) => run(`return ${code}`, 'check')
  const strip = (text) => String(text).replace(/\|c[0-9a-f]{8}|\|r/g, '')
  check('the world data ships every NPC, item and quest objective', ev(`(function() local n = 0 for _ in pairs(WishwellTBCWorld.npcs) do n = n + 1 end return n end)()`) > 15000
    && ev(`(function() local n = 0 for _ in pairs(WishwellTBCWorld.items) do n = n + 1 end return n end)()`) > 20000 && ev(`WishwellTBCWorld.quests[6][5]`).startsWith('Kill Garrick Padfoot'))
  // What the conversation shows for the last question: the answer, then each thing under it
  // as "name = small print [button]". Before anything is asked: the examples.
  const rows = () => strip(ev(`(function() local order, from = WishwellTBCChat.order or {}, 1
    for i, e in ipairs(order) do if e.kind == "q" then from = i + 1 end end
    local t = {} for i = from, #order do local e = order[i]
      t[#t + 1] = e.text .. " = " .. (e.meta or "") .. (e.button and (" [" .. e.button .. "]") or "") end
    return table.concat(t, " | ") end)()`))
  const ask = (question) => {
    // The real game tells the box its text changed; the fake needs telling.
    run(`SlashCmdList.WISHWELLTBC("ask ${question}")
      for _, w in ipairs(Fake.frames) do if rawget(w, "name") == "WishwellTBCSearch" then w.scripts.OnTextChanged() end end`, 'ask')
    return rows()
  }
  check('/ww ask opens the Wisp chat on a greeting and examples to click', ask('').startsWith('Where an item drops = where does Hellreaver drop [Ask] | Who sells something = ') && ev(`WishwellTBCDB.page`) === 'ask'
    && ev(`rawget(WishwellTBCFrame.status, "text")`) === 'Type a question, or click an example.')
  run(`for _, w in ipairs(Fake.frames) do local c = rawget(w, "chat")
    if type(c) == "table" and c.text == "Where someone is" then w.scripts.OnClick() break end end`, 'click example')
  check('clicking an example asks it', /^Hogger is a level 11 elite/.test(rows()))
  // Ask is hard to miss: a box in the header on every tab, and a tab of its own.
  run(`SlashCmdList.WISHWELLTBC("loot")
    rawset(WishwellTBCAskBar, "text", "where is hogger") WishwellTBCAskBar.scripts.OnEnterPressed(WishwellTBCAskBar)
    for _, w in ipairs(Fake.frames) do if rawget(w, "name") == "WishwellTBCSearch" then w.scripts.OnTextChanged() end end`, 'ask bar')
  check('typing in the header box and pressing Enter asks from any tab', ev(`WishwellTBCDB.page`) === 'ask' && /^Hogger is a level 11 elite/.test(rows())
    && ev(`rawget(WishwellTBCAskBar, "text")`) === '')
  check('there is an Ask tab too', ev(`WishwellTBCFrame.tabs.ask ~= nil`) === true)
  // Five tabs; Gear and Me hold several pages, picked from buttons in the header.
  check('there are five tabs', ev(`(function() local n = 0 for _ in pairs(WishwellTBCFrame.tabs) do n = n + 1 end return n end)()`) === 5)
  run(`WishwellTBCFrame.tabs.gear.scripts.OnClick()`, 'gear tab')
  check('Gear opens on Loot, with Loot, Wishlist and Sets in the header', ev(`WishwellTBCDB.page`) === 'browse' && ev(`rawget(WishwellTBCPage_browse, "shown") and rawget(WishwellTBCPage_wish, "shown") and rawget(WishwellTBCPage_sets, "shown")`) === true
    && ev(`rawget(WishwellTBCPage_browse, "text")`) === 'Loot')
  run(`WishwellTBCPage_sets.scripts.OnClick() WishwellTBCFrame.tabs.me.scripts.OnClick()`, 'sets then me')
  check('Me opens on Talents and swaps the header buttons', ev(`WishwellTBCDB.page`) === 'talents' && ev(`rawget(WishwellTBCPage_prof, "shown")`) === true && ev(`rawget(WishwellTBCPage_sets, "shown")`) === false)
  run(`WishwellTBCPage_alts.scripts.OnClick() WishwellTBCFrame.tabs.gear.scripts.OnClick()`, 'back to gear')
  check('a tab remembers which of its pages was open last', ev(`WishwellTBCDB.page`) === 'sets')
  run(`WishwellTBCFrame.tabs.me.scripts.OnClick()`, 'back to me')
  check('and so does the other', ev(`WishwellTBCDB.page`) === 'alts')
  run(`WishwellTBCFrame.tabs.quests.scripts.OnClick()`, 'quests tab')
  check('a tab with one page shows no header buttons', ev(`WishwellTBCDB.page`) === 'quests' && ev(`rawget(WishwellTBCPage_alts, "shown")`) === false)
  check('the window is its own rounded frame, with soft buttons', ev(`rawget(WishwellTBCFrame, "template")`) !== 'ButtonFrameTemplate' && ev(`rawget(WishwellTBCAskButton, "template")`) !== 'UIPanelButtonTemplate')
  check('where an item drops: boss, dungeon and difficulty', /^Hellreaver drops from Nazan & Vazruden in Hellfire Ramparts \(normal only\)/.test(ask('where does Hellreaver drop?')))
  check('the item itself is listed under the answer, ready to wish for', / \| Hellreaver = .*\[Wish\]/.test(rows()))
  check('who sells an item', /^Rough Arrow is sold by .+ in .+ \(\d+\.\d, \d+\.\d\)/.test(ask('who sells rough arrow')))
  check('where an NPC is, with a Map button', /^Hogger is a level 11 elite, found around Elwynn Forest \(25\.8, 89\.8\) \(5 spots; the pin marks the middle\)\./.test(ask('where is Hogger'))
    && / \| Hogger  Level 11 = Elwynn Forest \(25\.8, 89\.8\) \[Map\]/.test(rows()))
  // Where to level, however it is asked.
  check('"where can i get the most experience" is a where-to-level question', !/couldn't find|best guess/.test(ask('where can i get the most experience')))
  // No answer: the question is kept, and a button offers to send it on.
  run(`WishwellTBCDB.missed = nil StaticPopup_Show = function(which, a, b, data) Fake.box = which .. " " .. tostring(data) end`, 'feedback setup')
  check('with no answer Wisp offers to send the question on', /Can't find what you're looking for\? = Tell the author what you asked, so I can learn it \[Send\]/.test(ask('zzqx flurble')))
  check('and remembers what it could not answer', ev(`WishwellTBCDB.missed[1]`) === 'zzqx flurble')
  run(`for _, l in ipairs(WishwellTBCChat.lines) do if rawget(l, "shown") and l.row and l.row.feedback then l.go.scripts.OnClick() break end end`, 'send')
  check('Send puts the question in a box to copy', ev(`Fake.box`) === 'WISHWELLTBC_FEEDBACK Wishwell TBC 1.2.0: Wisp couldn\'t answer "zzqx flurble"')
  // What's new.
  check('"what\'s new" lists this version\'s changes', /^Wishwell TBC 1\.2\.0\n- Ask Wisp how the game works/.test(ask("what's new")))
  run(`WishwellTBCDB.newsSeen = "1.1.0" Fake.Fire("PLAYER_LOGIN") Fake.Fire("PLAYER_ENTERING_WORLD")
    Fake.shownNews = WishwellTBCDB.newsSeen`, 'logged in after an update')
  check('the update run-down pops up once', ev(`(function() SlashCmdList.WISHWELLTBC("news") return rawget(WishwellTBCToast, "shown") and rawget(WishwellTBCToast.title, "text") end)()`) === 'Wishwell TBC 1.2.0')
  run(`WishwellTBCFrame:Hide() WishwellTBCDB.page = 'home' WishwellTBCToast.scripts.OnClick(WishwellTBCToast, 'LeftButton')`, 'click the run-down')
  check('clicking the run-down opens Wisp on the full list', ev(`rawget(WishwellTBCFrame, 'shown') and WishwellTBCDB.page`) === 'ask' && /^Wishwell TBC 1\.2\.0\n- Ask Wisp/.test(rows()))
  check('how the game works: mount speed', /^Mount speed\nYour Riding skill sets how fast[\s\S]*Journeyman \(150\): \+100%[\s\S]*Artisan \(300\): \+280% flying/.test(ask('how does mount speed work')))
  run(`GetNumSkillLines = function() return 1 end GetSkillLineInfo = function() return "Riding", false, false, 150 end`, 'riding skill')
  check('and it says where your own Riding skill puts you', /Your Riding skill is 150: \+100% on the ground\./.test(ask('how fast is an epic mount')))
  run(`GetNumSkillLines = nil GetSkillLineInfo = nil`, 'skills back')
  check('the hit cap, with an offer to check yours', /^Hit\n[\s\S]*142 hit rating[\s\S]*202 spell hit rating[\s\S]*Want me to check yours\?/.test(ask('what is the hit cap'))
    && /^(Stat check for |Pick a build on the Talents tab)/.test(ask('yes')))
  check('heroic keys', /^Heroic dungeons\n[\s\S]*Flamewrought Key, from Honor Hold or Thrallmar/.test(ask('how do heroics work')))
  check('rested XP', /^Rested XP\n[\s\S]*kills give double XP/.test(ask('how does rested xp work')))
  check('a how-it-works word inside a look-up is still a look-up', !/^Mount speed/.test(ask('where is the riding trainer')) && !/^Hit\n/.test(ask('why do i miss so much')))
  check('a world drop is described by the levels and zones of what drops it',
    /^Blade of Wizardry is a world drop: \d+ kinds of level \d+-\d+ creature can drop it, most of them in .+\. Likeliest: .+ \((under )?[\d.]+%\)/.test(ask('where does blade of wizardry drop')))
  check('an ordinary drop names who drops it and how often', /^Primal Life is dropped by .+ \(\d+%\)\./.test(ask('where does primal life drop')))
  check('leather says what it is skinned from', /Knothide Leather[^\n]* is skinned from .+ \(\d+%\)/.test(ask('where do i get knothide leather')))
  check('a fish says where it is fished up', /is fished up in .+ \((under )?[\d.]+%\)/.test(ask('where do i get spotted feltail')))
  check('a pool fish says which pools', /is found in .*School.* \((under )?[\d.]+%\)/.test(ask('where do i get furious crawdad')))
  // A world drop with no named dropper still says how else to get it.
  check('a world drop also says who it can be pickpocketed from', /^Ivycloth Tunic is a world drop: [\s\S]*can be pickpocketed from .+ \((under )?[\d.]+%\)/.test(ask('where do i get ivycloth tunic')))
  check('and which chests it is found in, with the chance', /^Silver-thread Robe is a world drop: [\s\S]*can be pickpocketed from [\s\S]*is found in .*Chest.* \((under )?[\d.]+%\)/.test(ask('where does silver-thread robe drop')))
  check('an ordinary creature lists its own drops with their chances',
    /^Flesh Eater is a .*Drops \d+ things? I know of/.test(ask('what does flesh eater drop')) && /Flesh Eater · \d+%/.test(rows()))
  check('what a boss drops', /^Attumen the Huntsman is a .*Drops \d+ things? I know of/.test(ask('what does attumen the huntsman drop')) && /Attumen the Huntsman/.test(rows().split(' | ')[3]))
  check('a quest: where it starts, what it asks, where to hand it in',
    /^Bounty on Garrick Padfoot is a level \d+ quest that starts with .+\. Kill Garrick Padfoot and bring his head to Deputy Willem at Northshire Abbey\. Hand it in to Deputy Willem in Elwynn Forest/.test(ask('bounty on garrick padfoot')))
  check('a dungeon by name', /^The Underbog is a dungeon in Zangarmarsh, for levels 63 to 65, with a heroic version at 70\. Bosses: Hungarfen, /.test(ask('the underbog')))
  check('stat priority, when no build is known yet', /^Pick a build on the Talents tab/.test(ask('what is my stat priority')))
  run(`UnitFactionGroup = function() return "Alliance", "Alliance" end
    C_Map = { GetBestMapForUnit = function() return 1429 end, GetMapInfo = function() return { name = "Elwynn Forest" } end,
      GetPlayerMapPosition = function() return { GetXY = function() return 0.44, 0.66 end } end }`, 'elwynn')
  check('the nearest innkeeper on the map you are on', /^Innkeepers? here, nearest first\. Click Map for a pin\. =  \| Innkeeper Farley  Level 30 = Innkeeper · Elwynn Forest \(43\.8, 65\.8\)/.test(ask('nearest innkeeper')))
  check('nothing found says so, with examples', /^I couldn't find anything called "zzyzx"\. Check the spelling/.test(ask('where is zzyzx')))
  check('a close name still finds things, best fit first', /^Hogger is a /.test(ask('hogger')))
  check('asking in the plural finds the creature, where it roams and the quest that wants it',
    /^Cabal Initiate is a level 62-63 creature, found around Terokkar Forest \(\d+\.\d, \d+\.\d\) \(\d+ spots; the pin marks the middle\)\. Wanted for the quest Before Darkness Falls\./.test(ask('where are the cabal initiates')))
  // Colour, and a link out to the web.
  ask('where is Hogger')
  const raw = ev(`(function() local last for _, e in ipairs(WishwellTBCChat.order) do if e.kind == "a" then last = e.text end end return last end)()`)
  check('answers colour who and where', /^\|cffff9d5cHogger\|r is a level 11 elite, found around \|cff7fd4a3Elwynn Forest \(25\.8, 89\.8\)\|r/.test(raw))
  check('an answer comes with a Wowhead link to copy', / \| Hogger on Wowhead = Opens a box with the link to copy \[Link\]/.test(rows()))
  run(`StaticPopup_Show = function(which, a, b, data) Fake.link = which .. " " .. tostring(data) end
    for _, l in ipairs(WishwellTBCChat.lines) do if rawget(l, "shown") and l.row and l.row.link and l.row.name == "Hogger on Wowhead" then l.go.scripts.OnClick() break end end`, 'link')
  check('its button shows the link in a box', ev(`Fake.link`) === 'WISHWELLTBC_LINK https://www.wowhead.com/tbc/npc=448')
  check('when nothing is found it offers things it can answer, not a web search', /^I couldn't find anything called "zzyzx plorp"\. Check the spelling, or try fewer words\. Or try one of these:[\s\S]* =  \| What should I do next\? = Something I can answer \[Ask\] \| Best upgrades for me = /.test(ask('where is zzyzx plorp'))
    && !/Wowhead/.test(rows()))

  // Wisp talks back.
  check('it greets you back, by name', /^(Hi|Hello|Hey), Tester! /.test(ask('hello')))
  check('it says who it is', /^I'm Wisp, the little light that lives in Wishwell\./.test(ask('who are you?')))
  check('it takes thanks', /^(Any time!|Happy to help|You're welcome!|No trouble at all|That's what I'm here for)/.test(ask('thanks wisp')))
  check('help explains and lists examples', /^I look things up in Wishwell's lists for you\..* =  \| Where an item drops = /.test(ask('help')))
  check('it has a joke ready', /\?|\./.test(ask('tell me a joke')) && !/couldn't find/.test(rows()))
  check('it knows who you are', /^You're Tester, level \d+ \w+\. And my favourite, obviously\./.test(ask('who am i')))
  check('it does not claim to be an AI', /^I'm a wisp with a very good memory and no internet\./.test(ask('are you an ai?')))
  check('it takes a wipe in good humour', /^(It happens|Death is temporary|The floor in there)/.test(ask('we wiped')))
  // A remark follows an answer about a thing; Settings can switch the remarks off.
  check('an answer about an item ends with a remark', /^Hellreaver drops from Nazan & Vazruden[\s\S]*\n\n(Good taste|May your rolls|I'd wish for|Shiny|Fingers crossed)/.test(ask('hellreaver')))
  run(`WishwellTBCDB.chatter = false`, 'quiet')
  check('with remarks off it gives just the facts', !/\n\n(Good taste|May your rolls|I'd wish for|Shiny|Fingers crossed)/.test(ask('hellreaver')))
  run(`WishwellTBCDB.chatter = nil`, 'chatty')
  // Abbreviations: it says what the short word stands for and checks before running with it.
  check('a raid abbreviation is spelled out and checked', ask('what is ssc') === 'SSC is short for Serpentshrine Cavern, the 25-player raid in Zangarmarsh. Is that the one you mean? =  | Yes, Serpentshrine Cavern = Tell me about it [Ask]')
  check('saying yes goes on to answer about it', /^Serpentshrine Cavern is a 25-player raid in Zangarmarsh\. Bosses: /.test(ask('yes')))
  ask('ssc')
  check('saying no does not', /^No problem\. Tell me a bit more/.test(ask('no')))
  check('a word with more than one meaning lists them', /^SP can mean more than one thing\. It is short for spell power: raises the damage or healing of spells\. Or did you mean one of these\? =  \| The Slave Pens = The dungeon in Zangarmarsh \[Ask\]$/.test(ask('sp')))
  check('players\' slang is explained', /^BIS is short for best in slot: the best item you can get for one gear slot\./.test(ask('what does bis mean')) && ask('what is aoe') === 'AOE is short for area of effect: damage or healing that hits everything in an area. = ')
  check('a nickname for a dungeon works too', /^VC is short for The Deadmines, the dungeon in Westfall\. Is that the one you mean\?/.test(ask('vc')))
  // A near miss gets "did you mean".
  check('a misspelled name is put right and answered', /^I think you mean Hogger\.\nHogger is a level 11 elite/.test(ask('where is hoger')))
  check('a word spelled wrong inside a longer name too', /^I think you mean Attumen the Huntsman\.\nAttumen the Huntsman is a /.test(ask('what does atumen the huntsman drop')))
  check('when several names are as near, it asks which', /^I couldn't find anything called "cabal initate"\. Did you mean one of these\? =  \| Cabal /.test(ask('cabal initate')) || /^I think you mean Cabal Initiate\./.test(rows()))
  // Looser matching: punctuation, extra words.
  check('apostrophes do not matter', /^Kael'thas Sunstrider is a /.test(ask('where is kaelthas sunstrider')))
  check('nor do hyphens', /^Mana-Tombs is a dungeon in Terokkar Forest/.test(ask('mana tombs')) && /^Mana-Tombs is a dungeon/.test(ask('where is mana-tombs?')))
  check('extra words around a name are let go', /^Hogger is a level 11 elite/.test(ask('hogger elwynn gnoll')))
  check('chatter with no name in it still finds nothing', /^I couldn't find anything called/.test(ask('blorp flibber wibble')))
  // Crafted items and reputation rewards say how they are got.
  check('a crafted item names the profession, skill and what it takes', /^Living Crystal Breastplate is made with Leatherworking \(skill 330\) from 20 .+, 12 .+, 3 .+, 2 /.test(ask('living crystal breastplate')))
  check('a reputation reward names the faction and standing', /^Medallion of the Lightbearer is sold by .+\. It needs Exalted with The Aldor to buy\./.test(ask('medallion of the lightbearer')))
  check('"how do I make" finds the thing made', /^Living Crystal Breastplate is made with Leatherworking/.test(ask('how do i make a living crystal breastplate')))
  ask('hogger')
  ask('where are the cabal initiates')

  // It reads like a chat: what you asked on the right, the answer under it, older ones above.
  const talk = () => ev(`(function() local t = {} for _, e in ipairs(WishwellTBCChat.order) do if e.kind == "q" then t[#t + 1] = e.text end end return table.concat(t, " | ") end)()`)
  check('the conversation keeps earlier questions above the new one', talk().endsWith('hogger | where are the cabal initiates') && talk().split(' | ').length > 5)
  run(`rawset(WishwellTBCChatInput, "text", "who sells rough arrow") WishwellTBCChatInput.scripts.OnEnterPressed(WishwellTBCChatInput)`, 'type in chat')
  check('typing in the box at the bottom and pressing Enter asks', /^Rough Arrow is sold by /.test(rows()) && ev(`rawget(WishwellTBCChatInput, "text")`) === '')
  run(`WishwellTBCChatNew.scripts.OnClick()`, 'new chat')
  check('New chat clears it back to the greeting', talk() === '' && rows().startsWith('Where an item drops = '))
  // The quest guide works from the quest log: what is left to kill or collect, then the hand-in.
  run(`GetRealZoneText = function() return "Terokkar Forest" end
    CreateVector2D = function(x, y) return { x = x, y = y } end
    Fake.map = WishwellTBCWorld.areas[3519][2]
    C_Map = { GetBestMapForUnit = function() return Fake.map end, GetMapInfo = function() return { name = "Terokkar Forest" } end,
      GetPlayerMapPosition = function() return { GetXY = function() return 0.398, 0.596 end } end,
      GetWorldPosFromMapPos = function(map, v) return 0, { GetXY = function() return -v.y * 1000, -v.x * 1500 end } end }
    GetPlayerFacing = function() return 0 end
    Fake.goals = { { text = "Cabal Skirmisher slain: 8/8", finished = true }, { text = "Cabal Spell-weaver slain: 1/4", finished = false }, { text = "Cabal Initiate slain: 0/2", finished = false } }
    Fake.complete = nil
    GetNumQuestLogEntries = function() return 2 end
    GetQuestLogTitle = function(i) if i == 1 then return "Terokkar Forest", 0, nil, true end return "Before Darkness Falls", 63, nil, false, false, Fake.complete, nil, 10878 end
    C_QuestLog = { IsOnQuest = function(id) return id == 10878 end, IsQuestFlaggedCompleted = function() return true end,
      GetQuestObjectives = function() return Fake.goals end }
    SlashCmdList.WISHWELLTBC("guide")`, 'guide from log')
  const guide = () => strip(ev(`rawget(WishwellTBCGuide.giver, "text") .. " | " .. rawget(WishwellTBCGuide.dist, "text") .. " | " .. rawget(WishwellTBCGuide.count, "text") .. " | " .. rawget(WishwellTBCGuide.quests, "text")`))
  check('the guide sends you to what your quest still needs, nearest first, with the game\'s own count',
    /^Cabal Initiate \| They are around here \| 2 stops left \| Kill  Cabal Initiate slain: 0\/2\nfor Before Darkness Falls\nRoams 8 spots; the arrow points at the middle\.$/.test(guide()))
  check('a target that is already done is not a stop', !/Skirmisher/.test(guide()))
  run(`WishwellTBCGuide.skip.scripts.OnClick()`, 'skip initiate')
  check('the other target left is the next stop', /^Cabal Spell-weaver \| (They are around here|[\d,]+ yd  ·  [a-z ]+) \| 1 stop left \| Kill  Cabal Spell-weaver slain: 1\/4/.test(guide()))
  run(`Fake.complete = 1 for _, g in ipairs(Fake.goals) do g.finished = true end Fake.Fire("QUEST_LOG_UPDATE") Fake.Advance(2)`, 'quest done')
  check('once the quest is done the stop is the hand-in', /^Mekeda \| .* \| 1 stop left \| Hand in  Before Darkness Falls$/.test(guide()))
  run(`SlashCmdList.WISHWELLTBC("guide")`, 'guide off')
  // Follow-ups: a question about "he" or "it" is about the last thing answered.
  ask('where is hogger')
  check('"what does he drop" is about who was just asked about', /^Hogger is a level 11 elite/.test(ask('what does he drop?')))
  ask('hellreaver')
  check('"where does it drop" is about the item just asked about', /^Hellreaver drops from Nazan & Vazruden/.test(ask('where does it drop')))
  check('"wish for it" puts that item on the wishlist', /^Done\. Hellreaver is on your wishlist, and I'll shout when it drops\./.test(ask('wish for it')) && ev(`WishwellTBCDB.wish["Tester-"][24044] ~= nil`) === true)
  check('and saying it again does not take it off', /^Hellreaver is already on your wishlist/.test(ask('wish for it')) && ev(`WishwellTBCDB.wish["Tester-"][24044] ~= nil`) === true)
  check('a pronoun with something else named is not a follow-up', /^Hogger is a level 11 elite/.test(ask('where is that boss hogger')))
  // Questions about you.
  check('"what should I do next" lists what to do, with Go buttons', /^Here's what I'd do, in this order:\n1\. .+[\s\S]* \| .+ \[Go\]/.test(ask('what should i do next?')))
  check('"my wishlist" lists it', /^You have 1 thing on your wishlist\./.test(ask('what is on my wishlist')) && / \| Hellreaver = /.test(rows()))
  check('"what do I still need from Karazhan" looks at that raid for you', /^(I count \d+ upgrades? for you in Karazhan\.|I can't see an upgrade for you in Karazhan\.)/.test(ask('what do i still need from karazhan')))
  check('a slot can be asked for', /^(I count \d+ head upgrades? for you|I can't see a head upgrade for you)/.test(ask('best upgrade for my head')))
  check('"which dungeon should I run" picks for your level', /^(For a level \d+, best first:\n|I don't know of a dungeon for level \d+)/.test(ask('which dungeon should i run')))
  check('"what quests do I have" reads the quest log', /^You have 1 quest I know in your log:\nBefore Darkness Falls: ready to hand in to Mekeda in Terokkar Forest/.test(ask('what quests do i have')))
  check('a zone can be asked about, by level or by name', /^Zangarmarsh is a level \d+ to \d+ zone, going by its quests\./.test(ask('what level is zangarmarsh')) && /^Zangarmarsh is a level \d+ to \d+ zone/.test(ask('zangarmarsh')))
  check('it names the dungeons in a zone', /Raids and dungeons there: .*The Underbog/.test(rows()))
  check('gold, XP and training get an answer of their own', /^(You have |The game won't tell me your gold)/.test(ask('how much gold do i have'))
    && !/couldn't find/.test(ask('how much xp to level')) && /^(Visit your class trainer|You can train|You've trained)/.test(ask('what can i train')))
  // The kind of question is worked out from its words, not from set phrases.
  check('"where can I get better weapons for my level" is a question about gear', /^(I count \d+ weapon upgrades? for you|I can't see a weapon upgrade for you)/.test(ask('where can i get better weapons for my level')))
  check('so is "i need new gear"', /^(I count \d+ upgrades? for you|I can't see an upgrade for you)/.test(ask('i need new gear')))
  check('"where should i go to level" gets the zones with the most quest XP', /^(Where the most quest XP is waiting for a level \d+:\n1\. |I can't see a zone with much left)/.test(ask('where should i go to level')))
  check('"how do i make gold" is about gold', /^(You have |The game won't tell me your gold)/.test(ask('am i rich')))
  check('"what spec should i be" is about talents', /Talents page under Me/.test(ask('what spec should i be')))
  check('a name in the question still wins over the guess', /^Hogger is a level 11 elite/.test(ask('is hogger better')))
  check('a guess after a miss says it is a guess', /^I didn't catch all of that, so here's my best guess at what you're after\.\n(I count|I can't see)/.test(ask('yo hook me up with stronger gear innit')))
  check('a stray word that starts an item name does not hijack it', /^(I count d+ upgrades? for you|I can.t see an upgrade for you)/.test(ask('gimme some sweet purple upgrades plz')) && /^I didn.t catch all of that/.test(ask('yo whats some sweet purple gear plz')))
  check('a raid named alone is still about the raid', /^Karazhan is a 10-player raid/.test(ask('karazhan')))
  check('no Lua errors were printed', !/error/i.test(strip(ev(`table.concat(Fake.printed, "\\n")`))))
}

// ---- Wishwell TBC next to Raid Night on TBC Anniversary --------------------------------------
{
  const run = makeGame({ addon: WISHTBC, also: TBC, toc: 20506, build: '2.5.6' })
  const ev = (code) => run(`return ${code}`, 'check')
  run(`SlashCmdList.WISHWELLTBC("loot")`, 'both')
  check('Wishwell TBC and Raid Night run side by side with separate saved settings',
    ev(`WishwellTBCFrame ~= nil and type(RaidNightDB) == "table" and RaidNightDB ~= WishwellTBCDB and RaidNightDB.wish == nil`) === true)
  check('no Lua errors with both installed', !/error/i.test(ev(`table.concat(Fake.printed, "\\n")`)))
}

// ---- Chalkboard: the shared raid whiteboard ----------------------------------------------------
{
  const CHALK = { name: 'Chalkboard', files: ['Data.lua', 'Rooms.lua', 'Chalkboard.lua'] }
  const run = makeGame({ addon: CHALK, toc: 20506, build: '2.5.6' })
  const ev = (code) => run(`return ${code}`, 'check')
  const pump = `for i = 1, 40 do Chalkboard.Pump(0.25) end`
  const stroke = `Chalkboard.Begin(10, 10) Chalkboard.Move(200, 120) Chalkboard.Move(400, 300) Chalkboard.End()`

  run(`SlashCmdList.CHALKBOARD()`, 'open')
  check('Chalkboard opens with /chalk', ev(`ChalkboardFrame:IsShown()`) === true)
  run(`Fake.sent = {} ${stroke} ${pump}`, 'solo')
  check('drawing alone makes a line and sends nothing', ev(`select(1, Chalkboard.Count())`) === 1 && ev(`select(2, Chalkboard.Count())`) === 3 && ev(`#Fake.sent`) === 0)

  // As raid leader: the line goes out, and erasing and clearing follow it in order.
  run(`Fake.group = 5 Fake.leader = true Chalkboard.Clear() ${pump} Fake.sent = {} ${stroke} ${pump}`, 'lead')
  const sent = ev(`Fake.sent[1]`)
  check('the leader\'s line is sent to the raid in one message', ev(`#Fake.sent`) === 1 && /^P\w+~1.{9}$/.test(sent))
  run(`Fake.sent = {} Chalkboard.EraseAt(100, 62) ${pump}`, 'erase')
  check('the eraser picks up a line it touches and tells the raid', ev(`select(1, Chalkboard.Count())`) === 0 && /^E\w+$/.test(ev(`Fake.sent[1]`)))
  run(`Fake.sent = {} ${stroke} Chalkboard.ShowToRaid() ${stroke} Chalkboard.Clear() ${pump}`, 'order')
  check('show-to-raid goes out after the points drawn before it, and a clear after that', /^P B\w* O X$/.test(ev(`(table.concat(Fake.sent, " "):gsub("P%S+", "P"))`)))

  // A raider who joins late asks for the board and gets all of it by whisper.
  run(`${stroke} ${stroke} ${pump} Fake.sent = {}
    Fake.Fire("CHAT_MSG_ADDON", "Chalkboard", "Q", "RAID", "Raider3-Realm") ${pump}`, 'late')
  check('a late joiner is sent the whole board, and told to open it', ev(`#Fake.sent`) === 4 && ev(`Fake.sent[1] .. Fake.sent[2]`) === 'RBattumen' && ev(`select(2, Fake.sent[3]:gsub("~", ""))`) === 2 && ev(`Fake.sent[4]`) === 'O')

  // As a raider: only the leader and assists are listened to.
  const escaped = JSON.stringify(sent)
  run(`Fake.leader = false Chalkboard.Clear() ChalkboardFrame:Hide()
    Fake.Fire("CHAT_MSG_ADDON", "Chalkboard", "X", "RAID", "Leaderguy-Realm")
    Fake.Fire("CHAT_MSG_ADDON", "Chalkboard", ${escaped}, "RAID", "Raider3-Realm")`, 'raider')
  check('a raider cannot draw, and lines from other raiders are ignored', ev(`Chalkboard.Begin(5, 5)`) === false && ev(`select(1, Chalkboard.Count())`) === 0)
  run(`Fake.Fire("CHAT_MSG_ADDON", "Chalkboard", ${escaped}, "RAID", "Leaderguy-Realm")`, 'receive')
  check('the leader\'s line arrives whole', ev(`select(1, Chalkboard.Count())`) === 1 && ev(`select(2, Chalkboard.Count())`) === 3)
  run(`Fake.Fire("CHAT_MSG_ADDON", "Chalkboard", "P!!bad", "RAID", "Leaderguy-Realm")
    Fake.Fire("CHAT_MSG_ADDON", "Chalkboard", "Pzz9~1ab", "RAID", "Leaderguy-Realm")`, 'junk')
  check('broken messages are dropped without errors', ev(`select(1, Chalkboard.Count())`) === 1)
  run(`Fake.Fire("CHAT_MSG_ADDON", "Chalkboard", "O", "RAID", "Leaderguy-Realm")`, 'show')
  check('the leader can open the board on a raider\'s screen', ev(`ChalkboardFrame:IsShown()`) === true)
  run(`ChalkboardFrame:Hide() ChalkboardDB.autoOpen = false Fake.printed = {}
    Fake.Fire("CHAT_MSG_ADDON", "Chalkboard", "O", "RAID", "Leaderguy-Realm")`, 'optout')
  check('a raider who opted out gets a chat line instead', ev(`ChalkboardFrame:IsShown()`) === false && /Leaderguy is showing a plan/.test(ev(`Fake.printed[1]`)))

  // Boss icons and spell blips.
  run(`GetSpellInfo = function(id) return (id == 33238 or id == 33054) and "Whirlwind" or "Spell " .. id, nil, 136243 end`, 'spells')
  check('every raid has bosses, and each boss is known by its creature number', ev(`(function() local n = 0 for _, r in ipairs(ChalkboardData.raids) do if #r.bosses == 0 then return 0 end for _, b in ipairs(r.bosses) do if type(b.npc) ~= "number" then return 0 end n = n + 1 end end return n end)()`) >= 50)
  check('picking Maulgar lists his spells, each name once', ev(`ChalkboardData.raids[2].bosses[1].name`) === 'High King Maulgar' && ev(`Chalkboard.Pick(2, 1)`) === 5)
  check('a raider cannot place icons', ev(`Chalkboard.Place("b", 18831, 300, 200)`) === false)
  run(`Fake.Fire("CHAT_MSG_ADDON", "Chalkboard", "X", "RAID", "Leaderguy-Realm")
    Fake.leader = true ${pump} Fake.sent = {}
    Chalkboard.Place("b", 18831, 300, 200) Chalkboard.Place("s", 33238, 340, 220) ${pump}`, 'place')
  const placed = ev(`Fake.sent[1]`)
  check('the leader places a boss and a spell, and each is sent', ev(`select(3, Chalkboard.Count())`) === 2 && /^I\w+~b18831~.{3}$/.test(placed) && /^I\w+~s33238~.{3}$/.test(ev(`Fake.sent[2]`)))
  run(`Fake.sent = {} Fake.Fire("CHAT_MSG_ADDON", "Chalkboard", "Q", "RAID", "Raider3-Realm") ${pump}`, 'late icons')
  check('a late joiner gets the icons too', ev(`Fake.sent[1]`) === 'R' && ev(`select(2, Fake.sent[3]:gsub("~[bs]", ""))`) === 2)
  const id = placed.match(/^I(\w+)~/)[1]
  run(`Fake.sent = {} Chalkboard.MoveItem("${id}", 100, 100) Chalkboard.RemoveItem("${id}") ${pump}`, 'move')
  check('moving and removing an icon are sent', ev(`select(3, Chalkboard.Count())`) === 1 && ev(`Fake.sent[1]:sub(1, 1) .. Fake.sent[2]`) === 'IE' + id)
  run(`Chalkboard.Clear() Fake.leader = false
    Fake.Fire("CHAT_MSG_ADDON", "Chalkboard", ${JSON.stringify(placed)} .. "}zz1~s33238~abc", "RAID", "Leaderguy-Realm")
    Fake.Fire("CHAT_MSG_ADDON", "Chalkboard", "Izz2~q5~abc}zz3~b1~a", "RAID", "Leaderguy-Realm")
    Fake.Fire("CHAT_MSG_ADDON", "Chalkboard", "Izz4~b18831~abc", "RAID", "Raider3-Realm")`, 'receive icons')
  check('a raider sees the leader\'s icons, and junk or other raiders\' icons are ignored', ev(`select(3, Chalkboard.Count())`) === 2)
  run(`Fake.Fire("CHAT_MSG_ADDON", "Chalkboard", "E${id}", "RAID", "Leaderguy-Realm")`, 'remove icon')
  check('removing an icon reaches the raider', ev(`select(3, Chalkboard.Count())`) === 1)

  // Circles and cones are lines in the shape of one.
  run(`Fake.leader = true Chalkboard.Clear() ${pump} Fake.sent = {}
    Chalkboard.ShapeBegin("circle", 300, 200) Chalkboard.ShapeDrag(340, 200) Chalkboard.ShapeDrag(360, 200) ${pump}`, 'circle')
  check('a circle being dragged is not sent yet', ev(`#Fake.sent`) === 0 && ev(`select(2, Chalkboard.Count())`) === 33)
  run(`Chalkboard.End() ${pump}`, 'circle done')
  check('letting go sends the circle as one line', ev(`#Fake.sent`) === 1 && /^P\w+~1.{99}$/.test(ev(`Fake.sent[1]`)))
  run(`Fake.sent = {} Chalkboard.ShapeBegin("cone", 100, 100) Chalkboard.ShapeDrag(100, 180) Chalkboard.End() ${pump}`, 'cone')
  check('a cone goes from its tip, round the far edge and back', ev(`select(1, Chalkboard.Count())`) === 2 && /^P\w+~1.{33}$/.test(ev(`Fake.sent[1]`)))
  run(`Fake.sent = {} Chalkboard.ShapeBegin("circle", 500, 300) Chalkboard.ShapeDrag(502, 300) Chalkboard.End() ${pump}`, 'tiny')
  check('a shape that was only clicked, not dragged, is dropped', ev(`select(1, Chalkboard.Count())`) === 2 && ev(`#Fake.sent`) === 0)
  run(`Fake.sent = {} Chalkboard.EraseAt(360, 200) ${pump}`, 'erase circle')
  check('the eraser removes a circle by its edge', ev(`select(1, Chalkboard.Count())`) === 1 && /^E\w+$/.test(ev(`Fake.sent[1]`)))

  // Room sketches behind the plan.
  check('every room sketch has a name, fits the board and names real bosses', ev(`(function()
    local bosses, keys = {}, {}
    for _, r in ipairs(ChalkboardData.raids) do for _, b in ipairs(r.bosses) do bosses[b.name] = true end end
    for _, def in ipairs(ChalkboardRooms) do
      if type(def.name) ~= "string" or not def.key:match("^%w+$") or keys[def.key] then return "key " .. tostring(def.key) end
      keys[def.key] = true
      for _, name in ipairs(def.bosses or {}) do if not bosses[name] then return name end end
      if not def.image and not def.shapes and not def.clear then return "empty " .. def.key end
      for _, s in ipairs(def.shapes or {}) do
        local x, y, reach = s[2], s[3], (s[1] == "circle" or s[1] == "arc") and s[4] or 0
        if x - reach < 0 or x + reach > 768 or y - reach < 0 or y + reach > 432 then return def.key end
      end
    end
    return "fine"
  end)()`) === 'fine')
  run(`Fake.sent = {} Chalkboard.Pick(3, 1) Chalkboard.SetRoom("magtheridon") ${pump}`, 'room')
  check('the leader picks Magtheridon\'s room: its picture is shown and the raid is told', ev(`(Chalkboard.Room())`) === 'magtheridon' && ev(`select(2, Chalkboard.Room())`) === 0 && ev(`select(4, Chalkboard.Room())`) === 'magtheridon' && ev(`Fake.sent[1]`) === 'Bmagtheridon')
  check('every room picture is in the Maps folder', ev(`(function() local t = {} for _, d in ipairs(ChalkboardRooms) do if d.image and not d.custom then t[#t + 1] = d.image end end return table.concat(t, ",") end)()`).split(',').every((name) => existsSync(new URL(`../wow-addon/Chalkboard/Maps/${name}.jpg`, import.meta.url))))
  run(`Chalkboard.SetRoom("round")`, 'sketch')
  check('a plain shape is still drawn in chalk, with no picture', ev(`select(2, Chalkboard.Room())`) > 40 && ev(`select(4, Chalkboard.Room())`) === undefined)
  run(`Chalkboard.SetRoom("magtheridon") ${pump}`, 'back')
  run(`Fake.sent = {} Chalkboard.Clear() Fake.Fire("CHAT_MSG_ADDON", "Chalkboard", "Q", "RAID", "Raider3-Realm") ${pump}`, 'room late')
  check('clearing keeps the room, and a late joiner is sent it', ev(`(Chalkboard.Room())`) === 'magtheridon' && /^X R Bmagtheridon( O)?$/.test(ev(`table.concat(Fake.sent, " ")`)))
  run(`Chalkboard.SetRoom(nil) Fake.leader = false
    Fake.Fire("CHAT_MSG_ADDON", "Chalkboard", "Bchess", "RAID", "Leaderguy-Realm")`, 'room raider')
  check('a raider sees the room the leader picked', ev(`(Chalkboard.Room())`) === 'chess' && ev(`select(4, Chalkboard.Room())`) === 'chess')
  run(`Fake.Fire("CHAT_MSG_ADDON", "Chalkboard", "Bnosuchroom", "RAID", "Leaderguy-Realm")`, 'room unknown')
  check('an unknown room, a blank one and a raider\'s own pick leave a blank or unchanged board', ev(`Chalkboard.Room()`) === undefined && ev(`Chalkboard.SetRoom("aran")`) === false)

  // Saved plans, one per boss.
  run(`Fake.leader = true Chalkboard.Clear() Chalkboard.SetRoom(nil)`, 'plan reset')
  check('an empty board is not saved', ev(`Chalkboard.Save(17257)`) === false && ev(`ChalkboardDB.plans[17257]`) === undefined)
  run(`Chalkboard.SetRoom("magtheridon") ${stroke} Chalkboard.Place("b", 17257, 384, 216) Chalkboard.Place("s", 30616, 300, 150)`, 'plan draw')
  check('the board is saved for Magtheridon: room, line and icons', ev(`Chalkboard.Save(17257)`) === true
    && ev(`ChalkboardDB.plans[17257].room`) === 'magtheridon' && ev(`#ChalkboardDB.plans[17257].strokes`) === 1
    && ev(`#ChalkboardDB.plans[17257].strokes[1].p`) === 9 && ev(`#ChalkboardDB.plans[17257].items`) === 2)
  run(`Chalkboard.Clear() Chalkboard.SetRoom("chess") ${stroke} ${pump} Fake.sent = {}`, 'plan other')
  check('loading it replaces the board', ev(`Chalkboard.Load(17257)`) === true && ev(`(Chalkboard.Room())`) === 'magtheridon'
    && ev(`select(1, Chalkboard.Count())`) === 1 && ev(`select(2, Chalkboard.Count())`) === 3 && ev(`select(3, Chalkboard.Count())`) === 2)
  run(pump, 'plan send')
  check('and the raid is sent a clear, the room, the line and both icons', ev(`(table.concat(Fake.sent, " "):gsub("(%u)%S*", "%1"))`) === 'X B P I I' && ev(`Fake.sent[2]`) === 'Bmagtheridon')
  check('a boss with no plan loads nothing, and a raider cannot load for the raid', ev(`Chalkboard.Load(19044)`) === false
    && ev(`(function() Fake.leader = false local ok = Chalkboard.Load(17257) Fake.leader = true return ok end)()`) === false && ev(`select(3, Chalkboard.Count())`) === 2)

  // Minimap button.
  run(`ChalkboardFrame:Hide() ChalkboardMinimapButton:GetScript("OnClick")()`, 'minimap')
  check('the minimap button is shown and opens the board', ev(`ChalkboardMinimapButton:IsShown()`) === true && ev(`ChalkboardFrame:IsShown()`) === true)
  run(`SlashCmdList.CHALKBOARD(" Minimap ")`, 'minimap hide')
  check('/chalk minimap hides it and remembers that', ev(`ChalkboardMinimapButton:IsShown()`) === false && ev(`ChalkboardDB.minimapHidden`) === true && ev(`ChalkboardFrame:IsShown()`) === true)
  run(`SlashCmdList.CHALKBOARD("minimap")`, 'minimap show')
  check('and brings it back', ev(`ChalkboardMinimapButton:IsShown()`) === true)

  // Role markers and numbers; and the room follows the boss.
  run(`Fake.leader = true Chalkboard.Clear() ${pump} Fake.sent = {}
    Chalkboard.Place("m", 1, 100, 100) Chalkboard.Place("n", 3, 140, 100) ${pump}`, 'markers')
  check('a tank marker and a number are placed and sent', ev(`select(3, Chalkboard.Count())`) === 2 && /^I\w+~m1~.{3}$/.test(ev(`Fake.sent[1]`)) && /^I\w+~n3~.{3}$/.test(ev(`Fake.sent[2]`)))
  run(`Chalkboard.Clear() Fake.leader = false
    Fake.Fire("CHAT_MSG_ADDON", "Chalkboard", "Izz1~m2~abc}zz2~n9~abc}zz3~m99~abc}zz4~n0~abc", "RAID", "Leaderguy-Realm")`, 'markers in')
  check('a raider sees the markers, and ones that do not exist are ignored', ev(`select(3, Chalkboard.Count())`) === 2)
  run(`Fake.leader = true Chalkboard.Clear() ${pump} Fake.sent = {} Chalkboard.Pick(3, 1) ${pump}`, 'boss room')
  check('choosing Magtheridon puts his room behind the plan and tells the raid', ev(`(Chalkboard.Room())`) === 'magtheridon' && ev(`Fake.sent[1]`) === 'Bmagtheridon')
  run(`Fake.sent = {} Chalkboard.Pick(4, 1) ${pump}`, 'no room')
  check('a later raid\'s boss has its room too', ev(`ChalkboardData.raids[4].bosses[1].name`) === 'Hydross the Unstable' && ev(`(Chalkboard.Room())`) === 'hydross' && ev(`Fake.sent[1]`) === 'Bhydross')
  check('every raid boss has a room picture', ev(`(function() local have = {} for _, d in ipairs(ChalkboardRooms) do for _, n in ipairs(d.bosses or {}) do have[n] = true end end for _, r in ipairs(ChalkboardData.raids) do for _, b in ipairs(r.bosses) do if not have[b.name] then return b.name end end end return "all" end)()`) === 'all')
  run(`Chalkboard.Pick(1, 2) Fake.leader = false Chalkboard.Pick(3, 1)`, 'raider browse')
  check('a raider browsing bosses does not change the room', ev(`(Chalkboard.Room())`) === 'moroes')

  // Screen mode: the plan is drawn over the game view.
  run(`Fake.leader = true Chalkboard.Pick(3, 1) ChalkboardFrame:Show() ${pump} Fake.sent = {} Chalkboard.Screen() ${pump}`, 'screen on')
  check('the leader switches to drawing on screen: the raid is told, and the leader keeps a tool bar', ev(`Fake.sent[1]`) === 'Bscreen'
    && ev(`(Chalkboard.Overlay())`) === true && ev(`select(2, Chalkboard.Overlay())`) === true && ev(`select(3, Chalkboard.Overlay())`) === true)
  run(`Chalkboard.Screen()`, 'screen off')
  check('switching back returns to the boss\'s room', ev(`(Chalkboard.Room())`) === 'magtheridon' && ev(`(Chalkboard.Overlay())`) === false)
  run(`Fake.leader = false ChalkboardFrame:Hide()
    Fake.Fire("CHAT_MSG_ADDON", "Chalkboard", "Bscreen", "RAID", "Leaderguy-Realm")`, 'screen raider closed')
  check('a raider whose board is closed sees nothing yet', ev(`select(2, Chalkboard.Overlay())`) === false && ev(`select(3, Chalkboard.Overlay())`) === false)
  run(`ChalkboardDB.autoOpen = true Fake.Fire("CHAT_MSG_ADDON", "Chalkboard", "O", "RAID", "Leaderguy-Realm")`, 'screen raider open')
  check('when the leader shows it, the raider gets the lines over the game and no window', ev(`select(2, Chalkboard.Overlay())`) === true && ev(`select(3, Chalkboard.Overlay())`) === false)
  run(`SlashCmdList.CHALKBOARD()`, 'screen raider hide')
  check('/chalk hides the plan for a raider in screen mode', ev(`select(2, Chalkboard.Overlay())`) === false)
  run(`SlashCmdList.CHALKBOARD() Fake.Fire("CHAT_MSG_ADDON", "Chalkboard", "Bmagtheridon", "RAID", "Leaderguy-Realm")`, 'screen raider back')
  check('when the leader goes back to the board, a raider who was watching gets the window', ev(`(Chalkboard.Overlay())`) === false && ev(`select(3, Chalkboard.Overlay())`) === true)

  // Boss and spell icons stay on offer in screen mode, and picking a boss there keeps the mode.
  run(`Fake.leader = true Chalkboard.Pick(3, 1) Chalkboard.Screen() ${pump} Fake.sent = {}`, 'screen icons')
  check('picking another boss while drawing on screen keeps screen mode and sends nothing', ev(`Chalkboard.Pick(2, 1)`) === 5 && ev(`(Chalkboard.Room())`) === 'screen' && ev(`#Fake.sent`) === 0)
  run(`Chalkboard.Place("b", 18831, 300, 200) Chalkboard.Place("s", 33238, 340, 220) Chalkboard.Screen()`, 'screen leave')
  check('icons placed on screen stay when going back to the board, which shows that boss\'s room', ev(`select(3, Chalkboard.Count())`) >= 2 && ev(`(Chalkboard.Room())`) === 'maulgar')
  check('no Lua errors were printed by Chalkboard', !/error/i.test(ev(`table.concat(Fake.printed, "\\n")`)))
}

if (failed) {
  console.error(`\n${failed} check(s) failed`)
  process.exit(1)
}
console.log('\nall addon checks passed')
