-- Diagnostic: find which objects are trainers, and how a trainer reaches its
-- party.
--
-- Two unknowns. An object event packs a palette and an object type into one
-- byte as two nibbles, and the type value that means "trainer" is a constant we
-- do not have. And a trainer names its party by class and id, while the party
-- table was extracted as one flat run, so the class boundaries are missing.
--
-- Both are recoverable from the cartridge. A trainer object's script points at
-- a twelve-byte block — event flag, class, id, then four text pointers — so the
-- right type nibble is the one whose objects' scripts parse that way. And the
-- class boundaries are a pointer table whose entries land on trainer entries,
-- the same shape as the map group table.
--
--   love . --probe-trainers <rom> <report>

local Rom = require("src.rom.rom")
local tilesets = require("src.rom.tilesets")
local maps = require("src.rom.maps")
local events = require("src.rom.events")
local trainers = require("src.rom.trainers")
local text = require("src.rom.text")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

local TRAINER_BLOCK = 12
local MAX_CLASS = 67

--- Does a twelve-byte trainer block sit here?
local function trainer_block(rom, offset)
  if offset + TRAINER_BLOCK > rom.size then
    return nil
  end

  local class = rom:u8(offset + 2)
  local id = rom:u8(offset + 3)
  if class < 1 or class > MAX_CLASS or id < 1 or id > 64 then
    return nil
  end

  -- Four text pointers, all into the switchable window.
  for i = 0, 3 do
    local pointer = rom:u16le(offset + 4 + i * 2)
    -- The loss and after-battle slots are often zero.
    if pointer ~= 0 and (pointer < 0x4000 or pointer > 0x7FFF) then
      return nil
    end
  end

  return { flag = rom:u16le(offset), class = class, id = id }
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

  -- Every object in the game, with its type nibble and script location.
  local objects = {}
  for _, header in ipairs(map_result.headers) do
    local decoded = not header.unparsed and events.decode(rom, header)
    if decoded then
      local bank = math.floor(header.attributes.scripts / 0x4000)
      for _, object in ipairs(decoded.objects) do
        objects[#objects + 1] = {
          kind = object.colour_function % 16,
          palette = math.floor(object.colour_function / 16),
          script = object.script,
          bank = bank,
        }
      end
    end
  end

  local by_kind = {}
  for _, object in ipairs(objects) do
    by_kind[object.kind] = by_kind[object.kind] or { total = 0, trainer = 0 }
    by_kind[object.kind].total = by_kind[object.kind].total + 1

    if object.script then
      local flat = object.bank * 0x4000 + (object.script - 0x4000)
      if trainer_block(rom, flat) then
        by_kind[object.kind].trainer = by_kind[object.kind].trainer + 1
      end
    end
  end

  log("%d objects across the game", #objects)
  log("\nobject type nibble, and how many parse as a trainer block:")
  local kinds = {}
  for kind in pairs(by_kind) do
    kinds[#kinds + 1] = kind
  end
  table.sort(kinds)
  for _, kind in ipairs(kinds) do
    local entry = by_kind[kind]
    log("  type %2d: %4d objects, %4d parse as trainer (%d%%)",
      kind, entry.total, entry.trainer,
      math.floor(entry.trainer / entry.total * 100))
  end

  -- The class boundaries. Find a run of 2-byte pointers landing on the starts
  -- of trainer entries.
  local runs = trainers.locate(rom)
  if not runs then
    log("\ntrainer parties were not located")
  else
    local starts = {}
    local bank
    for _, run in ipairs(runs) do
      for _, entry in ipairs(run.entries) do
        starts[entry.offset] = true
        bank = bank or math.floor(entry.offset / 0x4000)
      end
    end

    local best = { count = 0 }
    local offset = 0
    while offset <= rom.size - 2 do
      local addr = rom:u16le(offset)
      local flat = bank * 0x4000 + (addr - 0x4000)
      if addr >= 0x4000 and addr <= 0x7FFF and starts[flat] then
        local start = offset
        local count = 0
        local previous = -1
        while offset <= rom.size - 2 do
          local next_addr = rom:u16le(offset)
          local next_flat = bank * 0x4000 + (next_addr - 0x4000)
          if next_addr < 0x4000 or next_addr > 0x7FFF or not starts[next_flat]
            or next_flat <= previous then
            break
          end
          count = count + 1
          previous = next_flat
          offset = offset + 2
        end
        if count > best.count then
          best = { count = count, offset = start }
        end
      else
        offset = offset + 1
      end
    end

    log("\nlongest run of pointers landing on trainer entries: %d at 0x%06X " ..
      "(bank $%02X)", best.count, best.offset,
      math.floor(best.offset / 0x4000))
    log("  Crystal has %d trainer classes by the pic table", MAX_CLASS)

    if best.count > 0 then
      log("\n  first classes:")
      for i = 0, math.min(best.count - 1, 7) do
        local addr = rom:u16le(best.offset + i * 2)
        local flat = bank * 0x4000 + (addr - 0x4000)
        local entry = trainers.decode(rom, flat)
        log("    class %2d -> 0x%06X  %s", i + 1, flat,
          entry and entry.name or "?")
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
