-- Diagnostic: how are the hidden items stored?
--
-- The background event types list "item" at 7, but nothing has ever read one.
-- A bg event is y, x, type, then two bytes. For the ordinary types those two
-- bytes are a text pointer; for a hidden item they are something else, and this
-- works out what by trying every reading and seeing which one is not noise.
--
--   love . --probe-hidden <rom> <report>

local Rom = require("src.rom.rom")
local tilesets = require("src.rom.tilesets")
local maps = require("src.rom.maps")
local events = require("src.rom.events")
local locate = require("src.rom.locate")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

local BGEVENT_ITEM = 7

function probe.run(rom_path, report_path)
  report = {}

  local rom, err = Rom.load(rom_path)
  if not rom then
    log("FATAL: %s", err)
    local fh = io.open(report_path, "w")
    if fh then fh:write(table.concat(report, "\n") .. "\n") fh:close() end
    return true
  end

  local names = locate.table(locate.descriptors.item_names, rom)
  local attributes = locate.table(locate.descriptors.item_attributes, rom)
  names = names and names.records
  attributes = attributes and attributes.records
  if not names then
    log("FATAL: the item names did not locate")
    local fh = io.open(report_path, "w")
    if fh then fh:write(table.concat(report, "\n") .. "\n") fh:close() end
    return true
  end

  local tileset_result = tilesets.locate(rom)
  local map_result = maps.locate(rom, tileset_result.count)

  local by_kind = {}
  local hidden = {}

  for _, header in ipairs(map_result.headers) do
    local decoded = not header.unparsed and events.decode(rom, header)
    if decoded then
      local bank = math.floor(header.attributes.scripts / 0x4000)
      for _, bg in ipairs(decoded.bg_events) do
        by_kind[bg.kind] = (by_kind[bg.kind] or 0) + 1
        if bg.kind == BGEVENT_ITEM then
          hidden[#hidden + 1] = { bg = bg, bank = bank }
        end
      end
    end
  end

  local kinds = {}
  for kind in pairs(by_kind) do kinds[#kinds + 1] = kind end
  table.sort(kinds)
  log("background events by type:")
  for _, kind in ipairs(kinds) do
    log("  %d %-12s %4d", kind, events.bg_types[kind] or "?", by_kind[kind])
  end

  log("\n%d events of the item type", #hidden)
  if #hidden == 0 then
    rom:release()
    local fh = io.open(report_path, "w")
    if fh then fh:write(table.concat(report, "\n") .. "\n") fh:close() end
    return true
  end

  local function real_item(value)
    return value >= 1 and value <= 255 and names[value]
      and names[value] ~= "TERU-SAMA"
  end

  -- Reading one: the two bytes are the value inline, low byte first. If the low
  -- byte is the item then it should name real items nearly every time.
  local inline_ok, inline_names = 0, {}
  local high_values = {}
  for _, entry in ipairs(hidden) do
    local word = entry.bg.script_word
    local low = word and (word % 256)
    local high = word and math.floor(word / 256)
    if low and real_item(low) then
      inline_ok = inline_ok + 1
      inline_names[names[low]] = (inline_names[names[low]] or 0) + 1
    end
    if high then
      high_values[high] = (high_values[high] or 0) + 1
    end
  end
  log("\nreading the two bytes inline: %d of %d name a real item",
    inline_ok, #hidden)

  local ranked = {}
  for value, count in pairs(high_values) do
    ranked[#ranked + 1] = { value = value, count = count }
  end
  table.sort(ranked, function(a, b) return a.count > b.count end)
  local parts = {}
  for i = 1, math.min(#ranked, 8) do
    parts[#parts + 1] = ("$%02X x%d"):format(ranked[i].value, ranked[i].count)
  end
  log("  the high byte takes %d distinct values: %s", #ranked,
    table.concat(parts, ", "))

  -- Reading two: the two bytes are a near pointer, and the item sits at the
  -- other end. This is how an item ball works, so it is the obvious rival.
  local pointer_ok = 0
  local pointer_names = {}
  local second_byte = {}
  for _, entry in ipairs(hidden) do
    local addr = entry.bg.script
    if addr and addr >= 0x4000 and addr <= 0x7FFF then
      local at = entry.bank * 0x4000 + (addr - 0x4000)
      if at + 1 < rom.size then
        local item = rom:u8(at)
        if real_item(item) then
          pointer_ok = pointer_ok + 1
          pointer_names[names[item]] = (pointer_names[names[item]] or 0) + 1
        end
        local next_byte = rom:u8(at + 1)
        second_byte[next_byte] = (second_byte[next_byte] or 0) + 1
      end
    end
  end
  log("\nreading them as a pointer: %d of %d land on a real item",
    pointer_ok, #hidden)

  ranked = {}
  for value, count in pairs(second_byte) do
    ranked[#ranked + 1] = { value = value, count = count }
  end
  table.sort(ranked, function(a, b) return a.count > b.count end)
  parts = {}
  for i = 1, math.min(#ranked, 8) do
    parts[#parts + 1] = ("$%02X x%d"):format(ranked[i].value, ranked[i].count)
  end
  log("  the byte after it takes %d distinct values: %s", #ranked,
    table.concat(parts, ", "))

  -- 74 of 85 sounds convincing until you notice that most byte values name a
  -- real item: only the unused slots do not, so roughly 86% of random bytes
  -- pass. That is what 74 of 85 is. The chance rate has to be measured, not
  -- assumed, before either reading can be believed.
  local real_count = 0
  for value = 1, 255 do
    if real_item(value) then
      real_count = real_count + 1
    end
  end
  log("\n%d of 255 byte values name a real item, so %d%% is the rate to beat",
    real_count, math.floor(real_count / 255 * 100))

  -- What actually sits at the far end of the pointer. If these are scripts,
  -- the first byte is an opcode and should repeat.
  local script_ops = require("src.rom.script_ops")
  local _, _, op_names = script_ops.widths()
  local first_byte = {}
  for _, entry in ipairs(hidden) do
    local addr = entry.bg.script
    if addr then
      local at = entry.bank * 0x4000 + (addr - 0x4000)
      local value = rom:u8(at)
      first_byte[value] = (first_byte[value] or 0) + 1
    end
  end
  local ranked_first = {}
  for value, count in pairs(first_byte) do
    ranked_first[#ranked_first + 1] = { value = value, count = count }
  end
  table.sort(ranked_first, function(a, b) return a.count > b.count end)
  log("\nthe first byte at the pointer target takes %d distinct values:",
    #ranked_first)
  for i = 1, math.min(#ranked_first, 6) do
    local value = ranked_first[i].value
    log("  $%02X x%-3d  opcode %s, item %s", value, ranked_first[i].count,
      tostring(op_names[value]), tostring(names[value]))
  end

  -- Reading three, which the raw bytes below give away: the target holds a
  -- two-byte event flag and then the item. Records sit three bytes apart and
  -- the flag increments along them, which is why the byte after the first was
  -- always $00 -- it was the flag's high half, not a second field.
  local third_ok, flags, duplicate_flags = 0, {}, 0
  local third_names = {}
  for _, entry in ipairs(hidden) do
    local addr = entry.bg.script
    if addr then
      local at = entry.bank * 0x4000 + (addr - 0x4000)
      if at + 2 < rom.size then
        local flag = rom:u16le(at)
        local item = rom:u8(at + 2)
        if real_item(item) then
          third_ok = third_ok + 1
          third_names[names[item]] = (third_names[names[item]] or 0) + 1
        end
        if flags[flag] then
          duplicate_flags = duplicate_flags + 1
        end
        flags[flag] = (flags[flag] or 0) + 1
      end
    end
  end
  log("\nreading flag then item: %d of %d name a real item (chance is %d%%)",
    third_ok, #hidden, math.floor(real_count / 255 * 100))

  local low, high, distinct_flags = math.huge, -1, 0
  for flag in pairs(flags) do
    low = math.min(low, flag)
    high = math.max(high, flag)
    distinct_flags = distinct_flags + 1
  end
  log("  %d distinct flags, from %d to %d, %d shared between two events",
    distinct_flags, low, high, duplicate_flags)

  local list = {}
  for name, count in pairs(third_names) do
    list[#list + 1] = { name = name, count = count }
  end
  table.sort(list, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.name < b.name
  end)
  local out = {}
  for i = 1, math.min(#list, 16) do
    out[#out + 1] = ("%s x%d"):format(list[i].name, list[i].count)
  end
  log("  %s", table.concat(out, ", "))

  log("\nthe raw bytes, for the first twenty:")
  log("  %-4s %-5s %-6s %-13s %-4s %s", "y,x", "word", "target", "low as item",
    "high", "bytes at the target")
  for i = 1, math.min(#hidden, 20) do
    local entry = hidden[i]
    local word = entry.bg.script_word or 0
    local low, high = word % 256, math.floor(word / 256)
    local target, bytes = "-", "-"
    if entry.bg.script then
      local at = entry.bank * 0x4000 + (entry.bg.script - 0x4000)
      target = ("%06X"):format(at)
      local parts = {}
      for k = 0, 5 do
        if at + k < rom.size then
          parts[#parts + 1] = ("%02X"):format(rom:u8(at + k))
        end
      end
      bytes = table.concat(parts, " ")
    end
    log("  %2d,%-2d $%04X %-6s %-13s $%02X  %s", entry.bg.y, entry.bg.x, word,
      target, tostring(names[low]), high, bytes)
  end

  local function show(label, counts)
    local list = {}
    for name, count in pairs(counts) do
      list[#list + 1] = { name = name, count = count }
    end
    table.sort(list, function(a, b)
      if a.count ~= b.count then return a.count > b.count end
      return a.name < b.name
    end)
    local out = {}
    for i = 1, math.min(#list, 16) do
      out[#out + 1] = ("%s x%d"):format(list[i].name, list[i].count)
    end
    log("\n%s:\n  %s", label, table.concat(out, ", "))
  end
  show("items under the inline reading", inline_names)
  show("items under the pointer reading", pointer_names)

  rom:release()

  local fh = io.open(report_path, "w")
  if fh then
    fh:write(table.concat(report, "\n") .. "\n")
    fh:close()
  end
  return true
end

return probe
