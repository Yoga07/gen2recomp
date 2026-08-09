-- Diagnostic: what does applymovement point at?
--
-- applymovement carries an object id and a pointer. The pointer leads to a
-- little movement language of its own -- step this way, turn that way, stop --
-- and none of it has been read yet. This dumps every block the scripts point
-- at and works out the alphabet from how the bytes are distributed.
--
--   love . --probe-movement <rom> <report>

local Rom = require("src.rom.rom")
local tilesets = require("src.rom.tilesets")
local maps = require("src.rom.maps")
local events = require("src.rom.events")
local script_decode = require("src.rom.script_decode")
local std_scripts = require("src.rom.std_scripts")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

local APPLYMOVEMENT = 0x69
local APPLYMOVEMENT_LAST = 0x6A

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

  local std_result = std_scripts.locate(rom)
  if std_result then
    for _, entry in ipairs(std_result.entries) do
      entries[#entries + 1] = { bank = entry.bank, addr = entry.addr }
    end
  end

  local code = script_decode.reachable(rom, entries)

  -- Every movement block the scripts point at.
  local targets, object_ids = {}, {}
  for bank, block in pairs(code) do
    for _, instruction in pairs(block) do
      local opcode = instruction.opcode
      local addr
      if opcode == APPLYMOVEMENT then
        object_ids[instruction.args[1] or 0] =
          (object_ids[instruction.args[1] or 0] or 0) + 1
        addr = (instruction.args[2] or 0) + (instruction.args[3] or 0) * 256
      elseif opcode == APPLYMOVEMENT_LAST then
        addr = (instruction.args[1] or 0) + (instruction.args[2] or 0) * 256
      end
      if addr and addr >= 0x4000 and addr <= 0x7FFF then
        targets[bank * 0x4000 + (addr - 0x4000)] = true
      end
    end
  end

  local count = 0
  for _ in pairs(targets) do count = count + 1 end
  log("%d distinct movement blocks", count)

  local ids = {}
  for id, times in pairs(object_ids) do
    ids[#ids + 1] = { id = id, times = times }
  end
  table.sort(ids, function(a, b) return a.times > b.times end)
  local parts = {}
  for i = 1, math.min(#ids, 12) do
    parts[#parts + 1] = ("%d x%d"):format(ids[i].id, ids[i].times)
  end
  log("object ids moved: %s", table.concat(parts, ", "))

  -- The terminator is whatever byte sits at the end of nearly every block. Try
  -- each candidate and see which one gives short, sane blocks everywhere.
  log("\nhow each candidate terminator behaves:")
  for _, candidate in ipairs({ 0xFF, 0xFE, 0x00, 0x47 }) do
    local lengths, total, longest = {}, 0, 0
    local unterminated = 0
    for at in pairs(targets) do
      local length = nil
      for i = 0, 63 do
        if rom:u8(at + i) == candidate then
          length = i
          break
        end
      end
      if length then
        total = total + 1
        lengths[length] = (lengths[length] or 0) + 1
        longest = math.max(longest, length)
      else
        unterminated = unterminated + 1
      end
    end
    log("  $%02X: %d of %d blocks end within 64 bytes, longest %d, %d never",
      candidate, total, count, longest, unterminated)
  end

  -- The alphabet: which bytes appear inside blocks, assuming $FF ends them.
  local alphabet, positions = {}, {}
  for at in pairs(targets) do
    for i = 0, 63 do
      local value = rom:u8(at + i)
      if value == 0xFF then
        break
      end
      alphabet[value] = (alphabet[value] or 0) + 1
      positions[value] = positions[value] or i
    end
  end

  local letters = {}
  for value, times in pairs(alphabet) do
    letters[#letters + 1] = { value = value, times = times }
  end
  table.sort(letters, function(a, b) return a.times > b.times end)
  log("\n%d distinct bytes inside movement blocks; commonest:", #letters)
  for i = 1, math.min(#letters, 24) do
    log("  $%02X x%d", letters[i].value, letters[i].times)
  end

  -- A few blocks in full.
  log("\nsome blocks in full:")
  local shown = 0
  for at in pairs(targets) do
    if shown < 12 then
      shown = shown + 1
      local bytes = {}
      for i = 0, 20 do
        local value = rom:u8(at + i)
        bytes[#bytes + 1] = ("%02X"):format(value)
        if value == 0xFF then break end
      end
      log("  0x%06X: %s", at, table.concat(bytes, " "))
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
