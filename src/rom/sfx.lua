-- The sound effect table.
--
-- Sound effects are channel data like music, and their table sits behind the
-- songs. It was invisible for a long time for a reason worth keeping: the song
-- locator insists a header's first entry is channel 0, which every song does
-- and no sound effect does. Gen 2 drives the hardware's four channels from two
-- sets of slots and effects use the second set, so an effect opens on channel 4
-- or later and every one was being rejected on a condition that was only ever a
-- property of music.
--
-- ## Finding it without asking the scripts
--
-- The table is located structurally — the first long run of pointers to headers
-- that open on the second channel set — so that what the scripts do with it
-- stays independent evidence rather than being the thing that defined it.
--
-- And the scripts agree emphatically. Scoring **every** offset in the cartridge
-- by how many of the 32 distinct ids `playsound` actually asks for land on a
-- real header, exactly one offset in two megabytes explains all 32, and it is
-- this one. The same scan run against `playmusic` puts the song table top,
-- which is the control: its answer was known independently, so a scan that
-- missed it would have been telling us nothing about anything.
--
-- ## Cries are not this
--
-- The same scan finds **no** offset that explains all 47 ids `cry` asks for —
-- the best manages 36, with several offsets tied there, which is what noise
-- looks like. A cry takes a species number and Gen 2 gives each species a base
-- cry plus a pitch and a length, so `cry` indexes something with that shape
-- rather than a table of headers. That table has not been found, and `cry` is
-- left unimplemented rather than pointed at this one.

local sfx = {}

sfx.RECORD_SIZE = 3

-- A sound effect uses the second set of channel slots. This is the whole
-- difference between an effect's header and a song's.
sfx.FIRST_CHANNEL = 4

-- Long enough that a run is a table rather than a coincidence. The real one is
-- far longer; this only has to exclude noise.
sfx.MINIMUM_RUN = 20

-- How many slots in a row may fail before the table is over.
--
-- Unused slots inside this table come in much longer runs than the song
-- table's, so the song table's tolerance of four cut it off at 78 entries when
-- the scripts plainly use id 202. Measured, the separation is still wide and
-- unambiguous: the longest gap *inside* the table is 17 slots, and the run of
-- failures after the last real entry is 31 and does not stop. Anything between
-- those two works; this sits in the middle of them.
sfx.MISS_LIMIT = 24

--- A sound header, opening on any channel of either set.
-- @return channel count, opening channel
function sfx.header_at(rom, bank, addr)
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
  local channel = first % 16
  if channel > 7 then
    return nil
  end

  local channels = {}
  for index = 0, count - 1 do
    local entry = base + index * sfx.RECORD_SIZE
    local marker = rom:u8(entry)
    if marker % 16 ~= channel + index then
      return nil
    end
    -- Only the first entry carries the count.
    if index > 0 and marker >= 64 then
      return nil
    end
    local pointer = rom:u16le(entry + 1)
    if pointer < 0x4000 or pointer > 0x7FFF then
      return nil
    end
    channels[index + 1] = pointer
  end

  return count, channel, channels
end

--- Locate the sound effect table.
-- @return { offset, count } or nil plus a reason
function sfx.locate(rom)
  local function entry_at(offset)
    if offset + 2 >= rom.size then
      return nil
    end
    return sfx.header_at(rom, rom:u8(offset), rom:u16le(offset + 1))
  end

  -- The first run of pointers to headers that open on the second channel set.
  -- Songs occupy the first set, so a long run of these cannot be music.
  local start, offset = nil, 0
  while offset <= rom.size - sfx.RECORD_SIZE do
    local count, channel = entry_at(offset)
    if count and channel >= sfx.FIRST_CHANNEL then
      local run, cursor = 0, offset
      while cursor <= rom.size - sfx.RECORD_SIZE do
        local next_count, next_channel = entry_at(cursor)
        if not next_count or next_channel < sfx.FIRST_CHANNEL then
          break
        end
        run = run + 1
        cursor = cursor + sfx.RECORD_SIZE
      end
      if run >= sfx.MINIMUM_RUN then
        start = offset
        break
      end
      offset = cursor + sfx.RECORD_SIZE
    else
      offset = offset + 1
    end
  end

  if not start then
    return nil, ("no run of %d pointers to second-set headers")
      :format(sfx.MINIMUM_RUN)
  end

  -- Enumerate from there, keeping the slots that do not decode. Same rule the
  -- song table needed: an effect is named by its index, so dropping an
  -- unreadable one would shift every effect after it.
  local entries, decoded, misses, last = {}, 0, 0, 0
  local index = 0
  while index < 512 do
    local at = start + index * sfx.RECORD_SIZE
    if at + 2 >= rom.size then
      break
    end
    local count, channel, channels = entry_at(at)
    -- A slot that decodes as a *first*-set header is not an effect. Two slots
    -- in this table do, and treating them as real would have put a song header
    -- in the effect table. Whether that was right was not something to reason
    -- about: rejecting them and re-running says at once, because if any effect
    -- the scripts ask for became unreadable the test that every id resolves
    -- would fail. It does not — all 32 still land — so they are unused slots
    -- that happen to decode, and this is the tighter, correct reading.
    if count and channel < sfx.FIRST_CHANNEL then
      count = nil
    end
    if count then
      entries[index + 1] = {
        bank = rom:u8(at),
        addr = rom:u16le(at + 1),
        count = count,
        channel = channel,
        channels = channels,
      }
      decoded = decoded + 1
      last = index + 1
      misses = 0
    else
      entries[index + 1] = { unparsed = true }
      misses = misses + 1
      if misses >= sfx.MISS_LIMIT then
        break
      end
    end
    index = index + 1
  end

  for slot = #entries, last + 1, -1 do
    entries[slot] = nil
  end

  return {
    offset = start,
    count = #entries,
    decoded = decoded,
    entries = entries,
  }
end

return sfx
