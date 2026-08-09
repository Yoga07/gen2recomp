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
-- This locates and reads the table. It does not play anything: sound would need
-- the channel command language, which is a bytecode of its own, and a Game Boy
-- sound chip to feed it to. Neither exists here yet.

local music = {}

music.MAX_CHANNELS = 4
music.RECORD_SIZE = 3
music.MINIMUM = 24
music.MAX_SONGS = 300

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
-- @return { offset, count, songs = { header, ... }, exact } or nil plus why
function music.locate(rom)
  local function run_length(from)
    local count = 0
    while count < music.MAX_SONGS do
      local at = from + count * music.RECORD_SIZE
      if at + 2 >= rom.size then
        break
      end
      if not music.header_at(rom, rom:u8(at), rom:u16le(at + 1)) then
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
  while start >= music.RECORD_SIZE do
    local bank = rom:u8(start - music.RECORD_SIZE)
    local addr = rom:u16le(start - music.RECORD_SIZE + 1)
    if not music.header_at(rom, bank, addr) then
      break
    end
    start = start - music.RECORD_SIZE
  end

  local count = run_length(start)
  local songs, exact = {}, 0
  for index = 1, count do
    local at = start + (index - 1) * music.RECORD_SIZE
    local header = music.header_at(rom, rom:u8(at), rom:u16le(at + 1))
    songs[index] = header
    if header.exact then
      exact = exact + 1
    end
  end

  return { offset = start, count = count, songs = songs, exact = exact }
end

return music
