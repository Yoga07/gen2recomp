-- Diagnostic: check the collision classification against warps and grass.
--
-- Two assertions failed after adopting the real collision constants:
-- only 680 of 1300 warps sit on a tile classified walkable, and only 50 maps
-- have grass tiles against 91 that carry an encounter table. Either the
-- classification is incomplete or the assumptions behind those checks are
-- wrong. This reports the raw distributions so the difference is visible.
--
--   love . --probe-collision2 <rom> <report>

local Rom = require("src.rom.rom")
local tilesets = require("src.rom.tilesets")
local maps = require("src.rom.maps")
local events = require("src.rom.events")
local encounters = require("src.rom.encounters")
local collision = require("src.rom.collision")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

local function ranked(counts, limit)
  local list = {}
  for value, count in pairs(counts) do
    list[#list + 1] = { value = value, count = count }
  end
  table.sort(list, function(a, b) return a.count > b.count end)
  local parts = {}
  for i = 1, math.min(#list, limit or 16) do
    parts[#parts + 1] = ("$%02X(%s) x%d"):format(list[i].value,
      collision.kind(list[i].value):sub(1, 4), list[i].count)
  end
  return table.concat(parts, "  ")
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

  local collision_cache = {}
  local function collision_for(id)
    if collision_cache[id] == nil then
      local header = tileset_result.headers[id]
      collision_cache[id] = header and tilesets.decode_collision(rom, header) or false
    end
    return collision_cache[id] or nil
  end

  local function value_at(header, grid, table_, x, y)
    local attributes = header.attributes
    local bx, by = math.floor(x / 2), math.floor(y / 2)
    if bx < 0 or bx >= attributes.width or by < 0 or by >= attributes.height then
      return nil
    end
    local entry = table_[grid[by + 1][bx + 1] + 1]
    return entry and entry[(y % 2) * 2 + (x % 2) + 1]
  end

  -- What lies under warps.
  local under_warps = {}
  for _, header in ipairs(map_result.headers) do
    local table_ = not header.unparsed and collision_for(header.tileset)
    local decoded = table_ and events.decode(rom, header)
    if decoded then
      local grid = maps.decode_block_data(rom, header)
      for _, warp in ipairs(decoded.warps) do
        local value = value_at(header, grid, table_, warp.x, warp.y)
        if value then
          under_warps[value] = (under_warps[value] or 0) + 1
        end
      end
    end
  end
  log("collision values under warps:\n  %s", ranked(under_warps, 18))

  -- Which maps have an encounter table, and what values their tiles carry.
  local grass_runs = encounters.locate_grass(rom)
  local has_table = {}
  if grass_runs then
    for _, run in ipairs(grass_runs) do
      for _, entry in ipairs(run.entries) do
        has_table[entry.group * 256 + entry.map] = true
      end
    end
  end

  local groups = maps.locate_groups(rom, map_result.headers)
  local group_of = {}
  if groups then
    local index_map = maps.group_index(map_result.headers, groups.groups)
    local starts = {}
    for group, start in pairs(index_map) do
      starts[#starts + 1] = { group = group, start = start }
    end
    table.sort(starts, function(a, b) return a.start < b.start end)
    for i, entry in ipairs(starts) do
      local last = starts[i + 1] and starts[i + 1].start - 1 or #map_result.headers
      for index = entry.start, last do
        group_of[index] = { group = entry.group, number = index - entry.start + 1 }
      end
    end
  end

  -- On maps that definitely have wild encounters, which values are common?
  -- Whatever the grass tiles are, they must be in here.
  local on_encounter_maps = {}
  local counted = 0
  for index, header in ipairs(map_result.headers) do
    local where = group_of[index]
    local table_ = not header.unparsed and collision_for(header.tileset)
    if table_ and where and has_table[where.group * 256 + where.number] then
      counted = counted + 1
      local grid = maps.decode_block_data(rom, header)
      for y = 0, header.attributes.height * 2 - 1 do
        for x = 0, header.attributes.width * 2 - 1 do
          local value = value_at(header, grid, table_, x, y)
          if value then
            on_encounter_maps[value] = (on_encounter_maps[value] or 0) + 1
          end
        end
      end
    end
  end
  log("\n%d maps carry an encounter table; values on them:\n  %s",
    counted, ranked(on_encounter_maps, 20))

  rom:release()

  local fh = io.open(report_path, "w")
  if fh then
    fh:write(table.concat(report, "\n") .. "\n")
    fh:close()
  end
  return true
end

return probe
