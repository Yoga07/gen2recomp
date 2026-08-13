-- The music table.
--
-- A song is a header followed by one command stream per channel. The header is
-- a run of three-byte entries -- a channel index, then a near pointer -- and
-- the first byte also carries how many channels there are, in its top two bits.
-- $C0 means "four channels, this is channel 0", and the entries after it must
-- then read 1, 2 and 3.
--
-- What confirms a header rather than merely allowing it is that **the header
-- ends exactly where its first channel begins**. The entries are contiguous
-- with the data they point at, so the arithmetic has to close. Fifty of the
-- fifty-nine songs satisfy that exactly; the rest carry one extra byte between
-- the header and the data, and are accepted but flagged rather than quietly
-- rounded off.
--
-- ## The table is longer than the first run of it
--
-- This used to stop at the first entry that did not decode, and reported 59
-- songs. That is the mistake the trainer class table made and the map headers
-- made before it, and the game's own scripts said so: `playmusic` asks for
-- music **78, 93, 96 and 97**, all of them past the end of a 59-entry table.
--
-- Walking straight on past the break finds the table continues to index 102,
-- with only **three** slots in between that do not decode — 59, 78 and 91 —
-- each an isolated single miss. Index 103 names bank `$C0`, which this
-- cartridge does not have, and nothing decodes for a long way after it. So the
-- table is **103 slots**, not 59.
--
-- The entries past the break were checked before being believed, against
-- properties measured from the original 59 that the new ones took no part in
-- establishing: **147 of their 149 channels open with one of the same handful
-- of bytes**, and 73% of their bytes fall below `$D0` against the same 73%
-- before the break. Same data, truncated table.
--
-- Slots that do not decode are kept as placeholders, because **entries are
-- addressed by position**: `playmusic` names a song by index, so dropping one
-- would not merely lose a song, it would shift every song after it and
-- silently rewire which music plays where. The same rule the map headers
-- needed, for the same reason.
--
-- This locates and reads the table. It does not play anything: sound would need
-- the channel command language, which is a bytecode of its own, and a Game Boy
-- sound chip to feed it to. Neither exists here yet.

local music = {}

music.MAX_CHANNELS = 4
music.RECORD_SIZE = 3
music.MINIMUM = 24
music.MAX_SONGS = 300

-- How many slots in a row may fail before the table is over. The measured
-- separation is wide: every gap inside the table is a single slot, and the run
-- of failures after the last entry is at least eight.
music.MISS_LIMIT = 4

--- Read a song header.
-- @return { channels = { addr, ... }, count, exact } or nil
function music.header_at(rom, bank, addr)
  if addr < 0x4000 or addr > 0x7FFF then
    return nil
  end
  if bank < 0 or bank * 0x4000 >= rom.size then
    return nil
  end

  local base = bank * 0x4000 + (addr - 0x4000)
  if base + music.RECORD_SIZE * music.MAX_CHANNELS >= rom.size then
    return nil
  end

  local first = rom:u8(base)
  local count = math.floor(first / 64) + 1
  -- The first entry is always channel zero, so the low nibble must be clear.
  if first % 16 ~= 0 then
    return nil
  end

  local channels = {}
  for index = 0, count - 1 do
    local entry = base + index * music.RECORD_SIZE
    local marker = rom:u8(entry)
    if marker % 16 ~= index then
      return nil
    end
    -- Only the first entry carries the count in its top bits.
    if index > 0 and marker >= 64 then
      return nil
    end
    local pointer = rom:u16le(entry + 1)
    if pointer < 0x4000 or pointer > 0x7FFF then
      return nil
    end
    channels[index + 1] = pointer
  end

  -- Channels are stored in order, so their pointers should climb.
  for index = 2, count do
    if channels[index] < channels[index - 1] then
      return nil
    end
  end

  local ends_at = addr + count * music.RECORD_SIZE
  return {
    count = count,
    channels = channels,
    bank = bank,
    addr = addr,
    -- True when the header runs straight into its own first channel.
    exact = ends_at == channels[1],
    slack = channels[1] - ends_at,
  }
end

--- Locate the music table.
--
-- Two steps, and conflating them is what truncated this table at 59. A run of
-- consecutive valid headers finds *where the table is*; it does not say where
-- the table ends, because a table may contain a slot that does not decode.
-- Enumeration fills the region afterwards, keeping the awkward slots as
-- placeholders so nothing shifts.
-- @return { offset, count, decoded, songs = { header|placeholder, ... }, exact }
--         or nil plus why
function music.locate(rom)
  local function decode_at(offset)
    if offset + 2 >= rom.size then
      return nil
    end
    return music.header_at(rom, rom:u8(offset), rom:u16le(offset + 1))
  end

  local function run_length(from)
    local count = 0
    while count < music.MAX_SONGS do
      local at = from + count * music.RECORD_SIZE
      if at + 2 >= rom.size then
        break
      end
      if not decode_at(at) then
        break
      end
      count = count + 1
    end
    return count
  end

  local best = { count = 0 }
  local offset = 0
  while offset <= rom.size - music.RECORD_SIZE * music.MINIMUM do
    local count = run_length(offset)
    if count > best.count then
      best = { count = count, offset = offset }
    end
    offset = offset + 1
  end

  if best.count < music.MINIMUM then
    return nil, ("the longest run of song headers was %d"):format(best.count)
  end

  -- A run reports where a valid stretch starts, not where the table starts.
  local start = best.offset
  while start >= music.RECORD_SIZE
    and decode_at(start - music.RECORD_SIZE) do
    start = start - music.RECORD_SIZE
  end

  -- Now fill the region. A slot that does not decode is kept rather than
  -- ending the walk, because the next one usually does and the index of
  -- everything after it has to stay where it is.
  local songs, exact, decoded = {}, 0, 0
  local misses, last_decoded, index = 0, 0, 0
  while index < music.MAX_SONGS do
    local at = start + index * music.RECORD_SIZE
    if at + 2 >= rom.size then
      break
    end

    local header = decode_at(at)
    if header then
      songs[index + 1] = header
      decoded = decoded + 1
      last_decoded = index + 1
      misses = 0
      if header.exact then
        exact = exact + 1
      end
    else
      songs[index + 1] = {
        unparsed = true,
        bank = rom:u8(at),
        addr = rom:u16le(at + 1),
      }
      misses = misses + 1
      if misses >= music.MISS_LIMIT then
        break
      end
    end
    index = index + 1
  end

  -- The table ends on its last real entry, not on the placeholders that
  -- followed it while the walk was deciding it had finished.
  for slot = #songs, last_decoded + 1, -1 do
    songs[slot] = nil
  end

  if #songs < music.MINIMUM then
    return nil, ("only %d song headers survive enumeration"):format(#songs)
  end

  return {
    offset = start,
    count = #songs,
    decoded = decoded,
    songs = songs,
    exact = exact,
  }
end

return music
