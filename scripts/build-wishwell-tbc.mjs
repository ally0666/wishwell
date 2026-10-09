// Builds the data files for Wishwell TBC (the TBC Anniversary addon).
//
//   npm i --no-save fengari                       (once; it reads the Lua quest table)
//   node scripts/build-wishwell-tbc.mjs --refresh  download everything again, then build
//   node scripts/build-wishwell-tbc.mjs            build from the saved copy in src/data/tbc.json
//
// Wishwell TBC is a separate addon from Wishwell (WoW Forever). It has its own data and its
// own build, so changing one cannot affect the other.
//
// Sources: loot, drop rates and item sets from AtlasLootClassic; quests, quest XP and where
// each quest starts from Questie's TBC tables.
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'

const ATLAS = 'https://raw.githubusercontent.com/Hoizame/AtlasLootClassic/master'
const QUESTIE = 'https://raw.githubusercontent.com/Questie/Questie/v10.5.1'
const SAVED = new URL('../src/data/tbc.json', import.meta.url)
const OUT_DIR = new URL('../wow-addon/WishwellTBC/', import.meta.url)

// id: short and never renamed once shipped (it is saved with wishlists and sent to group members).
// atlas: [file, key] pairs in AtlasLootClassic. aliases: other names the game uses for the place.
const C = 'classic'
const T = 'tbc'
const INSTANCES = [
  // The Burning Crusade raids
  { id: 'kara', name: 'Karazhan', kind: 'raid', size: 10, zone: 'Deadwind Pass', atlas: [[T, 'Karazhan']] },
  { id: 'gruul', name: "Gruul's Lair", kind: 'raid', size: 25, zone: "Blade's Edge Mountains", atlas: [[T, 'GruulsLair']] },
  { id: 'mag', name: "Magtheridon's Lair", kind: 'raid', size: 25, zone: 'Hellfire Peninsula', atlas: [[T, 'MagtheridonsLair']] },
  { id: 'ssc', name: 'Serpentshrine Cavern', kind: 'raid', size: 25, zone: 'Zangarmarsh', atlas: [[T, 'SerpentshrineCavern']] },
  { id: 'tk', name: 'Tempest Keep', kind: 'raid', size: 25, zone: 'Netherstorm', aliases: ['The Eye'], atlas: [[T, 'TempestKeep']] },
  { id: 'hyjal', name: 'Hyjal Summit', kind: 'raid', size: 25, zone: 'Tanaris', aliases: ['The Battle for Mount Hyjal'], atlas: [[T, 'HyjalSummit']] },
  { id: 'bt', name: 'Black Temple', kind: 'raid', size: 25, zone: 'Shadowmoon Valley', atlas: [[T, 'BlackTemple']] },
  { id: 'za', name: "Zul'Aman", kind: 'raid', size: 10, zone: 'Ghostlands', atlas: [[T, 'ZulAman']] },
  { id: 'swp', name: 'Sunwell Plateau', kind: 'raid', size: 25, zone: "Isle of Quel'Danas", aliases: ['The Sunwell'], atlas: [[T, 'SunwellPlateau']] },
  { id: 'world', name: 'World bosses and rares', kind: 'world', atlas: [[T, 'WorldBossesBC'], [C, 'WorldBosses']] },
  // Classic raids
  { id: 'mc', name: 'Molten Core', kind: 'raid', size: 40, zone: 'Blackrock Mountain', atlas: [[C, 'MoltenCore']] },
  { id: 'ony', name: "Onyxia's Lair", kind: 'raid', size: 40, zone: 'Dustwallow Marsh', atlas: [[C, 'Onyxia']] },
  { id: 'bwl', name: 'Blackwing Lair', kind: 'raid', size: 40, zone: 'Blackrock Mountain', atlas: [[C, 'BlackwingLair']] },
  { id: 'zg', name: "Zul'Gurub", kind: 'raid', size: 20, zone: 'Stranglethorn Vale', atlas: [[C, "Zul'Gurub"]] },
  { id: 'aq20', name: "Ruins of Ahn'Qiraj", kind: 'raid', size: 20, zone: 'Silithus', atlas: [[C, 'TheRuinsofAhnQiraj']] },
  { id: 'aq40', name: "Temple of Ahn'Qiraj", kind: 'raid', size: 40, zone: 'Silithus', aliases: ["Ahn'Qiraj", "Ahn'Qiraj Temple"], atlas: [[C, 'TheTempleofAhnQiraj']] },
  { id: 'naxx', name: 'Naxxramas', kind: 'raid', size: 40, zone: 'Eastern Plaguelands', atlas: [[C, 'Naxxramas']] },
  // The Burning Crusade dungeons
  { id: 'ramps', name: 'Hellfire Ramparts', kind: 'dungeon', zone: 'Hellfire Peninsula', levels: [60, 62], atlas: [[T, 'HellfireRamparts']] },
  { id: 'bf', name: 'The Blood Furnace', kind: 'dungeon', zone: 'Hellfire Peninsula', levels: [61, 63], atlas: [[T, 'TheBloodFurnace']] },
  { id: 'sp', name: 'The Slave Pens', kind: 'dungeon', zone: 'Zangarmarsh', levels: [62, 64], atlas: [[T, 'TheSlavePens']] },
  { id: 'ub', name: 'The Underbog', kind: 'dungeon', zone: 'Zangarmarsh', levels: [63, 65], atlas: [[T, 'TheUnderbog']] },
  { id: 'mt', name: 'Mana-Tombs', kind: 'dungeon', zone: 'Terokkar Forest', levels: [64, 66], atlas: [[T, 'Mana-Tombs']] },
  { id: 'ac', name: 'Auchenai Crypts', kind: 'dungeon', zone: 'Terokkar Forest', levels: [65, 67], atlas: [[T, 'AuchenaiCrypts']] },
  { id: 'ohf', name: 'Old Hillsbrad Foothills', kind: 'dungeon', zone: 'Tanaris', levels: [66, 68], aliases: ['The Escape From Durnholde'], atlas: [[T, 'OldHillsbradFoothills']] },
  { id: 'seth', name: 'Sethekk Halls', kind: 'dungeon', zone: 'Terokkar Forest', levels: [67, 69], atlas: [[T, 'SethekkHalls']] },
  { id: 'sv', name: 'The Steamvault', kind: 'dungeon', zone: 'Zangarmarsh', levels: [70, 70], atlas: [[T, 'TheSteamvault']] },
  { id: 'slabs', name: 'Shadow Labyrinth', kind: 'dungeon', zone: 'Terokkar Forest', levels: [70, 70], atlas: [[T, 'ShadowLabyrinth']] },
  { id: 'sh', name: 'The Shattered Halls', kind: 'dungeon', zone: 'Hellfire Peninsula', levels: [70, 70], atlas: [[T, 'TheShatteredHalls']] },
  { id: 'bm', name: 'The Black Morass', kind: 'dungeon', zone: 'Tanaris', levels: [70, 70], aliases: ['Opening of the Dark Portal'], atlas: [[T, 'TheBlackMorass']] },
  { id: 'mech', name: 'The Mechanar', kind: 'dungeon', zone: 'Netherstorm', levels: [70, 70], atlas: [[T, 'TheMechanar']] },
  { id: 'bot', name: 'The Botanica', kind: 'dungeon', zone: 'Netherstorm', levels: [70, 70], atlas: [[T, 'TheBotanica']] },
  { id: 'arc', name: 'The Arcatraz', kind: 'dungeon', zone: 'Netherstorm', levels: [70, 70], atlas: [[T, 'TheArcatraz']] },
  { id: 'mgt', name: "Magisters' Terrace", kind: 'dungeon', zone: "Isle of Quel'Danas", levels: [70, 70], atlas: [[T, 'MagistersTerrace']] },
  // Classic dungeons
  { id: 'rfc', name: 'Ragefire Chasm', kind: 'dungeon', zone: 'Orgrimmar', levels: [13, 18], atlas: [[C, 'Ragefire']] },
  { id: 'wc', name: 'Wailing Caverns', kind: 'dungeon', zone: 'The Barrens', levels: [15, 25], atlas: [[C, 'WailingCaverns']] },
  { id: 'deadmines', name: 'The Deadmines', kind: 'dungeon', zone: 'Westfall', levels: [18, 23], atlas: [[C, 'TheDeadmines']] },
  { id: 'sfk', name: 'Shadowfang Keep', kind: 'dungeon', zone: 'Silverpine Forest', levels: [22, 30], atlas: [[C, 'ShadowfangKeep']] },
  { id: 'bfd', name: 'Blackfathom Deeps', kind: 'dungeon', zone: 'Ashenvale', levels: [24, 32], atlas: [[C, 'BlackfathomDeeps']] },
  { id: 'stockade', name: 'The Stockade', kind: 'dungeon', zone: 'Stormwind City', levels: [22, 30], atlas: [[C, 'TheStockade']] },
  { id: 'gnomeregan', name: 'Gnomeregan', kind: 'dungeon', zone: 'Dun Morogh', levels: [29, 38], atlas: [[C, 'Gnomeregan']] },
  { id: 'rfk', name: 'Razorfen Kraul', kind: 'dungeon', zone: 'The Barrens', levels: [30, 40], atlas: [[C, 'RazorfenKraul']] },
  { id: 'sm', name: 'Scarlet Monastery', kind: 'dungeon', zone: 'Tirisfal Glades', levels: [28, 45], atlas: [[C, 'ScarletMonasteryGraveyard'], [C, 'ScarletMonasteryLibrary'], [C, 'ScarletMonasteryArmory'], [C, 'ScarletMonasteryCathedral']] },
  { id: 'rfd', name: 'Razorfen Downs', kind: 'dungeon', zone: 'The Barrens', levels: [40, 50], atlas: [[C, 'RazorfenDowns']] },
  { id: 'uldaman', name: 'Uldaman', kind: 'dungeon', zone: 'Badlands', levels: [42, 52], atlas: [[C, 'Uldaman']] },
  { id: 'zf', name: "Zul'Farrak", kind: 'dungeon', zone: 'Tanaris', levels: [44, 54], atlas: [[C, "Zul'Farrak"]] },
  { id: 'maraudon', name: 'Maraudon', kind: 'dungeon', zone: 'Desolace', levels: [46, 55], atlas: [[C, 'Maraudon']] },
  { id: 'st', name: 'Sunken Temple', kind: 'dungeon', zone: 'Swamp of Sorrows', levels: [50, 60], aliases: ["The Temple of Atal'Hakkar"], atlas: [[C, "TheTempleOfAtal'Hakkar"]] },
  { id: 'brd', name: 'Blackrock Depths', kind: 'dungeon', zone: 'Blackrock Mountain', levels: [52, 60], atlas: [[C, 'BlackrockDepths']] },
  { id: 'brs', name: 'Blackrock Spire', kind: 'dungeon', zone: 'Blackrock Mountain', levels: [55, 60], aliases: ['Lower Blackrock Spire', 'Upper Blackrock Spire'], atlas: [[C, 'LowerBlackrockSpire'], [C, 'UpperBlackrockSpire']] },
  { id: 'dm', name: 'Dire Maul', kind: 'dungeon', zone: 'Feralas', levels: [58, 60], atlas: [[C, 'DireMaulEast'], [C, 'DireMaulWest'], [C, 'DireMaulNorth']] },
  { id: 'scholo', name: 'Scholomance', kind: 'dungeon', zone: 'Western Plaguelands', levels: [58, 60], atlas: [[C, 'Scholomance']] },
  { id: 'strat', name: 'Stratholme', kind: 'dungeon', zone: 'Eastern Plaguelands', levels: [58, 60], atlas: [[C, 'Stratholme']] },
]

// Not real drops, or holiday bosses.
// Badge of Justice: a currency every heroic and raid boss gives, not loot to wish for.
const SKIP_ITEMS = new Set([29434])
const SKIP_BOSSES = new Set(['Keys', 'Coren Direbrew', 'Headless Horseman', 'Apothecary Hummel <Crown Chemical Co.>', 'Ahune <The Frost Lord>', 'Ahune'])

async function get(url) {
  const res = await fetch(url)
  if (!res.ok) throw new Error(`${url}: ${res.status}`)
  return res.text()
}

function braceBlock(src, openIdx) {
  let depth = 0
  for (let i = openIdx; i < src.length; i++) {
    const ch = src[i]
    if (ch === '{') depth++
    else if (ch === '}') {
      depth--
      if (depth === 0) return src.slice(openIdx, i + 1)
    }
  }
  throw new Error('unbalanced braces')
}

function lootRows(boss, label) {
  const at = boss.indexOf(label)
  if (at < 0) return []
  const loot = braceBlock(boss, boss.indexOf('{', at))
  const rows = []
  // { position, itemId ... }, -- Item name      (position 0 = hidden helper rows)
  for (const m of (loot + '\n').matchAll(/\{\s*(\d+)\s*,\s*(\d+)\s*[,}][^\n]*?(?:--\s*([^\n]*))?\n/g)) {
    if (Number(m[1]) === 0 || SKIP_ITEMS.has(Number(m[2]))) continue
    rows.push({ id: Number(m[2]), name: cleanName(m[3] || '') })
  }
  return rows
}

function cleanName(name) {
  const plain = name.replace(/\s+\/\/.*$/, '').replace(/\s{2,}.*$/, '').trim()
  return /^[\w' :,.\-!&()]+$/.test(plain) && plain.length <= 60 ? plain : ''
}

// Every boss in one AtlasLoot instance block: its normal drops, and drops that are heroic-only.
function parseAtlasInstance(src, key) {
  const start = src.indexOf(`data["${key}"] = {`)
  if (start < 0) throw new Error(`AtlasLoot data has no "${key}"`)
  const block = braceBlock(src, src.indexOf('{', start))
  const itemsIdx = block.indexOf('items = {')
  if (itemsIdx < 0) throw new Error(`"${key}" has no items`)
  const itemsBlock = braceBlock(block, block.indexOf('{', itemsIdx))
  const bosses = []
  let depth = 0
  for (let i = 0; i < itemsBlock.length; i++) {
    const ch = itemsBlock[i]
    if (ch === '{') {
      depth++
      if (depth === 2) {
        const boss = braceBlock(itemsBlock, i)
        const nameMatch = boss.match(/name\s*=\s*(?:AL\["([^"]+)"\]|"([^"]+)")/)
        if (nameMatch) {
          const name = (nameMatch[1] || nameMatch[2]).trim()
          const normal = lootRows(boss, '[NORMAL_DIFF]')
          const normalIds = new Set(normal.map((row) => row.id))
          // Where a boss has a heroic list too, a drop is marked heroic (heroic only) or
          // normalOnly; a drop on both lists is left unmarked.
          const heroicAll = lootRows(boss, '[HEROIC_DIFF]')
          const heroicIds = new Set(heroicAll.map((row) => row.id))
          if (heroicAll.length) for (const row of normal) if (!heroicIds.has(row.id)) row.normalOnly = true
          const heroic = heroicAll.filter((row) => !normalIds.has(row.id))
          for (const row of heroic) row.heroic = true
          const rows = [...normal, ...heroic]
          if (!SKIP_BOSSES.has(name) && rows.length) bosses.push({ name, rows })
        }
        i += boss.length - 1
        depth--
      }
    } else if (ch === '}') depth--
  }
  if (!bosses.length) throw new Error(`"${key}" parsed to no bosses`)
  return bosses
}

async function download() {
  const atlas = {
    [C]: await get(`${ATLAS}/AtlasLootClassic_DungeonsAndRaids/data.lua`),
    [T]: await get(`${ATLAS}/AtlasLootClassic_DungeonsAndRaids/data-tbc.lua`),
  }

  // ---- Loot -------------------------------------------------------------------------------
  const items = {}
  const maps = {}
  for (const inst of INSTANCES) {
    const seen = new Set()
    const rows = []
    for (const [file, key] of inst.atlas || []) {
      for (const boss of parseAtlasInstance(atlas[file], key)) {
        for (const row of boss.rows) {
          if (seen.has(row.id)) continue
          seen.add(row.id)
          const out = { id: row.id, boss: boss.name }
          if (row.name) out.name = row.name
          if (row.heroic) out.heroic = true
          if (row.normalOnly) out.normalOnly = true
          rows.push(out)
        }
      }
    }
    items[inst.id] = rows
    // The game's own number for the instance. Names differ ("Coilfang: The Underbog"); this does not.
    const found = []
    for (const [file, key] of inst.atlas || []) {
      const at = atlas[file].indexOf(`data["${key}"] = {`)
      const m = at >= 0 && braceBlock(atlas[file], atlas[file].indexOf('{', at)).match(/\bInstanceID\s*=\s*(\d+)/)
      if (m && !found.includes(Number(m[1]))) found.push(Number(m[1]))
    }
    if (found.length) maps[inst.id] = found
  }

  // ---- Drop rates ---------------------------------------------------------------------------
  const rates = {}
  for (const npc of (await get(`${ATLAS}/AtlasLootClassic_DungeonsAndRaids/droprate.lua`)).matchAll(/\[(\d+)\]\s*=\s*\{([^{}]*)\}/g)) {
    for (const item of npc[2].matchAll(/\[(\d+)\]\s*=\s*([\d.]+)/g)) {
      const id = Number(item[1])
      const rate = Number(item[2])
      if (rate > 0 && rate <= 100 && (!rates[id] || rate > rates[id])) rates[id] = rate
    }
  }
  for (const m of (await get(`${ATLAS}/AtlasLootClassic_DungeonsAndRaids/droprate_override.lua`)).matchAll(/\[(\d+)\]\s*=\s*(false|[\d.]+)/g)) {
    if (m[2] === 'false') delete rates[Number(m[1])]
    else rates[Number(m[1])] = Number(m[2])
  }

  // ---- Item sets (Classic and The Burning Crusade; later expansions start at 750) -----------
  const sets = []
  for (const m of (await get(`${ATLAS}/AtlasLootClassic/Data/ItemSet.lua`)).matchAll(/^\s*\[(\d+)\]\s*=\s*\{\s*\{([\d,\s]+)\}[^\n]*?--\s*([^\n]+)$/gm)) {
    const id = Number(m[1])
    const pieces = m[2].split(',').map((n) => Number(n.trim())).filter(Boolean)
    if (id < 750 && pieces.length >= 2) sets.push({ id, name: m[3].trim(), items: pieces })
  }
  sets.sort((a, b) => a.name.localeCompare(b.name))

  // ---- Quests ----------------------------------------------------------------------------------
  const require = createRequire(import.meta.url)
  const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari')
  const questSrc = await get(`${QUESTIE}/Database/TBC/tbcQuestDB.lua`)
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
    list(q[13]), list(q[12]), list(q[2] and q[2][1]), list(q[2] and q[2][2]),
  }, "\\t")
end
return table.concat(out, "\\n")`
  if (lauxlib.luaL_loadbuffer(L, to_luastring(program), null, to_luastring('quests')) || lua.lua_pcall(L, 0, 1, 0)) {
    throw new Error(to_jsstring(lua.lua_tostring(L, -1)))
  }
  const rows = to_jsstring(lua.lua_tostring(L, -1)).split('\n')

  const xp = new Map()
  for (const m of (await get(`${QUESTIE}/Database/QuestXP/DB/xpDB-tbc.lua`)).matchAll(/\[(\d+)\]\s*=\s*\{\s*(-?\d+)\s*,\s*(\d+)\s*\}/g)) {
    xp.set(Number(m[1]), Number(m[3]))
  }

  const zoneSrc = await get(`${QUESTIE}/Localization/lookups/lookupZones.lua`)
  const zoneName = new Map()
  const zoneContinent = new Map()
  {
    let continent = null
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
  for (const m of (await get(`${QUESTIE}/Database/Zones/zoneTables.lua`)).matchAll(/^\s*\[(\d+)\]\s*=\s*(\d+),\s*--[^\n]*->/gm)) {
    parent.set(Number(m[1]), Number(m[2]))
  }

  const CONTINENT = { 0: 'Eastern Kingdoms', 1: 'Kalimdor', 530: 'Outland' }
  const CLASS_SORT = new Set([-61, -81, -82, -141, -161, -162, -261, -262, -263])
  const PROFESSION_SORT = new Set([-24, -101, -121, -181, -182, -201, -264, -304, -324, -373])
  const SKIP_ZONE = new Set(['Alterac Valley', 'Arathi Basin', 'Warsong Gulch', 'Eye of the Storm', 'Deeprun Tram'])
  const SKIP_NAME = /^<|UNUSED|DEPRECATED|\[PH\]|\bTEST\b|zzOLD|REUSE|\bNYI\b|^\s*$|\[DNT\]/i
  // Blizzard's leftover placeholder quests. Case matters: "Covert Ops - Beta" and "Old Whitebark's Pendant" are real.
  const SKIP_LEFTOVER = /\bBETA\b|^\[?OLD\]?|\[Not Used\]/
  const quests = []
  const zones = {}
  const startedBy = new Map()
  for (const row of rows) {
    const [idText, name, minText, levelText, racesText, classesText, zoneText, flagsText, preAny, preAll, npcStarts, objectStarts] = row.split('\t')
    const id = Number(idText)
    const level = Number(levelText)
    const base = xp.get(id) || 0
    let zone = Number(zoneText)
    if (SKIP_NAME.test(name) || SKIP_LEFTOVER.test(name) || level <= 0 || level > 70 || base <= 0 || (Number(flagsText) & 1) === 1) continue
    if (zone > 0) {
      if (parent.has(zone)) zone = parent.get(zone)
      if (!zoneName.has(zone) || SKIP_ZONE.has(zoneName.get(zone))) continue
      zones[zone] = { name: zoneName.get(zone), group: CONTINENT[zoneContinent.get(zone)] || 'Dungeons and raids' }
    } else if (CLASS_SORT.has(zone)) {
      zone = -1
      zones[zone] = { name: 'Class quests', group: 'Other' }
    } else if (PROFESSION_SORT.has(zone)) {
      zone = -2
      zones[zone] = { name: 'Profession quests', group: 'Other' }
    } else {
      continue
    }
    const quest = { id, name, level, min: Number(minText), zone, xp: base }
    startedBy.set(id, { npcs: (npcStarts || '').split(',').filter(Boolean).map(Number), objects: (objectStarts || '').split(',').filter(Boolean).map(Number), area: Number(zoneText) })
    const races = Number(racesText)
    if (races) quest.races = races
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
  const kept = new Set(quests.map((q) => q.id))
  for (const quest of quests) {
    if (!quest.after) continue
    quest.after = quest.after.filter((id) => kept.has(id))
    if (!quest.after.length) {
      delete quest.after
      delete quest.afterAll
    }
  }

  // ---- Where each quest starts: the quest giver (or object) and a spot on the world map -------
  // Reads one of Questie's big tables and returns id -> { name, spawns: [[area, x, y], ...] },
  // one spot per area, for the ids asked for.
  async function spawnsOf(file, tableName, spawnKey, wanted) {
    const src = await get(`${QUESTIE}/Database/TBC/${file}`)
    const from = src.indexOf('[[return {', src.indexOf(tableName)) + 2
    const table = src.slice(from, src.lastIndexOf(']]'))
    const S = lauxlib.luaL_newstate()
    lualib.luaL_openlibs(S)
    const code = `
local all = (function() ${table} end)()
local out = {}
for _, id in ipairs({ ${[...wanted].join(',')} }) do
  local row = all[id]
  if row and type(row[${spawnKey}]) == "table" then
    local spots = {}
    for area, list in pairs(row[${spawnKey}]) do
      if type(list) == "table" and type(list[1]) == "table" and list[1][1] and list[1][1] >= 0 then
        spots[#spots + 1] = math.floor(area) .. ":" .. list[1][1] .. ":" .. list[1][2]
      end
    end
    table.sort(spots)
    if #spots > 0 then out[#out + 1] = math.floor(id) .. "\\t" .. row[1]:gsub("[\\t\\n]", " ") .. "\\t" .. table.concat(spots, ";") end
  end
end
return table.concat(out, "\\n")`
    if (lauxlib.luaL_loadbuffer(S, to_luastring(code), null, to_luastring(file)) || lua.lua_pcall(S, 0, 1, 0)) {
      throw new Error(to_jsstring(lua.lua_tostring(S, -1)))
    }
    const found = new Map()
    for (const line of to_jsstring(lua.lua_tostring(S, -1)).split('\n')) {
      const [id, name, spots] = line.split('\t')
      if (spots) found.set(Number(id), { name, spawns: spots.split(';').map((spot) => spot.split(':').map(Number)) })
    }
    return found
  }
  const uiMap = new Map()
  {
    const tables = await get(`${QUESTIE}/Database/Zones/zoneTables.lua`)
    const from = tables.indexOf('areaIdToUiMapId = {')
    for (const m of tables.slice(from, tables.indexOf('}', from)).matchAll(/\[(\d+)\]\s*=\s*(\d+)/g)) uiMap.set(Number(m[1]), Number(m[2]))
  }
  const wantedNpcs = new Set()
  const wantedObjects = new Set()
  for (const quest of quests) {
    for (const id of startedBy.get(quest.id).npcs) wantedNpcs.add(id)
    for (const id of startedBy.get(quest.id).objects) wantedObjects.add(id)
  }
  const npcs = await spawnsOf('tbcNpcDB.lua', 'QuestieDB.npcData', 7, wantedNpcs)
  const objects = await spawnsOf('tbcObjectDB.lua', 'QuestieDB.objectData', 4, wantedObjects)
  const starts = {}
  for (const quest of quests) {
    const by = startedBy.get(quest.id)
    const givers = [...by.npcs.map((id) => npcs.get(id)), ...by.objects.map((id) => objects.get(id))].filter(Boolean)
    // The spot in the quest's own zone if there is one, otherwise the first spot the world map can show.
    let pick = null
    for (const giver of givers) {
      const here = giver.spawns.find((spot) => spot[0] === by.area && uiMap.has(spot[0]))
      if (here) { pick = [giver.name, here]; break }
    }
    for (const giver of givers) {
      if (pick) break
      const anywhere = giver.spawns.find((spot) => uiMap.has(spot[0]))
      if (anywhere) pick = [giver.name, anywhere]
    }
    if (pick) starts[quest.id] = [pick[0], uiMap.get(pick[1][0]), Math.round(pick[1][1] * 10) / 10, Math.round(pick[1][2] * 10) / 10]
  }

  writeFileSync(SAVED, JSON.stringify({ fetched: new Date().toISOString().slice(0, 10), items, maps, rates, sets, zones, quests, starts }) + '\n')
  console.log('downloaded TBC data')
}

if (process.argv.includes('--refresh') || !existsSync(SAVED)) await download()
const data = JSON.parse(readFileSync(SAVED, 'utf8'))

function luaString(value) {
  return `"${String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`
}

// ---- Data.lua: places, loot, sets ---------------------------------------------------------------
const ids = new Set()
for (const inst of INSTANCES) {
  if (!/^[a-z][a-z0-9]{1,11}$/.test(inst.id) || /^m\d/.test(inst.id)) throw new Error(`bad instance id "${inst.id}"`)
  if (ids.has(inst.id)) throw new Error(`duplicate instance id "${inst.id}"`)
  ids.add(inst.id)
}
const lines = ['-- Generated by scripts/build-wishwell-tbc.mjs. Do not edit by hand.', 'WishwellTBCData = {', '  instances = {']
for (const inst of INSTANCES) {
  const parts = [`id = ${luaString(inst.id)}`, `name = ${luaString(inst.name)}`, `kind = ${luaString(inst.kind)}`]
  if (inst.size) parts.push(`size = ${inst.size}`)
  if (inst.zone) parts.push(`zone = ${luaString(inst.zone)}`)
  if (inst.levels) parts.push(`min = ${inst.levels[0]}`, `max = ${inst.levels[1]}`)
  if (inst.aliases) parts.push(`aliases = { ${inst.aliases.map(luaString).join(', ')} }`)
  if ((data.maps || {})[inst.id]) parts.push(`maps = { ${data.maps[inst.id].join(', ')} }`)
  lines.push(`    { ${parts.join(', ')} },`)
}
lines.push('  },', '  items = {')
let itemCount = 0
for (const inst of INSTANCES) {
  for (const item of data.items[inst.id] || []) {
    const parts = [`id = ${item.id}`]
    if (item.name) parts.push(`name = ${luaString(item.name)}`)
    parts.push(`boss = ${luaString(item.boss)}`, `raid = ${luaString(inst.id)}`)
    if (item.heroic) parts.push('heroic = true')
    if (item.normalOnly) parts.push('normalOnly = true')
    if (data.rates[item.id]) parts.push(`rate = ${data.rates[item.id]}`)
    lines.push(`    { ${parts.join(', ')} },`)
    itemCount++
  }
}
lines.push('  },', '  sets = {')
for (const set of data.sets) {
  lines.push(`    { id = ${set.id}, name = ${luaString(set.name)}, items = { ${set.items.join(', ')} }, bonus = {} },`)
}
lines.push('  },', '}', '')
writeFileSync(new URL('Data.lua', OUT_DIR), lines.join('\n'))

// ---- DataQuests.lua -----------------------------------------------------------------------------
const q = ['-- Generated by scripts/build-wishwell-tbc.mjs. Do not edit by hand.', 'WishwellTBCData = WishwellTBCData or {}', 'WishwellTBCData.questZones = {']
for (const [id, zone] of Object.entries(data.zones)) q.push(`  [${id}] = { ${luaString(zone.name)}, ${luaString(zone.group)} },`)
q.push('}', 'WishwellTBCData.quests = {')
for (const quest of data.quests) {
  const parts = [quest.id, luaString(quest.name), quest.level, quest.min, quest.zone, quest.xp, quest.races || 0, quest.classes || 0]
  if (quest.after) parts.push(`{ ${quest.after.join(', ')}${quest.afterAll ? ', all = true' : ''} }`)
  q.push(`  { ${parts.join(', ')} },`)
}
// Where each quest starts: { giver, world map id, x, y }.
q.push('}', 'WishwellTBCData.questStarts = {')
for (const [id, start] of Object.entries(data.starts)) q.push(`  [${id}] = { ${luaString(start[0])}, ${start[1]}, ${start[2]}, ${start[3]} },`)
q.push('}', '')
writeFileSync(new URL('DataQuests.lua', OUT_DIR), q.join('\n'))

console.log(`wrote ${INSTANCES.length} raids and dungeons, ${itemCount} items, ${data.sets.length} sets, ${data.quests.length} quests (${Object.keys(data.starts).length} with a start on the map) in ${Object.keys(data.zones).length} zones`)
