-- Read a real cartridge save and say what is in it.
--
--   love . --probe-sav <rom> <report> <save>
--
-- The ROM is needed for the base stats: the party is found by checking that
-- every member's stats come back out of the formula, and without the species'
-- base stats there is nothing to check against.

local Rom = require("src.rom.rom")
local locate = require("src.rom.locate")
local sav = require("src.engine.sav")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

function probe.run(rom_path, report_path, save_path)
  report = {}

  local function finish()
    local fh = io.open(report_path, "w")
    if fh then fh:write(table.concat(report, "\n") .. "\n") fh:close() end
    return true
  end

  if not save_path then
    log("FATAL: pass the save file as the third argument")
    return finish()
  end

  local rom, err = Rom.load(rom_path)
  if not rom then
    log("FATAL: %s", err)
    return finish()
  end

  local stats = locate.table(locate.descriptors.base_stats, rom)
  local names = locate.table(locate.descriptors.species_names, rom)
  rom:release()

  if not stats then
    log("FATAL: the base stats did not locate")
    return finish()
  end

  local file = io.open(save_path, "rb")
  if not file then
    log("FATAL: could not open %s", save_path)
    return finish()
  end
  local data = file:read("*all")
  file:close()

  log("%s", save_path)
  log("  %d bytes", #data)

  local members, where = sav.find_party(data, stats.records)
  if not members then
    log("  no party: %s", tostring(where))
    return finish()
  end

  log("  party found at 0x%04X, %d members", where, #members)
  for index, member in ipairs(members) do
    local name = names and names.records[member.species] or "?"
    log("    %d  %-11s L%-3d %d/%d HP  atk %d def %d spd %d spa %d spd %d%s",
      index, name, member.level, member.hp, member.stats.hp,
      member.stats.attack, member.stats.defense, member.stats.speed,
      member.stats.special_attack, member.stats.special_defense,
      member.shiny and "  shiny" or "")
  end

  return finish()
end

return probe
