-- Pokémon sprite palettes.
--
-- Gen 2 stores only two colours per sprite. The rendered four-colour palette is
-- white, those two, then black — the endpoints are implicit and never stored,
-- which is why the table is far smaller than it first appears. Each species
-- carries a normal pair and a shiny pair, so a record is four BGR555 words.
--
-- Locating the table needs no known colour values. Every stored word is a
-- 15-bit colour, so bit 15 is always clear, and within each pair the first
-- colour is the lighter one. Requiring both to hold across 251 consecutive
-- records is a signature nothing else in the cartridge satisfies.

local gfx = require("src.rom.gfx")
local bytes = require("src.util.bytes")

local palettes = {}

palettes.COLORS_PER_RECORD = 4 -- normal light, normal dark, shiny light, shiny dark
palettes.RECORD_SIZE = palettes.COLORS_PER_RECORD * 2
palettes.SPECIES_COUNT = 251

-- The implicit endpoints, as BGR555 words.
local WHITE = 0x7FFF
local BLACK = 0x0000

--- Sum of a BGR555 word's channels, used only to compare two colours.
local function brightness(word)
  return bytes.band(word, 0x1F)
    + bytes.band(bytes.rshift(word, 5), 0x1F)
    + bytes.band(bytes.rshift(word, 10), 0x1F)
end

--- Is the record at `offset` shaped like a palette entry?
--
-- Only the structural rule: four 15-bit words, not all black. An earlier
-- version also required the first colour of each pair to be the brighter one,
-- which sounds like it must be true of a light/dark pair and is not — enforcing
-- it caps the longest run in the cartridge at 98 records.
local function record_plausible(data, offset)
  if offset + palettes.RECORD_SIZE > #data then
    return false
  end

  local any_set = false
  for i = 0, palettes.COLORS_PER_RECORD - 1 do
    local word = bytes.u16le(data, offset + i * 2)
    -- BGR555 uses fifteen bits; the top bit is unused and always clear.
    if bytes.band(word, 0x8000) ~= 0 then
      return false
    end
    if word ~= 0 then
      any_set = true
    end
  end

  -- Rejects the large zero-filled regions that otherwise satisfy everything.
  return any_set
end

--- Species whose colour is not in dispute, used to tell the real table from
-- any other run of colour-shaped words. Same approach as the data tables:
-- structure narrows it down, known content decides.
local SPOT_CHECKS = {
  [1] = "g",       -- Bulbasaur
  [4] = "r",       -- Charmander
  [25] = "yellow", -- Pikachu
}

local function read_record(data, offset)
  return {
    normal = { bytes.u16le(data, offset), bytes.u16le(data, offset + 2) },
    shiny = { bytes.u16le(data, offset + 4), bytes.u16le(data, offset + 6) },
  }
end

--- Locate the sprite palette table.
-- @return { offset = n, records = { { normal = {c1, c2}, shiny = {c1, c2} } } }
--         or nil plus a reason
function palettes.locate(rom)
  local data = rom.data
  local stride = palettes.RECORD_SIZE
  local wanted = palettes.SPECIES_COUNT
  local limit = rom.size - stride

  -- Run lengths computed backwards, so each offset costs one record test rather
  -- than re-walking the whole table from every starting point.
  local run = {}
  for offset = limit, 0, -1 do
    if record_plausible(data, offset) then
      run[offset] = (run[offset + stride] or 0) + 1
    else
      run[offset] = 0
    end
  end

  local candidates = 0
  for offset = 0, limit do
    if run[offset] >= wanted then
      candidates = candidates + 1

      local ok = true
      for species, want in pairs(SPOT_CHECKS) do
        local record = read_record(data, offset + (species - 1) * stride)
        if palettes.dominant(record.normal[1]) ~= want then
          ok = false
          break
        end
      end

      if ok then
        local records = {}
        for species = 1, wanted do
          records[species] = read_record(data, offset + (species - 1) * stride)
        end
        return { offset = offset, records = records, candidates = candidates }
      end
    end
  end

  return nil, ("%d offsets held %d consecutive colour records but none had the " ..
    "expected hues for Bulbasaur, Charmander and Pikachu")
    :format(candidates, wanted)
end

--- Build a renderable four-colour palette from a stored pair.
-- @param pair  { light_word, dark_word }
-- @return array of 4 {r, g, b} triples in love's 0-1 range
function palettes.to_rgb(pair)
  local result = {}
  local words = { WHITE, pair[1], pair[2], BLACK }
  for i, word in ipairs(words) do
    local r, g, b = gfx.decode_color(word)
    result[i] = { r, g, b }
  end
  return result
end

--- Describe a colour as 5-bit channel values, for logging and tests.
function palettes.channels(word)
  return bytes.band(word, 0x1F),
         bytes.band(bytes.rshift(word, 5), 0x1F),
         bytes.band(bytes.rshift(word, 10), 0x1F)
end

--- Which channel dominates a colour: "r", "g", "b", or "grey" when no channel
-- leads by a clear margin. Used to check a palette is the hue it should be
-- without asserting exact values.
function palettes.dominant(word)
  local r, g, b = palettes.channels(word)
  local top = math.max(r, g, b)
  local bottom = math.min(r, g, b)

  if top - bottom < 4 then
    return "grey"
  end

  -- Red and green close together with blue well behind reads as yellow, which
  -- is what Pikachu needs. Checked before the single-channel cases because it
  -- is a property of two channels at once.
  if math.abs(r - g) < 6 and b < math.min(r, g) - 4 then
    return "yellow"
  end

  -- Otherwise the leading channel names the hue. Pink (31,14,21) is
  -- red-dominant even though blue outranks green, so the comparison must be
  -- against the maximum alone and not between the two trailing channels.
  if r == top then
    return "r"
  elseif g == top then
    return "g"
  end
  return "b"
end

return palettes
