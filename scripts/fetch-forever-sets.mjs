// Builds src/data/forever-sets.json: every WoW Forever item set with its pieces and bonuses.
//
//   node scripts/fetch-forever-sets.mjs
//   node scripts/build-forever-data.mjs
//
// Set names, piece names and bonuses come from wowtbc.gg's WoW Forever data. Piece item ids
// come from AtlasLootClassic's set table (matched by set id, and only trusted when the set
// name is the same), then from our own loot lists by item name. Sets whose pieces still have
// no ids are kept: the addon asks the game for them, and shows the piece names if it can't.
import { existsSync, readFileSync, writeFileSync } from 'node:fs'

const SETS_URL = 'https://wowtbc.gg/page-data/warcraftforever/loot-tables/dungeons/hall-of-thanes/page-data.json'
const ATLAS_URL = 'https://raw.githubusercontent.com/Hoizame/AtlasLootClassic/master/AtlasLootClassic/Data/ItemSet.lua'
const OUT = new URL('../src/data/forever-sets.json', import.meta.url)

const norm = (text) => String(text).toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim()

const siteRes = await fetch(SETS_URL, { headers: { 'User-Agent': 'Wishwell-data-build' } })
if (!siteRes.ok) throw new Error(`set list download failed: ${siteRes.status}`)
const siteSets = (await siteRes.json()).result.pageContext.setsData
if (!Array.isArray(siteSets) || siteSets.length < 50) throw new Error('set list looks wrong')

const atlasRes = await fetch(ATLAS_URL)
if (!atlasRes.ok) throw new Error(`AtlasLoot download failed: ${atlasRes.status}`)
const atlas = new Map()
// 	[209] = {{16866,16868,...},4,4,66,1,{...}}, -- Battlegear of Might
for (const m of (await atlasRes.text()).matchAll(/^\s*\[(\d+)\]\s*=\s*\{\s*\{([\d,\s]+)\}[^\n]*?--\s*([^\n]+)$/gm)) {
  atlas.set(Number(m[1]), { items: m[2].split(',').map((n) => Number(n.trim())).filter(Boolean), name: m[3].trim() })
}
if (atlas.size < 100) throw new Error('AtlasLoot set table looks wrong')

// Item names we already know ids for, from the loot lists. Only names that point at one id.
const byName = new Map()
for (const file of ['forever-loot.json', 'forever-standin.json']) {
  const url = new URL(`../src/data/${file}`, import.meta.url)
  if (!existsSync(url)) continue
  const data = JSON.parse(readFileSync(url, 'utf8'))
  for (const rows of Object.values(data.instances || data)) {
    for (const row of rows) {
      if (!row.name) continue
      const key = norm(row.name)
      if (byName.has(key) && byName.get(key) !== row.id) byName.set(key, null)
      else byName.set(key, row.id)
    }
  }
}

const out = []
let full = 0
let partial = 0
let none = 0
for (const set of siteSets) {
  const pieces = (set.set?.set_pieces || []).map((p) => String(p).trim())
  const bonus = (set.set?.set_bonus || [])
    .filter((b) => Number.isInteger(b.count) && b.value)
    .map((b) => ({ count: b.count, text: String(b.value).trim() }))
  let items = []
  const fromAtlas = atlas.get(set.id)
  if (fromAtlas && norm(fromAtlas.name) === norm(set.name) && fromAtlas.items.length === pieces.length) {
    items = fromAtlas.items
  } else {
    for (const piece of pieces) {
      // The site writes "Item 277117" when it knows the id but not the name yet.
      const raw = piece.match(/^Item (\d+)$/)
      const id = raw ? Number(raw[1]) : byName.get(norm(piece))
      if (id) items.push(id)
    }
  }
  const row = { id: set.id, name: String(set.name).trim(), items, bonus }
  if (items.length < pieces.length) row.pieces = pieces
  if (items.length === pieces.length && pieces.length > 0) full++
  else if (items.length > 0) partial++
  else none++
  out.push(row)
}
out.sort((a, b) => a.name.localeCompare(b.name))
writeFileSync(OUT, JSON.stringify({ source: 'https://wowtbc.gg/warcraftforever/ and AtlasLootClassic', fetched: new Date().toISOString().slice(0, 10), sets: out }, null, 1) + '\n')
console.log(`saved ${out.length} sets: ${full} with every piece id, ${partial} with some, ${none} with none (the game is asked for those)`)
