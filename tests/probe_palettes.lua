-- Diagnostic: find the Pokémon palette table and learn its real constraints.
--
-- The locator demanded 251 consecutive records where every word is a 15-bit
-- colour and, within each pair, the first colour is brighter than the second.
-- Nothing in the cartridge satisfies that, so one of those assumptions is
-- wrong. Report the longest run under each constraint separately, and say where
-- the best candidate breaks.
--
--   love . --probe-palettes <rom> <report>

local Rom = require("src.rom.rom")
local bytes = require("src.util.bytes")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

local RECORD_SIZE = 8
local WANT = 251

local function brightness(word)
  return bytes.band(word, 0x1F)
    + bytes.band(bytes.rshift(word, 5), 0x1F)
    + bytes.band(bytes.rshift(word, 10), 0x1F)
end

--- Longest run of records satisfying `predicate`, scanning on `stride`.
local function longest_run(rom, stride, predicate)
  local best = { length = 0, offset = 0 }
  local data = rom.data
  local limit = rom.size - stride

  local offset = 0
  while offset <= limit do
    if predicate(data, offset) then
      local start = offset
      local length = 0
      while offset <= limit and predicate(data, offset) do
        length = length + 1
        offset = offset + stride
      end
      if length > best.length then
        best = { length = length, offset = start }
      end
    else
      offset = offset + 1
    end
  end
  return best
end

local function words_of(data, offset, count)
  local words = {}
  for i = 0, count - 1 do
    words[i + 1] = bytes.u16le(data, offset + i * 2)
  end
  return words
end

local function all_15bit(data, offset)
  if offset + RECORD_SIZE > #data then
    return false
  end
  for i = 0, 3 do
    if bytes.band(bytes.u16le(data, offset + i * 2), 0x8000) ~= 0 then
      return false
    end
  end
  return true
end

local function light_before_dark(data, offset)
  if not all_15bit(data, offset) then
    return false
  end
  local w = words_of(data, offset, 4)
  return brightness(w[1]) > brightness(w[2]) and brightness(w[3]) > brightness(w[4])
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

  log("target: %d records of %d bytes", WANT, RECORD_SIZE)

  local a = longest_run(rom, RECORD_SIZE, all_15bit)
  log("\nconstraint: every word is 15-bit")
  log("  longest run %d records at 0x%06X (bank $%02X)",
    a.length, a.offset, math.floor(a.offset / 0x4000))

  local b = longest_run(rom, RECORD_SIZE, light_before_dark)
  log("\nconstraint: 15-bit AND light brighter than dark in both pairs")
  log("  longest run %d records at 0x%06X (bank $%02X)",
    b.length, b.offset, math.floor(b.offset / 0x4000))

  -- Walk the best 15-bit run and find the first record where the brightness
  -- ordering fails, which is the assumption most likely to be wrong.
  if a.length >= WANT then
    log("\n== brightness ordering across the 15-bit run at 0x%06X ==", a.offset)
    local violations = 0
    local shown = 0
    for record = 0, math.min(a.length, WANT) - 1 do
      local at = a.offset + record * RECORD_SIZE
      local w = words_of(rom.data, at, 4)
      local normal_ok = brightness(w[1]) > brightness(w[2])
      local shiny_ok = brightness(w[3]) > brightness(w[4])
      if not (normal_ok and shiny_ok) then
        violations = violations + 1
        if shown < 8 then
          shown = shown + 1
          log("  record %3d @ 0x%06X  normal %d/%d  shiny %d/%d  %s",
            record + 1, at, brightness(w[1]), brightness(w[2]),
            brightness(w[3]), brightness(w[4]),
            (not normal_ok and "normal inverted " or "") ..
            (not shiny_ok and "shiny inverted" or ""))
        end
      end
    end
    log("  %d of %d records violate the ordering", violations, math.min(a.length, WANT))

    log("\n  first records as channel triples (r,g,b out of 31):")
    for record = 0, 5 do
      local at = a.offset + record * RECORD_SIZE
      local w = words_of(rom.data, at, 4)
      local parts = {}
      for _, word in ipairs(w) do
        parts[#parts + 1] = ("%2d,%2d,%2d"):format(
          bytes.band(word, 0x1F),
          bytes.band(bytes.rshift(word, 5), 0x1F),
          bytes.band(bytes.rshift(word, 10), 0x1F))
      end
      log("    %3d: %s", record + 1, table.concat(parts, "  |  "))
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
