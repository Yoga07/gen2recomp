-- Diagnostic: which move does each TM and HM teach?
--
-- The items are named TM01 to TM50 and HM01 to HM07, which says nothing about
-- what they contain. Somewhere there is a list of 57 move ids in that order.
--
-- A run of 57 distinct valid move ids is not by itself convincing. What makes
-- it convincing is the tail: the last seven have to decode, through the move
-- name table this project already validates separately, to the seven field
-- moves. Cut, Fly, Surf, Strength, Flash, Whirlpool and Waterfall arriving in
-- that order at the end of a list found by shape alone is not a coincidence.
--
--   love . --probe-tmhm <rom> <report>

local Rom = require("src.rom.rom")
local locate = require("src.rom.locate")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

probe.COUNT = 57
probe.MOVE_COUNT = 251

function probe.run(rom_path, report_path)
  report = {}

  local rom, err = Rom.load(rom_path)
  if not rom then
    log("FATAL: %s", err)
    local fh = io.open(report_path, "w")
    if fh then fh:write(table.concat(report, "\n") .. "\n") fh:close() end
    return true
  end

  local names = locate.table(locate.descriptors.move_names, rom)
  if not names then
    log("FATAL: the move names did not locate")
    rom:release()
    local fh = io.open(report_path, "w")
    if fh then fh:write(table.concat(report, "\n") .. "\n") fh:close() end
    return true
  end
  names = names.records

  local function run_at(offset)
    local seen = {}
    for index = 0, probe.COUNT - 1 do
      local value = rom:u8(offset + index)
      if value < 1 or value > probe.MOVE_COUNT then
        return false
      end
      -- A machine teaching the same move as another would be pointless.
      if seen[value] then
        return false
      end
      seen[value] = true
    end
    return true
  end

  local hits = {}
  for offset = 0, rom.size - probe.COUNT do
    if run_at(offset) then
      hits[#hits + 1] = offset
    end
  end

  log("%d offsets hold %d distinct valid move ids in a row", #hits, probe.COUNT)

  -- The seven field moves, in HM order.
  local WANTED = { "CUT", "FLY", "SURF", "STRENGTH", "FLASH", "WHIRLPOOL",
                   "WATERFALL" }

  local matches = {}
  for _, offset in ipairs(hits) do
    local tail = {}
    for index = probe.COUNT - 7, probe.COUNT - 1 do
      tail[#tail + 1] = names[rom:u8(offset + index)]
    end
    local same = true
    for index, wanted in ipairs(WANTED) do
      if tail[index] ~= wanted then
        same = false
        break
      end
    end
    if same then
      matches[#matches + 1] = offset
    end
  end

  log("%d of them end with the seven field moves in HM order", #matches)

  for _, offset in ipairs(matches) do
    log("\n0x%06X:", offset)
    local line = {}
    for index = 0, probe.COUNT - 1 do
      local move = rom:u8(offset + index)
      local label = index < 50 and ("TM%02d"):format(index + 1)
        or ("HM%02d"):format(index - 49)
      line[#line + 1] = ("%s %s"):format(label, names[move] or "?")
      if #line == 4 then
        log("  %s", table.concat(line, "  "))
        line = {}
      end
    end
    if #line > 0 then
      log("  %s", table.concat(line, "  "))
    end
  end

  -- If nothing matched, show what the near misses look like so the shape can
  -- be judged rather than guessed at.
  if #matches == 0 then
    for i = 1, math.min(#hits, 6) do
      local tail = {}
      for index = probe.COUNT - 7, probe.COUNT - 1 do
        tail[#tail + 1] = names[rom:u8(hits[i] + index)] or "?"
      end
      log("  0x%06X ends: %s", hits[i], table.concat(tail, ", "))
    end
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
