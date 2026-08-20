-- Diagnostic: where is the table of standard scripts?
--
-- jumpstd and callstd end 278 scripts between them. Their operand is a word,
-- but the opcode table treats it as a pointer and it does not behave like one:
-- if it is really an index into a table of common routines, the values will be
-- small and tightly packed rather than spread across a bank.
--
-- This checks that first, then looks for the table those indices point into.
--
--   love . --probe-stdscripts <rom> <report>

local Rom = require("src.rom.rom")
local tilesets = require("src.rom.tilesets")
local maps = require("src.rom.maps")
local events = require("src.rom.events")
local script_ops = require("src.rom.script_ops")
local script_decode = require("src.rom.script_decode")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

local JUMPSTD, CALLSTD = 0x0C, 0x0D

function probe.run(rom_path, report_path, extra)
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

  local entries = {}
  for _, header in ipairs(map_result.headers) do
    local decoded = not header.unparsed and events.decode(rom, header)
    if decoded then
      local bank = math.floor(header.attributes.scripts / 0x4000)
      for _, bg in ipairs(decoded.bg_events) do
        if bg.script and bg.kind ~= events.BGEVENT_ITEM then
          entries[#entries + 1] = { bank = bank, addr = bg.script }
        end
      end
      for _, object in ipairs(decoded.objects) do
        if object.script and object.kind ~= events.OBJECT_TRAINER
          and object.kind ~= events.OBJECT_ITEM then
          entries[#entries + 1] = { bank = bank, addr = object.script }
        end
      end
      for _, coord in ipairs(decoded.coord_events) do
        if coord.script then
          entries[#entries + 1] = { bank = bank, addr = coord.script }
        end
      end
    end
  end

  local code = script_decode.reachable(rom, entries)

  local used, occurrences, highest = {}, 0, -1
  for _, block in pairs(code) do
    for _, instruction in pairs(block) do
      if instruction.opcode == JUMPSTD or instruction.opcode == CALLSTD then
        local value = (instruction.args[1] or 0)
          + (instruction.args[2] or 0) * 256
        used[value] = (used[value] or 0) + 1
        occurrences = occurrences + 1
        -- A handful of operands come back in the thousands. Five out of 211,
        -- against 26 values that sit between 0 and 51, so they are misparsed
        -- rather than evidence that the operand is an address. Bounding the
        -- search stops them dictating how big the table has to be.
        if value <= 200 then
          highest = math.max(highest, value)
        end
      end
    end
  end

  local distinct = 0
  for _ in pairs(used) do distinct = distinct + 1 end
  log("%d jumpstd/callstd commands, %d distinct operands, highest %d",
    occurrences, distinct, highest)

  local ordered = {}
  for value, count in pairs(used) do
    ordered[#ordered + 1] = { value = value, count = count }
  end
  table.sort(ordered, function(a, b) return a.value < b.value end)
  local parts = {}
  for i = 1, math.min(#ordered, 40) do
    parts[#parts + 1] = ("%d x%d"):format(ordered[i].value, ordered[i].count)
  end
  log("  operands: %s", table.concat(parts, ", "))

  if highest < 0 or highest > 200 then
    log("\nthese do not look like indices; stopping")
    rom:release()
    local fh = io.open(report_path, "w")
    if fh then fh:write(table.concat(report, "\n") .. "\n") fh:close() end
    return true
  end

  -- The table has to hold at least `highest + 1` entries. Two shapes are
  -- plausible: three bytes of bank-then-address, or two bytes of near pointer
  -- within whatever bank the table itself sits in.
  local widths, terminators = script_ops.widths()

  -- Commands that make a run of bytes a script rather than a coincidence.
  -- "Reaches a terminator" is far too weak on its own: two instructions can do
  -- that, and a pointer aimed at any byte that happens to be $91 passes. That
  -- weakness produced two confident false tables before this was tightened.
  local MEANINGFUL = {
    [0x47] = true, [0x49] = true, -- opentext, closetext
    [0x4B] = true, [0x4C] = true, -- farwritetext, writetext
    [0x51] = true, [0x52] = true, [0x53] = true, -- the jumptexts
    [0x31] = true, [0x32] = true, [0x33] = true, -- checkevent, clearevent, setevent
    [0x1F] = true, [0x9E] = true, -- giveitem, verbosegiveitem
    [0x0F] = true, -- special
    [0x54] = true, [0x55] = true, -- waitbutton, promptbutton
  }

  --- Does a real script decode from here?
  -- @return instruction count, or nil
  local function script_at(bank, addr)
    if addr < 0x4000 or addr > 0x7FFF then
      return nil
    end
    local at = bank * 0x4000 + (addr - 0x4000)
    if at >= rom.size then
      return nil
    end
    local count, meaningful = 0, false
    for _ = 1, 300 do
      if at + 1 > rom.size then
        return nil
      end
      local opcode = rom:u8(at)
      local width = widths[opcode]
      if width == nil then
        return nil
      end
      count = count + 1
      if MEANINGFUL[opcode] then
        meaningful = true
      end
      if terminators[opcode] then
        -- A standard script is a routine, not a two-instruction stub, and it
        -- has to do something recognisable.
        if count >= 3 and meaningful then
          return count
        end
        return nil
      end
      at = at + 1 + width
    end
    return nil
  end

  local need = highest + 1
  log("\nlooking for a table of at least %d entries", need)

  for _, shape in ipairs({ "bank first", "address first", "near" }) do
    local best = { count = 0 }
    for offset = 0, rom.size - need * 3 do
      local count = 0
      local seen, targets, lengths = {}, {}, {}
      while true do
        local at = offset + count * (shape == "near" and 2 or 3)
        local bank, addr
        if shape == "bank first" then
          bank, addr = rom:u8(at), rom:u16le(at + 1)
        elseif shape == "address first" then
          addr, bank = rom:u16le(at), rom:u8(at + 2)
        else
          bank, addr = math.floor(offset / 0x4000), rom:u16le(at)
        end
        local length = script_at(bank, addr)
        if not length then
          break
        end
        count = count + 1
        seen[bank * 0x10000 + addr] = true
        targets[count] = addr
        lengths[count] = length
        if count > 300 then
          break
        end
      end

      if count > best.count then
        local distinct = 0
        for _ in pairs(seen) do distinct = distinct + 1 end
        -- Real routines differ in length and sit at irregular addresses. A run
        -- whose targets march in a constant step is a uniform data table, and
        -- one whose entries all point at the same place is not a table at all.
        local uniform = true
        for i = 3, count do
          if targets[i] - targets[i - 1] ~= targets[2] - targets[1] then
            uniform = false
            break
          end
        end
        best = { count = count, offset = offset, distinct = distinct,
                 uniform = count > 2 and uniform }
      end
    end

    log("  %-14s longest run %3d at 0x%06X, %s distinct%s", shape, best.count,
      best.offset or 0, tostring(best.distinct),
      best.uniform and ", evenly spaced (a data table, not scripts)" or "")
    if best.count >= need and not best.uniform
      and (best.distinct or 0) >= need * 0.6 then
      log("    that covers every index used, and looks like scripts")
    end
  end

  -- Three candidates cannot all be right. What settles it is reading the
  -- scripts each one points at: standard scripts are the game's common
  -- routines, so their text should be recognisable.
  local text = require("src.rom.text")
  local function first_text(bank, addr)
    if addr < 0x4000 or addr > 0x7FFF then
      return "-"
    end
    local at = bank * 0x4000 + (addr - 0x4000)
    for _ = 1, 60 do
      if at + 1 > rom.size then
        return "-"
      end
      local opcode = rom:u8(at)
      local width = widths[opcode]
      if width == nil then
        return "-"
      end
      local near = script_ops.text_commands[opcode]
      local far = script_ops.far_text_commands[opcode]
      local text_bank, text_addr
      if near then
        text_bank, text_addr = bank, rom:u16le(at + 1)
      elseif far then
        text_bank, text_addr = rom:u8(at + 1), rom:u16le(at + 2)
      end
      if text_addr and text_addr >= 0x4000 and text_addr <= 0x7FFF then
        local flat = text_bank * 0x4000 + (text_addr - 0x4000)
        if flat < rom.size then
          local block = text.decode_dialogue(rom.data, flat)
          if block then
            return text.flatten(block):sub(1, 40)
          end
        end
      end
      if terminators[opcode] then
        return "(no text)"
      end
      at = at + 1 + width
    end
    return "-"
  end

  -- The one run that survived the tightening, read out in full so its entries
  -- can be judged rather than counted.
  local _, _, names = script_ops.widths()
  -- Which run to read out in full. Crystal's table by default; pass another
  -- offset to read a candidate found on a different cartridge.
  local TABLE = tonumber(extra) or 0x0BC042

  -- The run-finder reports where a valid run begins, which is not necessarily
  -- where the table begins: an entry the validator is too strict for would cut
  -- the front off. Walking backwards from the run shows the real start.
  log("\nwalking back from 0x%06X:", TABLE)
  for index = math.max(-50, -math.floor(TABLE / 3)), 2 do
    local at_table = TABLE + index * 3
    local bank, addr = rom:u8(at_table), rom:u16le(at_table + 1)
    local plausible = addr >= 0x4000 and addr <= 0x7FFF
      and bank * 0x4000 < rom.size
    log("  %3d $%02X:$%04X %s", index, bank, addr,
      plausible and (script_at(bank, addr) and "script" or "in range") or "-")
  end

  log("\nthe run at 0x%06X, entry by entry:", TABLE)
  for index = 0, 55 do
    local at_table = TABLE + index * 3
    local bank, addr = rom:u8(at_table), rom:u16le(at_table + 1)
    local at = bank * 0x4000 + (addr - 0x4000)
    local out = {}
    local readable = true
    for _ = 1, 10 do
      if at < 0 or at + 1 > rom.size then break end
      local opcode = rom:u8(at)
      local width = widths[opcode]
      if width == nil then
        out[#out + 1] = ("<%02X?>"):format(opcode)
        readable = false
        break
      end
      out[#out + 1] = names[opcode]
      at = at + 1 + width
      if terminators[opcode] then break end
    end
    -- What the routine says, not just what it is made of. A table of common
    -- routines should read like one: the landmark signpost, the fanfare, the
    -- shopkeeper. This is the check that counting instructions cannot make.
    log("  %2d $%02X:$%04X %-9s %-46s %s", index, bank, addr,
      readable and "" or "STOPS",
      table.concat(out, "; "):sub(1, 46), first_text(bank, addr))
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
