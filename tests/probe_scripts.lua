-- Diagnostic: work out Crystal's script bytecode well enough to walk it.
--
-- What is known: $53 shows a text block and ends the script, $4C shows one and
-- continues. That reads 175 of 2200 scripts, because it only ever looks at the
-- first instruction.
--
-- To walk further, each opcode's operand width has to be known, and there is no
-- table for that. Two things make it recoverable. Scripts are stored back to
-- back, so sorting the entry points within a bank gives each script's extent
-- from the gap to the next one. And a correct set of widths is one where
-- walking a script consumes its extent exactly and stops on a terminator —
-- wrong widths desynchronise and overshoot.
--
-- This gathers the evidence: what scripts open with, how long they are, and
-- what follows the instructions already understood.
--
--   love . --probe-scripts <rom> <report>

local Rom = require("src.rom.rom")
local tilesets = require("src.rom.tilesets")
local maps = require("src.rom.maps")
local events = require("src.rom.events")
local text = require("src.rom.text")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

local function ranked(counts, limit)
  local list = {}
  for value, count in pairs(counts) do
    list[#list + 1] = { value = value, count = count }
  end
  table.sort(list, function(a, b) return a.count > b.count end)
  local parts = {}
  for i = 1, math.min(#list, limit or 12) do
    parts[#parts + 1] = ("$%02X x%d"):format(list[i].value, list[i].count)
  end
  return table.concat(parts, "  "), list
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

  local tileset_result = tilesets.locate(rom)
  local map_result = maps.locate(rom, tileset_result.count)

  -- Every script entry point in the game, grouped by the bank it lives in.
  local by_bank = {}
  local entries = 0
  for _, header in ipairs(map_result.headers) do
    local decoded = not header.unparsed and events.decode(rom, header)
    if decoded then
      local bank = math.floor(header.attributes.scripts / 0x4000)
      by_bank[bank] = by_bank[bank] or {}
      for _, group in ipairs { decoded.bg_events, decoded.objects } do
        for _, item in ipairs(group) do
          if item.script then
            local flat = bank * 0x4000 + (item.script - 0x4000)
            if flat < rom.size then
              by_bank[bank][flat] = true
              entries = entries + 1
            end
          end
        end
      end
    end
  end

  local banks = 0
  for _ in pairs(by_bank) do
    banks = banks + 1
  end
  log("%d script pointers across %d banks", entries, banks)

  -- What do scripts open with?
  local openers = {}
  local unique = 0
  local sorted_by_bank = {}
  for bank, set in pairs(by_bank) do
    local list = {}
    for flat in pairs(set) do
      list[#list + 1] = flat
      unique = unique + 1
      openers[rom:u8(flat)] = (openers[rom:u8(flat)] or 0) + 1
    end
    table.sort(list)
    sorted_by_bank[bank] = list
  end

  log("%d distinct script addresses", unique)
  local opener_text = ranked(openers, 14)
  log("\nopening opcodes:\n  %s", opener_text)

  -- Script extents, from the gap to the next script in the same bank. Only
  -- meaningful where scripts really are contiguous, so the distribution of
  -- gaps is itself the evidence.
  local gaps = {}
  for _, list in pairs(sorted_by_bank) do
    for i = 1, #list - 1 do
      local gap = list[i + 1] - list[i]
      if gap > 0 and gap <= 64 then
        gaps[gap] = (gaps[gap] or 0) + 1
      end
    end
  end
  log("\ngaps between consecutive script addresses (bytes):\n  %s", ranked(gaps, 14))

  -- For scripts opening with an instruction we understand, what comes next?
  -- $53 takes two operand bytes, $4C likewise.
  for _, opcode in ipairs { 0x53, 0x4C } do
    local following = {}
    local count = 0
    for _, list in pairs(sorted_by_bank) do
      for _, flat in ipairs(list) do
        if rom:u8(flat) == opcode and flat + 4 < rom.size then
          count = count + 1
          following[rom:u8(flat + 3)] = (following[rom:u8(flat + 3)] or 0) + 1
        end
      end
    end
    log("\nbyte after a $%02X instruction (%d scripts):\n  %s",
      opcode, count, ranked(following, 12))
  end

  -- A first guess at terminators: bytes that appear immediately before the
  -- next script begins.
  local before_next = {}
  for _, list in pairs(sorted_by_bank) do
    for i = 1, #list - 1 do
      if list[i + 1] - list[i] <= 64 then
        before_next[rom:u8(list[i + 1] - 1)] =
          (before_next[rom:u8(list[i + 1] - 1)] or 0) + 1
      end
    end
  end
  log("\nbyte immediately before the next script starts:\n  %s",
    ranked(before_next, 12))

  -- Classify each common opening opcode by what its two-byte operand points
  -- at. A text pointer means the opcode shows a message; a pointer to another
  -- known script address means it is a jump worth following; neither means the
  -- operand is an id or a flag rather than an address.
  log("\n== what the operand at +1 points at ==")
  log("  %-6s %7s %7s %7s %7s", "opcode", "total", "text", "script", "other")

  for _, opcode in ipairs { 0x51, 0x6B, 0x53, 0x0C, 0x47, 0x9B, 0x31, 0x34 } do
    local total, to_text, to_script, other = 0, 0, 0, 0

    for bank, list in pairs(sorted_by_bank) do
      local known = by_bank[bank]
      for _, flat in ipairs(list) do
        if rom:u8(flat) == opcode and flat + 3 <= rom.size then
          total = total + 1
          local addr = rom:u16le(flat + 1)
          if addr >= 0x4000 and addr <= 0x7FFF then
            local target = bank * 0x4000 + (addr - 0x4000)
            if text.decode_dialogue(rom.data, target) then
              to_text = to_text + 1
            elseif known[target] then
              to_script = to_script + 1
            else
              other = other + 1
            end
          else
            other = other + 1
          end
        end
      end
    end

    log("  $%02X    %7d %7d %7d %7d", opcode, total, to_text, to_script, other)
  end

  -- Raw dumps of a few short scripts, for reading by eye.
  log("\n== short scripts, whole ==")
  local shown = 0
  for _, list in pairs(sorted_by_bank) do
    for i = 1, #list - 1 do
      local length = list[i + 1] - list[i]
      if length >= 3 and length <= 12 and shown < 14 then
        shown = shown + 1
        local raw = {}
        for j = 0, length - 1 do
          raw[#raw + 1] = ("%02X"):format(rom:u8(list[i] + j))
        end
        log("  0x%06X (%2d bytes): %s", list[i], length, table.concat(raw, " "))
      end
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
