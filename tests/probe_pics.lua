-- Diagnostic: compare candidate starts for the Pokémon pic pointer table.
--
-- The locator settled on $120084, but $120000 also produces valid front sizes
-- and sits exactly 22 entries earlier — and the table found at $120084 runs off
-- the end of the real data, failing to resolve back pointers for species 179
-- and 230-233. That is the signature of a table start that is too late.
--
-- The locator scans upward and returns the first offset that validates, so
-- $120000 must be failing a check. The only constraint the front sizes do not
-- cover is the back-sprite rule, which assumes every back pic decompresses to
-- exactly 6x6. Print both candidates side by side and find out.
--
--   love . --probe-pics <rom> <report>

local Rom = require("src.rom.rom")
local locate = require("src.rom.locate")
local lz = require("src.rom.lz")
local gfx = require("src.rom.gfx")
local pics = require("src.rom.pics")

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

  local stats = locate.table(locate.descriptors.base_stats, rom).records
  local names = locate.table(locate.descriptors.species_names, rom).records

  for _, base in ipairs { 0x120000, 0x120084 } do
    log("== candidate table at 0x%06X ==", base)
    log("  %-4s %-11s %-7s %10s %10s   %s",
      "spc", "name", "shape", "front", "back", "verdict")

    for species = 1, 20 do
      local entry = base + (species - 1) * 6
      local record = stats[species]
      local base_tiles = record.sprite_width * record.sprite_height

      local front_at = pics.resolve(rom, entry, pics.DEFAULT_BIAS)
      local back_at = pics.resolve(rom, entry + 3, pics.DEFAULT_BIAS)

      local front = front_at and lz.decompress(rom.data, front_at)
      local back = back_at and lz.decompress(rom.data, back_at)

      local front_tiles = front and (#front / gfx.BYTES_PER_TILE) or -1
      local back_tiles = back and (#back / gfx.BYTES_PER_TILE) or -1

      local verdict = {}
      if not front then
        verdict[#verdict + 1] = "front failed"
      elseif front_tiles < base_tiles then
        verdict[#verdict + 1] = ("front short by %d"):format(base_tiles - front_tiles)
      end
      if not back then
        verdict[#verdict + 1] = "back failed"
      elseif back_tiles ~= pics.BACK_TILES then
        verdict[#verdict + 1] = ("back is %d tiles"):format(back_tiles)
      end

      log("  %-4d %-11s %dx%-5d %10s %10s   %s",
        species, names[species] or "?",
        record.sprite_width, record.sprite_height,
        front and ("%d t"):format(front_tiles) or "fail",
        back and ("%d t"):format(back_tiles) or "fail",
        #verdict > 0 and table.concat(verdict, ", ") or "ok")
    end
    log("")
  end

  -- How far does each candidate hold up across the whole species range?
  for _, base in ipairs { 0x120000, 0x120084 } do
    local front_ok, back_ok, back_sizes = 0, 0, {}
    for species = 1, 251 do
      local entry = base + (species - 1) * 6
      local record = stats[species]
      local base_tiles = record.sprite_width * record.sprite_height

      local front_at = pics.resolve(rom, entry, pics.DEFAULT_BIAS)
      local front = front_at and lz.decompress(rom.data, front_at)
      if front and #front / gfx.BYTES_PER_TILE >= base_tiles then
        front_ok = front_ok + 1
      end

      local back_at = pics.resolve(rom, entry + 3, pics.DEFAULT_BIAS)
      local back = back_at and lz.decompress(rom.data, back_at)
      if back then
        local tiles = #back / gfx.BYTES_PER_TILE
        back_sizes[tiles] = (back_sizes[tiles] or 0) + 1
        if tiles == pics.BACK_TILES then
          back_ok = back_ok + 1
        end
      end
    end

    local distribution = {}
    for tiles, count in pairs(back_sizes) do
      distribution[#distribution + 1] = ("%dt:%d"):format(tiles, count)
    end
    table.sort(distribution)

    log("0x%06X over all 251: fronts ok %d, backs exactly 6x6 %d",
      base, front_ok, back_ok)
    log("  back size distribution: %s", table.concat(distribution, " "))
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
