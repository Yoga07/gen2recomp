-- Diagnostic: work out which collision values are walkable.
--
-- Each tileset carries four collision bytes per block, one per movement
-- quadrant. What the values *mean* is a table of constants we do not have.
--
-- But the cartridge tells us anyway. Every warp sits on a tile the player walks
-- onto, and every NPC stands on a tile the player can share or displace. So the
-- collision values found under 1300 warps and 1466 NPCs are walkable by
-- construction, and comparing that distribution against the distribution across
-- all map tiles separates floor from wall without a constants table.
--
--   love . --probe-collision <rom> <report>

local Rom = require("src.rom.rom")
local tilesets = require("src.rom.tilesets")
local maps = require("src.rom.maps")
local events = require("src.rom.events")

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

  -- Decode each tileset's collision table once.
  local collision_cache = {}
  local function collision_for(id)
    if collision_cache[id] == nil then
      local header = tileset_result.headers[id]
      collision_cache[id] = header and tilesets.decode_collision(rom, header) or false
    end
    return collision_cache[id] or nil
  end

  -- The four collision bytes cover a block's 2x2 movement quadrants, but their
  -- order is a guess. If it is wrong, a lookup returns a neighbouring cell --
  -- often the wall beside an NPC rather than the floor under it. The correct
  -- ordering is the one that puts the most NPCs on the floor value.
  local orderings = {
    { name = "row-major   (y*2+x)", index = function(x, y) return (y % 2) * 2 + (x % 2) end },
    { name = "column-major(x*2+y)", index = function(x, y) return (x % 2) * 2 + (y % 2) end },
  }

  local everywhere, under_warps, under_objects = {}, {}, {}
  local function bump(t, value)
    t[value] = (t[value] or 0) + 1
  end

  --- Collision value at a movement cell. Blocks are 2x2 movement cells, and the
  -- four collision bytes are in reading order within the block.
  local function collision_at(header, grid, collision, x, y)
    local attributes = header.attributes
    local block_x, block_y = math.floor(x / 2), math.floor(y / 2)
    if block_x < 0 or block_x >= attributes.width
      or block_y < 0 or block_y >= attributes.height then
      return nil
    end
    local block_id = grid[block_y + 1][block_x + 1]
    local entry = collision[block_id + 1]
    if not entry then
      return nil
    end
    return entry[(y % 2) * 2 + (x % 2) + 1]
  end

  local maps_used = 0
  for _, header in ipairs(map_result.headers) do
    local collision = not header.unparsed and collision_for(header.tileset)
    if collision then
      maps_used = maps_used + 1
      local grid = maps.decode_block_data(rom, header)

      for y = 0, header.attributes.height * 2 - 1 do
        for x = 0, header.attributes.width * 2 - 1 do
          local value = collision_at(header, grid, collision, x, y)
          if value then
            bump(everywhere, value)
          end
        end
      end

      local decoded = events.decode(rom, header)
      if decoded then
        for _, warp in ipairs(decoded.warps) do
          local value = collision_at(header, grid, collision, warp.x, warp.y)
          if value then
            bump(under_warps, value)
          end
        end
        for _, object in ipairs(decoded.objects) do
          local value = collision_at(header, grid, collision, object.x, object.y)
          if value then
            bump(under_objects, value)
          end
        end
      end
    end
  end

  log("sampled %d maps", maps_used)

  -- Rank values by how strongly they are associated with somewhere the player
  -- provably stands.
  local values = {}
  for value in pairs(everywhere) do
    values[#values + 1] = value
  end
  table.sort(values)

  log("\n%-6s %10s %8s %9s   %s", "value", "everywhere", "warps", "objects", "verdict")
  for _, value in ipairs(values) do
    local total = everywhere[value] or 0
    local warps = under_warps[value] or 0
    local objects = under_objects[value] or 0
    local standable = warps + objects

    -- Only report values that occur often enough to judge.
    if total >= 50 or standable > 0 then
      local verdict
      if standable > 0 then
        verdict = "WALKABLE (player stands here)"
      elseif total > 2000 then
        verdict = "likely blocking"
      else
        verdict = ""
      end
      log("$%02X    %10d %8d %9d   %s", value, total, warps, objects, verdict)
    end
  end

  local walkable = {}
  for _, value in ipairs(values) do
    if (under_warps[value] or 0) + (under_objects[value] or 0) > 0 then
      walkable[#walkable + 1] = ("$%02X"):format(value)
    end
  end
  log("\nvalues the player provably occupies: %s", table.concat(walkable, " "))

  -- Which quadrant ordering puts NPCs on the floor value most often?
  log("\n== quadrant ordering ==")
  for _, ordering in ipairs(orderings) do
    local on_floor, total = 0, 0
    for _, header in ipairs(map_result.headers) do
      local collision = not header.unparsed and collision_for(header.tileset)
      local decoded = collision and events.decode(rom, header)
      if decoded then
        local grid = maps.decode_block_data(rom, header)
        local attributes = header.attributes
        for _, object in ipairs(decoded.objects) do
          local bx, by = math.floor(object.x / 2), math.floor(object.y / 2)
          if bx >= 0 and bx < attributes.width and by >= 0 and by < attributes.height then
            local entry = collision[grid[by + 1][bx + 1] + 1]
            if entry then
              total = total + 1
              if entry[ordering.index(object.x, object.y) + 1] == 0x00 then
                on_floor = on_floor + 1
              end
            end
          end
        end
      end
    end
    log("  %s: %d of %d NPCs on $00 (%d%%)", ordering.name, on_floor, total,
      total > 0 and math.floor(on_floor / total * 100) or 0)
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
