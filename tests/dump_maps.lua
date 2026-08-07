-- Render maps to PNG for inspection.
--
--   love . --dump-maps <rom> <report>
--
-- Writes the largest maps into LOVE's save directory under dump/maps/. Size is
-- the selection criterion because towns and routes are the ones worth looking
-- at: an interior that is four blocks square tells you very little about
-- whether the block data decoded, whereas a town either looks like a town or
-- it does not.

local Rom = require("src.rom.rom")
local tilesets = require("src.rom.tilesets")
local maps = require("src.rom.maps")
local events = require("src.rom.events")

-- A movement tile is half a block on each edge, so 16 pixels in the render.
local TILE_PIXELS = maps.BLOCK_PIXELS / events.TILES_PER_BLOCK

--- Draw a hollow box one movement tile in size, so the map stays readable
-- underneath it. Positions are in movement tiles.
local function mark(image, x, y, r, g, b)
  local width, height = image:getDimensions()
  local left, top = x * TILE_PIXELS, y * TILE_PIXELS

  for i = 0, TILE_PIXELS - 1 do
    for _, point in ipairs {
      { left + i, top },
      { left + i, top + TILE_PIXELS - 1 },
      { left, top + i },
      { left + TILE_PIXELS - 1, top + i },
    } do
      local px, py = point[1], point[2]
      if px >= 0 and px < width and py >= 0 and py < height then
        image:setPixel(px, py, r, g, b, 1)
      end
    end
  end
end

local dump = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

local HOW_MANY = 10

function dump.run(rom_path, report_path)
  report = {}

  local rom, err = Rom.load(rom_path)
  if not rom then
    log("FATAL: %s", err)
    local fh = io.open(report_path, "w")
    if fh then fh:write(table.concat(report, "\n") .. "\n") fh:close() end
    return true
  end

  local tileset_result, tileset_err = tilesets.locate(rom)
  if not tileset_result then
    log("FATAL: %s", tileset_err)
    rom:release()
    local fh = io.open(report_path, "w")
    if fh then fh:write(table.concat(report, "\n") .. "\n") fh:close() end
    return true
  end

  local result, why = maps.locate(rom, tileset_result.count)
  if not result then
    log("FATAL: %s", why)
    rom:release()
    local fh = io.open(report_path, "w")
    if fh then fh:write(table.concat(report, "\n") .. "\n") fh:close() end
    return true
  end

  log("%d map headers in %d runs", #result.headers, #result.runs)
  for i, run in ipairs(result.runs) do
    log("  run %d: 0x%06X (bank $%02X), %d headers",
      i, run.offset, math.floor(run.offset / 0x4000), run.count)
  end

  -- Cache decoded tilesets, since many maps share one.
  local tileset_cache = {}
  local function tileset_for(id)
    if tileset_cache[id] == nil then
      local header = tileset_result.headers[id]
      if not header then
        tileset_cache[id] = false
      else
        local tiles = tilesets.decode_graphics(rom, header)
        tileset_cache[id] = tiles
          and { tiles = tiles, blocks = tilesets.decode_blocks(rom, header) }
          or false
      end
    end
    return tileset_cache[id] or nil
  end

  local ranked = {}
  for _, header in ipairs(result.headers) do
    if not header.unparsed then
      ranked[#ranked + 1] = header
    end
  end
  table.sort(ranked, function(a, b)
    return a.attributes.width * a.attributes.height
      > b.attributes.width * b.attributes.height
  end)

  love.filesystem.createDirectory("dump/maps")

  log("\n== largest maps ==")
  local written = 0
  for i = 1, math.min(#ranked, HOW_MANY) do
    local header = ranked[i]
    local attributes = header.attributes
    local tileset = tileset_for(header.tileset)

    local connections = maps.connection_list(attributes)
    log("  %2d: %2dx%-2d blocks  tileset %2d  %-7s  connections %s",
      i, attributes.width, attributes.height, header.tileset,
      header.environment_name or "?",
      #connections > 0 and table.concat(connections, ",") or "none")

    if tileset then
      local image = maps.render(rom, header, tileset.tiles, tileset.blocks)

      -- Overlay the events. This is the check that matters: warps should sit on
      -- doors and cave mouths, NPCs on walkable ground. Coordinates decoded
      -- from the wrong offset would scatter.
      local decoded, event_err = events.decode(rom, header)
      if not decoded then
        log("      events failed: %s", tostring(event_err))
      else
        log("      %d warps, %d triggers, %d signposts, %d objects",
          #decoded.warps, #decoded.coord_events, #decoded.bg_events,
          #decoded.objects)
        for _, warp in ipairs(decoded.warps) do
          mark(image, warp.x, warp.y, 1, 0.2, 0.2)
        end
        for _, bg in ipairs(decoded.bg_events) do
          mark(image, bg.x, bg.y, 1, 1, 0.2)
        end
        for _, object in ipairs(decoded.objects) do
          mark(image, object.x, object.y, 0.2, 0.5, 1)
        end
      end

      local encoded = image:encode("png")
      local path = ("dump/maps/%02d_%dx%d_ts%02d.png")
        :format(i, attributes.width, attributes.height, header.tileset)
      if love.filesystem.write(path, encoded:getString()) then
        written = written + 1
      end

      -- A second render tinting every cell whose collision value is not one of
      -- the two dominant ones. If those two really are floor, the tint should
      -- fall on buildings, trees, cliffs and water and leave paths clear.
      local collision = tilesets.decode_collision(rom, tileset_result.headers[header.tileset])
      local grid = maps.decode_block_data(rom, header)
      local overlay = maps.render(rom, header, tileset.tiles, tileset.blocks)

      for ty = 0, attributes.height * 2 - 1 do
        for tx = 0, attributes.width * 2 - 1 do
          local block_id = grid[math.floor(ty / 2) + 1][math.floor(tx / 2) + 1]
          local entry = collision[block_id + 1]
          local value = entry and entry[(ty % 2) * 2 + (tx % 2) + 1]
          -- Three-way tint so the two dominant values can be told apart:
          -- $00 left clear, $07 blue, everything else red.
          local tint
          if value == 0x00 then
            tint = nil
          elseif value == 0x07 then
            tint = { 0.3, 0.4, 1.0 }
          elseif value then
            tint = { 1.0, 0.3, 0.3 }
          end

          if tint then
            for py = 0, TILE_PIXELS - 1 do
              for px = 0, TILE_PIXELS - 1 do
                local ox, oy = tx * TILE_PIXELS + px, ty * TILE_PIXELS + py
                local r, g, b = overlay:getPixel(ox, oy)
                overlay:setPixel(ox, oy,
                  math.min(1, r * 0.45 + tint[1] * 0.55),
                  math.min(1, g * 0.45 + tint[2] * 0.55),
                  math.min(1, b * 0.45 + tint[3] * 0.55), 1)
              end
            end
          end
        end
      end

      local collision_path = ("dump/maps/%02d_collision.png"):format(i)
      love.filesystem.write(collision_path, overlay:encode("png"):getString())
    end
  end

  log("\nwrote %d maps to %s/dump/maps", written, love.filesystem.getSaveDirectory())

  rom:release()

  local fh = io.open(report_path, "w")
  if fh then
    fh:write(table.concat(report, "\n") .. "\n")
    fh:close()
  end
  return true
end

return dump
