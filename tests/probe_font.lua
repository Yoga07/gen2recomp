-- Diagnostic: find the font and work out where each character sits.
--
-- The bank scan done while hunting overworld sprites rendered bank $3E as
-- readable letters, so the font is there. But it rendered them as 2bpp and the
-- alphabet came out almost-but-not-quite right, which is the signature of 1bpp
-- data read as 2bpp: each pair of glyphs gets merged, one into each bitplane.
--
-- Render it both ways and compare. Then find where 'A' lands, because the
-- charmap puts A at $80 and the tile index has to be derived from that.
--
--   love . --probe-font <rom> <report>

local Rom = require("src.rom.rom")
local gfx = require("src.rom.gfx")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

--- How much ink a tile has, as a fraction. Blank tiles are the gaps between
-- runs of glyphs and are what makes the layout findable.
local function ink(tile)
  local set = 0
  for i = 1, 64 do
    if tile[i] ~= 0 then
      set = set + 1
    end
  end
  return set / 64
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

  love.filesystem.createDirectory("dump/font")

  -- Both readings of the same bytes, side by side.
  for _, bank in ipairs { 0x3E } do
    local base = bank * 0x4000

    local two = gfx.decode_tiles(rom.data, base, 256)
    if two then
      love.filesystem.write(("dump/font/bank%02X_2bpp.png"):format(bank),
        gfx.to_image_data(two, 16, nil, false):encode("png"):getString())
    end

    local one = gfx.decode_tiles_1bpp(rom.data, base, 256)
    if one then
      love.filesystem.write(("dump/font/bank%02X_1bpp.png"):format(bank),
        gfx.to_image_data(one, 16, nil, false):encode("png"):getString())
    end
  end

  -- Where in the bank does the glyph run start and end? Scan as 1bpp and
  -- report ink density so the boundaries are visible.
  log("1bpp tile ink density through bank $3E, in groups of 16 tiles:")
  local base = 0x3E * 0x4000
  local tiles_in_bank = 0x4000 / gfx.BYTES_PER_TILE_1BPP
  for group = 0, math.floor(tiles_in_bank / 16) - 1 do
    local total, blank = 0, 0
    for i = 0, 15 do
      local tile = gfx.decode_tile_1bpp(rom.data,
        base + (group * 16 + i) * gfx.BYTES_PER_TILE_1BPP)
      if tile then
        local density = ink(tile)
        total = total + density
        if density == 0 then
          blank = blank + 1
        end
      end
    end
    if group < 24 then
      log("  tiles %3d-%3d: mean ink %.2f, %d blank",
        group * 16, group * 16 + 15, total / 16, blank)
    end
  end

  -- Per-tile ink for the first 96 tiles. The blank tiles mark the gaps between
  -- glyph runs, which is how the alphabet's index is read off precisely rather
  -- than counted by eye off a 128-pixel-wide image.
  log("\nper-tile ink, bank $3E (blank tiles marked):")
  for row = 0, 5 do
    local cells = {}
    for column = 0, 15 do
      local index = row * 16 + column
      local density = ink_of and 0 or 0
      local tile = gfx.decode_tile_1bpp(rom.data,
        base + index * gfx.BYTES_PER_TILE_1BPP)
      local set = 0
      if tile then
        for i = 1, 64 do
          if tile[i] ~= 0 then set = set + 1 end
        end
      end
      density = set / 64
      cells[#cells + 1] = density == 0 and "  --" or ("%4.2f"):format(density)
    end
    log("  tile %3d: %s", row * 16, table.concat(cells, " "))
  end

  -- Where would the alphabet be for each plausible bias? A correct bias puts
  -- the space on a blank tile and every letter on an inked one.
  log("\nbias check (charmap A=$80, space=$7F):")
  for _, bias in ipairs { 0x40, 0x50, 0x60, 0x70, 0x80 } do
    local space_tile = 0x7F - bias
    local tile = gfx.decode_tile_1bpp(rom.data,
      base + space_tile * gfx.BYTES_PER_TILE_1BPP)
    local space_ink = 0
    if tile then
      for i = 1, 64 do
        if tile[i] ~= 0 then space_ink = space_ink + 1 end
      end
    end

    local letters_ok = 0
    for code = 0x80, 0x99 do
      local letter = gfx.decode_tile_1bpp(rom.data,
        base + (code - bias) * gfx.BYTES_PER_TILE_1BPP)
      local set = 0
      if letter then
        for i = 1, 64 do
          if letter[i] ~= 0 then set = set + 1 end
        end
      end
      if set > 4 and set < 40 then
        letters_ok = letters_ok + 1
      end
    end
    log("  bias $%02X: space tile %3d ink %d, %d of 26 letters plausible",
      bias, space_tile, space_ink, letters_ok)
  end

  -- Decisive test: render a string whose correct appearance is known, once per
  -- candidate bias. Whichever row reads "ROUTE 38" gives the answer directly,
  -- with no inference about which row of the sheet the alphabet starts on.
  local phrase = { 0x91, 0x8E, 0x94, 0x93, 0x84, 0x7F, 0xF9, 0xFE } -- ROUTE 38
  local biases = { 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80 }
  local sheet = love.image.newImageData(#phrase * 8, #biases * 9)

  for row, bias in ipairs(biases) do
    for column, code in ipairs(phrase) do
      local tile = gfx.decode_tile_1bpp(rom.data,
        base + (code - bias) * gfx.BYTES_PER_TILE_1BPP)
      if tile then
        for p = 1, 64 do
          local set = tile[p] ~= 0
          sheet:setPixel(
            (column - 1) * 8 + (p - 1) % 8,
            (row - 1) * 9 + math.floor((p - 1) / 8),
            set and 0 or 1, set and 0 or 1, set and 0 or 1, 1)
        end
      end
    end
  end
  love.filesystem.write("dump/font/biases.png", sheet:encode("png"):getString())
  log("\nbias rows in biases.png, top to bottom: $20 $30 $40 $50 $60 $70 $80")

  -- Render the first 128 glyphs at 16 across so the alphabet's position can be
  -- read straight off the image.
  local strip = gfx.decode_tiles_1bpp(rom.data, base, 128)
  if strip then
    love.filesystem.write("dump/font/glyphs.png",
      gfx.to_image_data(strip, 16, nil, false):encode("png"):getString())
  end

  log("\nwrote renders to %s/dump/font", love.filesystem.getSaveDirectory())

  rom:release()

  local fh = io.open(report_path, "w")
  if fh then
    fh:write(table.concat(report, "\n") .. "\n")
    fh:close()
  end
  return true
end

return probe
