-- Game Boy Color graphics decoding: 2bpp tile data and BGR555 palettes.

local bytes = require("src.util.bytes")

local gfx = {}

gfx.TILE_WIDTH = 8
gfx.TILE_HEIGHT = 8
gfx.BYTES_PER_TILE = 16 -- 8 rows x 2 bitplanes

--- Decode one 8x8 tile into 64 palette indices in the range 0-3.
--
-- Each row is two bytes: the first holds the low bit of every pixel, the second
-- the high bit. Bit 7 is the leftmost pixel, so the planes are read MSB first.
-- @param data   buffer holding tile data
-- @param offset 0-based offset of the tile
-- @param out    optional table to fill, to avoid churning garbage in a loop
function gfx.decode_tile(data, offset, out)
  out = out or {}
  local i = 1
  for row = 0, 7 do
    local low = string.byte(data, offset + row * 2 + 1)
    local high = string.byte(data, offset + row * 2 + 2)
    if not low or not high then
      return nil, ("tile at 0x%06X is truncated"):format(offset)
    end
    for bit_index = 7, 0, -1 do
      local lo = bytes.band(bytes.rshift(low, bit_index), 1)
      local hi = bytes.band(bytes.rshift(high, bit_index), 1)
      out[i] = hi * 2 + lo
      i = i + 1
    end
  end
  return out
end

--- Decode a run of consecutive tiles.
-- @return array of tiles, each a flat 64-entry array of palette indices.
function gfx.decode_tiles(data, offset, count)
  local tiles = {}
  for i = 0, count - 1 do
    local tile, err = gfx.decode_tile(data, offset + i * gfx.BYTES_PER_TILE)
    if not tile then
      return nil, err
    end
    tiles[i + 1] = tile
  end
  return tiles
end

--- How many whole tiles a buffer holds.
function gfx.tile_count(data)
  return math.floor(#data / gfx.BYTES_PER_TILE)
end

--- Decode a Game Boy Color palette entry.
--
-- Colours are 16-bit little-endian with five bits per channel in BGR order:
-- bit 0-4 red, 5-9 green, 10-14 blue, bit 15 unused. Scaling 5 bits to 8 by
-- replicating the high bits (v << 3 | v >> 2) maps 31 to 255 exactly, which
-- plain multiplication by 8 does not.
-- @return r, g, b as floats in 0-1, ready for love.graphics
function gfx.decode_color(word)
  local r5 = bytes.band(word, 0x1F)
  local g5 = bytes.band(bytes.rshift(word, 5), 0x1F)
  local b5 = bytes.band(bytes.rshift(word, 10), 0x1F)

  local function expand(v5)
    return bytes.bor(bytes.lshift(v5, 3), bytes.rshift(v5, 2)) / 255
  end

  return expand(r5), expand(g5), expand(b5)
end

--- Decode `count` four-colour palettes starting at `offset`.
-- @return array of palettes, each an array of 4 {r, g, b} triples.
function gfx.decode_palettes(data, offset, count)
  local palettes = {}
  for p = 0, count - 1 do
    local palette = {}
    for c = 0, 3 do
      local word = bytes.u16le(data, offset + (p * 4 + c) * 2)
      local r, g, b = gfx.decode_color(word)
      palette[c + 1] = { r, g, b }
    end
    palettes[p + 1] = palette
  end
  return palettes
end

--- The monochrome fallback, used when a palette is not yet known. Matches the
-- shades the original DMG hardware produced, darkest at index 3.
gfx.GREYSCALE = {
  { 1.00, 1.00, 1.00 },
  { 0.66, 0.66, 0.66 },
  { 0.33, 0.33, 0.33 },
  { 0.00, 0.00, 0.00 },
}

--- Render decoded tiles into a love ImageData laid out as a tilesheet.
--
-- Kept here rather than in the importer so the same code paths serve both the
-- PNG export and the in-game atlas upload.
-- @param tiles          array from decode_tiles
-- @param columns        tiles per row in the sheet
-- @param palette        array of 4 {r, g, b}; defaults to greyscale
-- @param transparent_0  treat colour index 0 as transparent (sprites do)
function gfx.to_image_data(tiles, columns, palette, transparent_0)
  palette = palette or gfx.GREYSCALE
  local rows = math.ceil(#tiles / columns)
  local image_data = love.image.newImageData(
    columns * gfx.TILE_WIDTH,
    rows * gfx.TILE_HEIGHT
  )

  for index, tile in ipairs(tiles) do
    local tile_x = ((index - 1) % columns) * gfx.TILE_WIDTH
    local tile_y = math.floor((index - 1) / columns) * gfx.TILE_HEIGHT
    for i = 1, 64 do
      local color_index = tile[i]
      local color = palette[color_index + 1]
      local alpha = (transparent_0 and color_index == 0) and 0 or 1
      image_data:setPixel(
        tile_x + (i - 1) % 8,
        tile_y + math.floor((i - 1) / 8),
        color[1], color[2], color[3], alpha
      )
    end
  end

  return image_data
end

return gfx
