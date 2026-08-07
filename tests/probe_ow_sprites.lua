-- Diagnostic: find where Crystal keeps its uncompressed overworld graphics.
--
-- Three structural searches for the sprite table came up empty. Chaining
-- entries by tile count found nothing under either a two- or three-byte
-- pointer, so the graphics are not stored in table order; and constraining on
-- field shape found no run remotely long enough for the 118 distinct sprite ids
-- the game's NPCs actually use.
--
-- The pic pointers were cracked by finding the data first and working
-- backwards, and the same applies here. Overworld sprites are uncompressed
-- 2bpp, so they can be read directly — the problem is knowing which banks hold
-- them. Score every bank on how much of it looks like character art rather than
-- code, tables or blank space, then render the best candidates and look.
--
--   love . --probe-ow-sprites <rom> <report>

local Rom = require("src.rom.rom")
local gfx = require("src.rom.gfx")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

local TILES_PER_BANK = 0x4000 / gfx.BYTES_PER_TILE

--- Does this tile look like art?
--
-- The obvious test — uses most of the palette, no single index dominant — is
-- worthless here. Compressed data is close to random, so it satisfies that
-- perfectly, and ranking by it just returns the Pokémon pic banks at 100%.
--
-- What separates art from random bytes is spatial coherence. Neighbouring
-- pixels in a drawing are usually the same colour; in random data they agree
-- about a quarter of the time. Measuring horizontal agreement therefore finds
-- uncompressed graphics specifically, which is what overworld sprites are.
local function tile_is_art(tile)
  local agreements, comparisons = 0, 0
  local uniform = true
  local first = tile[1]

  for row = 0, 7 do
    for column = 1, 7 do
      local i = row * 8 + column
      comparisons = comparisons + 1
      if tile[i] == tile[i + 1] then
        agreements = agreements + 1
      end
    end
  end

  for i = 2, 64 do
    if tile[i] ~= first then
      uniform = false
      break
    end
  end

  -- A blank or solid tile is perfectly coherent and tells us nothing.
  if uniform then
    return false
  end

  return agreements / comparisons > 0.6
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

  local scores = {}
  for bank = 0, rom.banks - 1 do
    local art = 0
    for index = 0, TILES_PER_BANK - 1 do
      local tile = gfx.decode_tile(rom.data, bank * 0x4000 + index * gfx.BYTES_PER_TILE)
      if tile and tile_is_art(tile) then
        art = art + 1
      end
    end
    scores[#scores + 1] = { bank = bank, art = art }
  end

  table.sort(scores, function(a, b) return a.art > b.art end)

  log("banks ranked by how much of them decodes as character art")
  log("(%d tiles per bank)", TILES_PER_BANK)
  for i = 1, math.min(#scores, 16) do
    log("  bank $%02X: %4d art tiles (%d%%)", scores[i].bank, scores[i].art,
      math.floor(scores[i].art / TILES_PER_BANK * 100))
  end

  love.filesystem.createDirectory("dump/ow")
  local written = 0
  for i = 1, math.min(#scores, 6) do
    local bank = scores[i].bank
    local tiles = gfx.decode_tiles(rom.data, bank * 0x4000, 256)
    if tiles then
      local image = gfx.to_image_data(tiles, 16, nil, false)
      love.filesystem.write(("dump/ow/bank%02X.png"):format(bank),
        image:encode("png"):getString())
      written = written + 1
    end
  end
  log("\nwrote %d bank renders to %s/dump/ow",
    written, love.filesystem.getSaveDirectory())

  -- Bank $30 renders as rows of little character frames and bank $3E as the
  -- font, so the sprite graphics live in the $30s. That turns the table search
  -- into a much narrower question: where is there a long run of pointers that
  -- all land in those banks?
  local SPRITE_BANKS = { [0x2F] = true, [0x30] = true, [0x31] = true,
                         [0x32] = true, [0x33] = true, [0x34] = true }

  log("\n== searching for a pointer table into the sprite banks ==")

  local function run_at(offset, stride, bank_at)
    local count = 0
    local at = offset
    while at + stride <= rom.size do
      local addr = rom:u16le(at)
      if addr < 0x4000 or addr > 0x7FFF then
        break
      end
      -- Some layouts carry the bank in the entry; others do not.
      if bank_at and not SPRITE_BANKS[rom:u8(at + bank_at)] then
        break
      end
      count = count + 1
      at = at + stride
    end
    return count
  end

  local candidates = {}
  for _, stride in ipairs { 4, 5, 6, 7, 8 } do
    for _, bank_at in ipairs { false, 2, 3, 4, 5 } do
      if not bank_at or bank_at < stride then
        local best = { length = 0 }
        for offset = 0, rom.size - stride do
          local length = run_at(offset, stride, bank_at)
          if length > best.length then
            best = { length = length, offset = offset }
          end
        end
        candidates[#candidates + 1] = {
          stride = stride, bank_at = bank_at,
          length = best.length, offset = best.offset,
        }
      end
    end
  end

  table.sort(candidates, function(a, b) return a.length > b.length end)

  log("  %-7s %-8s %8s   %s", "stride", "bank at", "entries", "offset")
  for i = 1, math.min(#candidates, 8) do
    local c = candidates[i]
    log("  %-7d %-8s %8d   0x%06X (bank $%02X)", c.stride,
      c.bank_at and tostring(c.bank_at) or "-", c.length, c.offset,
      math.floor(c.offset / 0x4000))
  end

  -- Render what the best bank-carrying candidate points at, so the answer can
  -- be checked by eye rather than by argument.
  local rendered_tables = 0
  for i = 1, #candidates do
    local c = candidates[i]
    if c.bank_at and c.length >= 32 and rendered_tables < 2 then
      rendered_tables = rendered_tables + 1
      log("  rendering table at 0x%06X (stride %d, bank at %d, %d entries)",
        c.offset, c.stride, c.bank_at, c.length)
      -- One sheet holding the first several sprites side by side, which is
      -- easier to judge than a dozen tiny images.
      local columns = 12
      local sheet = love.image.newImageData(columns * 16, 6 * 16)
      for n = 0, columns - 1 do
        local at = c.offset + n * c.stride
        local addr = rom:u16le(at)
        local bank = rom:u8(at + c.bank_at)
        local flat = bank * 0x4000 + (addr - 0x4000)
        if flat + 12 * gfx.BYTES_PER_TILE <= rom.size then
          local tiles = gfx.decode_tiles(rom.data, flat, 12)
          if tiles then
            for index, tile in ipairs(tiles) do
              -- Two tiles wide per frame, frames stacked downwards.
              local tx = n * 16 + ((index - 1) % 2) * 8
              local ty = math.floor((index - 1) / 2) * 8
              for p = 1, 64 do
                local shade = gfx.GREYSCALE[tile[p] + 1]
                sheet:setPixel(tx + (p - 1) % 8, ty + math.floor((p - 1) / 8),
                  shade[1], shade[2], shade[3], 1)
              end
            end
          end
        end
      end
      love.filesystem.write(("dump/ow/table%06X.png"):format(c.offset),
        sheet:encode("png"):getString())
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
