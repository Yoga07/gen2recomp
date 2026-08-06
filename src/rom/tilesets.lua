-- Overworld tilesets.
--
-- A Gen 2 map is not a grid of tiles. It is a grid of *blocks*, and a tileset
-- defines what a block looks like: 128 blocks, each a 4x4 arrangement of 8x8
-- tiles. So drawing a map means two indirections — map cell to block, block to
-- sixteen tiles — and the tileset supplies both the block table and the tile
-- graphics.
--
-- The header is fifteen bytes: three far pointers followed by three words.
--
--   0-2   graphics, LZ compressed 2bpp tiles
--   3-5   block definitions, 16 tile indices each
--   6-8   collision, one byte per block quadrant
--   9-10  tile animation script (near pointer)
--   11-12 unused, always zero
--   13-14 palette map (near pointer)
--
-- Nothing here is hardcoded to a cartridge. The table is found by requiring the
-- graphics pointer to resolve to a real LZ block and the collision pointer to
-- sit exactly one block table past the block pointer, which is a relationship
-- no unrelated data satisfies by accident.

local lz = require("src.rom.lz")
local gfx = require("src.rom.gfx")

local tilesets = {}

tilesets.HEADER_SIZE = 15
tilesets.TILES_PER_BLOCK = 16 -- 4x4
tilesets.BLOCK_WIDTH = 4
tilesets.BLOCK_HEIGHT = 4

-- Block count is not fixed and is not stored. Collision data begins where the
-- block table ends, so the gap between the two pointers gives the count:
-- Crystal's tilesets run to 64 or 128 blocks depending on how much variety the
-- area needs. Assuming a constant 128 finds almost none of them.
tilesets.MIN_BLOCKS = 16
tilesets.MAX_BLOCKS = 256

-- Collision stores one value per quadrant of each block.
tilesets.COLLISION_PER_BLOCK = 4

local MIN_GFX_BYTES = 0x200
local MAX_GFX_BYTES = 0x1800

--- Resolve a far pointer stored as (bank, address little-endian).
local function far(rom, offset)
  local bank = rom:u8(offset)
  local addr = rom:u16le(offset + 1)
  if addr < 0x4000 or addr > 0x7FFF then
    return nil
  end
  local flat = bank * 0x4000 + (addr - 0x4000)
  if flat < 0 or flat >= rom.size then
    return nil
  end
  return flat
end

--- Decode a header without validating it.
function tilesets.decode_header(rom, offset)
  local graphics = far(rom, offset)
  local blocks = far(rom, offset + 3)
  local collision = far(rom, offset + 6)
  if not graphics or not blocks or not collision then
    return nil
  end

  local span = collision - blocks
  local block_count
  if span > 0 and span % tilesets.TILES_PER_BLOCK == 0 then
    block_count = span / tilesets.TILES_PER_BLOCK
  end

  return {
    offset = offset,
    graphics = graphics,
    blocks = blocks,
    collision = collision,
    block_count = block_count,
    animation = rom:u16le(offset + 9),
    reserved = rom:u16le(offset + 11),
    palette_map = rom:u16le(offset + 13),
  }
end

--- Is the header at `offset` internally consistent?
local function header_valid(rom, offset)
  if offset + tilesets.HEADER_SIZE > rom.size then
    return false
  end

  local header = tilesets.decode_header(rom, offset)
  if not header then
    return false
  end

  -- The word at 11-12 is unused and always zero.
  if header.reserved ~= 0 then
    return false
  end

  -- Collision sits immediately after the block table, so the gap between the
  -- two pointers must be a whole number of blocks. This single relationship
  -- does most of the work of identifying the table.
  if not header.block_count
    or header.block_count < tilesets.MIN_BLOCKS
    or header.block_count > tilesets.MAX_BLOCKS then
    return false
  end

  -- Graphics must actually decompress to a whole number of tiles.
  local data = lz.decompress(rom.data, header.graphics)
  if not data then
    return false
  end
  local size = #data
  if size < MIN_GFX_BYTES or size > MAX_GFX_BYTES
    or size % gfx.BYTES_PER_TILE ~= 0 then
    return false
  end

  return true
end

--- Locate the tileset header table.
-- @return { offset = n, count = n, headers = { ... } } or nil plus a reason
function tilesets.locate(rom)
  local stride = tilesets.HEADER_SIZE
  local best = { count = 0 }

  local offset = 0
  while offset <= rom.size - stride do
    if header_valid(rom, offset) then
      local start = offset
      local count = 0
      while offset <= rom.size - stride and header_valid(rom, offset) do
        count = count + 1
        offset = offset + stride
      end
      if count > best.count then
        best = { count = count, offset = start }
      end
    else
      offset = offset + 1
    end
  end

  -- Crystal ships a few dozen tilesets; a handful of accidental matches would
  -- not form a long run.
  if best.count < 8 then
    return nil, ("longest run of consistent tileset headers was %d, too short " ..
      "to be the table"):format(best.count)
  end

  local headers = {}
  for i = 0, best.count - 1 do
    headers[i + 1] = tilesets.decode_header(rom, best.offset + i * stride)
  end

  return { offset = best.offset, count = best.count, headers = headers }
end

--- Decompress and decode a tileset's tile graphics.
-- @return array of tiles, each 64 palette indices
function tilesets.decode_graphics(rom, header)
  local data, err = lz.decompress(rom.data, header.graphics)
  if not data then
    return nil, err
  end
  return gfx.decode_tiles(data, 0, #data / gfx.BYTES_PER_TILE)
end

--- Read the block definitions: 128 blocks of 16 tile indices, row-major within
-- the block.
function tilesets.decode_blocks(rom, header)
  local blocks = {}
  for index = 0, header.block_count - 1 do
    local at = header.blocks + index * tilesets.TILES_PER_BLOCK
    local block = {}
    for i = 0, tilesets.TILES_PER_BLOCK - 1 do
      block[i + 1] = rom:u8(at + i)
    end
    blocks[index + 1] = block
  end
  return blocks
end

--- Read collision: four values per block, one per quadrant.
function tilesets.decode_collision(rom, header)
  local collision = {}
  for index = 0, header.block_count - 1 do
    local at = header.collision + index * tilesets.COLLISION_PER_BLOCK
    collision[index + 1] = {
      rom:u8(at), rom:u8(at + 1), rom:u8(at + 2), rom:u8(at + 3),
    }
  end
  return collision
end

--- Render the raw tile sheet, which is the quickest way to see whether the
-- graphics decoded at all.
function tilesets.tilesheet_image(tiles, columns, palette)
  return gfx.to_image_data(tiles, columns or 16, palette, false)
end

--- Render every block in the tileset as a grid, which is the quickest way to
-- see whether the block table decoded. A wrong block pointer still produces
-- tiles, but they assemble into noise rather than doors, trees and paths.
function tilesets.blockset_image(tiles, blocks, columns, palette)
  columns = columns or 8
  palette = palette or gfx.GREYSCALE

  local block_px_w = tilesets.BLOCK_WIDTH * gfx.TILE_WIDTH
  local block_px_h = tilesets.BLOCK_HEIGHT * gfx.TILE_HEIGHT
  local rows = math.ceil(#blocks / columns)

  local image = love.image.newImageData(columns * block_px_w, rows * block_px_h)

  for index, block in ipairs(blocks) do
    local origin_x = ((index - 1) % columns) * block_px_w
    local origin_y = math.floor((index - 1) / columns) * block_px_h

    for i, tile_index in ipairs(block) do
      -- Tile indices are 0-based; anything past the end of the sheet is left
      -- blank rather than wrapping, so an out-of-range index is visible.
      local tile = tiles[tile_index + 1]
      local tile_x = origin_x + ((i - 1) % tilesets.BLOCK_WIDTH) * gfx.TILE_WIDTH
      local tile_y = origin_y + math.floor((i - 1) / tilesets.BLOCK_WIDTH) * gfx.TILE_HEIGHT

      if tile then
        for p = 1, 64 do
          local color = palette[tile[p] + 1]
          image:setPixel(
            tile_x + (p - 1) % 8,
            tile_y + math.floor((p - 1) / 8),
            color[1], color[2], color[3], 1
          )
        end
      end
    end
  end

  return image
end

return tilesets
