-- Diagnostic: is there a cut tree or a whirlpool in the collision data?
--
-- Cut and Whirlpool clear something out of the way, so whatever they clear must
-- be distinguishable from ordinary scenery. This counts every collision value
-- that appears on a real map, says which the engine currently calls blocking,
-- and then asks a shape question of each: does it sit in the middle of a path?
--
-- Scenery comes in masses. A gate does not: it is one cell with walkable ground
-- on opposite sides of it, which is what makes it worth clearing.
--
--   love . --probe-terrain <rom> <report>

local Rom = require("src.rom.rom")
local tilesets = require("src.rom.tilesets")
local maps = require("src.rom.maps")
local collision = require("src.rom.collision")

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

  -- Decode every tileset's collision, so a map's blocks can be turned into
  -- per-cell terrain values.
  local sets = {}
  for index = 1, tileset_result.count do
    local header = tileset_result.headers[index]
    if header then
      sets[index] = tilesets.decode_collision(rom, header)
    end
  end

  local counts, gates, edges = {}, {}, {}

  for _, header in ipairs(map_result.headers) do
    if not header.unparsed and header.attributes then
      local set = sets[header.tileset]
      local blocks = maps.decode_block_data(rom, header)
      if set and blocks then
        local width = header.attributes.width * 2
        local height = header.attributes.height * 2

        -- Terrain value for a cell, through the block it belongs to. Blocks
        -- come back as rows of columns, and each covers two cells each way.
        local function at(cx, cy)
          if cx < 0 or cy < 0 or cx >= width or cy >= height then
            return nil
          end
          local row = blocks[math.floor(cy / 2) + 1]
          local block = row and row[math.floor(cx / 2) + 1]
          if not block then
            return nil
          end
          local quadrant = (cy % 2) * 2 + (cx % 2)
          local entry = set[block + 1]
          return entry and entry[quadrant + 1]
        end

        for cy = 0, height - 1 do
          for cx = 0, width - 1 do
            local value = at(cx, cy)
            if value then
              counts[value] = (counts[value] or 0) + 1

              -- A gate: blocked here, but walkable on two opposite sides.
              if not collision.walkable(value) then
                local left, right = at(cx - 1, cy), at(cx + 1, cy)
                local up, down = at(cx, cy - 1), at(cx, cy + 1)
                local horizontal = left and right
                  and collision.walkable(left) and collision.walkable(right)
                local vertical = up and down
                  and collision.walkable(up) and collision.walkable(down)
                if horizontal or vertical then
                  gates[value] = (gates[value] or 0) + 1
                end

                -- Water on both sides, which is what a whirlpool sits in.
                local wet = 0
                for _, neighbour in ipairs({ left, right, up, down }) do
                  if neighbour and collision.is_water(neighbour) then
                    wet = wet + 1
                  end
                end
                if wet >= 3 then
                  edges[value] = (edges[value] or 0) + 1
                end
              end
            end
          end
        end
      end
    end
  end

  local ranked = {}
  for value, count in pairs(counts) do
    ranked[#ranked + 1] = { value = value, count = count }
  end
  table.sort(ranked, function(a, b) return a.count > b.count end)

  log("%d distinct collision values across every map", #ranked)
  log("\n%-6s %-10s %8s %8s %8s", "value", "kind", "cells", "gates", "in water")
  for _, entry in ipairs(ranked) do
    local kind = collision.kind(entry.value)
    log("$%02X   %-10s %8d %8d %8d", entry.value, kind, entry.count,
      gates[entry.value] or 0, edges[entry.value] or 0)
  end

  -- The interesting ones: blocking, uncommon, and mostly sitting in a gap.
  log("\nblocking values that are mostly gates:")
  for _, entry in ipairs(ranked) do
    local gate = gates[entry.value] or 0
    if gate > 0 and gate >= entry.count * 0.4 then
      log("  $%02X: %d of %d occurrences gate a path (%d%%)", entry.value,
        gate, entry.count, math.floor(gate / entry.count * 100))
    end
  end

  -- A cut tree may not be terrain at all. If trees and boulders are objects
  -- instead, they will share a sprite and their scripts will all leave through
  -- the same standard script -- one routine for cutting, one for pushing.
  local events = require("src.rom.events")
  local script_decode = require("src.rom.script_decode")

  local by_sprite = {}
  for _, header in ipairs(map_result.headers) do
    local decoded = not header.unparsed and events.decode(rom, header)
    if decoded then
      local bank = math.floor(header.attributes.scripts / 0x4000)
      for _, object in ipairs(decoded.objects) do
        local entry = by_sprite[object.sprite]
        if not entry then
          entry = { count = 0, silent = 0, std = {}, bank = bank }
          by_sprite[object.sprite] = entry
        end
        entry.count = entry.count + 1

        -- Where its script goes, if it goes straight to a standard one.
        if object.script then
          local code = script_decode.reachable(rom,
            { { bank = bank, addr = object.script } })
          local block = code[bank]
          local instruction = block and block[object.script]
          if instruction and (instruction.op == "jumpstd"
            or instruction.op == "callstd") then
            local index = (instruction.args[1] or 0)
              + (instruction.args[2] or 0) * 256
            entry.std[index] = (entry.std[index] or 0) + 1
          end
        end
      end
    end
  end

  local sprites = {}
  for sprite, entry in pairs(by_sprite) do
    sprites[#sprites + 1] = { sprite = sprite, entry = entry }
  end
  table.sort(sprites, function(a, b) return a.entry.count > b.entry.count end)

  log("\nobject sprites whose scripts go straight to one standard script:")
  for _, item in ipairs(sprites) do
    local total, best, best_index = 0, 0, nil
    for index, count in pairs(item.entry.std) do
      total = total + count
      if count > best then best, best_index = count, index end
    end
    -- The tell: nearly every object with this sprite leaves through the same
    -- standard routine.
    if total >= 8 and best >= total * 0.9 then
      log("  sprite %3d: %3d objects, %d go to standard script %d",
        item.sprite, item.entry.count, best, best_index)
    end
  end

  -- Where each of those sprites lives. A boulder is a cave obstacle and a cut
  -- tree is an outdoor one, so the environments they stand in tell them apart
  -- without relying on squinting at a 16-pixel picture.
  log("\nwhere those sprites stand:")
  for _, sprite in ipairs({ 55, 89, 90 }) do
    local where = {}
    for _, header in ipairs(map_result.headers) do
      local decoded = not header.unparsed and events.decode(rom, header)
      if decoded then
        for _, object in ipairs(decoded.objects) do
          if object.sprite == sprite then
            local name = header.environment_name or "?"
            where[name] = (where[name] or 0) + 1
          end
        end
      end
    end
    local parts = {}
    for name, count in pairs(where) do
      parts[#parts + 1] = ("%s %d"):format(name, count)
    end
    table.sort(parts)
    log("  sprite %3d: %s", sprite, table.concat(parts, ", "))
  end

  -- What those standard scripts actually say. A tree and a boulder announce
  -- themselves in words, which is a far better identification than a count.
  local std_scripts = require("src.rom.std_scripts")
  local text = require("src.rom.text")
  local std = std_scripts.locate(rom)
  if std then
    log("\nwhat those standard scripts say:")
    for _, index in ipairs({ 0, 14, 15 }) do
      local entry = std.entries[index + 1]
      if entry then
        local code = script_decode.reachable(rom,
          { { bank = entry.bank, addr = entry.addr } })
        local block = code[entry.bank] or {}
        local addresses = {}
        for addr in pairs(block) do addresses[#addresses + 1] = addr end
        table.sort(addresses)
        local said = {}
        for _, addr in ipairs(addresses) do
          local instruction = block[addr]
          if instruction.text then
            said[#said + 1] = text.flatten({ pages = instruction.text })
          end
        end
        log("  %2d $%02X:$%04X  %s", index, entry.bank, entry.addr,
          #said > 0 and table.concat(said, " | "):sub(1, 96) or "(no text)")
      end
    end
  end

  -- Statistics identified the wrong thing once already, with the specials, so
  -- the candidate gets looked at rather than argued about. Render the map with
  -- the most of them and box every one.
  local WANTED = 0xB2
  local best = { count = 0 }
  for _, header in ipairs(map_result.headers) do
    if not header.unparsed and header.attributes then
      local set = sets[header.tileset]
      local blocks = maps.decode_block_data(rom, header)
      if set and blocks then
        local found = {}
        for cy = 0, header.attributes.height * 2 - 1 do
          for cx = 0, header.attributes.width * 2 - 1 do
            local row = blocks[math.floor(cy / 2) + 1]
            local block = row and row[math.floor(cx / 2) + 1]
            local entry = block and set[block + 1]
            local value = entry and entry[(cy % 2) * 2 + (cx % 2) + 1]
            if value == WANTED then
              found[#found + 1] = { cx, cy }
            end
          end
        end
        if #found > best.count then
          best = { count = #found, header = header, cells = found }
        end
      end
    end
  end

  log("\nthe map with the most $%02X has %d of them", WANTED, best.count)

  if best.header then
    local tileset = tilesets.decode_graphics(rom, tileset_result.headers[
      best.header.tileset])
    local blockset = tilesets.decode_blocks(rom,
      tileset_result.headers[best.header.tileset])
    if tileset and blockset then
      local image = maps.render(rom, best.header, tileset, blockset)
      local TILE = maps.BLOCK_PIXELS / 2
      local width, height = image:getDimensions()
      for _, cell in ipairs(best.cells) do
        local left, top = cell[1] * TILE, cell[2] * TILE
        for i = 0, TILE - 1 do
          for _, point in ipairs({
            { left + i, top }, { left + i, top + TILE - 1 },
            { left, top + i }, { left + TILE - 1, top + i },
          }) do
            if point[1] >= 0 and point[1] < width
              and point[2] >= 0 and point[2] < height then
              image:setPixel(point[1], point[2], 1, 0, 0, 1)
            end
          end
        end
      end
      love.filesystem.createDirectory("dump")
      local file = love.filesystem.newFile("dump/terrain.png")
      file:open("w")
      file:write(image:encode("png"):getString())
      file:close()
      log("  written to the save directory as dump/terrain.png")
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
