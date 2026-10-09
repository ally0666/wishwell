// Builds the talent plans for Wishwell TBC (wow-addon/WishwellTBC/DataTalents.lua).
//
//   node scripts/build-wishwell-tbc-talents.mjs --refresh   download the talent trees again, then build
//   node scripts/build-wishwell-tbc-talents.mjs             build from the saved copy in src/data/tbc-talents.json
//
// The talent trees (where each talent sits, its ranks, what it needs first) come from the
// wowsims TBC project. So do most of the builds: they are the standard level 70 builds its
// simulators use. Every build is checked against the trees here, so a build the game would
// not let you make stops the script instead of shipping.
import { existsSync, readFileSync, writeFileSync } from 'node:fs'

const WOWSIMS = 'https://raw.githubusercontent.com/wowsims/tbc/master/ui/core/talents'
const SAVED = new URL('../src/data/tbc-talents.json', import.meta.url)
const OUT = new URL('../wow-addon/WishwellTBC/DataTalents.lua', import.meta.url)
const POINTS = 61 // one a level from 10 to 70

// class file name -> [game class token, builds]. The first build of each role is the one
// the addon recommends. data: ranks per talent, tree by tree, in the usual talent-calculator form.
const CLASSES = {
  druid: ['DRUID', [
    { key: 'cat', role: 'dps', name: 'Feral (Cat)', data: '-503032132322105301251-05503301' },
    { key: 'balance', role: 'dps', name: 'Balance (Moonkin)', data: '510022312503135231351--520033' },
    { key: 'bear', role: 'tank', name: 'Feral (Bear)', data: '-503032132322105301251-05503301' },
    { key: 'resto', role: 'heal', name: 'Restoration (Tree of Life)', data: '--50353351531522531351' },
  ]],
  hunter: ['HUNTER', [
    { key: 'bm', role: 'dps', name: 'Beast Mastery', data: '512002015150122431051-0505201205' },
    { key: 'sv', role: 'dps', name: 'Survival', data: '502-0550201205-333200022003223005103' },
    { key: 'mm', role: 'dps', name: 'Marksmanship', data: '51200200502-0551201205013253135' },
  ]],
  mage: ['MAGE', [
    { key: 'fire', role: 'dps', name: 'Fire', data: '2-505202012303331053125-043500001' },
    { key: 'arcane', role: 'dps', name: 'Arcane', data: '2500250300030150330125--053500031003001' },
    { key: 'frost', role: 'dps', name: 'Frost', data: '230015031003--0535000310230012241551' },
  ]],
  paladin: ['PALADIN', [
    { key: 'ret', role: 'dps', name: 'Retribution', data: '5-503201-0523005130033125231051' },
    { key: 'prot', role: 'tank', name: 'Protection', data: '-0530513050000142521051-052050003003' },
    { key: 'holy', role: 'heal', name: 'Holy', data: '05503110520130531151-500251002103' },
  ]],
  priest: ['PRIEST', [
    { key: 'shadow', role: 'dps', name: 'Shadow', data: '500230013--503250510240103051451' },
    { key: 'holy', role: 'heal', name: 'Holy (Circle of Healing)', data: '50023011305-235050032002150520051' },
  ]],
  rogue: ['ROGUE', [
    { key: 'combat', role: 'dps', name: 'Combat (Swords)', data: '0053201252-023305102005015002321051' },
    { key: 'maces', role: 'dps', name: 'Combat (Maces)', data: '005320123-023305002005515002321051' },
    { key: 'mutilate', role: 'dps', name: 'Assassination (Mutilate)', data: '005323125500102501051-005305200005' },
  ]],
  shaman: ['SHAMAN', [
    { key: 'enh', role: 'dps', name: 'Enhancement', data: '250030502-502500210501133531151' },
    { key: 'ele', role: 'dps', name: 'Elemental', data: '55003105100213351051--05105301005' },
    { key: 'resto', role: 'heal', name: 'Restoration', data: '5003--55035051355310510321' },
  ]],
  warlock: ['WARLOCK', [
    { key: 'destro', role: 'dps', name: 'Destruction', data: '-20501301332001-50500051220051053105' },
    { key: 'aff', role: 'dps', name: 'Affliction', data: '55022000102351055103--50500051220001' },
    { key: 'demo', role: 'dps', name: 'Demonology', data: '01-2050030133250101501351-5050005112' },
  ]],
  warrior: ['WARRIOR', [
    { key: 'fury', role: 'dps', name: 'Fury', data: '3500501130201-05050005505012050115' },
    { key: 'arms', role: 'dps', name: 'Arms', data: '32003301352010500221-0550000500521203' },
    { key: 'prot', role: 'tank', name: 'Protection', data: '350003011-05-0055511033010103501351' },
  ]],
}

async function download() {
  const out = {}
  for (const cls of Object.keys(CLASSES)) {
    const res = await fetch(`${WOWSIMS}/${cls}.ts`)
    if (!res.ok) throw new Error(`${cls}: ${res.status}`)
    const trees = []
    let tree = null
    let talent = null
    let inPrereq = false
    for (const raw of (await res.text()).split('\n')) {
      const line = raw.trim()
      let m
      if ((m = line.match(/^name: '(.+)',$/))) {
        tree = { name: m[1], talents: [] }
        trees.push(tree)
      } else if (!tree) {
        continue
      } else if ((m = line.match(/^(?:\/\/)?\s*fieldName: '([\w ]+)'/))) {
        talent = { field: m[1] }
        tree.talents.push(talent)
        inPrereq = false
      } else if (/^location: \{/.test(line)) {
        inPrereq = false
      } else if (/^prereqLocation: \{/.test(line)) {
        inPrereq = true
        talent.pre = {}
      } else if ((m = line.match(/^rowIdx: (\d+)/))) {
        if (inPrereq) talent.pre.row = Number(m[1])
        else talent.row = Number(m[1])
      } else if ((m = line.match(/^colIdx: (\d+)/))) {
        if (inPrereq) talent.pre.col = Number(m[1])
        else talent.col = Number(m[1])
      } else if ((m = line.match(/^maxPoints: (\d+)/))) {
        talent.max = Number(m[1])
      }
    }
    if (trees.length !== 3) throw new Error(`${cls}: expected 3 trees, got ${trees.length}`)
    for (const t of trees) {
      for (const talent of t.talents) {
        if (talent.row == null || talent.col == null || !talent.max) throw new Error(`${cls} ${t.name}: incomplete talent ${talent.field}`)
      }
    }
    out[cls] = trees
  }
  writeFileSync(SAVED, JSON.stringify(out) + '\n')
  console.log('downloaded the talent trees')
}

if (process.argv.includes('--refresh') || !existsSync(SAVED)) await download()
const TREES = JSON.parse(readFileSync(SAVED, 'utf8'))

// Checks a build the way the game does, and returns the order to spend the points in:
// the main tree first, top row down, then the other trees.
function plan(cls, build) {
  const where = `${cls} ${build.name}`
  const parts = build.data.split('-')
  if (parts.length > 3) throw new Error(`${where}: too many trees`)
  const trees = TREES[cls].map((tree, t) => {
    const digits = parts[t] || ''
    if (digits.length > tree.talents.length) throw new Error(`${where}: too many talents in ${tree.name}`)
    const picks = tree.talents.map((talent, i) => ({ ...talent, tab: t + 1, rank: Number(digits[i] || 0) }))
    let above = 0
    for (let row = 0; row <= 8; row++) {
      const inRow = picks.filter((p) => p.row === row)
      const spent = inRow.reduce((sum, p) => sum + p.rank, 0)
      if (spent > 0 && above < row * 5) throw new Error(`${where}: row ${row + 1} of ${tree.name} needs ${row * 5} points above it, has ${above}`)
      above += spent
    }
    for (const p of picks) {
      if (p.rank > p.max) throw new Error(`${where}: ${p.field} has ${p.rank} of ${p.max}`)
      if (p.rank > 0 && p.pre) {
        const need = picks.find((o) => o.row === p.pre.row && o.col === p.pre.col)
        if (!need || need.rank < need.max) throw new Error(`${where}: ${p.field} needs ${need ? need.field : 'a missing talent'} first`)
      }
    }
    return { name: tree.name, picks, points: above }
  })
  const total = trees.reduce((sum, tree) => sum + tree.points, 0)
  if (total !== POINTS) throw new Error(`${where}: ${total} points, expected ${POINTS}`)

  const order = []
  const byPoints = [...trees].sort((a, b) => b.points - a.points)
  for (const tree of byPoints) {
    for (let row = 0; row <= 8; row++) {
      const inRow = tree.picks.filter((p) => p.row === row && p.rank > 0)
      // A talent that another one in the same row needs goes first.
      inRow.sort((a, b) => {
        if (b.pre && b.pre.row === a.row && b.pre.col === a.col) return -1
        if (a.pre && a.pre.row === b.row && a.pre.col === b.col) return 1
        return a.col - b.col
      })
      for (const p of inRow) {
        for (let i = 0; i < p.rank; i++) order.push(`${p.tab}${p.row + 1}${p.col + 1}`)
      }
    }
  }
  return { points: trees.map((tree) => tree.points), order: order.join('') }
}

const lines = ['-- Generated by scripts/build-wishwell-tbc-talents.mjs. Do not edit by hand.',
  '-- order: three digits for each talent point in the order to spend them: tree, row, column.',
  'WishwellTBCData = WishwellTBCData or {}', 'WishwellTBCData.talents = {']
let count = 0
for (const [cls, [token, builds]] of Object.entries(CLASSES)) {
  lines.push(`  ${token} = {`, `    trees = { ${TREES[cls].map((tree) => `"${tree.name}"`).join(', ')} },`, '    builds = {')
  const keys = new Set()
  for (const build of builds) {
    if (keys.has(build.key)) throw new Error(`${cls}: duplicate key ${build.key}`)
    keys.add(build.key)
    const made = plan(cls, build)
    lines.push(`      { key = "${build.key}", role = "${build.role}", name = "${build.name}", points = { ${made.points.join(', ')} }, order = "${made.order}" },`)
    count++
  }
  lines.push('    },', '  },')
}
lines.push('}', '')
writeFileSync(OUT, lines.join('\n'))
console.log(`wrote ${count} checked builds for ${Object.keys(CLASSES).length} classes`)
