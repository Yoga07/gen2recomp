-- Render every front sprite into one contact sheet, so the pic table can be
-- checked by eye rather than by decompressed size alone.
--
-- Sizes are a weak test: a pointer into the wrong bank that happens to land on
-- another species' pic decodes perfectly and is still wrong. A sheet of 251
-- recognisable Pokemon in Pokedex order is a much stronger one, and the entries
-- whose banks had to be solved for should be indistinguishable from the rest.
--
--   love . --probe-sheet <rom> <out.png>

local Rom = require("src.rom.rom")
local locate = require("src.rom.locate")
local pics = require("src.rom.pics")
local palettes = require("src.rom.palettes")

local probe = {}

local CELL = 7 * 8 -- the largest sprite is 7x7 tiles
local COLUMNS = 16

function probe.run(rom_path, out_path)
  local rom = Rom.load(rom_path)
  local stats = locate.table(locate.descriptors.base_stats, rom).records
  local table_info, why = pics.locate(rom, stats)
  if not table_info then
    print("pic table did not locate: " .. tostring(why))
    return true
  end
  local palette_result = palettes.locate(rom)

  local rows = math.ceil(251 / COLUMNS)
  local sheet = love.image.newImageData(COLUMNS * CELL, rows * CELL)

  for species = 1, 251 do
    if species ~= pics.UNOWN_SPECIES then
      local tiles = pics.decode_front(rom, table_info, species, stats)
      if tiles then
        local record = stats[species]
        local palette = palette_result
          and palettes.to_rgb(palette_result.records[species].normal)
        local image = pics.to_image_data(tiles, record.sprite_width,
          record.sprite_height, palette, false)
        local cell = species - 1
        sheet:paste(image, (cell % COLUMNS) * CELL,
          math.floor(cell / COLUMNS) * CELL, 0, 0,
          image:getWidth(), image:getHeight())
      end
    end
  end

  local fh = io.open(out_path, "wb")
  fh:write(sheet:encode("png"):getString())
  fh:close()
  rom:release()
  return true
end

return probe
