-- Diagnostic: run the opcode-table inference and report what it learned.
--
--   love . --probe-walker <rom> <report>

local Rom = require("src.rom.rom")
local tilesets = require("src.rom.tilesets")
local maps = require("src.rom.maps")
local events = require("src.rom.events")
local script_table = require("src.rom.script_table")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
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

  local tileset_result = tilesets.locate(rom)
  local map_result = maps.locate(rom, tileset_result.count)
  local sorted, total = script_table.collect_entries(rom, map_result, events)

  local extents = script_table.extents(sorted)
  log("%d script pointers, %d with a usable extent", total, #extents)

  local inferred = script_table.infer(rom, sorted)
  log("\nlearned %d opcodes over %d rounds", inferred.learned, inferred.rounds)

  local list = {}
  for opcode, width in pairs(inferred.widths) do
    list[#list + 1] = { opcode = opcode, width = width }
  end
  table.sort(list, function(a, b) return a.opcode < b.opcode end)

  local parts = {}
  for _, entry in ipairs(list) do
    parts[#parts + 1] = ("$%02X:%d%s"):format(entry.opcode, entry.width,
      inferred.terminators[entry.opcode] and "*" or "")
  end
  log("\nopcode:operands  (* = ends the script)")
  for i = 1, #parts, 10 do
    log("  %s", table.concat(parts, "  ", i, math.min(i + 9, #parts)))
  end

  local counts = script_table.score(rom, sorted, inferred)
  log("\nwalking the %d scripts with known extents:", #extents)
  log("  ended on a terminator: %d (%d landing exactly on the boundary)",
    counts.ended, counts.exact)
  log("  hit an unknown opcode: %d", counts.unknown)
  log("  ran past the extent:   %d", counts.overrun)

  -- What is still unknown, and how often it blocks a walk.
  local blockers = {}
  for _, script in ipairs(extents) do
    local limit = script.offset + script.extent
    local status, _, position =
      script_table.walk(rom, script.offset, limit, inferred.widths,
        inferred.terminators)
    if status == "unknown" then
      local opcode = rom:u8(position)
      blockers[opcode] = (blockers[opcode] or 0) + 1
    end
  end

  local ranked = {}
  for opcode, count in pairs(blockers) do
    ranked[#ranked + 1] = { opcode = opcode, count = count }
  end
  table.sort(ranked, function(a, b) return a.count > b.count end)

  log("\nopcodes still blocking walks:")
  local blocked = {}
  for i = 1, math.min(#ranked, 16) do
    blocked[#blocked + 1] = ("$%02X x%d"):format(ranked[i].opcode, ranked[i].count)
  end
  log("  %s", table.concat(blocked, "  "))

  -- Why each blocker failed to be learned: the distribution of leftover bytes
  -- when it is reached. A clean fixed-width opcode produces one dominant value;
  -- a spread means the extents disagree, which is what the agreement threshold
  -- is there to catch.
  log("\nleftover bytes when each blocker is reached (width would be this minus 1):")
  for i = 1, math.min(#ranked, 5) do
    local opcode = ranked[i].opcode
    local tally, at_start, mid = {}, 0, 0

    for _, script in ipairs(extents) do
      local limit = script.offset + script.extent
      local status, _, position =
        script_table.walk(rom, script.offset, limit, inferred.widths,
          inferred.terminators)
      if status == "unknown" and rom:u8(position) == opcode then
        local remaining = limit - position
        if remaining <= 24 then
          tally[remaining] = (tally[remaining] or 0) + 1
        end
        if position == script.offset then
          at_start = at_start + 1
        else
          mid = mid + 1
        end
      end
    end

    local parts = {}
    for remaining = 1, 24 do
      if tally[remaining] then
        parts[#parts + 1] = ("%d:%d"):format(remaining, tally[remaining])
      end
    end
    log("  $%02X (%d at script start, %d mid-script): %s",
      opcode, at_start, mid, table.concat(parts, "  "))
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
