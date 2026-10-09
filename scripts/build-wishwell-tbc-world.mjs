// Builds wow-addon/WishwellTBC_World/Data.lua: the world data behind Wishwell TBC's Ask box.
//   npm i --no-save fengari   (once)
//   node scripts/build-wishwell-tbc-world.mjs
//
// Most of it comes from Questie's database for The Burning Crusade client, which covers
// Classic and TBC: every NPC and where it stands, every item and who drops, sells or rewards
// it, and each quest's objectives and where it is handed in.
// What is crafted (profession, skill and reagents) and what each reputation sells come from
// AtlasLootClassic.
// What each creature drops and how often, world drops included, comes from the CMaNGOS TBC
// database (github.com/cmangos/tbc-db), a community reconstruction of the game's loot tables.
// It ships as its own load-on-demand addon so the game only reads it when a question is asked.
import { createRequire } from 'node:module'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { gunzipSync } from 'node:zlib'

const QUESTIE = 'https://raw.githubusercontent.com/Questie/Questie/v10.5.1'
const ATLAS = 'https://raw.githubusercontent.com/Hoizame/AtlasLootClassic/master'
const OUT_DIR = new URL('../wow-addon/WishwellTBC_World/', import.meta.url)
const CACHE = join(tmpdir(), 'wishwell-questie-v10.5.1')
const CMANGOS = 'https://raw.githubusercontent.com/cmangos/tbc-db/master/Full_DB/TBCDB_1.11.0_Vengeance_One_A_Cmangos_Story.sql.gz'
const CMANGOS_CACHE = join(tmpdir(), 'wishwell-cmangos-tbc', 'db.sql.gz')
// An item that more kinds of creature than this can drop is a world drop: it is described
// by the levels and zones of what drops it, not by a list of names.
const WORLD_DROP = 12
const SKIP_NAME = /^<|UNUSED|DEPRECATED|\[PH\]|\bTEST\b|zzOLD|REUSE|\bNYI\b|^\s*$|\[DNT\]|\bDND\b|^OLD\b|\(old\d*\)|^Monster -|^Deprecated|^Test |\[UNUSED\]|^QA|^TEMP\b/i

async function get(path, base = QUESTIE) {
  mkdirSync(CACHE, { recursive: true })
  const file = join(CACHE, (base === QUESTIE ? '' : 'atlas_') + path.replace(/\//g, '_'))
  if (existsSync(file) && !process.argv.includes('--refresh')) return readFileSync(file, 'utf8')
  const res = await fetch(`${base}/${path}`)
  if (!res.ok) throw new Error(`${path}: ${res.status}`)
  const text = await res.text()
  writeFileSync(file, text)
  return text
}

const require = createRequire(import.meta.url)
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari')

// Runs a Questie table through real Lua and returns the lines the program prints out.
function rowsOf(src, tableName, program) {
  const from = src.indexOf('[[return {', src.indexOf(tableName)) + 2
  const table = src.slice(from, src.lastIndexOf(']]'))
  const L = lauxlib.luaL_newstate()
  lualib.luaL_openlibs(L)
  const code = `
local all = (function() ${table} end)()
local out = {}
local function clean(s) return (tostring(s or ""):gsub("[\\t\\n\\r]", " ")) end
local function ids(t)
  if type(t) ~= "table" then return "" end
  local list = {}
  for _, v in ipairs(t) do if type(v) == "number" then list[#list + 1] = tostring(math.floor(v)) end end
  return table.concat(list, ",")
end
-- One spot to stand for a thing: in its home area if it has one, else the first area by number.
local function spot(spawns, home)
  if type(spawns) ~= "table" then return "" end
  local function ok(list) return type(list) == "table" and type(list[1]) == "table" and type(list[1][1]) == "number" end
  local area, list = home, home and spawns[home]
  if not ok(list) then
    area, list = nil, nil
    local keys = {}
    for a in pairs(spawns) do keys[#keys + 1] = a end
    table.sort(keys)
    for _, a in ipairs(keys) do if ok(spawns[a]) then area, list = a, spawns[a] break end end
  end
  if not list then return "" end
  -- Of all the places it stands in that area, the one nearest the middle of them.
  local sx, sy, n = 0, 0, 0
  for _, at in ipairs(list) do
    if type(at) == "table" and type(at[1]) == "number" and type(at[2]) == "number" then sx, sy, n = sx + at[1], sy + at[2], n + 1 end
  end
  local best, bestD = list[1], nil
  for _, at in ipairs(list) do
    if type(at) == "table" and type(at[1]) == "number" and type(at[2]) == "number" then
      local d = (at[1] - sx / n) ^ 2 + (at[2] - sy / n) ^ 2
      if not bestD or d < bestD then best, bestD = at, d end
    end
  end
  return math.floor(area) .. ":" .. best[1] .. ":" .. best[2] .. ":" .. n
end
${program}
return table.concat(out, "\\n")`
  if (lauxlib.luaL_loadbuffer(L, to_luastring(code), null, to_luastring(tableName)) || lua.lua_pcall(L, 0, 1, 0)) {
    throw new Error(to_jsstring(lua.lua_tostring(L, -1)))
  }
  return to_jsstring(lua.lua_tostring(L, -1)).split('\n').filter(Boolean).map((line) => line.split('\t'))
}

const nums = (text) => (text ? text.split(',').map(Number) : [])
const spotOf = (text) => (text ? text.split(':').map(Number) : null)

// ---- Read Questie -------------------------------------------------------------------------------
const npcRows = rowsOf(await get('Database/TBC/tbcNpcDB.lua'), 'QuestieDB.npcData', `
for id, r in pairs(all) do
  out[#out + 1] = table.concat({ math.floor(id), clean(r[1]), math.floor(r[4] or 0), math.floor(r[5] or 0), math.floor(r[6] or 0),
    spot(r[7], r[9]), clean(r[13]), clean(r[14]), math.floor(r[15] or 0) }, "\\t")
end`)
const itemRows = rowsOf(await get('Database/TBC/tbcItemDB.lua'), 'QuestieDB.itemData', `
for id, r in pairs(all) do
  out[#out + 1] = table.concat({ math.floor(id), clean(r[1]), ids(r[2]), ids(r[3]), ids(r[6]), ids(r[14]),
    math.floor(r[9] or 0), math.floor(r[10] or 0), math.floor(r[12] or -1) }, "\\t")
end`)
const objectRows = rowsOf(await get('Database/TBC/tbcObjectDB.lua'), 'QuestieDB.objectData', `
for id, r in pairs(all) do
  out[#out + 1] = table.concat({ math.floor(id), clean(r[1]), spot(r[4], r[5]) }, "\\t")
end`)
const questRows = rowsOf(await get('Database/TBC/tbcQuestDB.lua'), 'QuestieDB.questData', `
local function firsts(t)
  if type(t) ~= "table" then return "" end
  local list = {}
  for _, v in ipairs(t) do if type(v) == "table" and type(v[1]) == "number" then list[#list + 1] = tostring(math.floor(v[1])) end end
  return table.concat(list, ",")
end
for id, q in pairs(all) do
  local o = type(q[10]) == "table" and q[10] or {}
  local text = type(q[8]) == "table" and table.concat(q[8], " ") or ""
  out[#out + 1] = table.concat({ math.floor(id), ids(q[3] and q[3][1]), ids(q[3] and q[3][2]), firsts(o[1]), firsts(o[2]), firsts(o[3]), clean(text) }, "\\t")
end`)

const uiMap = new Map()
{
  const tables = await get('Database/Zones/zoneTables.lua')
  const from = tables.indexOf('areaIdToUiMapId = {')
  for (const m of tables.slice(from, tables.indexOf('}', from)).matchAll(/\[(\d+)\]\s*=\s*(\d+)/g)) uiMap.set(Number(m[1]), Number(m[2]))
}
const areaName = new Map()
{
  const src = await get('Localization/lookups/lookupZones.lua')
  const from = src.indexOf('l10n.zoneLookup = {')
  for (const m of src.slice(from).matchAll(/\[(\d+)\]\s*=\s*"([^"]+)"/g)) if (!areaName.has(Number(m[1]))) areaName.set(Number(m[1]), m[2])
}

// ---- Put it together ----------------------------------------------------------------------------
// The quests Wishwell TBC lists; objectives are only kept for those.
const shipped = new Set(JSON.parse(readFileSync(new URL('../src/data/tbc.json', import.meta.url), 'utf8')).quests.map((q) => q.id))

const npcs = new Map()
for (const [id, name, min, max, rank, spot, side, sub, flags] of npcRows) {
  if (SKIP_NAME.test(name)) continue
  npcs.set(Number(id), { name, min: Number(min), max: Number(max), rank: Number(rank), spot: spotOf(spot), side, sub, flags: Number(flags) })
}
const objects = new Map()
for (const [id, name, spot] of objectRows) {
  if (SKIP_NAME.test(name) || !spot) continue
  objects.set(Number(id), { name, spot: spotOf(spot) })
}
// The most telling few of a long list of droppers: bosses and elites first, then the rest.
function few(ids, limit) {
  const known = ids.filter((id) => npcs.has(id))
  known.sort((a, b) => npcs.get(b).rank - npcs.get(a).rank || npcs.get(b).max - npcs.get(a).max || a - b)
  return known.slice(0, limit)
}
const items = new Map()
for (const [id, name, drops, objectDrops, rewards, vendors, level, need] of itemRows) {
  if (SKIP_NAME.test(name)) continue
  const droppers = nums(drops).filter((n) => npcs.has(n))
  items.set(Number(id), {
    name, level: Number(level), need: Number(need),
    drops: few(droppers, 6), dropCount: droppers.length,
    vendors: few(nums(vendors), 5),
    rewards: nums(rewards).filter((q) => shipped.has(q)).slice(0, 4),
    objects: nums(objectDrops).filter((o) => objects.has(o)).slice(0, 3),
  })
}
const quests = new Map()
const usedObjects = new Set()
for (const [id, endNpcs, endObjects, creatures, objs, needItems, text] of questRows) {
  if (!shipped.has(Number(id))) continue
  const endNpc = nums(endNpcs).find((n) => npcs.has(n))
  const endObject = nums(endObjects).find((o) => objects.has(o))
  const quest = {
    end: endNpc ? endNpc : endObject ? -endObject : 0,
    creatures: nums(creatures).filter((n) => npcs.has(n)).slice(0, 6),
    objects: nums(objs).filter((o) => objects.has(o)).slice(0, 4),
    items: nums(needItems).filter((i) => items.has(i)).slice(0, 6),
    text: text.trim(),
  }
  if (endObject && !endNpc) usedObjects.add(endObject)
  for (const o of quest.objects) usedObjects.add(o)
  quests.set(Number(id), quest)
}
for (const item of items.values()) for (const o of item.objects) usedObjects.add(o)

// ---- What creatures drop, from the CMaNGOS TBC database ------------------------------------------
{
  if (!existsSync(CMANGOS_CACHE)) {
    mkdirSync(dirname(CMANGOS_CACHE), { recursive: true })
    const res = await fetch(CMANGOS)
    if (!res.ok) throw new Error(`${CMANGOS}: ${res.status}`)
    writeFileSync(CMANGOS_CACHE, Buffer.from(await res.arrayBuffer()))
  }
  const sql = gunzipSync(readFileSync(CMANGOS_CACHE)).toString('utf8')
  // The column names of a table, in order, and each of its rows as an array of values.
  const columns = (table) => {
    const at = sql.indexOf(`CREATE TABLE \`${table}\` (`)
    const names = []
    for (const line of sql.slice(at, sql.indexOf('\n) ', at)).split('\n').slice(1)) {
      const m = /^\s+`(\w+)`/.exec(line)
      if (m) names.push(m[1])
    }
    return names
  }
  function* rowsIn(table) {
    const head = `INSERT INTO \`${table}\` VALUES `
    let at = 0
    while ((at = sql.indexOf(head, at)) >= 0) {
      let i = at + head.length
      while (sql[i] === '(') {
        const row = []
        i++
        for (;;) {
          if (sql[i] === "'") {
            let text = ''
            i++
            while (sql[i] !== "'") {
              if (sql[i] === '\\') i++
              text += sql[i++]
            }
            i++
            row.push(text)
          } else {
            const from = i
            while (sql[i] !== ',' && sql[i] !== ')') i++
            const raw = sql.slice(from, i)
            row.push(raw === 'NULL' ? null : Number(raw))
          }
          if (sql[i] === ')') break
          i++
        }
        yield row
        i++
        if (sql[i] === ',') i++
      }
      at = i
    }
  }
  // [table id] = [{ item, chance, group, ref, times }]. A row with a negative count points at a shared table.
  const tablesOf = (table) => {
    const out = new Map()
    for (const [entry, item, chance, group, countOrRef, maxCount] of rowsIn(table)) {
      if (!out.has(entry)) out.set(entry, [])
      out.get(entry).push({ item, chance: Math.abs(chance), group, ref: countOrRef < 0 ? -countOrRef : 0, times: Math.max(1, maxCount) })
    }
    return out
  }
  const creatureLoot = tablesOf('creature_loot_template')
  const shared = tablesOf('reference_loot_template')
  // The chance (0 to 1) of each row of a table. Rows in a group share one roll; a row with
  // no chance of its own takes an equal share of what the others leave.
  const rowChances = (rows) => {
    const left = new Map()
    for (const r of rows) {
      if (r.group > 0) {
        const g = left.get(r.group) || { set: 0, open: 0 }
        if (r.chance > 0) g.set += r.chance
        else g.open++
        left.set(r.group, g)
      }
    }
    return rows.map((r) => {
      if (r.group === 0 || r.chance > 0) return Math.min(1, r.chance / 100)
      const g = left.get(r.group)
      return Math.max(0, 100 - g.set) / g.open / 100
    })
  }
  const merge = (into, item, chance) => into.set(item, 1 - (1 - (into.get(item) || 0)) * (1 - chance))
  // A shared table laid flat: [item] = chance, with the tables it points at folded in.
  const flat = new Map()
  const flatten = (id, depth = 0) => {
    if (flat.has(id)) return flat.get(id)
    const out = new Map()
    flat.set(id, out)
    const rows = shared.get(id) || []
    const chances = rowChances(rows)
    rows.forEach((r, i) => {
      if (!r.ref) merge(out, r.item, chances[i])
      else if (depth < 6) for (const [item, c] of flatten(r.ref, depth + 1)) merge(out, item, chances[i] * (1 - (1 - c) ** r.times))
    })
    return out
  }
  const cols = columns('creature_template')
  const at = (name) => {
    const i = cols.indexOf(name)
    if (i < 0) throw new Error('creature_template has no ' + name)
    return i
  }
  const [ENTRY, MINLEVEL, MAXLEVEL, LOOT] = [at('Entry'), at('MinLevel'), at('MaxLevel'), at('LootId')]
  const named = new Map() // [item] = Map(npc -> chance), creatures that drop it by name
  const wide = new Map() // [big shared table] = { users: [[npc, chance of rolling on it]] }
  for (const row of rowsIn('creature_template')) {
    const npc = row[ENTRY]
    const rows = creatureLoot.get(row[LOOT])
    if (!rows || !npcs.has(npc)) continue
    npcs.get(npc).lvl = [row[MINLEVEL], row[MAXLEVEL]]
    const chances = rowChances(rows)
    const mine = new Map()
    rows.forEach((r, i) => {
      if (!r.ref) return merge(mine, r.item, chances[i])
      const table = flatten(r.ref)
      if (table.size > 60) {
        if (!wide.has(r.ref)) wide.set(r.ref, { users: [] })
        wide.get(r.ref).users.push([npc, chances[i], r.times])
      } else {
        for (const [item, c] of table) merge(mine, item, chances[i] * (1 - (1 - c) ** r.times))
      }
    })
    for (const [item, c] of mine) {
      if (!named.has(item)) named.set(item, new Map())
      named.get(item).set(npc, c)
    }
  }
  // Each big shared table summed up once: who rolls on it, their levels and zones.
  const far = new Map() // [item] = { npcs: Set, min, max, areas: Map, best }
  for (const [ref, w] of wide) {
    for (const [item, c] of flatten(ref)) {
      if (!far.has(item)) far.set(item, { npcs: new Set(), min: 99, max: 0, areas: new Map(), best: 0 })
      const f = far.get(item)
      for (const [npc, roll, times] of w.users) {
        if (f.npcs.has(npc)) continue
        f.npcs.add(npc)
        const n = npcs.get(npc)
        f.min = Math.min(f.min, n.lvl[0])
        f.max = Math.max(f.max, n.lvl[1])
        if (n.spot) f.areas.set(n.spot[0], (f.areas.get(n.spot[0]) || 0) + 1)
        f.best = Math.max(f.best, roll * (1 - (1 - c) ** times))
      }
    }
  }
  const pct = (c) => Number((c * 100).toPrecision(2))
  let withDrops = 0
  let worldDrops = 0
  for (const [id, item] of items) {
    const byName = [...(named.get(id) || [])].sort((a, b) => b[1] - a[1] || a[0] - b[0])
    const f = far.get(id)
    const count = byName.length + (f ? [...f.npcs].filter((n) => !named.get(id)?.has(n)).length : 0)
    if (count === 0) continue
    withDrops++
    item.dropCount = count
    item.drops = byName.slice(0, 6).map(([npc]) => npc)
    item.chances = byName.slice(0, 6).map(([, c]) => pct(c))
    if (count > WORLD_DROP) {
      worldDrops++
      // Levels, zones and best chance over everything that drops it, named or not.
      const all = f || { min: 99, max: 0, areas: new Map(), best: 0 }
      const areas = new Map(all.areas)
      let [min, max, best] = [all.min, all.max, all.best]
      for (const [npc, c] of byName) {
        const n = npcs.get(npc)
        min = Math.min(min, n.lvl[0])
        max = Math.max(max, n.lvl[1])
        best = Math.max(best, c)
        if (n.spot && !(f && f.npcs.has(npc))) areas.set(n.spot[0], (areas.get(n.spot[0]) || 0) + 1)
      }
      item.world = { min, max, best: pct(best), areas: [...areas].sort((a, b) => b[1] - a[1] || a[0] - b[0]).slice(0, 3).map(([area]) => area) }
    }
  }
  // What each creature drops that few others do: [npc] = [[item, chance], ...], likeliest first.
  for (const [id, by] of named) {
    const item = items.get(id)
    if (!item || item.dropCount > WORLD_DROP) continue
    for (const [npc, c] of by) {
      const n = npcs.get(npc)
      if (!n.loot) n.loot = []
      n.loot.push([id, pct(c)])
    }
  }
  for (const n of npcs.values()) if (n.loot) n.loot = n.loot.sort((a, b) => b[1] - a[1] || a[0] - b[0]).slice(0, 12)
  console.log(`loot tables: ${withDrops} items with droppers, ${worldDrops} of them world drops`)
}

// ---- Crafting and reputation, from AtlasLootClassic ---------------------------------------------
// Profession numbers as AtlasLoot has them.
const PROFESSIONS = { 1: 'First Aid', 2: 'Blacksmithing', 3: 'Leatherworking', 4: 'Alchemy', 6: 'Cooking', 7: 'Mining', 8: 'Tailoring',
  9: 'Engineering', 10: 'Enchanting', 11: 'Fishing', 13: 'Poisons', 14: 'Jewelcrafting' }
// [item] = { profession, skill needed, [reagent, ...], [how many, ...] }. TBC's table wins where both have an item.
const crafted = new Map()
{
  const src = await get('AtlasLootClassic/Data/Profession.lua', ATLAS)
  const classicAt = src.indexOf('PROFESSION_DATA.CLASSIC = {')
  const tbcAt = src.indexOf('PROFESSION_DATA.BCC = {')
  const wrathAt = src.indexOf('PROFESSION_DATA.WRATH = {')
  if (classicAt < 0 || tbcAt < classicAt || wrathAt < tbcAt) throw new Error('AtlasLoot profession data has moved')
  const entry = /\[(\d+)\]\s*=\s*\{\s*(nil|\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*\d+\s*,\s*\d+\s*,\s*\{([\d,\s]*)\}\s*,\s*\{([\d,\s]*)\}/g
  for (const part of [src.slice(classicAt, tbcAt), src.slice(tbcAt, wrathAt)]) {
    for (const m of part.matchAll(entry)) {
      const item = Number(m[2])
      const prof = Number(m[3])
      if (!item || !PROFESSIONS[prof] || !items.has(item)) continue
      const reagents = nums(m[5].replace(/\s/g, ''))
      const counts = nums(m[6].replace(/\s/g, ''))
      if (!reagents.length || reagents.some((id) => !items.has(id))) continue
      crafted.set(item, { prof, skill: Number(m[4]), reagents, counts: reagents.map((_, i) => counts[i] || 1) })
    }
  }
}
// [item] = { faction id, standing (5 friendly ... 8 exalted) }, and the factions' names.
const FACTIONS = { 932: 'The Aldor', 934: 'The Scryers', 935: "The Sha'tar", 1011: 'Lower City', 989: 'Keepers of Time', 967: 'The Violet Eye',
  990: 'The Scale of the Sands', 942: 'Cenarion Expedition', 933: 'The Consortium', 1012: 'Ashtongue Deathsworn', 1077: 'Shattered Sun Offensive',
  1031: "Sha'tari Skyguard", 1015: 'Netherwing', 970: 'Sporeggar', 1038: "Ogri'la", 922: 'Tranquillien', 947: 'Thrallmar', 941: "The Mag'har",
  946: 'Honor Hold', 978: 'Kurenai', 529: 'Argent Dawn', 576: 'Timbermaw Hold', 59: 'Thorium Brotherhood', 609: 'Cenarion Circle',
  270: 'Zandalar Tribe', 910: 'Brood of Nozdormu', 749: 'Hydraxian Waterlords', 87: 'Bloodsail Buccaneers', 589: 'Wintersaber Trainers' }
const repItems = new Map()
const usedFactions = new Set()
for (const file of ['AtlasLootClassic_Factions/data.lua', 'AtlasLootClassic_Factions/data-tbc.lua']) {
  let faction = 0
  let standing = 0
  for (const line of (await get(file, ATLAS)).split('\n')) {
    if (/^data\[/.test(line)) faction = standing = 0
    const mark = line.match(/"f(\d+)rep(\d)"/)
    if (mark) {
      faction = Number(mark[1])
      standing = Number(mark[2])
      continue
    }
    const item = line.match(/^\s*\{\s*\d+\s*,\s*(\d+)\s*[,}]/)
    if (item && FACTIONS[faction] && standing >= 4 && items.has(Number(item[1])) && !repItems.has(Number(item[1]))) {
      repItems.set(Number(item[1]), [faction, standing])
      usedFactions.add(faction)
    }
  }
}

// ---- Write --------------------------------------------------------------------------------------
const q = (text) => `"${String(text).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`
const list = (arr) => (arr.length ? `{${arr.join(',')}}` : '0')
const num = (n) => (Number.isInteger(n) ? String(n) : n.toFixed(1))
const usedAreas = new Set()
const place = (spot) => {
  if (!spot) return '0,0,0'
  usedAreas.add(spot[0])
  return `${spot[0]},${num(spot[1])},${num(spot[2])}`
}
const areasOf = (areas) => {
  for (const area of areas) usedAreas.add(area)
  return list(areas)
}
const lines = [
  '-- Generated by scripts/build-wishwell-tbc-world.mjs. Do not edit by hand.',
  '-- From the Questie database (github.com/Questie/Questie), v10.5.1, for the TBC client.',
  '-- Crafting and reputation from AtlasLootClassic (github.com/Hoizame/AtlasLootClassic).',
  '-- Drop chances and world drops from the CMaNGOS TBC database (github.com/cmangos/tbc-db).',
  'WishwellTBCWorld = {',
  '  -- [id] = { name, lowest level, highest level, area, x, y, role flags, title, friendly to (A, H, AH), rank, how many spots }',
  '  npcs = {',
]
for (const [id, n] of [...npcs].sort((a, b) => a[0] - b[0])) {
  lines.push(`[${id}]={${q(n.name)},${n.min},${n.max},${place(n.spot)},${n.flags},${q(n.sub)},${q(n.side)},${n.rank},${n.spot ? n.spot[3] || 1 : 0}},`)
}
lines.push('  },', '  -- [id] = { name, item level, level needed, dropped by, how many drop it in all, sold by, quests that reward it, found in,\n  --   the chance (%) from each of "dropped by", and for a world drop { lowest level, highest level, best chance (%), { areas } } }', '  items = {')
for (const [id, i] of [...items].sort((a, b) => a[0] - b[0])) {
  const more = i.world ? `,${list(i.chances)},{${i.world.min},${i.world.max},${i.world.best},${areasOf(i.world.areas)}}` : (i.chances && i.chances.length ? `,${list(i.chances)}` : '')
  lines.push(`[${id}]={${q(i.name)},${i.level},${i.need},${list(i.drops)},${i.dropCount},${list(i.vendors)},${list(i.rewards)},${list(i.objects)}${more}},`)
}
lines.push('  },', '  -- [npc] = { item, chance (%), item, chance, ... }: what it drops that few others do, likeliest first', '  loot = {')
for (const [id, n] of [...npcs].sort((a, b) => a[0] - b[0])) {
  if (n.loot) lines.push(`[${id}]={${n.loot.map(([item, c]) => `${item},${c}`).join(',')}},`)
}
lines.push('  },', '  -- [id] = { name, area, x, y }: chests, plants and the like that a quest or an item points at', '  objects = {')
for (const id of [...usedObjects].sort((a, b) => a - b)) {
  const o = objects.get(id)
  lines.push(`[${id}]={${q(o.name)},${place(o.spot)}},`)
}
lines.push('  },', '  -- [quest id] = { handed in to (an NPC id, or minus an object id), creatures, objects, items, what the quest asks }', '  quests = {')
for (const [id, quest] of [...quests].sort((a, b) => a[0] - b[0])) {
  lines.push(`[${id}]={${quest.end},${list(quest.creatures)},${list(quest.objects)},${list(quest.items)},${q(quest.text)}},`)
}
lines.push('  },', '  -- [item] = { profession, skill needed, { reagent item, ... }, { how many of each, ... } }: what players make', '  crafted = {')
for (const [id, c] of [...crafted].sort((a, b) => a[0] - b[0])) {
  lines.push(`[${id}]={${c.prof},${c.skill},{${c.reagents.join(',')}},{${c.counts.join(',')}}},`)
}
lines.push('  },', '  professions = {')
for (const [id, name] of Object.entries(PROFESSIONS)) lines.push(`[${id}]=${q(name)},`)
lines.push('  },', '  -- [item] = { faction, standing needed (5 friendly, 6 honored, 7 revered, 8 exalted) }: sold for reputation', '  rep = {')
for (const [id, r] of [...repItems].sort((a, b) => a[0] - b[0])) lines.push(`[${id}]={${r[0]},${r[1]}},`)
lines.push('  },', '  factions = {')
for (const id of [...usedFactions].sort((a, b) => a - b)) lines.push(`[${id}]=${q(FACTIONS[id])},`)
lines.push('  },', '  -- [area] = { name, world map id (0 if the world map cannot show it) }', '  areas = {')
for (const area of [...usedAreas].sort((a, b) => a - b)) {
  lines.push(`[${area}]={${q(areaName.get(area) || '')},${uiMap.get(area) || 0}},`)
}
lines.push('  },', '}', '')
mkdirSync(OUT_DIR, { recursive: true })
writeFileSync(new URL('Data.lua', OUT_DIR), lines.join('\n'))
writeFileSync(new URL('WishwellTBC_World.toc', OUT_DIR), [
  '## Interface: 20506',
  '## Title: Wishwell TBC: World data',
  '## Notes: Every NPC, item and quest objective, for the Ask box in Wishwell TBC. Loads only when a question is asked.',
  '## Author: Squirt',
  '## Version: 1.2.0',
  '## Dependencies: WishwellTBC',
  '## LoadOnDemand: 1',
  '',
  'Data.lua',
  '',
].join('\n'))
const bytes = lines.join('\n').length
console.log(`wrote ${crafted.size} crafted items, ${repItems.size} reputation items, ${npcs.size} NPCs, ${items.size} items, ${usedObjects.size} objects, ${quests.size} quests, ${usedAreas.size} areas (${(bytes / 1048576).toFixed(1)} MB)`)
