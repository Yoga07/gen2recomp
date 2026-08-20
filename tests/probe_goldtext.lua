-- Diagnostic: which opcode table does Gold actually use?
--
-- Gold overruns its scripts 33 times where Crystal never does, and the project's
-- width inference reads $52 as taking two operand bytes where the pokecrystal
-- table says three. Two bytes is a near pointer and three is a far one, so the
-- question is whether Crystal inserted a command at $52 and shifted everything
-- above it -- in which case Gold's whole upper opcode range means something
-- other than what the table says.
--
-- The test is the one the project already trusts for widths: a wrong width
-- desynchronises the walk, so it sails past the end of the script rather than
-- landing on it. Exact landings and overruns decide this.
--
--   love . --probe-goldtext <rom> <report>

local Rom = require("src.rom.rom")
local tilesets = require("src.rom.tilesets")
local maps = require("src.rom.maps")
local events = require("src.rom.events")
local script_ops = require("src.rom.script_ops")
local script_table = require("src.rom.script_table")

local probe = {}

function probe.run(rom_path, report_path)
  local out = {}
  local function log(fmt, ...)
    out[#out + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
  end

  local rom = Rom.load(rom_path)
  local tileset_result = tilesets.locate(rom)
  local map_result = maps.locate(rom, tileset_result.count)
  local sorted = script_table.collect_entries(rom, map_result, events)
  local widths, terminators = script_ops.widths()

  local function copy(source)
    local result = {}
    for key, value in pairs(source) do
      result[key] = value
    end
    return result
  end

  --- Score a hypothesis and log it.
  local function try(label, trial_widths, trial_terminators)
    local counts = script_table.score(rom, sorted,
      { widths = trial_widths, terminators = trial_terminators })
    log("  %-34s %5d %5d %6d %6d", label, counts.ended, counts.exact,
      counts.unknown, counts.overrun)
    return counts
  end

  --- Everything from `from` upwards means what the table says about the opcode
  -- one higher: the shape the cartridge would have if Crystal inserted a
  -- command at `from`.
  local function shifted(from)
    local w, t = {}, {}
    for opcode = 0, 0xFF do
      local source = opcode >= from and opcode + 1 or opcode
      if widths[source] ~= nil then
        w[opcode] = widths[source]
        t[opcode] = terminators[source]
      end
    end
    return w, t
  end

  log("== how the walks land under each opcode table ==")
  log("  hypothesis                         ended exact blocked overran")
  try("the table as it stands", widths, terminators)

  local only52 = copy(widths)
  only52[0x52] = 2
  try("$52 takes two operand bytes", only52, terminators)

  for _, from in ipairs({ 0x52, 0x53, 0x54 }) do
    local w, t = shifted(from)
    try(("everything from $%02X shifted by one"):format(from), w, t)
  end

  -- A shift that runs to the end of the table would move `end` off $91, and
  -- Gold's scripts do terminate, so the two lists must come back into step
  -- somewhere. This asks where: opcodes in [$52, limit] read as the table's
  -- entry one higher, everything above reads as itself.
  local function partial(limit)
    local w, t = {}, {}
    for opcode = 0, 0xFF do
      local source = (opcode >= 0x52 and opcode <= limit) and opcode + 1 or opcode
      if widths[source] ~= nil then
        w[opcode] = widths[source]
        t[opcode] = terminators[source]
      end
    end
    return w, t
  end

  log("\n== where the two opcode lists come back into step ==")
  local best
  for limit = 0x52, 0xFF do
    local w, t = partial(limit)
    local counts = script_table.score(rom, sorted,
      { widths = w, terminators = t })
    if not best or counts.exact > best.exact then
      best = { exact = counts.exact, limit = limit }
    end
  end
  log("  best: shifting $52 to $%02X", best.limit)
  log("  the whole curve, so a step is visible as a step:")
  log("  limit  ended exact blocked overran")
  local previous
  for limit = 0x52, 0xB4 do
    local w, t = partial(limit)
    local counts = script_table.score(rom, sorted,
      { widths = w, terminators = t })
    -- Only print where the answer moves; a flat stretch says nothing.
    if previous == nil or counts.exact ~= previous then
      log("   $%02X   %5d %5d %6d %6d", limit, counts.ended, counts.exact,
        counts.unknown, counts.overrun)
      previous = counts.exact
    end
  end

  rom:release()
  local fh = io.open(report_path, "w")
  fh:write(table.concat(out, "\n") .. "\n")
  fh:close()
  return true
end

return probe
