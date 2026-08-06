-- Render tilesets to PNG for inspection.
--
--   love . --dump-tilesets <rom> <report>
--
-- Writes into LOVE's save directory under dump/tilesets/. Two images per
-- tileset: the raw tile sheet, which shows whether the graphics decompressed,
-- and the blockset, which shows whether the block table decoded. The second is
-- the one that matters — wrong block data still yields plausible tiles, but
-- they assemble into noise instead of doors, trees and paths.

local Rom = require("src.rom.rom")
local tilesets = require("src.rom.tilesets")

local dump = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

local function write_png(path, image)
  local encoded = image:encode("png")
  local ok, err = love.filesystem.write(path, encoded:getString())
  if not ok then
    log("  could not write %s: %s", path, tostring(err))
  end
  return ok
end

function dump.run(rom_path, report_path)
  report = {}

  local rom, err = Rom.load(rom_path)
  if not rom then
    log("FATAL: %s", err)
    local fh = io.open(report_path, "w")
    if fh then fh:write(table.concat(report, "\n") .. "\n") fh:close() end
    return true
  end

  local result, why = tilesets.locate(rom)
  if not result then
    log("FATAL: %s", why)
    rom:release()
    local fh = io.open(report_path, "w")
    if fh then fh:write(table.concat(report, "\n") .. "\n") fh:close() end
    return true
  end

  log("tileset header table at 0x%06X (bank $%02X), %d headers",
    result.offset, math.floor(result.offset / 0x4000), result.count)

  love.filesystem.createDirectory("dump/tilesets")

  for index, header in ipairs(result.headers) do
    local tiles, tile_err = tilesets.decode_graphics(rom, header)
    if not tiles then
      log("  %2d: graphics failed: %s", index, tostring(tile_err))
    else
      local blocks = tilesets.decode_blocks(rom, header)

      -- How many distinct tiles do the blocks actually reference, and does any
      -- index point past the end of the sheet? Both are strong signals.
      local seen, out_of_range, highest = {}, 0, -1
      for _, block in ipairs(blocks) do
        for _, tile_index in ipairs(block) do
          seen[tile_index] = true
          highest = math.max(highest, tile_index)
          if tile_index >= #tiles then
            out_of_range = out_of_range + 1
          end
        end
      end
      local distinct = 0
      for _ in pairs(seen) do
        distinct = distinct + 1
      end

      log("  %2d: gfx 0x%06X %3d tiles | blocks 0x%06X | coll 0x%06X | " ..
        "%3d distinct tiles used, highest %3d, %d out of range",
        index, header.graphics, #tiles, header.blocks, header.collision,
        distinct, highest, out_of_range)

      write_png(("dump/tilesets/%02d_tiles.png"):format(index),
        tilesets.tilesheet_image(tiles, 16))
      write_png(("dump/tilesets/%02d_blocks.png"):format(index),
        tilesets.blockset_image(tiles, blocks, 8))
    end
  end

  log("\nwritten to %s/dump/tilesets", love.filesystem.getSaveDirectory())

  rom:release()

  local fh = io.open(report_path, "w")
  if fh then
    fh:write(table.concat(report, "\n") .. "\n")
    fh:close()
  end
  return true
end

return dump
