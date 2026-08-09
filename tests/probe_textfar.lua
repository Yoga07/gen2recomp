-- Diagnostic: why does a third of the game's dialogue refuse to decode?
--
-- 340 scripts end at a text command whose text would not decode. Either the
-- text engine has a control code we do not know, or those pointers do not lead
-- to text at all. This takes every text target in the reachable script graph,
-- tries to decode it, and for the ones that fail reports what byte they start
-- with -- and then tests whether that byte is an indirection to the real text.
--
--   love . --probe-textfar <rom> <report>

local Rom = require("src.rom.rom")
local tilesets = require("src.rom.tilesets")
local maps = require("src.rom.maps")
local events = require("src.rom.events")
local script_ops = require("src.rom.script_ops")
local script_decode = require("src.rom.script_decode")
local text = require("src.rom.text")

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

  -- Every text target in the graph, as a flat offset.
  local targets = {}
  for bank, block in pairs(code) do
    for _, instruction in pairs(block) do
      local opcode = instruction.opcode
      local near = script_ops.text_commands[opcode]
      local far = script_ops.far_text_commands[opcode]
      local text_bank, text_addr
      if near then
        text_bank = bank
        text_addr = (instruction.args[1] or 0) + (instruction.args[2] or 0) * 256
      elseif far then
        text_bank = instruction.args[1] or 0
        text_addr = (instruction.args[2] or 0) + (instruction.args[3] or 0) * 256
      end
      if text_addr and text_addr >= 0x4000 and text_addr <= 0x7FFF then
        local flat = text_bank * 0x4000 + (text_addr - 0x4000)
        if flat + 4 < rom.size then
          targets[flat] = true
        end
      end
    end
  end

  local total, decoded_ok, failed = 0, 0, {}
  local first_byte = {}
  for flat in pairs(targets) do
    total = total + 1
    if text.decode_dialogue(rom.data, flat) then
      decoded_ok = decoded_ok + 1
    else
      local value = rom:u8(flat)
      first_byte[value] = (first_byte[value] or 0) + 1
      failed[#failed + 1] = flat
    end
  end

  log("%d distinct text targets, %d decode, %d do not", total, decoded_ok,
    total - decoded_ok)

  local ranked = {}
  for value, count in pairs(first_byte) do
    ranked[#ranked + 1] = { value = value, count = count }
  end
  table.sort(ranked, function(a, b) return a.count > b.count end)
  log("\nwhat the ones that fail start with:")
  for i = 1, math.min(#ranked, 10) do
    log("  $%02X x%d", ranked[i].value, ranked[i].count)
  end

  if #ranked == 0 then
    rom:release()
    local fh = io.open(report_path, "w")
    if fh then fh:write(table.concat(report, "\n") .. "\n") fh:close() end
    return true
  end

  -- They start with $00, which is the correct opening byte, so the pointers do
  -- lead to text and the decoder is choking on something inside. Walk each one
  -- by hand and record the first byte it cannot account for.
  local offender = {}
  local context = {}
  for _, flat in ipairs(failed) do
    for i = 0, 400 do
      local code = rom:u8(flat + i)
      if not code then break end
      local control = text.controls[code]
      if control == "done" or control == "prompt" then
        break
      end
      if not control and not text.charmap[code]
        and not text.substitutions[code] then
        offender[code] = (offender[code] or 0) + 1
        if not context[code] then
          local bytes, reads = {}, {}
          for k = math.max(0, i - 12), i + 18 do
            bytes[#bytes + 1] = ("%02X"):format(rom:u8(flat + k))
            local at = rom:u8(flat + k)
            reads[#reads + 1] = text.charmap[at] or text.substitutions[at]
              or (text.controls[at] and "|") or ("<%02X>"):format(at)
          end
          context[code] = ("0x%06X at +%d\n        %s\n        %s")
            :format(flat, i, table.concat(bytes, " "), table.concat(reads))
        end
        break
      end
    end
  end

  log("\nthe first byte each failing block cannot account for:")
  local by_offender = {}
  for code, count in pairs(offender) do
    by_offender[#by_offender + 1] = { code = code, count = count }
  end
  table.sort(by_offender, function(a, b) return a.count > b.count end)
  for i = 1, math.min(#by_offender, 14) do
    local code = by_offender[i].code
    log("  $%02X x%-4d  %s", code, by_offender[i].count, context[code])
  end

  -- Where does $75 occur? If it is a control it will sit in one place; if it is
  -- a glyph it will turn up anywhere a letter would.
  for _, suspect in ipairs({ 0x75, 0x14 }) do
    local positions, occurrences = {}, 0
    for flat in pairs(targets) do
      for i = 0, 300 do
        local code = rom:u8(flat + i)
        local control = text.controls[code]
        if control == "done" or control == "prompt" then break end
        if code == suspect then
          occurrences = occurrences + 1
          positions[i] = (positions[i] or 0) + 1
        end
      end
    end
    local spots = {}
    for position, count in pairs(positions) do
      spots[#spots + 1] = { position = position, count = count }
    end
    table.sort(spots, function(a, b) return a.count > b.count end)
    local parts = {}
    for i = 1, math.min(#spots, 6) do
      parts[#parts + 1] = ("+%d x%d"):format(spots[i].position, spots[i].count)
    end
    log("\n$%02X occurs %d times over %d distinct positions: %s", suspect,
      occurrences, #spots, table.concat(parts, ", "))
  end

  -- If they are controls that draw nothing, skipping them should leave text
  -- that decodes and reads as English. That is the test, rather than assuming.
  local recovered, samples_ok = 0, {}
  for _, flat in ipairs(failed) do
    local out, ok = {}, false
    for i = 0, 400 do
      local code = rom:u8(flat + i)
      local control = text.controls[code]
      if control == "done" or control == "prompt" then
        ok = true
        break
      end
      if code == 0x75 or code == 0x14 or code == 0x01 then
        -- skipped
      elseif control then
        out[#out + 1] = " / "
      elseif text.charmap[code] then
        out[#out + 1] = text.charmap[code]
      elseif text.substitutions[code] then
        out[#out + 1] = text.substitutions[code]
      else
        break
      end
    end
    if ok then
      recovered = recovered + 1
      if #samples_ok < 6 then
        samples_ok[#samples_ok + 1] = table.concat(out):sub(1, 64)
      end
    end
  end
  log("\nskipping $75, $14 and $01: %d of %d recover", recovered, #failed)
  for _, sample in ipairs(samples_ok) do
    log("  %s", sample)
  end

  -- Glyph or control? The font settles it, the same way it settled where the
  -- accented e lives. A byte that draws ink is a character; one whose tile is
  -- blank draws nothing and must be a control. The contractions are the
  -- control group here: they are known to be glyphs now, so they had better
  -- carry ink.
  local font = require("src.rom.font")
  local located = font.locate(rom, "crystal")
  if located then
    local glyphs = font.decode(rom, located)
    local function ink(code)
      local tile = glyphs[font.tile_for(code) + 1]
      if not tile then
        return -1
      end
      -- Tiles come back as a flat run of 64 pixels.
      local count = 0
      for i = 1, 64 do
        if (tile[i] or 0) ~= 0 then count = count + 1 end
      end
      return count
    end

    log("\nink in the font tile for each byte:")
    for _, code in ipairs({ 0xD0, 0xD4, 0xD6, 0x75, 0x14, 0x01, 0x7F, 0x80 }) do
      log("  $%02X -> tile %3d, %3d pixels", code, font.tile_for(code),
        ink(code))
    end

    -- Ink alone says something is drawn there, not what. Print the tiles and
    -- look, which is what settled the font bias and the accented e.
    for _, code in ipairs({ 0x75, 0x80, 0xD4 }) do
      local tile = glyphs[font.tile_for(code) + 1]
      if tile then
        log("\n$%02X (tile %d):", code, font.tile_for(code))
        for row = 0, 7 do
          local line = {}
          for column = 1, 8 do
            line[#line + 1] = (tile[row * 8 + column] or 0) ~= 0 and "#" or "."
          end
          log("    %s", table.concat(line))
        end
      end
    end
  else
    log("\nthe font did not locate, so ink could not be measured")
  end

  local marker = ranked[1].value
  log("\ntesting $%02X as an indirection:", marker)

  local as_addr_bank, as_bank_addr, neither = 0, 0, 0
  local samples = {}
  for _, flat in ipairs(failed) do
    if rom:u8(flat) == marker then
      local ok_one, ok_two = false, false

      -- address then bank
      local addr = rom:u16le(flat + 1)
      local bank = rom:u8(flat + 3)
      if addr >= 0x4000 and addr <= 0x7FFF then
        local target = bank * 0x4000 + (addr - 0x4000)
        if target + 1 < rom.size and text.decode_dialogue(rom.data, target) then
          ok_one = true
          if #samples < 8 then
            local block = text.decode_dialogue(rom.data, target)
            samples[#samples + 1] = ("0x%06X -> bank $%02X:$%04X  %s")
              :format(flat, bank, addr, text.flatten(block):sub(1, 46))
          end
        end
      end

      -- bank then address
      local bank2 = rom:u8(flat + 1)
      local addr2 = rom:u16le(flat + 2)
      if addr2 >= 0x4000 and addr2 <= 0x7FFF then
        local target = bank2 * 0x4000 + (addr2 - 0x4000)
        if target + 1 < rom.size and text.decode_dialogue(rom.data, target) then
          ok_two = true
        end
      end

      if ok_one then
        as_addr_bank = as_addr_bank + 1
      end
      if ok_two then
        as_bank_addr = as_bank_addr + 1
      end
      if not ok_one and not ok_two then
        neither = neither + 1
      end
    end
  end

  log("  address then bank: %d decode", as_addr_bank)
  log("  bank then address: %d decode", as_bank_addr)
  log("  neither: %d", neither)

  log("\nwhat comes back, reading it as address then bank:")
  for _, sample in ipairs(samples) do
    log("  %s", sample)
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
