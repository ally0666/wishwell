// Draws the rounded-corner artwork for Wishwell TBC's window, panels and buttons.
//   node scripts/make-wishwell-tbc-art.mjs
//
// Two white 64x64 images, tinted in game:
//   Round.tga      a filled square with rounded corners
//   RoundEdge.tga  the outline of the same shape
// The addon cuts each into nine pieces (four corners, four sides, the middle) so one image
// makes a rounded box of any size. The corners are the outer 24 pixels; the curve's radius is 20.
import { readFileSync, writeFileSync } from 'node:fs'

const SIZE = 64
const RADIUS = 20
const LINE = 2 // outline thickness
const SAMPLES = 4 // per pixel, each way, for smooth edges
const OUT = new URL('../wow-addon/WishwellTBC/', import.meta.url)

// How far a point is inside the rounded square (negative outside).
function inside(x, y) {
  const cx = Math.min(Math.max(x, RADIUS), SIZE - RADIUS)
  const cy = Math.min(Math.max(y, RADIUS), SIZE - RADIUS)
  return RADIUS - Math.hypot(x - cx, y - cy)
}

function draw(covers) {
  const pixels = Buffer.alloc(SIZE * SIZE * 4)
  for (let y = 0; y < SIZE; y++) {
    for (let x = 0; x < SIZE; x++) {
      let hit = 0
      for (let sy = 0; sy < SAMPLES; sy++) {
        for (let sx = 0; sx < SAMPLES; sx++) {
          if (covers(inside(x + (sx + 0.5) / SAMPLES, y + (sy + 0.5) / SAMPLES))) hit++
        }
      }
      const at = (y * SIZE + x) * 4
      pixels[at] = pixels[at + 1] = pixels[at + 2] = 255 // BGR: white
      pixels[at + 3] = Math.round((hit / (SAMPLES * SAMPLES)) * 255)
    }
  }
  // Uncompressed 32-bit TGA, the same kind as the wisp artwork.
  const header = Buffer.alloc(18)
  header[2] = 2
  header.writeUInt16LE(SIZE, 12)
  header.writeUInt16LE(SIZE, 14)
  header[16] = 32
  header[17] = 0x08 // 8 alpha bits, bottom row first (the shape is the same either way up)
  return Buffer.concat([header, pixels])
}

writeFileSync(new URL('Round.tga', OUT), draw((depth) => depth >= 0))
writeFileSync(new URL('RoundEdge.tga', OUT), draw((depth) => depth >= 0 && depth <= LINE))

// ---- WispIcon.tga: the wisp, as one picture, for Wisp's tab ------------------------------------
// The wisp is drawn in game from two sheets of 32x32 pixel art: WispBody.tga (a 4x4 sheet of
// flame frames) and WispFace.tga (4 faces in a row: open, half, closed, happy). The icon is the
// first flame with the happy face on it, doubled in size with hard edges so it stays pixel art.
function readTga(name) {
  const buf = readFileSync(new URL(name, OUT))
  if (buf[2] !== 2 || buf[16] !== 32) throw new Error(`${name}: expected an uncompressed 32-bit TGA`)
  const width = buf.readUInt16LE(12)
  const height = buf.readUInt16LE(14)
  const topDown = (buf[17] & 0x20) !== 0
  const start = 18 + buf[0]
  // (x, y) from the top left -> [b, g, r, a], as stored
  return (x, y) => {
    const i = start + ((topDown ? y : height - 1 - y) * width + x) * 4
    return [buf[i], buf[i + 1], buf[i + 2], buf[i + 3]]
  }
}
{
  const CELL = 32
  const body = readTga('WispBody.tga')
  const face = readTga('WispFace.tga')
  const HAPPY = 3
  const pixels = Buffer.alloc(SIZE * SIZE * 4)
  for (let y = 0; y < SIZE; y++) {
    for (let x = 0; x < SIZE; x++) {
      const sx = Math.floor((x * CELL) / SIZE)
      const sy = Math.floor((y * CELL) / SIZE)
      const under = body(sx, sy)
      const over = face(HAPPY * CELL + sx, sy)
      const k = over[3] / 255
      // The picture is written bottom row first, like the others.
      const at = ((SIZE - 1 - y) * SIZE + x) * 4
      for (let c = 0; c < 3; c++) pixels[at + c] = Math.round(over[c] * k + under[c] * (1 - k))
      pixels[at + 3] = Math.max(under[3], over[3])
    }
  }
  const header = Buffer.alloc(18)
  header[2] = 2
  header.writeUInt16LE(SIZE, 12)
  header.writeUInt16LE(SIZE, 14)
  header[16] = 32
  header[17] = 0x08
  writeFileSync(new URL('WispIcon.tga', OUT), Buffer.concat([header, pixels]))
}
console.log('wrote Round.tga, RoundEdge.tga and WispIcon.tga')
