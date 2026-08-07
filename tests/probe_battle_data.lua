-- Diagnostic: locate wild encounter tables and trainer parties.
--
--   love . --probe-battle-data <rom> <report>

local Rom = require("src.rom.rom")
local locate = require("src.rom.locate")
local encounters = require("src.rom.encounters")
local trainers = require("src.rom.trainers")

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

  local names = locate.table(locate.descriptors.species_names, rom)
  local species_names = names and names.records or {}
  local function species_of(id)
    return species_names[id] or ("#" .. id)
  end

  -- Grass.
  local grass, grass_err = encounters.locate_grass(rom)
  if not grass then
    log("grass: %s", grass_err)
  else
    log("grass encounter runs:")
    local total = 0
    for _, run in ipairs(grass) do
      total = total + run.count
      log("  0x%06X (bank $%02X): %d maps",
        run.offset, math.floor(run.offset / 0x4000), run.count)
    end
    log("  %d maps with grass encounters in total", total)

    local sample = grass[1].entries[1]
    log("\n  first entry: group %d map %d, rates morn %d day %d nite %d",
      sample.group, sample.map, sample.rates.morn, sample.rates.day,
      sample.rates.nite)
    for _, time in ipairs(encounters.times) do
      local parts = {}
      for _, slot in ipairs(sample.slots[time]) do
        parts[#parts + 1] = ("L%d %s"):format(slot.level, species_of(slot.species))
      end
      log("    %-5s %s", time, table.concat(parts, ", "))
    end

    -- Which species actually appear in the wild, as a sanity check.
    local seen = {}
    local distinct = 0
    for _, run in ipairs(grass) do
      for _, entry in ipairs(run.entries) do
        for _, time in ipairs(encounters.times) do
          for _, slot in ipairs(entry.slots[time]) do
            if not seen[slot.species] then
              seen[slot.species] = true
              distinct = distinct + 1
            end
          end
        end
      end
    end
    log("\n  %d distinct species appear in grass", distinct)
  end

  -- Water.
  local water, water_err = encounters.locate_water(rom)
  if not water then
    log("\nwater: %s", water_err)
  else
    local total = 0
    log("\nwater encounter runs:")
    for _, run in ipairs(water) do
      total = total + run.count
      log("  0x%06X (bank $%02X): %d maps",
        run.offset, math.floor(run.offset / 0x4000), run.count)
    end
    log("  %d maps with water encounters in total", total)
  end

  -- Trainers.
  local runs, trainer_err = trainers.locate(rom)
  if not runs then
    log("\ntrainers: %s", trainer_err)
  else
    log("\ntrainer party runs (longest first):")
    local total = 0
    for i = 1, math.min(#runs, 8) do
      total = total + runs[i].count
      log("  0x%06X (bank $%02X): %d trainers",
        runs[i].offset, math.floor(runs[i].offset / 0x4000), runs[i].count)
    end

    local all = 0
    for _, run in ipairs(runs) do
      all = all + run.count
    end
    log("  %d runs, %d trainers in total", #runs, all)

    log("\n  sample trainers:")
    local shown = 0
    for _, run in ipairs(runs) do
      for _, trainer in ipairs(run.entries) do
        if shown < 10 and #trainer.party >= 2 then
          shown = shown + 1
          local party = {}
          for _, member in ipairs(trainer.party) do
            party[#party + 1] = ("L%d %s"):format(member.level,
              species_of(member.species))
          end
          log("    %-12s %-10s %s", trainer.name, trainer.type_name,
            table.concat(party, ", "))
        end
      end
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
