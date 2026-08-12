-- Diagnostic: which water collision value is a whirlpool?
--
-- The earlier attempt asked the question directly — "which of the water values
-- is it" — and got nowhere, because roughly two dozen values are water and
-- nothing about a value's number says anything. This asks instead what a
-- whirlpool must *do*, and measures every water value against it.
--
-- Three properties, and the third is the one that matters:
--
--   rare      you need Whirlpool in a handful of places, not everywhere
--   isolated  a whirlpool is one cell sitting in water, not a coastline
--   gating    blocking it must cut the water in two, or clearing it buys nothing
--
-- The gating measure is the one that went wrong for cut trees, where "62% of
-- its cells have walkable ground on opposite sides" turned out to be counting a
-- fence as a doorway. That failure was a *local* measure — two cells either
-- side — so this uses a global one instead: flood the map's water, then flood it
-- again with the candidate removed, and see whether the number of separate
-- bodies of water goes up. A wall across open sea splits it too, which is why
-- isolation is measured alongside: a whirlpool is a dot, not a line.
--
--   love . --probe-whirlpool <rom> <report>

local Rom = require("src.rom.rom")
local tilesets = require("src.rom.tilesets")
local maps = require("src.rom.maps")
local collision = require("src.rom.collision")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

local function write(path)
  local fh = io.open(path, "w")
  if fh then
    fh:write(table.concat(report, "\n") .. "\n")
    fh:close()
  end
end

--- Number of connected regions among the cells `include` accepts.
local function components(width, height, include)
  local seen = {}
  local count = 0
  local stack = {}

  for cy = 0, height - 1 do
    for cx = 0, width - 1 do
      local key = cy * width + cx
      if not seen[key] and include(cx, cy) then
        count = count + 1
        stack[#stack + 1] = key
        seen[key] = true
        while #stack > 0 do
          local at = table.remove(stack)
          local x, y = at % width, math.floor(at / width)
          local function push(nx, ny)
            if nx >= 0 and ny >= 0 and nx < width and ny < height then
              local next_key = ny * width + nx
              if not seen[next_key] and include(nx, ny) then
                seen[next_key] = true
                stack[#stack + 1] = next_key
              end
            end
          end
          push(x - 1, y) push(x + 1, y) push(x, y - 1) push(x, y + 1)
        end
      end
    end
  end
  return count
end

function probe.run(rom_path, report_path)
  report = {}

  local rom, err = Rom.load(rom_path)
  if not rom then
    log("FATAL: %s", err)
    write(report_path)
    return true
  end

  local tileset_result = tilesets.locate(rom)
  local map_result = maps.locate(rom, tileset_result.count)

  local sets = {}
  for index = 1, tileset_result.count do
    local header = tileset_result.headers[index]
    if header then
      sets[index] = tilesets.decode_collision(rom, header)
    end
  end

  -- Per water value: where it is and what it does.
  local stat = {}
  local function entry(value)
    stat[value] = stat[value] or {
      cells = 0, maps = 0, clusters = 0, cluster_cells = 0,
      gating_maps = 0, in_channel = 0, on_maps = {},
    }
    return stat[value]
  end

  local water_values = {}
  for value = 0, 255 do
    if collision.is_water(value) then
      water_values[#water_values + 1] = value
      entry(value)
    end
  end

  for index, header in ipairs(map_result.headers) do
    if not header.unparsed and header.attributes then
      local set = sets[header.tileset]
      local blocks = maps.decode_block_data(rom, header)
      if set and blocks then
        local width = header.attributes.width * 2
        local height = header.attributes.height * 2

        local grid = {}
        local function at(cx, cy)
          if cx < 0 or cy < 0 or cx >= width or cy >= height then
            return nil
          end
          return grid[cy * width + cx]
        end

        for cy = 0, height - 1 do
          for cx = 0, width - 1 do
            local row = blocks[math.floor(cy / 2) + 1]
            local block = row and row[math.floor(cx / 2) + 1]
            local quadrant = (cy % 2) * 2 + (cx % 2)
            local record = block and set[block + 1]
            grid[cy * width + cx] = record and record[quadrant + 1]
          end
        end

        local present = {}
        for cy = 0, height - 1 do
          for cx = 0, width - 1 do
            local value = at(cx, cy)
            if value and collision.is_water(value) then
              present[value] = (present[value] or 0) + 1
            end
          end
        end

        -- How many separate bodies of water this map has as it stands.
        local whole = components(width, height, function(cx, cy)
          local value = at(cx, cy)
          return value ~= nil and collision.is_water(value)
        end)

        for value, count in pairs(present) do
          local record = entry(value)
          record.cells = record.cells + count
          record.maps = record.maps + 1
          record.on_maps[#record.on_maps + 1] = { map = index, cells = count }

          -- Take it out and see whether the water falls apart.
          local without = components(width, height, function(cx, cy)
            local other = at(cx, cy)
            return other ~= nil and other ~= value
              and collision.is_water(other)
          end)
          if without > whole then
            record.gating_maps = record.gating_maps + 1
          end

          -- How clumped is it? A coastline is one big region; a whirlpool is
          -- a scatter of single cells.
          record.clusters = record.clusters + components(width, height,
            function(cx, cy) return at(cx, cy) == value end)
          record.cluster_cells = record.cluster_cells + count

          -- And does it sit *in* the water, with water on opposite sides?
          for cy = 0, height - 1 do
            for cx = 0, width - 1 do
              if at(cx, cy) == value then
                local function wet(nx, ny)
                  local other = at(nx, ny)
                  return other ~= nil and other ~= value
                    and collision.is_water(other)
                end
                if (wet(cx - 1, cy) and wet(cx + 1, cy))
                  or (wet(cx, cy - 1) and wet(cx, cy + 1)) then
                  record.in_channel = record.in_channel + 1
                end
              end
            end
          end
        end
      end
    end
  end

  log("== every water value, and what it does ==")
  log("  value | cells | maps | clusters | mean size | in channel | gates on")
  table.sort(water_values)
  for _, value in ipairs(water_values) do
    local record = stat[value]
    if record.cells > 0 then
      log("   $%02X  | %5d | %4d | %8d | %9.1f | %9d%% | %d",
        value, record.cells, record.maps, record.clusters,
        record.cluster_cells / math.max(record.clusters, 1),
        math.floor(record.in_channel / record.cells * 100),
        record.gating_maps)
    end
  end

  -- The rare values, with the maps they sit on named as far as the cartridge
  -- lets us. A whirlpool guards a sea route; a waterfall is in a cave. The
  -- environment tells those apart without either being assumed.
  log("\n== where the rare values are ==")
  local environments = {}
  for _, value in ipairs(water_values) do
    local record = stat[value]
    if record.cells > 0 and record.maps <= 20 then
      table.sort(record.on_maps, function(a, b) return a.cells > b.cells end)
      log("  $%02X, %d cells on %d map(s):", value, record.cells, record.maps)
      for index = 1, math.min(#record.on_maps, 14) do
        local place = record.on_maps[index]
        local header = map_result.headers[place.map]
        local attributes = header and header.attributes
        log("    map %3d  %-9s %2dx%-2d blocks  %2d warps  %s cells",
          place.map, tostring(header and header.environment),
          attributes and attributes.width or 0,
          attributes and attributes.height or 0,
          attributes and #(attributes.warps or {}) or 0,
          place.cells)
        environments[header and header.environment or "?"] =
          (environments[header and header.environment or "?"] or 0) + 1
      end
    end
  end

  -- What a whirlpool actually does in Crystal is guard a way in: the Whirl
  -- Islands entrances sit behind them. So the question is not whether blocking
  -- the value splits the sea but whether it puts a warp out of reach.
  log("\n== does blocking it put a warp out of reach? ==")
  for _, value in ipairs(water_values) do
    local record = stat[value]
    if record.cells > 0 and record.maps <= 20 then
      local touching = 0
      for _, place in ipairs(record.on_maps) do
        local header = map_result.headers[place.map]
        local set = sets[header.tileset]
        local blocks = maps.decode_block_data(rom, header)
        if set and blocks and header.attributes then
          local width = header.attributes.width * 2
          local height = header.attributes.height * 2
          local function at(cx, cy)
            if cx < 0 or cy < 0 or cx >= width or cy >= height then
              return nil
            end
            local row = blocks[math.floor(cy / 2) + 1]
            local block = row and row[math.floor(cx / 2) + 1]
            local quadrant = (cy % 2) * 2 + (cx % 2)
            local entry_at = block and set[block + 1]
            return entry_at and entry_at[quadrant + 1]
          end

          for _, warp in ipairs(header.attributes.warps or {}) do
            local wx, wy = warp.x, warp.y
            if wx and wy then
              for _, delta in ipairs({ { -1, 0 }, { 1, 0 }, { 0, -1 },
                                       { 0, 1 } }) do
                if at(wx + delta[1], wy + delta[2]) == value then
                  touching = touching + 1
                end
              end
            end
          end
        end
      end
      log("  $%02X sits next to a warp %d time(s)", value, touching)
    end
  end

  -- And the thing that settles it: look at them.
  --
  -- Every measure above is a statistic about where a value sits, and this
  -- project has been burnt twice by exactly that — the cut tree that "gated a
  -- path" 62% of the time turned out to be a fence, and only rendering it
  -- showed so. A whirlpool is a swirl. Rendering every block that carries a
  -- candidate value asks the question the art can answer directly.
  log("\n== rendering the blocks that carry each candidate ==")
  love.filesystem.createDirectory("dump/whirlpool")

  local gfx = require("src.rom.gfx")
  local SCALE = 4

  local function write_blocks(name, tiles, blocks)
    local flat = tilesets.blockset_image(tiles, blocks,
      math.min(#blocks, 8))
    local wide = love.image.newImageData(flat:getWidth() * SCALE,
      flat:getHeight() * SCALE)
    for y = 0, wide:getHeight() - 1 do
      for x = 0, wide:getWidth() - 1 do
        local r, g, b = flat:getPixel(math.floor(x / SCALE),
          math.floor(y / SCALE))
        wide:setPixel(x, y, r, g, b, 1)
      end
    end
    love.filesystem.write(("dump/whirlpool/%s.png"):format(name),
      wide:encode("png"):getString())
  end

  for _, value in ipairs(water_values) do
    if stat[value].cells > 0 and stat[value].maps <= 20 then
      for index = 1, tileset_result.count do
        local header = tileset_result.headers[index]
        local set = sets[index]
        if header and set then
          local blocks = tilesets.decode_blocks(rom, header)
          local tiles = tilesets.decode_graphics(rom, header)
          if blocks and tiles then
            local chosen = {}
            for block_index, quadrants in ipairs(set) do
              local carries = false
              for _, quadrant in ipairs(quadrants) do
                carries = carries or quadrant == value
              end
              if carries and blocks[block_index] then
                chosen[#chosen + 1] = blocks[block_index]
              end
            end
            if #chosen > 0 then
              write_blocks(("%02X_tileset%02d"):format(value, index),
                tiles, chosen)
              log("  $%02X: %d block(s) in tileset %d", value, #chosen, index)
            end
          end
        end
      end
    end
  end
  log("  written to %s/dump/whirlpool",
    love.filesystem.getSaveDirectory())

  rom:release()
  write(report_path)
  return true
end

return probe
