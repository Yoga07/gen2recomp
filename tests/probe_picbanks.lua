-- Diagnostic: solve the pic table's bank mapping one stored bank at a time.
--
-- No single bias decodes Gold's table: bias 0 gets 197 of 251 fronts and the
-- rest want $0C or $0F. That means the cartridge does not add one constant to
-- every bank byte, so the question is not "which constant" but "does each
-- stored bank byte have a physical bank under which every one of its entries
-- decodes". A stored bank with 26 entries that all decode at one physical bank
-- and nowhere else is not a coincidence; a stored bank with several such banks,
-- or none, is a wrong reading.
--
--   love . --probe-picbanks <rom> <report> [base]

local Rom = require("src.rom.rom")
local locate = require("src.rom.locate")
local lz = require("src.rom.lz")
local gfx = require("src.rom.gfx")
local pics = require("src.rom.pics")

local probe = {}

function probe.run(rom_path, report_path, arg)
  local out = {}
  local function log(fmt, ...)
    out[#out + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
  end

  local rom = Rom.load(rom_path)
  local stats = locate.table(locate.descriptors.base_stats, rom).records
  local base = tonumber(arg or "0x048000")

  -- Every pointer in the table, tagged with the size its target must decode to.
  local entries = {}
  for species = 1, 251 do
    local at = base + (species - 1) * 6
    local want = stats[species].sprite_width * stats[species].sprite_height
      * gfx.BYTES_PER_TILE
    entries[#entries + 1] = { at = at, species = species, kind = "front",
      least = want }
    entries[#entries + 1] = { at = at + 3, species = species, kind = "back",
      exact = pics.BACK_BYTES }
  end

  local function decodes(entry, bank)
    local addr = rom:u16le(entry.at + 1)
    if addr < 0x4000 or addr > 0x7FFF then return false end
    local flat = bank * 0x4000 + (addr - 0x4000)
    if flat + 2 > rom.size then return false end
    local data = lz.decompress(rom.data, flat)
    if not data then return false end
    if entry.exact then return #data == entry.exact end
    return #data >= entry.least and #data % gfx.BYTES_PER_TILE == 0
  end

  -- Group by stored bank byte.
  local groups = {}
  for _, entry in ipairs(entries) do
    local bank = rom:u8(entry.at)
    groups[bank] = groups[bank] or {}
    table.insert(groups[bank], entry)
  end

  local keys = {}
  for bank in pairs(groups) do keys[#keys + 1] = bank end
  table.sort(keys)

  log("== stored bank -> physical banks that decode all of its entries ==")
  for _, stored in ipairs(keys) do
    local group = groups[stored]
    local perfect, best, best_count = {}, nil, -1
    for bank = 0, 127 do
      local hits = 0
      for _, entry in ipairs(group) do
        if decodes(entry, bank) then hits = hits + 1 end
      end
      if hits > best_count then best, best_count = bank, hits end
      if hits == #group then perfect[#perfect + 1] = bank end
    end
    local shown = {}
    for index, bank in ipairs(perfect) do shown[index] = ("$%02X"):format(bank) end
    log("  $%02X  %3d entries  all decode at: %s   (best otherwise $%02X, %d)",
      stored, #group,
      #perfect > 0 and table.concat(shown, " ") or "-- none --",
      best, best_count)
  end

  rom:release()
  local fh = io.open(report_path, "w")
  fh:write(table.concat(out, "\n") .. "\n")
  fh:close()
  return true
end

return probe
