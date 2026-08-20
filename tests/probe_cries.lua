-- Diagnostic: which cry does each species make?
--
-- `cry` takes a species number, and scoring every offset in the cartridge
-- against the ids it asks for found nothing — the best managed 36 of 47 with
-- several offsets tied, which is noise. So a cry is not a direct index into a
-- table of headers. Gen 2 gives each species a *base* cry plus a pitch and a
-- length, which means two structures: a small block of base cries, and a
-- 251-entry table pointing into it.
--
-- The block is already in sight. Between the song table and the effect table
-- sit pointers into one bank whose addresses climb by exactly nine — three
-- channel entries each, so headers stored back to back. This measures that
-- block rather than assuming it, then looks for the per-species table.
--
-- ## What makes the answer checkable
--
-- A run of 251 small bytes is not, on its own, worth much. What is worth
-- something is that **evolution families share a base cry**: Bulbasaur,
-- Ivysaur and Venusaur are the same sound at different pitches. The evolution
-- data was extracted by a separate search from a different bank, so a candidate
-- table that makes evolutions agree is being confirmed by something that had no
-- way to know about it.
--
--   love . --probe-cries <rom> <report>

local Rom = require("src.rom.rom")
local music = require("src.rom.music")
local sfx = require("src.rom.sfx")
local locate = require("src.rom.locate")
local learnsets = require("src.rom.learnsets")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

local function write(path)
  local fh = io.open(path, "w")
  if fh then
    fh:write(table.concat(report, "\n") .. "\n")
    fh:close()
  end
end

probe.SPECIES = 251

function probe.run(rom_path, report_path)
  report = {}

  local rom, err = Rom.load(rom_path)
  if not rom then
    log("FATAL: %s", err)
    write(report_path)
    return true
  end

  local songs = music.locate(rom)
  local effects = sfx.locate(rom)
  if not songs or not effects then
    log("FATAL: need both the song and effect tables to bracket the cries")
    rom:release()
    write(report_path)
    return true
  end

  local from = songs.offset + songs.count * 3
  local to = effects.offset
  log("== between the songs (end 0x%06X) and the effects (0x%06X) ==", from, to)
  log("  %d bytes, room for %d three-byte entries", to - from,
    math.floor((to - from) / 3))

  -- A sound header whose channels *rise* rather than run consecutively.
  --
  -- This is the second time that condition has been too tight. `header_at`
  -- demands channel n, then n+1, then n+2, which is true of every song and of
  -- most effects — and false of a cry. The first cry in this cartridge reads
  --
  --   84 77 78 | 05 86 78 | 07 95 78
  --
  -- which is three channels opening on 4, and then 5, and then **7**. It skips
  -- the wave channel. Nothing says a sound has to use an unbroken run of them,
  -- and requiring it rejected every cry in the game.
  local function rising_header(bank, addr)
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
    local n = math.floor(first / 64) + 1
    local previous = -1
    local opening = first % 16
    if opening > 7 then
      return nil
    end
    for index = 0, n - 1 do
      local entry = base + index * 3
      local marker = rom:u8(entry)
      local channel = marker % 16
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
    end
    return n, opening
  end

  -- The longest run of three-byte entries pointing at headers, started from
  -- *every* offset rather than from a three-byte grid anchored at the song
  -- table's end. The thing between the two tables is 13 bytes long — an inline
  -- header and a terminator — and 13 is not a multiple of 3, so a grid walk
  -- steps straight over the start of the cry table and never lands on it.
  local first_entry, count, channels = nil, 0, {}
  for start = from, to - 3 do
    local run, at, seen = 0, start, {}
    while at <= to - 3 do
      local n, channel = rising_header(rom:u8(at), rom:u16le(at + 1))
      if not n then
        break
      end
      run = run + 1
      seen[channel] = (seen[channel] or 0) + 1
      at = at + 3
    end
    if run > count then
      first_entry, count, channels = start, run, seen
    end
  end

  local spread = {}
  for channel, times in pairs(channels) do
    spread[#spread + 1] = ("ch%d x%d"):format(channel, times)
  end
  table.sort(spread)
  log("  a run of %d headers begins at 0x%06X; opening channels: %s",
    count, first_entry or 0, table.concat(spread, ", "))

  if count < 8 then
    log("  too short to be the base cries; stopping")
    rom:release()
    write(report_path)
    return true
  end

  local cry_count = count
  log("  taking that as %d base cries", cry_count)

  -- Now the per-species table. A record's first byte should be a base cry
  -- index, so 251 of them in a row all below the cry count is already sharp:
  -- most byte values fail it, so a wrong offset dies within a couple of
  -- records.
  -- The evolution pairs, from a table found by a separate search in a
  -- different bank. This is what a wrong answer cannot fake.
  local stats = locate.table(locate.descriptors.base_stats, rom)
  local learn = stats and learnsets.locate(rom, stats.records)
  local families = {}
  if learn then
    for species, record in ipairs(learn.records) do
      for _, evolution in ipairs(record.evolutions or {}) do
        if evolution.into and evolution.into <= probe.SPECIES then
          families[#families + 1] = { species, evolution.into }
        end
      end
    end
  end

  -- "251 bytes that are all small" turns out to be a weak thing to ask for —
  -- whole regions of the cartridge satisfy it — so it is used only to narrow
  -- the field, and evolution agreement decides. Score every candidate and keep
  -- the best rather than listing thousands of them.
  log("\n== scoring every candidate by evolution agreement ==")
  log("  %d evolution pairs to check", #families)
  local best = {}
  for stride = 3, 8 do
    local candidates, top = 0, nil
    for offset = 0, rom.size - stride * probe.SPECIES - 1 do
      local ok, seen_counts, distinct = true, {}, 0
      for index = 0, probe.SPECIES - 1 do
        local value = rom:u8(offset + index * stride)
        if value >= cry_count then
          ok = false
          break
        end
        if not seen_counts[value] then
          seen_counts[value] = 0
          distinct = distinct + 1
        end
        seen_counts[value] = seen_counts[value] + 1
      end
      if ok and distinct >= 20 then
        candidates = candidates + 1
        local same = 0
        for _, pair in ipairs(families) do
          if rom:u8(offset + (pair[1] - 1) * stride)
            == rom:u8(offset + (pair[2] - 1) * stride) then
            same = same + 1
          end
        end

        -- Score the excess over *this candidate's own* noise floor, not the
        -- raw rate. A region that is mostly one value makes any two species
        -- agree, so it scores 90% on evolutions while meaning nothing — the
        -- same trap as the hidden items, which read correctly 74 times out of
        -- 85 when chance was also 74. The floor is the chance that two species
        -- drawn from this candidate's own distribution match, which is the sum
        -- of the squared frequencies.
        local floor = 0
        for _, times in pairs(seen_counts) do
          floor = floor + (times / probe.SPECIES) ^ 2
        end
        local excess = same / math.max(#families, 1) - floor

        if not top or excess > top.excess then
          top = { offset = offset, stride = stride, same = same,
                  distinct = distinct, floor = floor, excess = excess }
        end
      end
    end
    if top then
      best[#best + 1] = top
      log("  stride %d: %d candidates; best excess %+d points at 0x%06X " ..
        "(%d%% agree against its own %d%% floor)", stride, candidates,
        math.floor(top.excess * 100), top.offset,
        math.floor(top.same / math.max(#families, 1) * 100),
        math.floor(top.floor * 100))
    else
      log("  stride %d: no candidates", stride)
    end
  end

  table.sort(best, function(a, b) return a.excess > b.excess end)

  -- What would chance look like? Two species drawn at random out of the same
  -- table, so the cries and their distribution are held fixed and only the
  -- pairing is broken.
  if best[1] then
    local hit = best[1]
    math.randomseed(20260817)
    local total = 0
    for _ = 1, 40 do
      local same = 0
      for _ = 1, #families do
        if rom:u8(hit.offset + (math.random(1, probe.SPECIES) - 1) * hit.stride)
          == rom:u8(hit.offset
            + (math.random(1, probe.SPECIES) - 1) * hit.stride) then
          same = same + 1
        end
      end
      total = total + same
    end
    log("  chance, pairing species at random: %.1f of %d (%d%%)",
      total / 40, #families,
      math.floor(total / 40 / math.max(#families, 1) * 100))
  end

  local hits = best

  -- Show the first records so the layout can be read rather than assumed.
  do
    local hit = hits[1]
    local names = locate.table(locate.descriptors.species_names, rom)
    names = names and names.records or {}
    log("\n== the best candidate, read as three words ==")
    log("  0x%06X, %d bytes a record", hit.offset, hit.stride)
    log("  species      cry  pitch  length")
    for species = 1, 10 do
      local at = hit.offset + (species - 1) * hit.stride
      log("  %3d %-11s %3d  %5d  %5d", species, names[species] or "?",
        rom:u16le(at), rom:u16le(at + 2), rom:u16le(at + 4))
    end

    -- Does it use the cry block that was found separately, and all of it?
    --
    -- This is the check worth having: the block was measured between two other
    -- tables without any reference to this one, so the two agreeing is two
    -- searches converging rather than one search congratulating itself.
    local used, lowest, highest = {}, math.huge, -1
    local out_of_range = 0
    local pitch_low, pitch_high = math.huge, -1
    local length_low, length_high = math.huge, -1
    for species = 1, probe.SPECIES do
      local at = hit.offset + (species - 1) * hit.stride
      local cry = rom:u16le(at)
      if cry >= cry_count then
        out_of_range = out_of_range + 1
      end
      used[cry] = true
      lowest = math.min(lowest, cry)
      highest = math.max(highest, cry)
      pitch_low = math.min(pitch_low, rom:u16le(at + 2))
      pitch_high = math.max(pitch_high, rom:u16le(at + 2))
      length_low = math.min(length_low, rom:u16le(at + 4))
      length_high = math.max(length_high, rom:u16le(at + 4))
    end
    local distinct = 0
    local missing = {}
    for cry = 0, cry_count - 1 do
      if used[cry] then
        distinct = distinct + 1
      else
        missing[#missing + 1] = cry
      end
    end

    log("\n  cries named: %d distinct, %d to %d, %d outside the block",
      distinct, lowest, highest, out_of_range)
    log("  of the %d base cries found separately, %d are used; unused: %s",
      cry_count, distinct,
      #missing > 0 and table.concat(missing, " ") or "none")
    log("  pitch spans %d to %d, length spans %d to %d",
      pitch_low, pitch_high, length_low, length_high)
  end

  rom:release()
  write(report_path)
  return true
end

return probe
