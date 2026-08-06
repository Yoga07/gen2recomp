-- Pokémon and trainer sprite pointers.
--
-- Sprite pointers are three-byte entries of (bank, address little-endian), but
-- the stored bank is biased: every pic lives in a contiguous run of high banks,
-- so the tables keep a small number and the game adds a constant before
-- switching. Crystal's constant is $36. This is why a naive far-pointer reader
-- finds nothing here.
--
-- The other trap is size. A species' front pic does not decompress to
-- width * height * 16 bytes. Crystal animates front sprites, and the extra
-- frames are appended inside the same compressed block, so the decompressed
-- data is the base sprite followed by however many animation tiles that species
-- needs. The base sprite is the first width * height tiles; the remainder is
-- frame data. Back sprites are a uniform 6x6 and are not animated.
--
-- Tiles within a pic are stored column by column, not row by row.

local lz = require("src.rom.lz")
local gfx = require("src.rom.gfx")

local pics = {}

-- Crystal's bias. Tried first because it is almost certainly right; the
-- locator falls back to solving for it if this fails.
pics.DEFAULT_BIAS = 0x36

pics.BACK_TILES = 6 * 6
pics.BACK_BYTES = pics.BACK_TILES * gfx.BYTES_PER_TILE

-- Unown is the one species whose entry in the main table is not a usable
-- pointer. It has 26 forms, one per letter, and the game branches on the
-- species before the normal lookup to read a dedicated 26-entry table instead.
--
-- That table has NOT been located yet, and the attempts so far are instructive
-- about why. Searching for "26 consecutive equally sized sprites" matches the
-- trainer class table at $128000, whose 67 entries are all 7x7. Adding "and the
-- 27th entry must break the pattern" just moves the match to $12807B — entries
-- 41 to 66 of that same table, where the run ends because the table does.
--
-- A correct search needs a discriminator that is actually about Unown rather
-- than about run length. The likely flaw in the premise is the assumption that
-- all 26 forms decompress to the same size: 250 of 251 species carry appended
-- animation frames, so Unown's forms probably differ in length too.
pics.UNOWN_SPECIES = 201
pics.UNOWN_FORMS = 26

local STRIDE = 6 -- front pointer then back pointer, three bytes each
local VERIFY_SPECIES = 16
local MAX_ANIMATION_FACTOR = 6 -- a sane ceiling on base + frames

--- Resolve one three-byte pointer to a flat ROM offset.
function pics.resolve(rom, offset, bias)
  local bank = rom:u8(offset)
  local addr = rom:u16le(offset + 1)
  if addr < 0x4000 or addr > 0x7FFF then
    return nil
  end
  local flat = (bank + bias) * 0x4000 + (addr - 0x4000)
  if flat < 0 or flat + 2 > rom.size then
    return nil
  end
  return flat
end

--- Is `size` a credible decompressed front pic for a sprite of `base_tiles`?
local function front_size_ok(size, base_tiles)
  local base_bytes = base_tiles * gfx.BYTES_PER_TILE
  return size >= base_bytes
    and size <= base_bytes * MAX_ANIMATION_FACTOR
    and size % gfx.BYTES_PER_TILE == 0
end

--- Validate a candidate table by decoding the first several species.
local function verify(rom, offset, bias, stats, species_count)
  for species = 1, species_count do
    local entry = offset + (species - 1) * STRIDE
    if entry + STRIDE > rom.size then
      return false
    end

    local record = stats[species]
    local base_tiles = record.sprite_width * record.sprite_height
    if base_tiles == 0 then
      return false
    end

    local front_at = pics.resolve(rom, entry, bias)
    if not front_at then
      return false
    end
    local front = lz.decompress(rom.data, front_at)
    if not front or not front_size_ok(#front, base_tiles) then
      return false
    end

    local back_at = pics.resolve(rom, entry + 3, bias)
    if not back_at then
      return false
    end
    local back = lz.decompress(rom.data, back_at)
    if not back or #back ~= pics.BACK_BYTES then
      return false
    end
  end
  return true
end

--- Cheap structural gate before the expensive verification: the first several
-- entries must all carry an address in the switchable bank window.
--
-- Deliberately says nothing about the bank bytes. An earlier version also
-- required consecutive banks to stay close together, which sounds reasonable
-- and is wrong — a species' front and back pics live in different parts of the
-- pic region, so the banks alternate rather than climb. Crystal's table opens
-- with banks $1D $22 $19 $20 $12 $1D $1A $21, and a proximity rule rejected the
-- real table while admitting a false one 22 entries later.
--
-- Requiring eight addresses in a quarter of the value space already rejects all
-- but a handful of offsets in the ROM, which is all this needs to do.
local function shape_ok(rom, offset)
  for i = 0, 7 do
    local at = offset + i * 3
    if at + 3 > rom.size then
      return false
    end
    local addr = rom:u16le(at + 1)
    if addr < 0x4000 or addr > 0x7FFF then
      return false
    end
  end
  return true
end

--- Locate the Pokémon pic pointer table.
-- @param stats decoded base-stat records, which supply the expected footprints
-- @return { offset, bias, stride } or nil plus a reason
function pics.locate(rom, stats)
  -- Fast path: the known bias, one linear pass.
  for offset = 0, rom.size - STRIDE * VERIFY_SPECIES do
    if shape_ok(rom, offset)
      and verify(rom, offset, pics.DEFAULT_BIAS, stats, VERIFY_SPECIES) then
      return { offset = offset, bias = pics.DEFAULT_BIAS, stride = STRIDE }
    end
  end

  -- Fallback: solve for the bias. Only reached on a cartridge whose constant
  -- differs from Crystal's, so the cost is acceptable.
  for offset = 0, rom.size - STRIDE * VERIFY_SPECIES do
    if shape_ok(rom, offset) then
      for bias = 0, 0x7F do
        -- Reject on species 1 before paying for the full verification.
        local front_at = pics.resolve(rom, offset, bias)
        if front_at then
          local front = lz.decompress(rom.data, front_at)
          local base_tiles = stats[1].sprite_width * stats[1].sprite_height
          if front and front_size_ok(#front, base_tiles)
            and verify(rom, offset, bias, stats, VERIFY_SPECIES) then
            return { offset = offset, bias = bias, stride = STRIDE }
          end
        end
      end
    end
  end

  return nil, "no offset validated as a pic pointer table"
end

--- Where species `n`'s front and back sprites live.
function pics.entry(rom, table_info, n)
  local entry = table_info.offset + (n - 1) * table_info.stride
  return pics.resolve(rom, entry, table_info.bias),
         pics.resolve(rom, entry + 3, table_info.bias)
end

--- Decode a species' front sprite.
-- @return tiles (base frame only), animation_tiles, total decompressed bytes
function pics.decode_front(rom, table_info, n, stats)
  local front_at = pics.entry(rom, table_info, n)
  if not front_at then
    return nil, ("species %d has no resolvable front pointer"):format(n)
  end

  local data, err = lz.decompress(rom.data, front_at)
  if not data then
    return nil, err
  end

  local record = stats[n]
  local base_tiles = record.sprite_width * record.sprite_height
  local total_tiles = #data / gfx.BYTES_PER_TILE

  if total_tiles < base_tiles then
    return nil, ("species %d decompressed to %d tiles, fewer than the %d its " ..
      "recorded footprint needs"):format(n, total_tiles, base_tiles)
  end

  local tiles = gfx.decode_tiles(data, 0, base_tiles)
  return tiles, total_tiles - base_tiles, #data
end

function pics.decode_back(rom, table_info, n)
  local _, back_at = pics.entry(rom, table_info, n)
  if not back_at then
    return nil, ("species %d has no resolvable back pointer"):format(n)
  end
  local data, err = lz.decompress(rom.data, back_at)
  if not data then
    return nil, err
  end
  return gfx.decode_tiles(data, 0, pics.BACK_TILES)
end

--- Arrange a pic's tiles into an image.
--
-- Pics are stored column-major: tile 0 is the top-left, tile 1 is directly
-- below it, and a new column starts every `height` tiles. Laying them out
-- row-major produces a recognisable but scrambled sprite, which is a subtle
-- enough bug to be worth stating plainly.
function pics.to_image_data(tiles, width, height, palette, transparent_0)
  palette = palette or gfx.GREYSCALE
  local image_data = love.image.newImageData(
    width * gfx.TILE_WIDTH,
    height * gfx.TILE_HEIGHT
  )

  for index, tile in ipairs(tiles) do
    local column = math.floor((index - 1) / height)
    local row = (index - 1) % height
    local origin_x = column * gfx.TILE_WIDTH
    local origin_y = row * gfx.TILE_HEIGHT

    for i = 1, 64 do
      local color_index = tile[i]
      local color = palette[color_index + 1]
      local alpha = (transparent_0 and color_index == 0) and 0 or 1
      image_data:setPixel(
        origin_x + (i - 1) % 8,
        origin_y + math.floor((i - 1) / 8),
        color[1], color[2], color[3], alpha
      )
    end
  end

  return image_data
end

return pics
