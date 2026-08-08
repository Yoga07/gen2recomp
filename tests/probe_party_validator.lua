-- Diagnostic: why does the trainer party validator reject entries?
--
-- 274 of 332 trainer objects reach a party. A rejection part-way through a
-- class truncates every trainer after it, so a handful of bad decodes cost far
-- more than a handful of trainers. This walks every class from its first entry
-- and reports where each walk stops and why, with the bytes at the failure.
--
--   love . --probe-party-validator <rom> <report>

local Rom = require("src.rom.rom")
local trainers = require("src.rom.trainers")
local text = require("src.rom.text")

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

  local runs = trainers.locate(rom)
  local all = {}
  for _, run in ipairs(runs) do
    for _, entry in ipairs(run.entries) do
      all[#all + 1] = entry
    end
  end

  local groups = trainers.locate_groups(rom, all)
  if not groups then
    log("FATAL: no class table")
    local fh = io.open(report_path, "w")
    if fh then fh:write(table.concat(report, "\n") .. "\n") fh:close() end
    return true
  end

  local reasons = {}
  local stops = {}
  local total_walked = 0

  -- Walk each class until it stops, recording where and why.
  local ordered = {}
  for class, start in pairs(groups.classes) do
    ordered[#ordered + 1] = { class = class, start = start }
  end
  table.sort(ordered, function(a, b) return a.start < b.start end)

  for index, entry in ipairs(ordered) do
    local limit = ordered[index + 1] and ordered[index + 1].start or rom.size
    local at = entry.start
    local walked = 0

    while at < limit do
      local record, consumed = trainers.decode(rom, at)
      if not record then
        -- `consumed` carries the reason when the decode failed.
        local reason = tostring(consumed)
        reasons[reason] = (reasons[reason] or 0) + 1

        if #stops < 14 then
          local bytes = {}
          for i = 0, 15 do
            if at + i < rom.size then
              bytes[#bytes + 1] = ("%02X"):format(rom:u8(at + i))
            end
          end
          -- Decode the leading bytes as text, which is what a name would be.
          local as_name = {}
          for i = 0, 15 do
            local code = rom:u8(at + i)
            if code == 0x50 then
              break
            end
            as_name[#as_name + 1] = text.charmap[code] or ("<%02X>"):format(code)
          end

          stops[#stops + 1] = ("class %2d after %d entries at 0x%06X: %s\n" ..
            "      %s\n      reads as: %s")
            :format(entry.class, walked, at, reason,
              table.concat(bytes, " "), table.concat(as_name))
        end
        break
      end

      walked = walked + 1
      total_walked = total_walked + 1
      at = at + consumed
    end
  end

  log("%d classes, %d trainers walked before stopping", #ordered, total_walked)
  log("(the flat scan found %d)", #all)

  log("\nwhy walks stop:")
  local ranked = {}
  for reason, count in pairs(reasons) do
    ranked[#ranked + 1] = { reason = reason, count = count }
  end
  table.sort(ranked, function(a, b) return a.count > b.count end)
  for _, entry in ipairs(ranked) do
    log("  %3d x %s", entry.count, entry.reason)
  end

  log("\nwhere they stop:")
  for _, stop in ipairs(stops) do
    log("  %s", stop)
  end

  -- Cross-reference against the trainers the maps actually point at, so the
  -- ones still out of reach can be named rather than counted.
  local tilesets = require("src.rom.tilesets")
  local maps = require("src.rom.maps")
  local events = require("src.rom.events")

  local tileset_result = tilesets.locate(rom)
  local map_result = maps.locate(rom, tileset_result.count)

  local class_length = {}
  for class, start in pairs(groups.classes) do
    local count = 0
    for id = 1, 64 do
      if trainers.party_for(rom, groups, class, id) then
        count = count + 1
      else
        break
      end
    end
    class_length[class] = count
  end

  local failures = {}
  local outside = {}
  for _, header in ipairs(map_result.headers) do
    local decoded = not header.unparsed and events.decode(rom, header)
    if decoded then
      local bank = math.floor(header.attributes.scripts / 0x4000)
      for _, object in ipairs(decoded.objects) do
        if object.kind == events.OBJECT_TRAINER and object.script then
          local block = events.decode_trainer(rom, bank, object.script)
          if block and not groups.classes[block.class] then
            outside[block.class] = (outside[block.class] or 0) + 1
          end
          if block and groups.classes[block.class] then
            local party, why = trainers.party_for(rom, groups, block.class, block.id)
            if not party then
              local key = ("class %d (holds %d) id %d: %s")
                :format(block.class, class_length[block.class] or 0,
                  block.id, tostring(why))
              failures[key] = (failures[key] or 0) + 1
            end
          end
        end
      end
    end
  end

  log("\nwhat each class holds:")
  for _, entry in ipairs(ordered) do
    local names = {}
    for id = 1, 8 do
      local record = trainers.party_for(rom, groups, entry.class, id)
      if not record then break end
      names[#names + 1] = record.name
    end
    log("  class %2d at 0x%06X holds %2d: %s", entry.class, entry.start,
      class_length[entry.class] or 0, table.concat(names, ", "))
  end

  log("\ntrainer objects naming a real class but not reaching a party:")
  local listed = 0
  for key, count in pairs(failures) do
    if listed < 12 then
      listed = listed + 1
      log("  %d x %s", count, key)
    end
  end
  if listed == 0 then
    log("  none")
  end

  -- Does a single consistent shift of the class/id pair inside the block
  -- account for the objects that miss? A shift that works everywhere is a
  -- layout error; scattered results mean the blocks are simply not trainers.
  log("\nresolution by where class and id are read in the block:")
  for shift = 0, 6 do
    local hit, miss = 0, 0
    for _, header in ipairs(map_result.headers) do
      local decoded = not header.unparsed and events.decode(rom, header)
      if decoded then
        local bank = math.floor(header.attributes.scripts / 0x4000)
        for _, object in ipairs(decoded.objects) do
          if object.kind == events.OBJECT_TRAINER and object.script
            and object.script >= 0x4000 and object.script <= 0x7FFF then
            local base = bank * 0x4000 + (object.script - 0x4000)
            if base + shift + 1 < rom.size then
              local class = rom:u8(base + shift)
              local id = rom:u8(base + shift + 1)
              if class >= 1 and id >= 1 and groups.classes[class]
                and trainers.party_for(rom, groups, class, id) then
                hit = hit + 1
              else
                miss = miss + 1
              end
            end
          end
        end
      end
    end
    log("  class at byte %d: %d resolve, %d do not", shift, hit, miss)
  end

  log("\nthe class table past where it stops:")
  local anchor = math.floor((groups.classes[1] or 0) / 0x4000)
  for class = 54, 70 do
    local at = groups.offset + (class - 1) * 2
    if at + 2 <= rom.size then
      local addr = rom:u16le(at)
      local flat = anchor * 0x4000 + (addr - 0x4000)
      local bytes, reads = {}, {}
      if addr >= 0x4000 and addr <= 0x7FFF and flat + 16 < rom.size then
        for i = 0, 15 do
          bytes[#bytes + 1] = ("%02X"):format(rom:u8(flat + i))
        end
        for i = 0, 15 do
          local code = rom:u8(flat + i)
          if code == 0x50 then break end
          reads[#reads + 1] = text.charmap[code]
            or text.substitutions[code] or ("<%02X>"):format(code)
        end
      end
      local _, why = trainers.decode(rom, flat)
      log("  class %2d -> $%04X (0x%06X) %s\n      %s | %s", class, addr, flat,
        groups.classes[class] and "resolved" or "REJECTED",
        table.concat(bytes, " "), table.concat(reads))
    end
  end

  log("\nclasses named that are not in the table:")
  local by_class = {}
  for class, count in pairs(outside) do
    by_class[#by_class + 1] = { class = class, count = count }
  end
  table.sort(by_class, function(a, b) return a.class < b.class end)
  for _, entry in ipairs(by_class) do
    log("  class %3d named %d times", entry.class, entry.count)
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
