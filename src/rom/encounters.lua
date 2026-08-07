-- Wild encounter tables.
--
-- Grass entries carry a map id, three encounter rates for morning, day and
-- night, and then seven level-and-species pairs for each of those three times
-- of day. Water entries are the same idea with one rate and three pairs.
--
--   grass  2 map + 3 rates + 3 x 7 x 2 = 47 bytes
--   water  2 map + 1 rate  +     3 x 2 =  9 bytes
--
-- Both tables end with $FF where a map group would be.
--
-- The structure is documented in pokecrystal; where the tables *are* is found
-- here by search, so the same code works on Gold and Silver. The signature is
-- strong: an entry constrains 21 species to the 251 that exist and 21 levels to
-- 1-100, which arbitrary bytes do not manage.

local encounters = {}

encounters.GRASS_TIMES = 3
encounters.GRASS_SLOTS = 7
encounters.WATER_SLOTS = 3

encounters.GRASS_ENTRY = 2 + 3 + encounters.GRASS_TIMES * encounters.GRASS_SLOTS * 2
encounters.WATER_ENTRY = 2 + 1 + encounters.WATER_SLOTS * 2

encounters.TERMINATOR = 0xFF
encounters.SPECIES_COUNT = 251
encounters.MAX_LEVEL = 100
encounters.MAX_GROUP = 26

encounters.times = { "morn", "day", "nite" }

local function valid_pair(rom, offset)
  local level = rom:u8(offset)
  local species = rom:u8(offset + 1)
  return level >= 1 and level <= encounters.MAX_LEVEL
     and species >= 1 and species <= encounters.SPECIES_COUNT
end

local function valid_header(rom, offset)
  local group = rom:u8(offset)
  local map = rom:u8(offset + 1)
  return group >= 1 and group <= encounters.MAX_GROUP and map >= 1
end

--- Is there a well-formed entry of `slots` pairs per time block at `offset`?
local function valid_entry(rom, offset, times, slots, rate_bytes)
  local size = 2 + rate_bytes + times * slots * 2
  if offset + size > rom.size then
    return false
  end
  if not valid_header(rom, offset) then
    return false
  end

  -- Rates are a fraction of 255 and are never zero for a map that has
  -- encounters at all.
  for i = 0, rate_bytes - 1 do
    if rom:u8(offset + 2 + i) == 0 then
      return false
    end
  end

  local at = offset + 2 + rate_bytes
  for i = 0, times * slots - 1 do
    if not valid_pair(rom, at + i * 2) then
      return false
    end
  end
  return true
end

--- Decode one grass entry.
local function decode_grass(rom, offset)
  local entry = {
    offset = offset,
    group = rom:u8(offset),
    map = rom:u8(offset + 1),
    rates = {},
    slots = {},
  }

  for i = 1, encounters.GRASS_TIMES do
    entry.rates[encounters.times[i]] = rom:u8(offset + 1 + i)
  end

  local at = offset + 5
  for time = 1, encounters.GRASS_TIMES do
    local list = {}
    for slot = 1, encounters.GRASS_SLOTS do
      local base = at + ((time - 1) * encounters.GRASS_SLOTS + (slot - 1)) * 2
      list[slot] = { level = rom:u8(base), species = rom:u8(base + 1) }
    end
    entry.slots[encounters.times[time]] = list
  end

  return entry
end

local function decode_water(rom, offset)
  local entry = {
    offset = offset,
    group = rom:u8(offset),
    map = rom:u8(offset + 1),
    rate = rom:u8(offset + 2),
    slots = {},
  }
  for slot = 1, encounters.WATER_SLOTS do
    local base = offset + 3 + (slot - 1) * 2
    entry.slots[slot] = { level = rom:u8(base), species = rom:u8(base + 1) }
  end
  return entry
end

--- Find every run of encounter entries of a given shape.
--
-- Crystal keeps Johto and Kanto in separate tables, so runs are returned as a
-- list rather than assuming there is only one.
-- @return list of { offset, count, entries }
local function find_runs(rom, times, slots, rate_bytes, decode, minimum)
  local size = 2 + rate_bytes + times * slots * 2
  local runs = {}

  local offset = 0
  while offset <= rom.size - size do
    if valid_entry(rom, offset, times, slots, rate_bytes) then
      local start = offset
      local entries = {}
      while offset <= rom.size - size
        and valid_entry(rom, offset, times, slots, rate_bytes) do
        entries[#entries + 1] = decode(rom, offset)
        offset = offset + size
      end

      -- A real table is closed by $FF where the next map group would be.
      local terminated = offset < rom.size
        and rom:u8(offset) == encounters.TERMINATOR

      if #entries >= minimum and terminated then
        runs[#runs + 1] = { offset = start, count = #entries, entries = entries }
      end
    else
      offset = offset + 1
    end
  end

  return runs
end

--- Locate the grass encounter tables.
function encounters.locate_grass(rom)
  local runs = find_runs(rom, encounters.GRASS_TIMES, encounters.GRASS_SLOTS,
    3, decode_grass, 8)
  if #runs == 0 then
    return nil, "no run of grass encounter entries found"
  end
  return runs
end

--- Locate the water encounter tables.
--
-- Water entries are only nine bytes and constrain far less than grass ones, so
-- a longer run is demanded before believing it.
function encounters.locate_water(rom)
  local runs = find_runs(rom, 1, encounters.WATER_SLOTS, 1, decode_water, 12)
  if #runs == 0 then
    return nil, "no run of water encounter entries found"
  end
  return runs
end

return encounters
