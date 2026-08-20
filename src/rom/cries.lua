-- Which cry each species makes.
--
-- `cry` takes a species number, and scoring every offset in the cartridge
-- against the ids it asks for found nothing — the best managed 36 of 47 with
-- several offsets tied, which is noise rather than a near miss. So a cry is not
-- a direct index into a table of sounds. It is two structures: a small block of
-- **base cries**, and a per-species table naming one of them plus a pitch and a
-- length, which is how 251 species are given distinct voices out of 68 sounds.
--
-- ## The block, and a validator that was wrong twice
--
-- The base cries sit between the song table and the effect table, and they were
-- invisible for the same reason the effect table was: an over-tight condition
-- that is true of music and not of everything.
--
-- The first time it was the *opening* channel — songs always open on channel 0
-- and effects never do. The second time it was worse, because it looked
-- harmless: `header_at` requires a header's channels to be **consecutive**,
-- channel n then n+1 then n+2. The first cry in Crystal reads
--
--   84 77 78 | 05 86 78 | 07 95 78
--
-- which is three channels opening on 4, then 5, then **7**. It skips the wave
-- channel. Nothing says a sound must use an unbroken run of channels, and
-- requiring it rejected every cry in the game.
--
-- There is a third, duller trap in the same place. The thing between the two
-- tables is 13 bytes long — an inline header and a terminator — and 13 is not a
-- multiple of three, so a walk stepping three bytes at a time from the song
-- table's end steps straight over the start of the cry block and never lands on
-- it. The scan starts from every offset instead.
--
-- ## The per-species table
--
-- 251 records of six bytes: a base cry, a pitch, and a length, each a
-- little-endian word. Pitch is **signed** — it runs to 65529, which is -7.
--
--   BULBASAUR   cry 15  pitch 128  length 129
--   IVYSAUR     cry 15  pitch  32  length 256
--   VENUSAUR    cry 15  pitch   0  length 320
--
-- The pitch falls and the length grows as a family evolves, which is what makes
-- a Venusaur sound like a bigger Bulbasaur.
--
-- ## What accepts it
--
-- Two things, and the second is the one worth having.
--
-- "251 records whose first word is a valid cry index" is far too weak on its
-- own — tens of thousands of offsets satisfy it, because whole regions of a
-- cartridge are small numbers. What is not weak is that the table must use
-- **every one of the base cries and no others**: 68 distinct values, 0 to 67,
-- none out of range. The block was measured between two unrelated tables
-- without any reference to this one, so the two agreeing is two searches
-- converging rather than one confirming itself.
--
-- And separately, as evidence rather than as a condition, evolution families
-- share a base cry — 59% of them, against a floor of 1% for that table's own
-- distribution. The evolution data comes from a different bank by a different
-- search again. That check lives in the test suite; the locator does not use
-- it, so it stays independent.

local cries = {}

cries.SPECIES_COUNT = 251
cries.RECORD_SIZE = 6

--- A sound header whose channel indices rise but need not be consecutive.
-- @return channel count, opening channel, channel addresses
function cries.header_at(rom, bank, addr)
  if addr < 0x4000 or addr > 0x7FFF then
    return nil
  end
  if bank < 1 or bank * 0x4000 >= rom.size then
    return nil
  end
  local base = bank * 0x4000 + (addr - 0x4000)
  if base + 12 >= rom.size then
    return nil
  end

  local first = rom:u8(base)
  local count = math.floor(first / 64) + 1
  local opening = first % 16
  if opening > 7 then
    return nil
  end

  local previous, channels = -1, {}
  for index = 0, count - 1 do
    local entry = base + index * 3
    local marker = rom:u8(entry)
    local channel = marker % 16
    -- Rising rather than consecutive. This is the whole difference.
    if channel > 7 or channel <= previous then
      return nil
    end
    previous = channel
    if index > 0 and marker >= 64 then
      return nil
    end
    local pointer = rom:u16le(entry + 1)
    if pointer < 0x4000 or pointer > 0x7FFF then
      return nil
    end
    channels[index + 1] = { channel = channel, addr = pointer }
  end

  return count, opening, channels
end

--- The block of base cries, bracketed by the song and effect tables.
-- @return { offset, count, entries }
function cries.locate_block(rom, music_result, sfx_result)
  local from = music_result.offset + music_result.count * 3
  local to = sfx_result.offset

  -- Started from every offset, not from a three-byte grid: what sits between
  -- the two tables is 13 bytes long and would push a grid walk out of phase.
  local best = { count = 0 }
  for start = from, to - 3 do
    local run, at = 0, start
    while at <= to - 3 do
      if not cries.header_at(rom, rom:u8(at), rom:u16le(at + 1)) then
        break
      end
      run = run + 1
      at = at + 3
    end
    if run > best.count then
      best = { count = run, offset = start }
    end
  end

  if best.count < 8 then
    return nil, ("only %d base cries between the songs and the effects")
      :format(best.count)
  end

  local entries = {}
  for index = 0, best.count - 1 do
    local at = best.offset + index * 3
    local count, opening, channels =
      cries.header_at(rom, rom:u8(at), rom:u16le(at + 1))
    entries[index + 1] = {
      bank = rom:u8(at),
      addr = rom:u16le(at + 1),
      count = count,
      channel = opening,
      channels = channels,
    }
  end

  return { offset = best.offset, count = best.count, entries = entries }
end

--- Read a signed little-endian word.
local function s16(rom, offset)
  local value = rom:u16le(offset)
  return value >= 0x8000 and value - 0x10000 or value
end

--- Locate the per-species table.
-- @return { offset, block, records = { { cry, pitch, length } } } or nil, why
function cries.locate(rom, music_result, sfx_result)
  local block, why = cries.locate_block(rom, music_result, sfx_result)
  if not block then
    return nil, why
  end

  local accepted = {}
  local limit = rom.size - cries.RECORD_SIZE * cries.SPECIES_COUNT - 1
  for offset = 0, limit do
    local ok, seen, distinct = true, {}, 0
    for index = 0, cries.SPECIES_COUNT - 1 do
      local cry = rom:u16le(offset + index * cries.RECORD_SIZE)
      if cry >= block.count then
        ok = false
        break
      end
      if not seen[cry] then
        seen[cry] = true
        distinct = distinct + 1
      end
    end
    -- Every base cry used and none invented. A region of small numbers passes
    -- the first test in its thousands; passing this one as well is what makes
    -- the answer an answer.
    if ok and distinct == block.count then
      accepted[#accepted + 1] = offset
    end
  end

  if #accepted == 0 then
    return nil, ("no run of %d records names every one of the %d base cries")
      :format(cries.SPECIES_COUNT, block.count)
  end

  -- The test cannot tell the table from itself shifted a whole record along.
  --
  -- Sliding the window forward by six bytes drops species 1 and picks up
  -- whatever follows the table, and because many species share a cry the
  -- remaining 250 still name all 68. Five offsets pass in Crystal and they are
  -- 0x0F2787 and the next four multiples of six after it — one table, counted
  -- five times, not five candidates.
  --
  -- So the accepted offsets are grouped into runs spaced a record apart and the
  -- *start* of a run is the table, the same way the standard-script and music
  -- tables had to be walked back to their real beginnings. Two separate runs
  -- would be genuine ambiguity and are still refused.
  local runs = {}
  for _, offset in ipairs(accepted) do
    local previous = runs[#runs]
    if previous and offset == previous.last + cries.RECORD_SIZE then
      previous.last = offset
    else
      runs[#runs + 1] = { first = offset, last = offset }
    end
  end

  if #runs > 1 then
    local places = {}
    for index = 1, math.min(#runs, 6) do
      places[#places + 1] = ("0x%06X"):format(runs[index].first)
    end
    return nil, ("the cry table validated at %d separate places (%s); " ..
      "refusing to guess"):format(#runs, table.concat(places, ", "))
  end

  local offset = runs[1].first
  local records = {}
  for species = 1, cries.SPECIES_COUNT do
    local at = offset + (species - 1) * cries.RECORD_SIZE
    records[species] = {
      cry = rom:u16le(at),
      -- Signed: it runs to -7 in this cartridge, and reading it unsigned would
      -- send those species several octaves in the wrong direction.
      pitch = s16(rom, at + 2),
      length = rom:u16le(at + 4),
    }
  end

  return { offset = offset, block = block, records = records }
end

return cries
