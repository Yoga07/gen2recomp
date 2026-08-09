-- Diagnostic: where is the music, and what shape is it?
--
-- A Gen 2 song is a header followed by one command stream per channel. The
-- header is a run of three-byte entries -- a byte holding the channel index,
-- then a near pointer -- and the very first byte also carries how many channels
-- there are, in its top two bits. That packing is specific enough to search
-- for: a first byte of $C0 means "four channels, this is channel 0", and the
-- three entries after it must then say 1, 2 and 3.
--
--   love . --probe-audio <rom> <report>

local Rom = require("src.rom.rom")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

probe.MAX_CHANNELS = 4

--- Does a song header start here?
-- @return channel count and the channel pointers, or nil
function probe.header_at(rom, bank, addr)
  if addr < 0x4000 or addr > 0x7FFF then
    return nil
  end
  local base = bank * 0x4000
  local at = base + (addr - 0x4000)
  if at + 3 * probe.MAX_CHANNELS >= rom.size then
    return nil
  end

  local first = rom:u8(at)
  local count = math.floor(first / 64) + 1
  -- The channel index lives in the low nibble, and the first entry is always
  -- channel zero.
  if first % 16 ~= 0 then
    return nil
  end

  local channels = {}
  for index = 0, count - 1 do
    local entry = at + index * 3
    local marker = rom:u8(entry)
    -- Only the first entry carries the count; the rest are a bare index.
    local channel = marker % 16
    if channel ~= index then
      return nil
    end
    if index > 0 and marker >= 64 then
      return nil
    end
    local pointer = rom:u16le(entry + 1)
    if pointer < 0x4000 or pointer > 0x7FFF then
      return nil
    end
    channels[index + 1] = pointer
  end

  return count, channels
end

function probe.run(rom_path, report_path)
  report = {}

  local rom, err = Rom.load(rom_path)
  if not rom then
    log("FATAL: %s", err)
    local fh = io.open(report_path, "w")
    if fh then fh:write(table.concat(report, "\n") .. "\n") fh:close() end
    return true
  end

  -- Look for a table of three-byte bank-and-address entries whose targets are
  -- song headers. Every song in a bank shares that bank, which is the same
  -- sharpening the standard-script table needed.
  -- The bank is read per entry rather than fixed. Music does not fit in one
  -- bank, and requiring a constant one stopped the run at 10 songs.
  local function run_length(from)
    local count, seen = 0, {}
    while count < 300 do
      local at = from + count * 3
      if at + 2 >= rom.size then break end
      local bank = rom:u8(at)
      if bank * 0x4000 >= rom.size then break end
      local addr = rom:u16le(at + 1)
      if not probe.header_at(rom, bank, addr) then break end
      count = count + 1
      seen[bank * 0x10000 + addr] = true
    end
    local distinct = 0
    for _ in pairs(seen) do distinct = distinct + 1 end
    return count, distinct
  end

  local best = { count = 0 }
  local offset = 0
  while offset <= rom.size - 3 * 8 do
    local count, distinct = run_length(offset)
    if count > best.count then
      best = { count = count, offset = offset, bank = rom:u8(offset),
               distinct = distinct }
    end
    offset = offset + 1
  end

  -- The run reports where a valid stretch starts, not where the table starts.
  -- Walking back is what found the front of the standard-script table.
  if best.offset then
    local start = best.offset
    while start >= 3 do
      local bank = rom:u8(start - 3)
      local addr = rom:u16le(start - 2)
      if bank * 0x4000 >= rom.size or not probe.header_at(rom, bank, addr) then
        break
      end
      start = start - 3
    end
    if start ~= best.offset then
      log("the run starts at 0x%06X but the table reaches back to 0x%06X",
        best.offset, start)
      best.offset = start
      best.count = run_length(start)
    end
  end

  log("longest run of song pointers: %d at 0x%06X in bank $%02X, %d distinct",
    best.count, best.offset or 0, best.bank or 0, best.distinct or 0)

  if best.count < 4 then
    log("\nno music table found with this shape")
    rom:release()
    local fh = io.open(report_path, "w")
    if fh then fh:write(table.concat(report, "\n") .. "\n") fh:close() end
    return true
  end

  -- What the entries look like.
  local by_channels = {}
  -- The header should end exactly where its first channel begins. Where it
  -- does not, the shape is not what it is being read as.
  log("\nheader bytes, and whether the header ends where channel 1 starts:")
  for index = 0, 7 do
    local at = best.offset + index * 3
    local bank = rom:u8(at)
    local addr = rom:u16le(at + 1)
    local count, channels = probe.header_at(rom, bank, addr)
    if count then
      local base = bank * 0x4000 + (addr - 0x4000)
      local bytes = {}
      for i = 0, 3 * count + 2 do
        bytes[#bytes + 1] = ("%02X"):format(rom:u8(base + i))
      end
      local ends_at = addr + 3 * count
      log("  %2d $%02X:$%04X %d ch, header ends $%04X, channel 1 at $%04X %s",
        index, bank, addr, count, ends_at, channels[1],
        ends_at == channels[1] and "" or "  <- MISMATCH")
      log("       %s", table.concat(bytes, " "))
    end
  end

  log("\nthe first two dozen songs:")
  for index = 0, math.min(best.count - 1, 23) do
    local at = best.offset + index * 3
    local bank = rom:u8(at)
    local addr = rom:u16le(at + 1)
    local count, channels = probe.header_at(rom, bank, addr)
    by_channels[count] = (by_channels[count] or 0) + 1
    local parts = {}
    for _, pointer in ipairs(channels or {}) do
      parts[#parts + 1] = ("$%04X"):format(pointer)
    end
    log("  %3d $%02X:$%04X  %d channels: %s", index, bank, addr, count,
      table.concat(parts, " "))
  end

  for index = 24, best.count - 1 do
    local at = best.offset + index * 3
    local count = probe.header_at(rom, rom:u8(at), rom:u16le(at + 1))
    by_channels[count] = (by_channels[count] or 0) + 1
  end

  local shape = {}
  for count, times in pairs(by_channels) do
    shape[#shape + 1] = ("%d channels x%d"):format(count, times)
  end
  table.sort(shape)
  log("\nacross all %d songs: %s", best.count, table.concat(shape, ", "))

  -- What is in a channel stream. The command language is unknown, so this just
  -- reports the byte distribution to see whether it looks like a language at
  -- all rather than like compressed data.
  local first_song = probe.header_at(rom, rom:u8(best.offset),
    rom:u16le(best.offset + 1))
  local _, channels = probe.header_at(rom, rom:u8(best.offset),
    rom:u16le(best.offset + 1))
  if channels and channels[1] then
    local bank = rom:u8(best.offset)
    local at = bank * 0x4000 + (channels[1] - 0x4000)
    local bytes = {}
    for i = 0, 47 do
      bytes[#bytes + 1] = ("%02X"):format(rom:u8(at + i))
    end
    log("\nthe first channel of song 0 begins:\n  %s",
      table.concat(bytes, " "))
  end

  rom:release()

  local fh = io.open(report_path, "w")
  if fh then
    fh:write(table.concat(report, "\n") .. "\n")
    fh:close()
  end
  return true
end

return probe
