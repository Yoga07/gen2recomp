-- Diagnostic: what does a script's sound id index?
--
-- The song table is known, and two more tables of sound headers were found
-- sitting behind it. What is missing is the arithmetic in between: `playsound`
-- asks for ids up to 202 and `cry` for ids up to 250, and nothing yet says
-- which entry of which table either of those means.
--
-- Rather than guess a base offset and check whether it looks plausible, this
-- scores **every** offset in the cartridge against the ids the scripts actually
-- use. A table base is right when the ids the game asks for land on real
-- headers; a wrong base puts them on rubbish.
--
-- The method checks itself first. `playmusic`'s ids have a known answer — the
-- song table, whose offset was established separately — so if the scan does not
-- put that table top of the list for `playmusic`, the scan is wrong and nothing
-- it says about the other two means anything.
--
--   love . --probe-soundids <rom> <report>

local Rom = require("src.rom.rom")
local music = require("src.rom.music")
local cache = require("src.import.cache")

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

--- A sound header, allowing it to open on any channel of either set.
local function header_at(rom, bank, addr)
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
  for index = 0, count - 1 do
    local entry = base + index * 3
    local marker = rom:u8(entry)
    if marker % 16 ~= channel + index then
      return nil
    end
    if index > 0 and marker >= 64 then
      return nil
    end
    local pointer = rom:u16le(entry + 1)
    if pointer < 0x4000 or pointer > 0x7FFF then
      return nil
    end
  end
  return count, channel
end

function probe.run(rom_path, report_path)
  report = {}

  local rom, err = Rom.load(rom_path)
  if not rom then
    log("FATAL: %s", err)
    write(report_path)
    return true
  end

  -- The ids the game actually asks for, from the decoded scripts.
  local game_id
  for _, entry in ipairs(cache.list_games()) do
    if entry.current then
      game_id = entry.game
    end
  end
  local code = game_id and cache.read(game_id, "script_code")
  if not code then
    log("FATAL: no decoded scripts in the cache; run an import first")
    rom:release()
    write(report_path)
    return true
  end

  local wanted = { playmusic = {}, playsound = {}, cry = {} }
  local dropped = { playmusic = 0, playsound = 0, cry = 0 }
  for _, block in pairs(code) do
    for _, instruction in pairs(block) do
      local set = wanted[instruction.op]
      if set and instruction.args then
        local id = (instruction.args[1] or 0)
          + (instruction.args[2] or 0) * 256
        -- A handful of operands are plainly not ids: they come from the few
        -- scripts that misparse, and they are counted rather than hidden.
        if id < 256 then
          set[id] = true
        else
          dropped[instruction.op] = dropped[instruction.op] + 1
        end
      end
    end
  end

  local ids = {}
  for op, set in pairs(wanted) do
    local list = {}
    for id in pairs(set) do
      list[#list + 1] = id
    end
    table.sort(list)
    ids[op] = list
    log("%s: %d distinct ids, highest %d, %d operands too large to be ids",
      op, #list, list[#list] or 0, dropped[op])
  end

  -- One pass: is there a sound header pointer at this offset?
  log("\nscanning every offset for a table base...")
  local valid = {}
  for offset = 0, rom.size - 3 do
    valid[offset] = header_at(rom, rom:u8(offset), rom:u16le(offset + 1))
      and true or false
  end

  --- Score a base: how many of the ids land on a real header.
  local function score_bases(list)
    local best = {}
    local highest = list[#list] or 0
    for base = 0, rom.size - 3 - highest * 3 do
      local hits = 0
      for _, id in ipairs(list) do
        if valid[base + id * 3] then
          hits = hits + 1
        end
      end
      if hits > 0 then
        best[#best + 1] = { base = base, hits = hits }
      end
    end
    table.sort(best, function(a, b)
      if a.hits ~= b.hits then
        return a.hits > b.hits
      end
      return a.base < b.base
    end)
    return best
  end

  local located = music.locate(rom)
  local song_base = located and located.offset

  for _, op in ipairs({ "playmusic", "playsound", "cry" }) do
    local list = ids[op]
    log("\n== %s: %d ids, highest %d ==", op, #list, list[#list] or 0)
    if #list == 0 then
      log("  nothing to score")
    else
      local best = score_bases(list)
      local perfect = 0
      for _, entry in ipairs(best) do
        if entry.hits == #list then
          perfect = perfect + 1
        end
      end
      log("  %d offsets explain every id; %d explain at least one",
        perfect, #best)
      for index = 1, math.min(#best, 6) do
        local entry = best[index]
        log("    0x%06X  %d of %d%s", entry.base, entry.hits, #list,
          song_base and entry.base == song_base and "   <-- the song table"
            or "")
      end
    end
  end

  -- Where does the effect table actually stop? The enumeration that built the
  -- cache gave up after eight misses in a row and got 78 entries, but the
  -- scripts ask for id 202 and it resolves — so the gaps inside are wider than
  -- eight. Map them rather than picking a tolerance and hoping.
  log("\n== the shape of the effect table ==")
  do
    local base = 0x0E927C
    local runs, current = {}, nil
    local decoded, last = 0, -1
    for index = 0, 259 do
      local at = base + index * 3
      local ok = at + 2 < rom.size
        and header_at(rom, rom:u8(at), rom:u16le(at + 1))
      if ok then
        decoded = decoded + 1
        last = index
      end
      if current and current.ok == (ok and true or false) then
        current.count = current.count + 1
      else
        current = { ok = ok and true or false, from = index, count = 1 }
        runs[#runs + 1] = current
      end
    end

    log("  %d of the first 260 slots decode; the last is %d", decoded, last)
    local gaps = {}
    for _, run in ipairs(runs) do
      if not run.ok and run.count >= 4 then
        gaps[#gaps + 1] = ("%d..%d (%d)"):format(run.from,
          run.from + run.count - 1, run.count)
      end
    end
    log("  runs of four or more that do not decode: %s",
      #gaps > 0 and table.concat(gaps, ", ") or "none")

    -- Do the ids the scripts ask for sit inside the decoding slots?
    local inside, outside = 0, {}
    for _, id in ipairs(ids.playsound) do
      local at = base + id * 3
      if header_at(rom, rom:u8(at), rom:u16le(at + 1)) then
        inside = inside + 1
      else
        outside[#outside + 1] = id
      end
    end
    log("  %d of %d ids the scripts use land on a decoding slot%s",
      inside, #ids.playsound,
      #outside > 0 and ("; missing " .. table.concat(outside, " ")) or "")
  end

  log("\n(the playmusic row is the control: its answer is known " ..
    "independently, so if the song table is not at the top of it, nothing " ..
    "below it can be trusted either)")

  rom:release()
  write(report_path)
  return true
end

return probe
