// Downloads WoW Forever loot tables (item ids, bosses, quest rewards) from wowtbc.gg and
// saves them to src/data/forever-loot.json. Run it again whenever more loot has been
// discovered, then run: node scripts/build-forever-data.mjs
//
//   node scripts/fetch-forever-loot.mjs
//
// "discovered" is the site's own flag: true means the item has been seen in WoW Forever.
import { readFileSync, writeFileSync } from 'node:fs'

const BASE = 'https://wowtbc.gg/page-data/warcraftforever/loot-tables'
const OUT = new URL('../src/data/forever-loot.json', import.meta.url)
const source = JSON.parse(readFileSync(new URL('../src/data/forever.json', import.meta.url), 'utf8'))

// Site page -> Raid Night instance id.
const PAGES = {
  'raids/barrow-deeps': 'barrow',
  'raids/hyjal-summit': 'fhyjal',
  'raids/onyxia-s-lair': 'onyxia',
  'dungeons/hall-of-thanes': 'thanes',
  'dungeons/ruins-of-lordaeron': 'lordaeron',
  'dungeons/excavation-site-wetlands': 'excavation',
  'dungeons/city-of-dalaran': 'dalaran',
  'dungeons/the-drowned-city': 'drowned',
  'dungeons/krol-dok-stronghold': 'kroldok',
  'dungeons/alcaz-prison': 'alcaz',
  'dungeons/blackmaw-hold': 'blackmaw',
  'dungeons/shaper-s-terrace': 'shaper',
  'dungeons/ragefire-chasm': 'rfc',
  'dungeons/wailing-caverns': 'wc',
  'dungeons/the-deadmines': 'deadmines',
  'dungeons/shadowfang-keep': 'sfk',
  'dungeons/blackfathom-deeps': 'bfd',
  'dungeons/the-stockade': 'stockade',
  'dungeons/gnomeregan': 'gnomeregan',
  'dungeons/razorfen-kraul': 'rfk',
  'dungeons/scarlet-monastery-graveyard': 'sm',
  'dungeons/scarlet-monastery-library': 'sm',
  'dungeons/scarlet-monastery-armory': 'sm',
  'dungeons/scarlet-monastery-cathedral': 'sm',
  'dungeons/razorfen-downs': 'rfd',
  'dungeons/uldaman': 'uldaman',
  'dungeons/zul-farrak': 'zf',
  'dungeons/maraudon': 'maraudon',
  'dungeons/the-temple-of-atal-hakkar': 'st',
  'dungeons/blackrock-depths': 'brd',
  'dungeons/blackrock-spire-lower': 'brs',
  'dungeons/blackrock-spire-upper': 'brs',
  'dungeons/dire-maul-east': 'dm',
  'dungeons/dire-maul-west': 'dm',
  'dungeons/dire-maul-north': 'dm',
  'dungeons/scholomance': 'scholo',
  'dungeons/stratholme': 'strat',
}

const SLOTS = {
  head: 'Head', neck: 'Neck', shoulder: 'Shoulder', shoulders: 'Shoulder', back: 'Back', chest: 'Chest',
  wrist: 'Wrist', wrists: 'Wrist', hands: 'Hands', waist: 'Waist', legs: 'Legs', feet: 'Feet',
  finger: 'Finger', trinket: 'Trinket', 'main hand': 'Main Hand', 'off hand': 'Off-hand',
  'held in off-hand': 'Off-hand', 'one-hand': 'One-Hand', 'two-hand': 'Two-Hand', ranged: 'Ranged',
  thrown: 'Thrown', relic: 'Relic', shield: 'Shield', bag: 'Bag',
}

const RARITY = { poor: 0, common: 1, uncommon: 2, rare: 3, epic: 4, legendary: 5 }

const known = new Set(source.instances.map((inst) => inst.id))
const out = {}
const pagesSeen = []
let missing = 0
const levels = {}

for (const [page, instanceId] of Object.entries(PAGES)) {
  if (!known.has(instanceId)) throw new Error(`forever.json has no instance "${instanceId}"`)
  const res = await fetch(`${BASE}/${page}/page-data.json`, { headers: { 'User-Agent': 'RaidNightForever-data-build' } })
  if (!res.ok) {
    console.log(`  ${page}: not on the site (${res.status})`)
    missing++
    continue
  }
  const ctx = (await res.json()).result.pageContext
  const gear = new Map((ctx.gearData || []).map((g) => [g.id, g]))
  const rows = (out[instanceId] ||= [])
  const have = new Set(rows.map((row) => row.id))
  let count = 0
  for (const dungeon of ctx.loot || []) {
    // Level range the dungeon is meant for; wings of one dungeon are merged into one range.
    if (Array.isArray(dungeon.levels) && dungeon.levels.length === 2 && dungeon.levels.every(Number.isInteger)) {
      const range = (levels[instanceId] ||= [dungeon.levels[0], dungeon.levels[1]])
      range[0] = Math.min(range[0], dungeon.levels[0])
      range[1] = Math.max(range[1], dungeon.levels[1])
    }
    const groups = [
      ...(dungeon.bosses || []).map((b) => ({ boss: b.name, items: b.items })),
      ...(dungeon.quests || []).map((q) => ({ boss: 'Quest rewards', items: q.items, faction: q.faction })),
    ]
    for (const group of groups) {
      for (const id of group.items || []) {
        if (have.has(id) || !Number.isInteger(id)) continue
        have.add(id)
        const g = gear.get(id) || {}
        const row = { id, name: g.name || '', boss: String(group.boss).trim(), discovered: g.discovered === true }
        const slot = SLOTS[String(g.slot || '').toLowerCase()]
        if (slot) row.slot = slot
        const quality = RARITY[String(g.rarity || '').toLowerCase()]
        if (quality !== undefined) row.q = quality
        if (group.faction === 'Alliance' || group.faction === 'Horde') row.faction = group.faction
        rows.push(row)
        count++
      }
    }
  }
  pagesSeen.push(page)
  console.log(`  ${page}: ${count} items`)
  await new Promise((resolve) => setTimeout(resolve, 250))
}

const total = Object.values(out).reduce((n, rows) => n + rows.length, 0)
const discovered = Object.values(out).reduce((n, rows) => n + rows.filter((row) => row.discovered).length, 0)
writeFileSync(OUT, JSON.stringify({ source: 'https://wowtbc.gg/warcraftforever/loot-tables/', fetched: new Date().toISOString().slice(0, 10), levels, instances: out }, null, 1) + '\n')
console.log(`saved ${total} items (${discovered} seen in WoW Forever) from ${pagesSeen.length} pages; ${missing} pages missing`)
