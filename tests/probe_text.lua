-- Diagnostic: find Crystal's dialogue text and how scripts reach it.
--
-- The charmap is already proven — it decodes all 251 species and move names —
-- so text can be found directly by scanning for long runs of bytes that decode
-- as readable characters and end in a terminator. Dialogue is distinctive:
-- ordinary data does not produce twenty consecutive letters and spaces.
--
-- The second half is the connection. Every signpost and NPC carries a script
-- pointer, already extracted. If those scripts contain pointers to the text
-- found by the scan, then the bytes between them are the script bytecode, and
-- the byte before a text pointer is the opcode that prints it.
--
--   love . --probe-text <rom> <report>

local Rom = require("src.rom.rom")
local text = require("src.rom.text")
local tilesets = require("src.rom.tilesets")
local maps = require("src.rom.maps")
local events = require("src.rom.events")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

-- Control bytes that appear inside dialogue: line breaks, paragraph breaks,
-- prompts and the terminator.
local CONTROL = {
  [0x50] = "@",   -- end of string
  [0x4F] = "\\l", -- next line, bottom
  [0x51] = "\\p", -- paragraph, clears the box
  [0x55] = "\\c", -- continue
  [0x57] = "\\d", -- done
  [0x58] = "\\x", -- prompt
  [0x00] = "\\0",
}

local MIN_RUN = 24

--- Longest readable run starting at `offset`, in characters.
local function run_at(rom, offset)
  local letters = 0
  local at = offset
  while at < rom.size do
    local byte_value = rom:u8(at)
    if text.charmap[byte_value] then
      letters = letters + 1
      at = at + 1
    elseif CONTROL[byte_value] then
      -- A terminator ends the run; other controls continue it.
      if byte_value == 0x50 or byte_value == 0x57 then
        return letters, at - offset + 1
      end
      at = at + 1
    else
      return letters, at - offset
    end
  end
  return letters, at - offset
end

--- Decode a string for display, showing control codes explicitly.
local function render(rom, offset, limit)
  local out = {}
  local at = offset
  while at < rom.size and #out < limit do
    local byte_value = rom:u8(at)
    if text.charmap[byte_value] then
      out[#out + 1] = text.charmap[byte_value]
    elseif CONTROL[byte_value] then
      out[#out + 1] = CONTROL[byte_value]
      if byte_value == 0x50 or byte_value == 0x57 then
        break
      end
    else
      break
    end
    at = at + 1
  end
  return table.concat(out)
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

  -- Scan for dialogue.
  local banks = {}
  local found = {}
  local offset = 0
  while offset < rom.size do
    local letters, length = run_at(rom, offset)
    if letters >= MIN_RUN then
      local bank = math.floor(offset / 0x4000)
      banks[bank] = (banks[bank] or 0) + 1
      found[#found + 1] = { offset = offset, letters = letters }
      offset = offset + math.max(length, 1)
    else
      offset = offset + 1
    end
  end

  log("%d strings of at least %d characters", #found, MIN_RUN)

  local ranked = {}
  for bank, count in pairs(banks) do
    ranked[#ranked + 1] = { bank = bank, count = count }
  end
  table.sort(ranked, function(a, b) return a.count > b.count end)

  log("\ntop text banks:")
  for i = 1, math.min(#ranked, 12) do
    log("  bank $%02X: %d strings", ranked[i].bank, ranked[i].count)
  end

  log("\nsample dialogue:")
  local step = math.max(1, math.floor(#found / 12))
  for i = 1, #found, step do
    local entry = found[i]
    log("  0x%06X  %s", entry.offset, render(rom, entry.offset, 90))
  end

  -- Now the connection. Take the scripts that signposts point at and look at
  -- what is there.
  local tileset_result = tilesets.locate(rom)
  local map_result = maps.locate(rom, tileset_result.count)

  local text_at = {}
  for _, entry in ipairs(found) do
    text_at[entry.offset] = true
  end

  log("\n== bytes at signpost script pointers ==")
  local shown = 0
  local opcode_before_text = {}
  local scripts_checked, scripts_hitting_text = 0, 0

  for _, header in ipairs(map_result.headers) do
    local decoded = not header.unparsed and events.decode(rom, header)
    if decoded then
      local script_bank = math.floor(header.attributes.scripts / 0x4000)
      for _, bg in ipairs(decoded.bg_events) do
        if bg.script then
          local flat = script_bank * 0x4000 + (bg.script - 0x4000)
          if flat + 16 <= rom.size then
            scripts_checked = scripts_checked + 1

            -- Look for a 2-byte pointer in the first few bytes that lands on
            -- discovered text within the same bank.
            local hit
            for i = 0, 6 do
              local addr = rom:u16le(flat + i)
              if addr >= 0x4000 and addr <= 0x7FFF then
                local target = script_bank * 0x4000 + (addr - 0x4000)
                if text_at[target] then
                  hit = { at = i, target = target }
                  break
                end
              end
            end

            if hit then
              scripts_hitting_text = scripts_hitting_text + 1
              if hit.at > 0 then
                local opcode = rom:u8(flat + hit.at - 1)
                opcode_before_text[opcode] = (opcode_before_text[opcode] or 0) + 1
              end

              if shown < 10 then
                shown = shown + 1
                local raw = {}
                for i = 0, 7 do
                  raw[#raw + 1] = ("%02X"):format(rom:u8(flat + i))
                end
                log("  0x%06X: %s  -> text at 0x%06X (pointer at +%d)",
                  flat, table.concat(raw, " "), hit.target, hit.at)
                log("      %s", render(rom, hit.target, 70))
              end
            end
          end
        end
      end
    end
  end

  log("\n%d of %d signpost scripts reach discovered text in their first bytes",
    scripts_hitting_text, scripts_checked)

  local opcodes = {}
  for opcode, count in pairs(opcode_before_text) do
    opcodes[#opcodes + 1] = { opcode = opcode, count = count }
  end
  table.sort(opcodes, function(a, b) return a.count > b.count end)

  log("\nbytes immediately before a text pointer:")
  for i = 1, math.min(#opcodes, 8) do
    log("  $%02X x%d", opcodes[i].opcode, opcodes[i].count)
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
