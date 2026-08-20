-- Diagnostic: why does the pic table not locate on a Gold cartridge?
--
-- The locator finds it in Crystal and returns "no offset validated as a pic
-- pointer table" for Gold. That is the right failure to have — it refuses
-- rather than guessing — but it says nothing about which of its assumptions is
-- the wrong one, and there are several: the stride, the bias, the size a front
-- pic decompresses to, and whether the fronts and backs are interleaved at all.
--
-- So this reports how far a candidate gets rather than whether it passes.
-- Something that verifies nine species and then stops is a table with one
-- assumption wrong; something that verifies none is a table that is not there.
--
--   love . --probe-picsearch <rom> <report>

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

local function write(path)
  local fh = io.open(path, "w")
  if fh then
    fh:write(table.concat(report, "\n") .. "\n")
    fh:close()
  end
end

--- How many species verify in a row from this offset under this bias.
-- @param stride 6 when fronts and backs are interleaved, 3 when the backs live
--        in a table of their own
local function depth(rom, offset, bias, stats, stride, limit, want_back)
  for species = 1, limit do
    local entry = offset + (species - 1) * stride
    if entry + stride > rom.size then
      return species - 1
    end
    local record = stats[species]
    local base = record.sprite_width * record.sprite_height
      * gfx.BYTES_PER_TILE
    if base == 0 then
      return species - 1
    end

    local front_at = pics.resolve(rom, entry, bias)
    if not front_at then
      return species - 1
    end
    local front = lz.decompress(rom.data, front_at)
    if not front or #front < base or #front % gfx.BYTES_PER_TILE ~= 0 then
      return species - 1
    end

    if want_back then
      local back_at = pics.resolve(rom, entry + 3, bias)
      if not back_at then
        return species - 1
      end
      local back = lz.decompress(rom.data, back_at)
      if not back or #back ~= pics.BACK_BYTES then
        return species - 1
      end
    end
  end
  return limit
end

function probe.run(rom_path, report_path)
  report = {}

  local rom, err = Rom.load(rom_path)
  if not rom then
    log("FATAL: %s", err)
    write(report_path)
    return true
  end

  local stats = locate.table(locate.descriptors.base_stats, rom)
  if not stats then
    log("FATAL: the base stats did not locate")
    rom:release()
    write(report_path)
    return true
  end
  stats = stats.records

  log("species 1 is %dx%d, so its front is %d bytes before any animation",
    stats[1].sprite_width, stats[1].sprite_height,
    stats[1].sprite_width * stats[1].sprite_height * gfx.BYTES_PER_TILE)

  -- Bank boundaries were the first guess, because Crystal's table starts on
  -- one. Gold's does not, so narrow by shape first: a pointer table is a long
  -- run of three-byte entries whose addresses all sit in the switchable window,
  -- and that is cheap to test and rare enough to leave only a handful of
  -- places worth paying for a decompression at.
  log("\n== long runs of three-byte entries with switchable addresses ==")
  local runs = {}
  do
    local offset = 0
    while offset < rom.size - 3 do
      local addr = rom:u16le(offset + 1)
      if addr >= 0x4000 and addr <= 0x7FFF then
        local start, count = offset, 0
        while offset < rom.size - 3 do
          local a = rom:u16le(offset + 1)
          if a < 0x4000 or a > 0x7FFF then
            break
          end
          count = count + 1
          offset = offset + 3
        end
        if count >= 200 then
          runs[#runs + 1] = { at = start, count = count }
        end
      else
        offset = offset + 1
      end
    end
  end
  table.sort(runs, function(a, b) return a.count > b.count end)
  log("  %d runs of 200 or more", #runs)
  for index = 1, math.min(#runs, 8) do
    log("    0x%06X  %d entries", runs[index].at, runs[index].count)
  end

  -- Now pay for the decompressions, but only at the starts of those runs and
  -- at every three-byte position inside the first few of them, since a table
  -- need not begin where its run of valid addresses does.
  log("\n== how far each gets, over every bias ==")
  local best = { depth = 0 }
  local fronts = { depth = 0 }
  local three = { depth = 0 }
  -- Every three-byte position in every run, and a few before each one starts:
  -- a table need not begin where its run of valid addresses does, and Gold's
  -- run begins three bytes into a bank, which is suspicious enough to look
  -- behind. Species 1 is checked first and alone, because it costs one
  -- decompression and throws almost everything out; only survivors are
  -- deepened.
  for _, run in ipairs(runs) do
    for step = -2, run.count - 1 do
      local offset = run.at + step * 3
      if offset >= 0 then
        for bias = 0, 0x7F do
          if depth(rom, offset, bias, stats, 3, 1, false) == 1 then
            local paired = depth(rom, offset, bias, stats, 6, 24, true)
            if paired > best.depth then
              best = { depth = paired, offset = offset, bias = bias,
                       stride = 6 }
            end
            local only = depth(rom, offset, bias, stats, 6, 24, false)
            if only > fronts.depth then
              fronts = { depth = only, offset = offset, bias = bias,
                         stride = 6 }
            end
            local flat = depth(rom, offset, bias, stats, 3, 24, false)
            if flat > three.depth then
              three = { depth = flat, offset = offset, bias = bias,
                        stride = 3 }
            end
          end
        end
      end
    end
  end
  log("  interleaved, backs checked : %d species at 0x%06X bias $%02X",
    best.depth, best.offset or 0, best.bias or 0)
  log("  interleaved, fronts only   : %d species at 0x%06X bias $%02X",
    fronts.depth, fronts.offset or 0, fronts.bias or 0)
  log("  stride 3, fronts only      : %d species at 0x%06X bias $%02X",
    three.depth, three.offset or 0, three.bias or 0)

  -- Whatever got furthest, show the entry that stopped it.
  local winner = best
  if fronts.depth > winner.depth then winner = fronts end
  if three.depth > winner.depth then winner = three end
  if winner.depth > 0 and winner.offset then
    local stride = winner.stride or (winner == three and 3 or 6)
    log("\n== the first entries at 0x%06X, bias $%02X, stride %d ==",
      winner.offset, winner.bias, stride)
    for species = 1, math.min(winner.depth + 6, 20) do
      local entry = winner.offset + (species - 1) * stride
      local bank = rom:u8(entry)
      local addr = rom:u16le(entry + 1)
      local at = pics.resolve(rom, entry, winner.bias)
      local data = at and lz.decompress(rom.data, at)
      local base = stats[species].sprite_width * stats[species].sprite_height
        * gfx.BYTES_PER_TILE
      log("  %3d  $%02X:$%04X -> %s  wanted at least %d, got %s", species,
        bank, addr, at and ("0x%06X"):format(at) or "unresolvable", base,
        data and tostring(#data) or "no decompression")
    end
  end

  rom:release()
  write(report_path)
  return true
end

return probe
