// Draws wow-addon/Wishwell/logo-400.png (the CurseForge project image) from the wisp art.
//   node scripts/make-wishwell-logo.mjs
import { readFileSync, writeFileSync } from 'node:fs'
import { deflateSync, crc32 } from 'node:zlib'

const DIR = new URL('../wow-addon/Wishwell/', import.meta.url)
const SIZE = 400
const SCALE = 9 // the wisp is 32x32 pixel art

// Uncompressed 32-bit TGA -> { width, height, at(x, y) => [r, g, b, a] }
function readTga(name) {
  const buf = readFileSync(new URL(name, DIR))
  if (buf[2] !== 2 || buf[16] !== 32) throw new Error(`${name}: expected an uncompressed 32-bit TGA`)
  const width = buf.readUInt16LE(12)
  const height = buf.readUInt16LE(14)
  const topDown = (buf[17] & 0x20) !== 0
  const start = 18 + buf[0]
  return {
    width,
    height,
    at(x, y) {
      const row = topDown ? y : height - 1 - y
      const i = start + (row * width + x) * 4
      return [buf[i + 2], buf[i + 1], buf[i], buf[i + 3]]
    },
  }
}

const body = readTga('WispBody.tga') // 4x4 sheet of 32x32 flame frames
const face = readTga('WispFace.tga') // 4x1 sheet: open, half, closed, happy
const CELL = 32

const pixels = Buffer.alloc(SIZE * SIZE * 4)
function put(x, y, [r, g, b, a]) {
  if (x < 0 || y < 0 || x >= SIZE || y >= SIZE || a === 0) return
  const i = (y * SIZE + x) * 4
  const t = a / 255
  pixels[i] = Math.round(r * t + pixels[i] * (1 - t))
  pixels[i + 1] = Math.round(g * t + pixels[i + 1] * (1 - t))
  pixels[i + 2] = Math.round(b * t + pixels[i + 2] * (1 - t))
  pixels[i + 3] = 255
}

// Background: dark, with a soft warm glow behind the wisp and a gold frame like the game's.
const cx = SIZE / 2
const cy = SIZE / 2 + 6
for (let y = 0; y < SIZE; y++) {
  for (let x = 0; x < SIZE; x++) {
    const d = Math.hypot(x - cx, y - cy) / (SIZE / 2)
    const glow = Math.max(0, 1 - d) ** 2
    const edge = Math.min(x, y, SIZE - 1 - x, SIZE - 1 - y)
    let color = [14 + glow * 46, 13 + glow * 34, 18 + glow * 10, 255]
    if (edge < 4) color = [38, 30, 16, 255]
    else if (edge < 10) color = [201, 162, 74, 255]
    else if (edge < 12) color = [92, 70, 28, 255]
    put(x, y, color)
  }
}

// The wisp: first flame frame with the happy face, scaled up with hard pixel edges.
const left = Math.round(cx - (CELL * SCALE) / 2)
const top = Math.round(cy - (CELL * SCALE) / 2)
for (let y = 0; y < CELL * SCALE; y++) {
  for (let x = 0; x < CELL * SCALE; x++) {
    const sx = Math.floor(x / SCALE)
    const sy = Math.floor(y / SCALE)
    put(left + x, top + y, body.at(sx, sy))
    put(left + x, top + y, face.at(3 * CELL + sx, sy))
  }
}

// Minimal PNG writer (RGBA, no interlace).
function chunk(type, data) {
  const head = Buffer.alloc(8)
  head.writeUInt32BE(data.length, 0)
  head.write(type, 4, 'ascii')
  const tail = Buffer.alloc(4)
  tail.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), data])) >>> 0, 0)
  return Buffer.concat([head, data, tail])
}
const header = Buffer.alloc(13)
header.writeUInt32BE(SIZE, 0)
header.writeUInt32BE(SIZE, 4)
header[8] = 8 // bit depth
header[9] = 6 // RGBA
const raw = Buffer.alloc((SIZE * 4 + 1) * SIZE)
for (let y = 0; y < SIZE; y++) {
  pixels.copy(raw, y * (SIZE * 4 + 1) + 1, y * SIZE * 4, (y + 1) * SIZE * 4)
}
const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk('IHDR', header),
  chunk('IDAT', deflateSync(raw)),
  chunk('IEND', Buffer.alloc(0)),
])
writeFileSync(new URL('logo-400.png', DIR), png)
console.log(`wrote logo-400.png (${png.length} bytes)`)
