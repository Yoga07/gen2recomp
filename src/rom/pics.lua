-- Pokémon and trainer sprite pointers.
--
-- Sprite pointers are three-byte entries of (bank, address little-endian), but
-- the stored bank is not the bank the data is in. Every pic lives in a run of
-- high banks, so the table keeps a small number and the game adds a constant
-- before switching. Crystal's constant is $36. This is why a naive far-pointer
-- reader finds nothing here.
--
-- On Gold the constant is not enough. Its pic region is banks $12 and $15-$1E:
-- banks $13 and $14 sit in the middle of that range and hold other data, so the
-- pics that would have gone there went to $1F, $20 and $2E instead, and the
-- table records them under the bank numbers the region skipped. Adding any one
-- constant to every entry therefore decodes at most 197 of 251 fronts, and the
-- locator below solves for the mapping instead of assuming it: find the
-- constant that explains the most entries, then, for each stored bank it fails
-- on, look for the one physical bank at which every one of that bank's entries
-- decodes. Crystal's answer comes out as the uniform +$36 it always was.
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
-- locator falls back to solving for the mapping if this fails.
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

-- How many of the first VERIFY_SPECIES may fail and the table still be worth
-- solving a mapping for. Gold's first sixteen contain one entry in a remapped
-- bank; something that is not a table does not come close to this.
local VERIFY_TOLERANCE = 3

-- Once a mapping is solved it must explain the whole table but for Unown's
-- front and back, which are not pointers at all.
local UNMAPPED_LIMIT = 2

-- Below this fraction of the table decoding under the best constant there is
-- nothing worth solving: a real table is mostly right before any remapping.
local COVERAGE_FLOOR = 0.6

--- Resolve one three-byte pointer to a flat ROM offset.
-- @param overrides optional map of stored bank to physical bank, consulted
--        before the constant; used for cartridges whose pic region is not one
--        unbroken run of banks
function pics.resolve(rom, offset, bias, overrides)
  local bank = rom:u8(offset)
  local addr = rom:u16le(offset + 1)
  if addr < 0x4000 or addr > 0x7FFF then
    return nil
  end
  local physical = overrides and overrides[bank] or (bank + bias)
  local flat = physical * 0x4000 + (addr - 0x4000)
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

--- Does the pointer at `at` decode as a front pic of at least `base_tiles`?
local function front_ok(rom, at, bias, overrides, base_tiles)
  local flat = pics.resolve(rom, at, bias, overrides)
  if not flat then
    return false
  end
  local data = lz.decompress(rom.data, flat)
  return data ~= nil and front_size_ok(#data, base_tiles)
end

--- Does the pointer at `at` decode as a back pic? Backs are a uniform 6x6.
local function back_ok(rom, at, bias, overrides)
  local flat = pics.resolve(rom, at, bias, overrides)
  if not flat then
    return false
  end
  local data = lz.decompress(rom.data, flat)
  return data ~= nil and #data == pics.BACK_BYTES
end

--- How many of the first `species_count` species decode, front and back.
--
-- Counts rather than returning on the first failure, because the point is to
-- tell a table with a few entries in an unusual bank apart from something that
-- is not a table at all. `needed` keeps that from costing anything: once enough
-- species have failed that the total cannot be reached, there is no reason to
-- keep decompressing.
local function score(rom, offset, bias, overrides, stats, species_count, needed)
  local hits = 0
  for species = 1, species_count do
    local entry = offset + (species - 1) * STRIDE
    if entry + STRIDE > rom.size then
      break
    end
    local record = stats[species]
    local base_tiles = record.sprite_width * record.sprite_height
    if base_tiles > 0
      and front_ok(rom, entry, bias, overrides, base_tiles)
      and back_ok(rom, entry + 3, bias, overrides) then
      hits = hits + 1
    elseif needed and hits + (species_count - species) < needed then
      return hits
    end
  end
  return hits
end

--- Validate a candidate table by decoding the first several species.
local function verify(rom, offset, bias, stats, species_count)
  return score(rom, offset, bias, nil, stats, species_count, species_count)
    == species_count
end

--- Every pointer in the table, with what its target must decode to.
local function pointers(rom, offset, stats)
  local list = {}
  for species = 1, #stats do
    local entry = offset + (species - 1) * STRIDE
    if entry + STRIDE > rom.size then
      break
    end
    local record = stats[species]
    list[#list + 1] = { at = entry,
      base_tiles = record.sprite_width * record.sprite_height }
    list[#list + 1] = { at = entry + 3 }
  end
  return list
end

--- Does this pointer decode when its address is read out of `bank`?
local function decodes_in(rom, pointer, bank)
  local addr = rom:u16le(pointer.at + 1)
  if addr < 0x4000 or addr > 0x7FFF then
    return false
  end
  local flat = bank * 0x4000 + (addr - 0x4000)
  if flat < 0 or flat + 2 > rom.size then
    return false
  end
  local data = lz.decompress(rom.data, flat)
  if not data then
    return false
  end
  if pointer.base_tiles then
    return pointer.base_tiles > 0 and front_size_ok(#data, pointer.base_tiles)
  end
  return #data == pics.BACK_BYTES
end

--- Solve the stored-bank to physical-bank mapping for a candidate table.
--
-- `bias` explains most of the table; this decides what to do about the rest. A
-- stored bank the constant fails on is searched across every bank in the
-- cartridge, and accepted only if exactly one bank decodes every entry naming
-- it. Twenty-six pointers all landing on compressed pics of the sizes the base
-- stats predict, in one bank and no other, is not something a wrong guess does.
-- Two such banks is ambiguity, and is refused rather than picked between.
--
-- @return map of stored bank to physical bank, or nil plus a reason
local function solve_banks(rom, offset, bias, stats)
  local list = pointers(rom, offset, stats)
  if #list == 0 then
    return nil, "the table does not fit in the cartridge"
  end

  -- Group the pointers the constant does not explain by the bank they name.
  local unexplained, groups, failing = 0, {}, {}
  for _, pointer in ipairs(list) do
    local bank = rom:u8(pointer.at)
    if not decodes_in(rom, pointer, bank + bias) then
      if not groups[bank] then
        groups[bank] = {}
        failing[#failing + 1] = bank
      end
      table.insert(groups[bank], pointer)
      unexplained = unexplained + 1
    end
  end

  if #list - unexplained < #list * COVERAGE_FLOOR then
    return nil, "the constant explains too little of the table to be solved"
  end

  local banks = math.floor(rom.size / 0x4000)
  local overrides, left = {}, 0
  table.sort(failing)
  for _, stored in ipairs(failing) do
    local group = groups[stored]
    local found
    for bank = 0, banks - 1 do
      local all = true
      for _, pointer in ipairs(group) do
        if not decodes_in(rom, pointer, bank) then
          all = false
          break
        end
      end
      if all then
        if found then
          return nil, ("stored bank $%02X decodes in both bank $%02X and $%02X")
            :format(stored, found, bank)
        end
        found = bank
      end
    end
    if found then
      overrides[stored] = found
    else
      left = left + #group
    end
  end

  if left > UNMAPPED_LIMIT then
    return nil, ("%d pointers decode in no bank at all"):format(left)
  end

  -- Fill in the banks the constant did explain, so the map is the whole answer
  -- and nothing downstream needs the constant as well.
  for _, pointer in ipairs(list) do
    local bank = rom:u8(pointer.at)
    if overrides[bank] == nil then
      overrides[bank] = bank + bias
    end
  end
  return overrides
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
-- @return { offset, bias, overrides, stride } or nil plus a reason
function pics.locate(rom, stats)
  -- Fast path: the known constant explains every entry, in one linear pass.
  for offset = 0, rom.size - STRIDE * VERIFY_SPECIES do
    if shape_ok(rom, offset)
      and verify(rom, offset, pics.DEFAULT_BIAS, stats, VERIFY_SPECIES) then
      return { offset = offset, bias = pics.DEFAULT_BIAS, stride = STRIDE }
    end
  end

  -- Fallback: solve for the constant, and then for whatever the constant does
  -- not cover. Only reached on a cartridge that is not laid out like Crystal's,
  -- so the cost of a second pass is acceptable.
  local ambiguity
  local base_tiles = stats[1].sprite_width * stats[1].sprite_height
  for offset = 0, rom.size - STRIDE * VERIFY_SPECIES do
    if shape_ok(rom, offset) then
      for bias = 0, 0x7F do
        -- Reject on species 1 before paying for anything else.
        if front_ok(rom, offset, bias, nil, base_tiles)
          and score(rom, offset, bias, nil, stats, VERIFY_SPECIES,
            VERIFY_SPECIES - VERIFY_TOLERANCE)
            >= VERIFY_SPECIES - VERIFY_TOLERANCE then
          local overrides, why = solve_banks(rom, offset, bias, stats)
          if overrides then
            return { offset = offset, bias = bias, overrides = overrides,
                     stride = STRIDE }
          elseif why and why:find("both bank") then
            ambiguity = why
          end
        end
      end
    end
  end

  return nil, ambiguity or "no offset validated as a pic pointer table"
end

--- Where species `n`'s front and back sprites live.
function pics.entry(rom, table_info, n)
  local entry = table_info.offset + (n - 1) * table_info.stride
  return pics.resolve(rom, entry, table_info.bias, table_info.overrides),
         pics.resolve(rom, entry + 3, table_info.bias, table_info.overrides)
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
