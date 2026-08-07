-- Overworld sprites: the player and the NPCs walking around the map.
--
-- These are stored uncompressed, which is why none of the tricks that found the
-- Pokémon pics work here. There is no LZ block to index and, unlike the pics,
-- the graphics are not laid out in table order, so entries cannot be chained by
-- size either. Both were tried and both found nothing.
--
-- What worked was finding the graphics first. Scoring every bank on spatial
-- coherence — how often horizontally adjacent pixels share a colour — separates
-- uncompressed art from everything else, including compressed data, which is
-- near-random and defeats the more obvious "uses most of the palette" test by
-- satisfying it perfectly. That put the sprites in the $30s and the font in
-- $3E, which narrowed the table search to "a long run of pointers landing in
-- those banks".
--
-- Entry layout, six bytes:
--
--   0-1  address, within the bank named at byte 3
--   2    VRAM allocation in bytes, $C0 for every sprite in the game
--   3    bank
--   4    type: 1 walking, 2 standing, 3 still
--   5    palette
--
-- Byte 2 is not the size of the data in ROM, which is the trap here. It is how
-- much the game copies into VRAM, and it is $C0 — twelve tiles — for every
-- entry, while the actual graphic is twelve tiles for a standing sprite and
-- twenty-four for a walking one. Reading it as a ROM length finds seven entries
-- and rejects the rest.
--
-- The real extent comes from the gap to the next entry's address, exactly as a
-- tileset's block count comes from the gap between its block and collision
-- pointers.
--
-- A frame is 16x16, so four tiles in reading order. Frame 0 faces down, 1 up
-- and 2 to the side; the left-facing view is the side one mirrored, which is
-- how the original saved a frame.

local gfx = require("src.rom.gfx")

local ow_sprites = {}

ow_sprites.ENTRY_SIZE = 6
ow_sprites.TILES_PER_FRAME = 4
ow_sprites.FRAME_PIXELS = 16

-- VRAM allocation per sprite, in bytes. $C0 is twelve tiles, which walking and
-- standing sprites use; still sprites such as an item lying on the ground take
-- $40, four tiles. Anything that is a whole number of 16x16 frames is allowed,
-- because assuming the common value alone stops the table 68 entries in.
ow_sprites.FRAME_BYTES = ow_sprites.TILES_PER_FRAME * gfx.BYTES_PER_TILE
ow_sprites.MAX_VRAM_BYTES = 0x100
ow_sprites.MAX_TILES = 64

-- Where the graphics live. Used to tell the table from other pointer runs.
ow_sprites.BANKS = {
  [0x2F] = true, [0x30] = true, [0x31] = true,
  [0x32] = true, [0x33] = true, [0x34] = true,
}

-- Frame indices within a standard walking sprite.
ow_sprites.FACE_DOWN = 0
ow_sprites.FACE_UP = 1
ow_sprites.FACE_SIDE = 2

-- Crystal's NPCs reference more sprite ids than the table has entries; the high
-- ones are special-cased by the game rather than being table lookups.
ow_sprites.MIN_ENTRIES = 32

local function decode_entry(rom, offset)
  local addr = rom:u16le(offset)
  if addr < 0x4000 or addr > 0x7FFF then
    return nil
  end

  local bank = rom:u8(offset + 3)
  if not ow_sprites.BANKS[bank] then
    return nil
  end

  local vram = rom:u8(offset + 2)
  if vram == 0 or vram > ow_sprites.MAX_VRAM_BYTES
    or vram % ow_sprites.FRAME_BYTES ~= 0 then
    return nil
  end

  local flat = bank * 0x4000 + (addr - 0x4000)
  if flat >= rom.size then
    return nil
  end

  return {
    offset = offset,
    address = addr,
    bank = bank,
    graphics = flat,
    vram_tiles = vram / gfx.BYTES_PER_TILE,
    kind = rom:u8(offset + 4),
    palette = rom:u8(offset + 5),
  }
end

--- Locate the overworld sprite table.
-- @return { offset = n, entries = {...} } or nil plus a reason
function ow_sprites.locate(rom)
  local best = { count = 0 }

  local offset = 0
  while offset <= rom.size - ow_sprites.ENTRY_SIZE do
    if decode_entry(rom, offset) then
      local start = offset
      local count = 0
      while offset <= rom.size - ow_sprites.ENTRY_SIZE
        and decode_entry(rom, offset) do
        count = count + 1
        offset = offset + ow_sprites.ENTRY_SIZE
      end
      if count > best.count then
        best = { count = count, offset = start }
      end
    else
      offset = offset + 1
    end
  end

  if best.count < ow_sprites.MIN_ENTRIES then
    return nil, ("longest run of sprite entries was %d, too short to be the table")
      :format(best.count)
  end

  local entries = {}
  for i = 0, best.count - 1 do
    entries[i + 1] = decode_entry(rom, best.offset + i * ow_sprites.ENTRY_SIZE)
  end

  -- Fill in each sprite's real extent from where the next one starts. Entries
  -- that end a bank have no successor to measure against, so they fall back to
  -- the VRAM allocation, which is the minimum a sprite can be.
  for i, entry in ipairs(entries) do
    local following = entries[i + 1]
    -- The VRAM allocation is the floor: a sprite is never smaller than what
    -- the game copies out of it.
    local tiles = entry.vram_tiles

    if following and following.bank == entry.bank
      and following.address > entry.address then
      local span = (following.address - entry.address) / gfx.BYTES_PER_TILE
      if span % ow_sprites.TILES_PER_FRAME == 0 and span <= ow_sprites.MAX_TILES
        and span >= tiles then
        tiles = span
      end
    end

    if entry.graphics + tiles * gfx.BYTES_PER_TILE > rom.size then
      tiles = entry.vram_tiles
    end

    entry.tiles = tiles
    entry.frames = tiles / ow_sprites.TILES_PER_FRAME
  end

  return { offset = best.offset, entries = entries }
end

--- Decode one sprite's tiles.
function ow_sprites.decode(rom, entry)
  return gfx.decode_tiles(rom.data, entry.graphics, entry.tiles)
end

--- Render a sprite as a horizontal strip of 16x16 frames, which is the layout
-- the engine indexes into by facing.
function ow_sprites.to_image_data(tiles, frames, palette)
  palette = palette or gfx.GREYSCALE
  local image = love.image.newImageData(
    frames * ow_sprites.FRAME_PIXELS, ow_sprites.FRAME_PIXELS)

  for index, tile in ipairs(tiles) do
    local frame = math.floor((index - 1) / ow_sprites.TILES_PER_FRAME)
    local within = (index - 1) % ow_sprites.TILES_PER_FRAME
    local origin_x = frame * ow_sprites.FRAME_PIXELS + (within % 2) * gfx.TILE_WIDTH
    local origin_y = math.floor(within / 2) * gfx.TILE_HEIGHT

    for p = 1, 64 do
      local index_value = tile[p]
      local colour = palette[index_value + 1]
      -- Colour 0 is the transparent surround on overworld sprites.
      image:setPixel(
        origin_x + (p - 1) % 8,
        origin_y + math.floor((p - 1) / 8),
        colour[1], colour[2], colour[3],
        index_value == 0 and 0 or 1
      )
    end
  end

  return image
end

return ow_sprites
