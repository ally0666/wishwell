// Builds src/data/forever-droprates.json: how often each Classic item drops, in percent.
//
//   node scripts/fetch-forever-droprates.mjs
//   node scripts/build-forever-data.mjs
//
// The numbers are AtlasLootClassic's Classic Era drop rates. Nobody has published WoW Forever
// rates, so the addon shows these as "Classic rate" and keeps its own count of what it sees.
import { writeFileSync } from 'node:fs'

const BASE = 'https://raw.githubusercontent.com/Hoizame/AtlasLootClassic/master/AtlasLootClassic_DungeonsAndRaids'
const OUT = new URL('../src/data/forever-droprates.json', import.meta.url)

async function get(file) {
  const res = await fetch(`${BASE}/${file}`)
  if (!res.ok) throw new Error(`${file}: ${res.status}`)
  return res.text()
}

const rates = {}
// [npcID] = { [itemID] = rate, ... }. An item that several creatures drop keeps its best rate.
const src = await get('droprate.lua')
for (const npc of src.matchAll(/\[(\d+)\]\s*=\s*\{([^{}]*)\}/g)) {
  for (const item of npc[2].matchAll(/\[(\d+)\]\s*=\s*([\d.]+)/g)) {
    const id = Number(item[1])
    const rate = Number(item[2])
    if (rate > 0 && rate <= 100 && (!rates[id] || rate > rates[id])) rates[id] = rate
  }
}
// Hand corrections AtlasLoot applies on top: a number replaces the rate, false removes it.
const over = await get('droprate_override.lua')
for (const m of over.matchAll(/\[(\d+)\]\s*=\s*(false|[\d.]+)/g)) {
  if (m[2] === 'false') delete rates[Number(m[1])]
  else rates[Number(m[1])] = Number(m[2])
}

const count = Object.keys(rates).length
if (count < 500) throw new Error(`only ${count} drop rates found; the source format may have changed`)
writeFileSync(OUT, JSON.stringify({ source: 'AtlasLootClassic (Classic Era drop rates)', fetched: new Date().toISOString().slice(0, 10), rates }) + '\n')
console.log(`saved drop rates for ${count} items`)
