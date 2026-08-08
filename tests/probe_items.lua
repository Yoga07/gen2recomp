-- Diagnostic: where are the item names and item attributes?
--
-- Items are the last big table the importer does not read. The name table is
-- reachable the same way the move names were — "MASTER BALL" is always item 1,
-- and the names are packed with the terminator between them rather than padded
-- to a fixed width. The attribute table has no text to anchor to, so this dumps
-- what sits around the names and lets the shape be read off rather than guessed.
--
--   love . --probe-items <rom> <report>

local Rom = require("src.rom.rom")
local text = require("src.rom.text")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

local function encode(name)
  local out = {}
  for i = 1, #name do
    local c = name:sub(i, i)
    if c == " " then
      out[#out + 1] = string.char(0x7F)
    else
      out[#out + 1] = string.char(c:byte() - ("A"):byte() + 0x80)
    end
  end
  return table.concat(out)
end

local function find_all(haystack, needle)
  local hits, from = {}, 1
  while true do
    local start = haystack:find(needle, from, true)
    if not start then break end
    hits[#hits + 1] = start - 1
    from = start + 1
  end
  return hits
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

  local signature = encode("MASTER BALL") .. string.char(text.TERMINATOR)
  local hits = find_all(rom.data, signature)
  log("MASTER BALL occurs %d times", #hits)

  for _, offset in ipairs(hits) do
    log("\n=== 0x%06X (bank $%02X) ===", offset, math.floor(offset / 0x4000))

    -- Walk forward as terminated strings for as long as they stay plausible.
    -- Where it stops, and on what, is what says how long the table is.
    local names, at = {}, offset
    while #names < 300 do
      local decoded, consumed = text.decode_terminated(rom.data, at, 20)
      if not decoded or consumed == 1 then
        log("  stops after %d names at 0x%06X on byte $%02X", #names, at,
          rom:u8(at))
        break
      end
      names[#names + 1] = decoded
      at = at + consumed
    end

    -- Print in rows so the shape of the list is visible at a glance.
    for row = 1, #names, 6 do
      local parts = {}
      for i = row, math.min(row + 5, #names) do
        parts[#parts + 1] = ("%3d %-13s"):format(i, names[i])
      end
      log("  %s", table.concat(parts, ""))
    end
  end

  -- The attribute table has no text in it, so the anchor has to be the prices.
  -- Poke Ball at 200, Great Ball at 600 and Ultra Ball at 1200 are fixed and
  -- well spread through the first few records, and Master Ball is free. Four
  -- words at known strides is a much narrower thing to match than any one of
  -- them alone.
  local KNOWN_PRICE = {
    [1] = 0,      -- MASTER BALL
    [2] = 1200,   -- ULTRA BALL
    [4] = 600,    -- GREAT BALL
    [5] = 200,    -- POKE BALL
  }
  -- Held back from the search and checked afterwards, so they are evidence
  -- rather than part of the fit.
  local SPOT_PRICE = {
    [9] = 100,    -- ANTIDOTE
    [14] = 3000,  -- FULL RESTORE
    [18] = 300,   -- POTION
    [32] = 4800,  -- RARE CANDY
    [38] = 600,   -- FULL HEAL
  }

  for stride = 5, 10 do
    local matches = {}
    for offset = 0, rom.size - stride * 6 - 2 do
      local ok = true
      for item, price in pairs(KNOWN_PRICE) do
        if rom:u16le(offset + (item - 1) * stride) ~= price then
          ok = false
          break
        end
      end
      if ok then
        matches[#matches + 1] = offset
      end
    end

    local detail = {}
    for _, offset in ipairs(matches) do
      local hit, total = 0, 0
      for item, price in pairs(SPOT_PRICE) do
        total = total + 1
        if rom:u16le(offset + (item - 1) * stride) == price then
          hit = hit + 1
        end
      end
      detail[#detail + 1] = ("0x%06X (%d/%d spot checks)"):format(offset, hit,
        total)
    end
    log("\nstride %d: %d candidate(s) %s", stride, #matches,
      table.concat(detail, ", "))
  end

  -- Read the seven bytes for items whose pocket is not in doubt, so the field
  -- order can be read off instead of assumed. A ball, a potion, a key item and
  -- a machine should disagree in exactly one column.
  local ATTRS = 0x0067C1
  local WATCH = {
    { 1, "MASTER BALL" }, { 5, "POKE BALL" }, { 7, "BICYCLE" },
    { 9, "ANTIDOTE" }, { 18, "POTION" }, { 32, "RARE CANDY" },
    { 54, "COIN CASE" }, { 127, "CARD KEY" }, { 173, "BERRY" },
    { 191, "TM01" }, { 243, "HM01" },
  }
  log("\nseven bytes per item at 0x%06X:", ATTRS)
  log("  %-13s %6s  %s", "item", "price", "b2 b3 b4 b5 b6")
  for _, entry in ipairs(WATCH) do
    local at = ATTRS + (entry[1] - 1) * 7
    log("  %-13s %6d  %02X %02X %02X %02X %02X", entry[2], rom:u16le(at),
      rom:u8(at + 2), rom:u8(at + 3), rom:u8(at + 4), rom:u8(at + 5),
      rom:u8(at + 6))
  end

  -- Whatever column holds the pocket should take only a handful of values
  -- across all 255 items, and each column's spread says which.
  log("\nhow many distinct values each column takes over 255 items:")
  for column = 2, 6 do
    local seen, count = {}, 0
    for item = 1, 255 do
      local value = rom:u8(ATTRS + (item - 1) * 7 + column)
      if not seen[value] then
        seen[value] = true
        count = count + 1
      end
    end
    local values = {}
    for value in pairs(seen) do values[#values + 1] = value end
    table.sort(values)
    local shown = {}
    for i = 1, math.min(#values, 10) do
      shown[#shown + 1] = ("%02X"):format(values[i])
    end
    log("  byte %d: %3d distinct  %s%s", column, count,
      table.concat(shown, " "), #values > 10 and " ..." or "")
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
