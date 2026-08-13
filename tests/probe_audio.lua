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

  -- How far does the table really go?
  --
  -- The locator stops at the first entry that does not validate, which is the
  -- mistake the trainer class table made and the map headers made before it.
  -- The scripts say it is a mistake here too: they ask for music ids 78, 93,
  -- 96 and 97, and the run stops at 59. Entries are addressed by position, so
  -- an omitted one does not merely lose a song -- it shifts every song after it
  -- and silently rewires which music plays where.
  --
  -- This walks straight on past the end, tolerating failures, and reports what
  -- is actually there.
  log("\n== walking past the end of the accepted run ==")
  local music = require("src.rom.music")
  local located = music.locate(rom)
  if located then
    log("  the locator accepts %d entries from 0x%06X", located.count,
      located.offset)

    local misses, run_of_misses, worst_gap = 0, 0, 0
    local last_good = -1
    for index = 0, 149 do
      local at = located.offset + index * 3
      if at + 2 >= rom.size then
        break
      end
      local bank = rom:u8(at)
      local addr = rom:u16le(at + 1)
      local header = bank * 0x4000 < rom.size
        and music.header_at(rom, bank, addr) or nil

      if header then
        run_of_misses = 0
        last_good = index
      else
        misses = misses + 1
        run_of_misses = run_of_misses + 1
        worst_gap = math.max(worst_gap, run_of_misses)
      end

      -- Report the region around the break and everything past it.
      if index >= located.count - 3 and index <= located.count + 45 then
        local raw = {}
        for i = 0, 2 do
          raw[#raw + 1] = ("%02X"):format(rom:u8(at + i))
        end
        log("  %3d  %s  $%02X:$%04X  %s", index, table.concat(raw, " "),
          bank, addr,
          header and ("%d channels, %s"):format(header.count,
            header.exact and "closes exactly" or "one byte of slack")
            or "does not decode")
      end

      if run_of_misses >= 8 then
        break
      end
    end

    -- Are the entries past the break the same kind of thing?
    --
    -- They decode, but so can coincidence, and the banks change character at
    -- index 92 -- $3A/$3B/$3D up to there, then $33, $07 and a run of $5E. So
    -- they are checked against properties measured from the *original* 59,
    -- which the new ones took no part in establishing: a channel opens with one
    -- of only six bytes, most of its bytes are below $D0, and it ends on $FF.
    local function channel_stats(from, to)
      local openers, bytes, low, ends_ff, channels = {}, 0, 0, 0, 0
      for index = from, to do
        local at = located.offset + index * 3
        if at + 2 < rom.size then
          local bank = rom:u8(at)
          if bank * 0x4000 < rom.size then
            local header = music.header_at(rom, bank, rom:u16le(at + 1))
            if header then
              for slot, pointer in ipairs(header.channels) do
                channels = channels + 1
                local base = bank * 0x4000 + (pointer - 0x4000)
                openers[rom:u8(base)] = (openers[rom:u8(base)] or 0) + 1
                -- Up to the next channel, or a bounded window for the last.
                local finish = header.channels[slot + 1]
                  and (bank * 0x4000 + (header.channels[slot + 1] - 0x4000))
                  or math.min(base + 256, rom.size - 1)
                for offset_at = base, finish - 1 do
                  local value = rom:u8(offset_at)
                  bytes = bytes + 1
                  if value < 0xD0 then low = low + 1 end
                end
                if finish > base and rom:u8(finish - 1) == 0xFF then
                  ends_ff = ends_ff + 1
                end
              end
            end
          end
        end
      end
      return openers, bytes, low, ends_ff, channels
    end

    local old_openers, old_bytes, old_low, old_ff, old_ch =
      channel_stats(0, located.count - 1)
    local new_openers, new_bytes, new_low, new_ff, new_ch =
      channel_stats(located.count, last_good)

    local known = {}
    for byte in pairs(old_openers) do
      known[byte] = true
    end
    local recognised, strange = 0, {}
    for byte, times in pairs(new_openers) do
      if known[byte] then
        recognised = recognised + times
      else
        strange[#strange + 1] = ("$%02X x%d"):format(byte, times)
      end
    end

    local function opener_list(set)
      local out = {}
      for byte in pairs(set) do
        out[#out + 1] = ("$%02X"):format(byte)
      end
      table.sort(out)
      return table.concat(out, " ")
    end

    log("\n  the first %d entries: %d channels, opening bytes %s",
      located.count, old_ch, opener_list(old_openers))
    log("    %d%% of bytes below $D0, %d of %d channels end on $FF",
      math.floor(old_low / math.max(old_bytes, 1) * 100), old_ff, old_ch)
    log("  the entries past the break: %d channels, opening bytes %s",
      new_ch, opener_list(new_openers))
    log("    %d%% of bytes below $D0, %d of %d channels end on $FF",
      math.floor(new_low / math.max(new_bytes, 1) * 100), new_ff, new_ch)
    log("    %d of %d openers are ones the first %d already used%s",
      recognised, new_ch, located.count,
      #strange > 0 and (", new: " .. table.concat(strange, " ")) or "")

    log("\n  last entry that decodes: %d", last_good)
    log("  entries that do not decode before it: %d", misses - run_of_misses)
    log("  longest run of consecutive failures: %d", worst_gap)
    log("  the scripts ask for ids up to 97, so the table needs at least 98")
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
