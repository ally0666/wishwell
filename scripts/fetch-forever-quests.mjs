// Builds src/data/forever-quests.json: quests with their level, zone, who can do them and
// how much XP they give.
//
//   npm i --no-save fengari      (once; it reads the Lua tables)
//   node scripts/fetch-forever-quests.mjs
//   node scripts/build-forever-data.mjs
//
// The quest list and XP values are the Classic Era tables from the Questie project
// (https://github.com/Questie/Questie). WoW Forever keeps the Classic quests; its new quests
// are not in any public table yet, so they are not in this file.
import { writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari')

const BASE = 'https://raw.githubusercontent.com/Questie/Questie/v10.5.1'
const OUT = new URL('../src/data/forever-quests.json', import.meta.url)

async function get(path) {
  const res = await fetch(`${BASE}/${path}`)
  if (!res.ok) throw new Error(`${path}: ${res.status}`)
  return res.text()
}

const questSrc = await get('Database/Classic/classicQuestDB.lua')
const xpSrc = await get('Database/QuestXP/DB/xpDB-classic.lua')
const zoneSrc = await get('Localization/lookups/lookupZones.lua')
const parentSrc = await get('Database/Zones/zoneTables.lua')

// ---- Quests: run the Lua table and print the fields we need, one quest per line -----------
const body = questSrc.slice(questSrc.indexOf('[[return {') + 2, questSrc.lastIndexOf(']]'))
const L = lauxlib.luaL_newstate()
lualib.luaL_openlibs(L)
const program = `
local quests = (function() ${body} end)()
local out = {}
local function list(t)
  if type(t) ~= "table" then return "" end
  local ids = {}
  for _, v in ipairs(t) do if type(v) == "number" then ids[#ids + 1] = tostring(math.floor(v)) end end
  return table.concat(ids, ",")
end
for id, q in pairs(quests) do
  out[#out + 1] = table.concat({
    math.floor(id), (q[1] or ""):gsub("[\\t\\n]", " "), math.floor(q[4] or 0), math.floor(q[5] or 0),
    math.floor(q[6] or 0), math.floor(q[7] or 0), math.floor(q[17] or 0), math.floor(q[24] or 0),
    list(q[13]), list(q[12]),
  }, "\\t")
end
return table.concat(out, "\\n")`
if (lauxlib.luaL_loadbuffer(L, to_luastring(program), null, to_luastring('quests')) || lua.lua_pcall(L, 0, 1, 0)) {
  throw new Error(to_jsstring(lua.lua_tostring(L, -1)))
}
const rows = to_jsstring(lua.lua_tostring(L, -1)).split('\n')

// ---- XP: [id] = {level, xp} -------------------------------------------------------------------
const xp = new Map()
for (const m of xpSrc.matchAll(/\[(\d+)\]\s*=\s*\{\s*(-?\d+)\s*,\s*(\d+)\s*\}/g)) xp.set(Number(m[1]), Number(m[3]))

// ---- Zones: names, continents, and sub-zone -> zone -----------------------------------------
const zoneName = new Map()
const zoneContinent = new Map()
{
  let continent = null
  // Skip the continent-name table at the top of the file; its numbers are not zone ids.
  for (const line of zoneSrc.slice(zoneSrc.indexOf('l10n.zoneLookup')).split('\n')) {
    const head = line.match(/^\s*\[(\d+)\]\s*=\s*\{\s*$/)
    if (head) {
      continent = Number(head[1])
      continue
    }
    const entry = line.match(/^\s*\[(\d+)\]\s*=\s*"([^"]+)"/)
    if (entry) {
      const id = Number(entry[1])
      if (!zoneName.has(id)) zoneName.set(id, entry[2])
      if (continent !== null && !zoneContinent.has(id)) zoneContinent.set(id, continent)
    }
  }
}
const parent = new Map()
for (const m of parentSrc.matchAll(/^\s*\[(\d+)\]\s*=\s*(\d+),\s*--[^\n]*->/gm)) parent.set(Number(m[1]), Number(m[2]))

const CONTINENT = { 0: 'Eastern Kingdoms', 1: 'Kalimdor' }
// Negative "zones" are quest categories. Class and profession quests are kept; holiday,
// event and battleground ones are not part of levelling.
const CLASS_SORT = new Set([-61, -81, -82, -141, -161, -162, -261, -262, -263])
const PROFESSION_SORT = new Set([-24, -101, -121, -181, -182, -201, -264, -304, -324])

// Not part of levelling in WoW Forever at launch: battlegrounds and the raids that are not open.
const SKIP_ZONE = new Set([
  'Alterac Valley', 'Arathi Basin', 'Warsong Gulch', "Ahn'Qiraj", "Ruins of Ahn'Qiraj", 'Blackwing Lair',
  'Molten Core', 'Naxxramas', "Zul'Gurub", 'Deeprun Tram',
])

const SKIP_NAME = /^<|UNUSED|DEPRECATED|\[PH\]|\bTEST\b|zzOLD|REUSE|\bNYI\b|^\s*$|\[DNT\]/i
const quests = []
const zones = {}
let dropped = 0
for (const row of rows) {
  const [idText, name, minText, levelText, racesText, classesText, zoneText, flagsText, preAny, preAll] = row.split('\t')
  const id = Number(idText)
  const level = Number(levelText)
  const base = xp.get(id) || 0
  const repeatable = (Number(flagsText) & 1) === 1
  let zone = Number(zoneText)
  if (SKIP_NAME.test(name) || level <= 0 || level > 60 || base <= 0 || repeatable) {
    dropped++
    continue
  }
  let group
  if (zone > 0) {
    if (parent.has(zone)) zone = parent.get(zone)
    if (!zoneName.has(zone) || SKIP_ZONE.has(zoneName.get(zone))) {
      dropped++
      continue
    }
    group = CONTINENT[zoneContinent.get(zone)] || 'Dungeons and raids'
    zones[zone] = { name: zoneName.get(zone), group }
  } else if (CLASS_SORT.has(zone)) {
    zone = -1
    zones[zone] = { name: 'Class quests', group: 'Other' }
  } else if (PROFESSION_SORT.has(zone)) {
    zone = -2
    zones[zone] = { name: 'Profession quests', group: 'Other' }
  } else {
    dropped++
    continue
  }
  const quest = { id, name, level, min: Number(minText), zone, xp: base }
  // 77 = every Alliance race, 178 = every Horde race, 255 = everyone.
  const races = Number(racesText)
  if (races && races !== 255) quest.races = races
  const classes = Number(classesText)
  if (classes) quest.classes = classes
  const after = (preAny || preAll || '').split(',').filter(Boolean).map(Number)
  if (after.length) {
    quest.after = after
    if (!preAny && preAll && after.length > 1) quest.afterAll = true
  }
  quests.push(quest)
}
quests.sort((a, b) => a.id - b.id)
// Prerequisites that were dropped (events, unused quests) would block a quest forever.
const kept = new Set(quests.map((q) => q.id))
for (const quest of quests) {
  if (!quest.after) continue
  quest.after = quest.after.filter((id) => kept.has(id))
  if (!quest.after.length) {
    delete quest.after
    delete quest.afterAll
  }
}

writeFileSync(OUT, JSON.stringify({ source: 'Questie v10.5.1 (Classic Era quest and XP tables)', fetched: new Date().toISOString().slice(0, 10), zones, quests }) + '\n')
console.log(`saved ${quests.length} quests in ${Object.keys(zones).length} zones (${dropped} left out: events, repeatables, unused or no XP)`)
