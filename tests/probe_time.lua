-- Diagnostic: what does checktime ask for?
--
-- 78 scripts call it and the interpreter steps over them. Its operand is one
-- byte. If the times of day are a bitmask -- morning, day and night as separate
-- bits -- the values used will be small and made of ones, twos and fours rather
-- than scattered across the range.
--
--   love . --probe-time <rom> <report>

local Rom = require("src.rom.rom")
local tilesets = require("src.rom.tilesets")
local maps = require("src.rom.maps")
local events = require("src.rom.events")
local script_decode = require("src.rom.script_decode")
local std_scripts = require("src.rom.std_scripts")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

local CHECKTIME = 0x2B

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

  local entries = {}
  for _, header in ipairs(map_result.headers) do
    local decoded = not header.unparsed and events.decode(rom, header)
    if decoded then
      local bank = math.floor(header.attributes.scripts / 0x4000)
      for _, bg in ipairs(decoded.bg_events) do
        if bg.script and bg.kind ~= events.BGEVENT_ITEM then
          entries[#entries + 1] = { bank = bank, addr = bg.script }
        end
      end
      for _, object in ipairs(decoded.objects) do
        if object.script and object.kind ~= events.OBJECT_TRAINER
          and object.kind ~= events.OBJECT_ITEM then
          entries[#entries + 1] = { bank = bank, addr = object.script }
        end
      end
      for _, coord in ipairs(decoded.coord_events) do
        if coord.script then
          entries[#entries + 1] = { bank = bank, addr = coord.script }
        end
      end
    end
  end

  local std = std_scripts.locate(rom)
  if std then
    for _, entry in ipairs(std.entries) do
      entries[#entries + 1] = { bank = entry.bank, addr = entry.addr }
    end
  end

  local code = script_decode.reachable(rom, entries)

  local used, total = {}, 0
  for _, block in pairs(code) do
    for _, instruction in pairs(block) do
      if instruction.opcode == CHECKTIME then
        local value = instruction.args[1] or 0
        used[value] = (used[value] or 0) + 1
        total = total + 1
      end
    end
  end

  log("%d checktime commands", total)
  local ranked = {}
  for value, count in pairs(used) do
    ranked[#ranked + 1] = { value = value, count = count }
  end
  table.sort(ranked, function(a, b) return a.value < b.value end)

  log("\noperands used:")
  for _, entry in ipairs(ranked) do
    -- Spell the value out in bits, since a mask should read cleanly.
    local bits = {}
    for bit = 0, 7 do
      if math.floor(entry.value / 2 ^ bit) % 2 == 1 then
        bits[#bits + 1] = ("bit %d"):format(bit)
      end
    end
    log("  %3d (0x%02X) x%-3d  %s", entry.value, entry.value, entry.count,
      #bits > 0 and table.concat(bits, " + ") or "none")
  end

  local highest = ranked[#ranked] and ranked[#ranked].value or 0
  log("\nhighest operand is %d; a three-way mask would top out at 7", highest)

  rom:release()

  local fh = io.open(report_path, "w")
  if fh then
    fh:write(table.concat(report, "\n") .. "\n")
    fh:close()
  end
  return true
end

return probe
