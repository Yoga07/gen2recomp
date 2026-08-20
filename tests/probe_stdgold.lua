-- Diagnostic: what separates the real standard-script table from every other
-- run of same-bank pointers, measured on more than one cartridge.
--
-- The locator scores each entry with std_scripts.script_at, which demands three
-- instructions and a meaningful command. That is calibrated on Crystal, where
-- 37 of 52 entries clear it. Gold's standard scripts are much shorter -- many
-- are a single farjumptext -- so only 13 of its 46 do, and the locator's "half
-- the entries must be routines" rule rejects the real table.
--
-- Rather than guess a lower threshold, this measures two scores for every
-- candidate: how many targets decode as any valid instruction sequence at all,
-- and how many clear the strict rule. It then reports the best candidate that
-- does not overlap the winner, since that -- not a shifted copy of the winner
-- itself -- is what a wrong answer actually scores.
--
--   love . --probe-stdgold <rom> <report>

local Rom = require("src.rom.rom")
local script_ops = require("src.rom.script_ops")
local std_scripts = require("src.rom.std_scripts")

local probe = {}

function probe.run(rom_path, report_path)
  local out = {}
  local function log(fmt, ...)
    out[#out + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
  end
  local function row_line(row)
    log("    0x%06X  $%02X   %3d      %3d (%3d%%)     %3d (%3d%%)", row.offset,
      row.bank, row.count, row.decoded,
      math.floor(row.decoded * 100 / row.count), row.routines,
      math.floor(row.routines * 100 / row.count))
  end

  local rom = Rom.load(rom_path)
  local widths, terminators = script_ops.widths()
  local banks = math.floor(rom.size / 0x4000)

  --- Does anything at all decode here -- a valid instruction sequence that
  -- reaches a terminator? No minimum length, no meaningful command required.
  local function decodes(bank, addr)
    if addr < 0x4000 or addr > 0x7FFF then
      return false
    end
    local at = bank * 0x4000 + (addr - 0x4000)
    if at >= rom.size then
      return false
    end
    for _ = 1, 300 do
      if at + 1 > rom.size then
        return false
      end
      local opcode = rom:u8(at)
      local width = widths[opcode]
      if width == nil then
        return false
      end
      if terminators[opcode] then
        return true
      end
      at = at + 1 + width
    end
    return false
  end

  --- The longest run of same-bank pointers from here, as the locator counts it.
  local function run_from(offset)
    local first = rom:u8(offset)
    if first >= banks then
      return 0
    end
    local count = 0
    while count < std_scripts.MAX_ENTRIES do
      local at = offset + count * 3
      if at + 3 > rom.size then
        break
      end
      local addr = rom:u16le(at + 1)
      if rom:u8(at) ~= first or addr < 0x4000 or addr > 0x7FFF then
        break
      end
      count = count + 1
    end
    return count
  end

  local rows = {}
  local offset = 0
  while offset <= rom.size - std_scripts.MINIMUM * 3 do
    local count = run_from(offset)
    if count >= std_scripts.MINIMUM then
      local bank = rom:u8(offset)
      local decoded, routines = 0, 0
      for index = 0, count - 1 do
        local addr = rom:u16le(offset + index * 3 + 1)
        if decodes(bank, addr) then
          decoded = decoded + 1
        end
        if std_scripts.script_at(rom, bank, addr, widths, terminators) then
          routines = routines + 1
        end
      end
      rows[#rows + 1] = { offset = offset, bank = bank, count = count,
        decoded = decoded, routines = routines }
    end
    offset = offset + 1
  end

  log("== same-bank runs of %d or more: %d qualify on shape alone ==",
    std_scripts.MINIMUM, #rows)
  if #rows == 0 then
    log("  nothing to rank; this cartridge has no such run")
    rom:release()
    local fh = io.open(report_path, "w")
    fh:write(table.concat(out, "\n") .. "\n")
    fh:close()
    return true
  end

  -- Rank by how many entries look like routines, counted rather than
  -- proportioned. A proportion prefers a table with its first entries shaved
  -- off, since the entries failing the strict rule tend to sit at the front; a
  -- count keeps the true start on top.
  table.sort(rows, function(a, b)
    if a.routines ~= b.routines then
      return a.routines > b.routines
    end
    return a.count > b.count
  end)

  log("  offset      bank  entries  decode        strict rule")
  for index = 1, math.min(#rows, 8) do
    row_line(rows[index])
  end

  local winner = rows[1]
  local last = winner.offset + winner.count * 3
  log("\n== best candidates that do not overlap the winner ==")
  local shown = 0
  for _, row in ipairs(rows) do
    if row.offset + row.count * 3 <= winner.offset or row.offset >= last then
      row_line(row)
      shown = shown + 1
      if shown >= 4 then
        break
      end
    end
  end
  if shown == 0 then
    log("    none: every other run is a shifted copy of the winner")
  end

  -- The property both known tables share: the run begins at the very start of
  -- the bank all its entries name. The sound-effect table, which is the best
  -- unrelated candidate on both cartridges, has neither half of that.
  log("\n== candidates anchored to the start of the bank they name ==")
  local anchored = 0
  for _, row in ipairs(rows) do
    if row.offset % 0x4000 == 0 and math.floor(row.offset / 0x4000) == row.bank then
      row_line(row)
      anchored = anchored + 1
    end
  end
  log("    %d anchored candidate(s)", anchored)

  log("\n  the winner scores %d of %d", winner.routines, winner.count)
  log("  it starts at a bank boundary: %s", tostring(winner.offset % 0x4000 == 0))
  log("  it sits in bank $%02X and its entries all name bank $%02X",
    math.floor(winner.offset / 0x4000), winner.bank)

  rom:release()
  local fh = io.open(report_path, "w")
  fh:write(table.concat(out, "\n") .. "\n")
  fh:close()
  return true
end

return probe
