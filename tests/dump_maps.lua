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
    ranked[#ranked + 1] = header
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
      local encoded = image:encode("png")
      local path = ("dump/maps/%02d_%dx%d_ts%02d.png")
        :format(i, attributes.width, attributes.height, header.tileset)
      if love.filesystem.write(path, encoded:getString()) then
        written = written + 1
      end
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
