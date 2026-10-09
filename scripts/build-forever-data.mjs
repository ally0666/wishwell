// Builds DataForever.lua for both WoW Forever addons (Wishwell and Raid Night Forever)
// from src/data/forever.json. Each addon gets its own copy under its own table name.
//
//   node scripts/build-forever-data.mjs            rebuild from the saved stand-in list
//   node scripts/build-forever-data.mjs --refresh  re-download Classic loot for the stand-in list first
//
// Stand-in rows are Classic Era drops (from AtlasLootClassic). The addon shows them as
// unconfirmed until the item is seen dropping in WoW Forever or added to forever.json.
import { existsSync, readFileSync, writeFileSync } from 'node:fs'

const ATLAS_URL =
  'https://raw.githubusercontent.com/Hoizame/AtlasLootClassic/master/AtlasLootClassic_DungeonsAndRaids/data.lua'
const SOURCE = new URL('../src/data/forever.json', import.meta.url)
const STANDIN = new URL('../src/data/forever-standin.json', import.meta.url)
const SITE = new URL('../src/data/forever-loot.json', import.meta.url) // from scripts/fetch-forever-loot.mjs
const OUTPUTS = [
  { file: new URL('../wow-addon/Wishwell/DataForever.lua', import.meta.url), table: 'WishwellData', sets: true },
  { file: new URL('../wow-addon/RaidNightForever/DataForever.lua', import.meta.url), table: 'RaidNightForeverData' },
]

// Not real drops, or holiday bosses that were added to Classic after vanilla.
const SKIP_BOSSES = new Set(['Keys', 'Coren Direbrew', 'Headless Horseman', 'Apothecary Hummel <Crown Chemical Co.>'])

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

// Every boss in one AtlasLoot instance block, with its normal-mode item ids and names.
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
        const diffIdx = boss.indexOf('[NORMAL_DIFF]')
        if (nameMatch && diffIdx >= 0) {
          const name = (nameMatch[1] || nameMatch[2]).trim()
          const loot = braceBlock(boss, boss.indexOf('{', diffIdx))
          const rows = []
          // { position, itemId ... }, -- Item name      (position 0 = hidden helper rows)
          const rowRe = /\{\s*(\d+)\s*,\s*(\d+)\s*[,}][^\n]*?(?:--\s*([^\n]*))?\n/g
          let m
          while ((m = rowRe.exec(loot + '\n'))) {
            if (Number(m[1]) === 0) continue
            rows.push({ id: Number(m[2]), name: (m[3] || '').trim() })
          }
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

function cleanName(name) {
  // AtlasLoot comments sometimes carry notes after the name; keep only a plain item name.
  const plain = name.replace(/\s+\/\/.*$/, '').replace(/\s{2,}.*$/, '').trim()
  return /^[\w' :,.\-!&()]+$/.test(plain) && plain.length <= 60 ? plain : ''
}

const source = JSON.parse(readFileSync(SOURCE, 'utf8'))

if (process.argv.includes('--refresh') || !existsSync(STANDIN)) {
  const res = await fetch(ATLAS_URL)
  if (!res.ok) throw new Error(`AtlasLoot download failed: ${res.status}`)
  const atlas = await res.text()
  const standin = {}
  for (const inst of source.instances) {
    if (!inst.atlas) continue
    const seen = new Set()
    const rows = []
    for (const key of inst.atlas) {
      for (const boss of parseAtlasInstance(atlas, key)) {
        for (const row of boss.rows) {
          if (seen.has(row.id)) continue
          seen.add(row.id)
          rows.push({ id: row.id, name: cleanName(row.name), boss: boss.name })
        }
      }
    }
    for (const extra of inst.extraIds || []) {
      if (!seen.has(extra.id)) rows.push(extra)
    }
    standin[inst.id] = rows
  }
  writeFileSync(STANDIN, JSON.stringify(standin, null, 1) + '\n')
  console.log('refreshed stand-in list from AtlasLootClassic')
}

const standin = JSON.parse(readFileSync(STANDIN, 'utf8'))
const siteFile = existsSync(SITE) ? JSON.parse(readFileSync(SITE, 'utf8')) : {}
const site = siteFile.instances || {}
const siteLevels = siteFile.levels || {} // the level range each dungeon is meant for
const RATES = new URL('../src/data/forever-droprates.json', import.meta.url) // from scripts/fetch-forever-droprates.mjs
const rates = existsSync(RATES) ? JSON.parse(readFileSync(RATES, 'utf8')).rates : {}
const SETS = new URL('../src/data/forever-sets.json', import.meta.url) // from scripts/fetch-forever-sets.mjs
// The set list also carries Season of Discovery sets (ids 1000-2097), which are not part of
// WoW Forever as far as anyone has seen. Classic sets and the new Forever sets are kept.
const sets = (existsSync(SETS) ? JSON.parse(readFileSync(SETS, 'utf8')).sets : []).filter(
  (set) => set.id < 1000 || set.id >= 2098,
)

function luaString(value) {
  return `"${String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`
}

const ids = new Set()
for (const inst of source.instances) {
  if (!/^[a-z][a-z0-9]{1,11}$/.test(inst.id)) throw new Error(`bad instance id "${inst.id}"`)
  if (/^m\d/.test(inst.id)) throw new Error(`instance id "${inst.id}" clashes with ids the addon makes up in game`)
  if (ids.has(inst.id)) throw new Error(`duplicate instance id "${inst.id}"`)
  ids.add(inst.id)
}
for (const item of source.items) {
  if (!ids.has(item.raid)) throw new Error(`item ${item.id} names unknown instance "${item.raid}"`)
  if (!Number.isInteger(item.id) || !item.boss) throw new Error(`item ${JSON.stringify(item)} needs id and boss`)
}

const lines = []
lines.push('-- Generated from src/data/forever.json by scripts/build-forever-data.mjs. Do not edit by hand.')
lines.push('__TABLE__ = {')
lines.push('  instances = {')
for (const inst of source.instances) {
  const parts = [`id = ${luaString(inst.id)}`, `name = ${luaString(inst.name)}`, `kind = ${luaString(inst.kind)}`]
  if (inst.size) parts.push(`size = ${inst.size}`)
  if (inst.zone) parts.push(`zone = ${luaString(inst.zone)}`)
  const range = inst.levels || siteLevels[inst.id]
  if (range) parts.push(`min = ${range[0]}`, `max = ${range[1]}`)
  if (inst.aliases) parts.push(`aliases = { ${inst.aliases.map(luaString).join(', ')} }`)
  lines.push(`    { ${parts.join(', ')} },`)
}
lines.push('  },')
lines.push('  items = {')
let confirmed = 0
let unconfirmed = 0
for (const inst of source.instances) {
  // Three sources, most trusted first. An item id is only listed once per raid or dungeon.
  //   1. forever.json items: confirmed by hand
  //   2. forever-loot.json: the loot site's tables; "discovered" there means seen in WoW Forever
  //   3. forever-standin.json: Classic loot nobody has confirmed yet
  const rows = [
    ...source.items.filter((item) => item.raid === inst.id).map((item) => ({ ...item, sure: true })),
    ...(site[inst.id] || []).map((item) => ({ ...item, sure: item.discovered === true })),
    ...(standin[inst.id] || []).map((item) => ({ ...item, sure: false })),
  ]
  const seen = new Set()
  for (const item of rows) {
    if (seen.has(item.id)) continue
    seen.add(item.id)
    const parts = [`id = ${item.id}`]
    if (item.name) parts.push(`name = ${luaString(item.name)}`)
    if (item.slot) parts.push(`slot = ${luaString(item.slot)}`)
    parts.push(`boss = ${luaString(item.boss)}`, `raid = ${luaString(inst.id)}`)
    if (item.classes) parts.push(`classes = ${luaString(item.classes)}`)
    if (item.faction) parts.push(`faction = ${luaString(item.faction)}`)
    // Classic drop chance in percent. Quest rewards are not drops.
    if (rates[item.id] && item.boss !== 'Quest rewards') parts.push(`rate = ${rates[item.id]}`)
    if (Number.isInteger(item.q)) parts.push(`q = ${item.q}`)
    if (!item.sure) parts.push('standin = true')
    lines.push(`    { ${parts.join(', ')} },`)
    if (item.sure) confirmed++
    else unconfirmed++
  }
}
lines.push('  },')
lines.push('__SETS__')
lines.push('}')
lines.push('')

const setLines = ['  sets = {']
for (const set of sets) {
  const parts = [`id = ${set.id}`, `name = ${luaString(set.name)}`, `items = { ${set.items.join(', ')} }`]
  if (set.pieces) parts.push(`pieces = { ${set.pieces.map(luaString).join(', ')} }`)
  parts.push(`bonus = { ${set.bonus.map((b) => `{ ${b.count}, ${luaString(b.text)} }`).join(', ')} }`)
  setLines.push(`    { ${parts.join(', ')} },`)
}
setLines.push('  },')

for (const out of OUTPUTS) {
  const text = lines
    .join('\n')
    .replace('__TABLE__', out.table)
    .replace('__SETS__\n', out.sets ? setLines.join('\n') + '\n' : '')
  writeFileSync(out.file, text)
}
console.log(`wrote ${sets.length} item sets (Wishwell only)`)

// Quests (from scripts/fetch-forever-quests.mjs). One row per quest:
//   { id, name, level, needs level, zone, base XP, race mask, class mask, { quests that come first } }
const QUESTS = new URL('../src/data/forever-quests.json', import.meta.url)
if (existsSync(QUESTS)) {
  const data = JSON.parse(readFileSync(QUESTS, 'utf8'))
  const out = ['-- Generated from src/data/forever-quests.json by scripts/build-forever-data.mjs. Do not edit by hand.']
  out.push('WishwellData = WishwellData or {}')
  out.push('WishwellData.questZones = {')
  for (const [id, zone] of Object.entries(data.zones)) {
    out.push(`  [${id}] = { ${luaString(zone.name)}, ${luaString(zone.group)} },`)
  }
  out.push('}')
  out.push('WishwellData.quests = {')
  for (const q of data.quests) {
    const parts = [q.id, luaString(q.name), q.level, q.min, q.zone, q.xp, q.races || 0, q.classes || 0]
    if (q.after) parts.push(`{ ${q.after.join(', ')}${q.afterAll ? ', all = true' : ''} }`)
    out.push(`  { ${parts.join(', ')} },`)
  }
  out.push('}')
  out.push('')
  writeFileSync(new URL('../wow-addon/Wishwell/DataQuests.lua', import.meta.url), out.join('\n'))
  console.log(`wrote ${data.quests.length} quests in ${Object.keys(data.zones).length} zones (Wishwell only)`)
}
console.log(`wrote ${source.instances.length} instances, ${confirmed} confirmed items, ${unconfirmed} stand-in items`)
