-- Diagnostic: are the objects with type nibble 1 really item balls?
--
-- The nibble is meant to be 0 script, 1 item ball, 2 trainer, but only the
-- trainer value has ever been checked against anything. An item ball's script
-- pointer is supposed to lead to two bytes rather than to bytecode: the item
-- and how many of it. If that is right then the bytes there should name real
-- items in sensible quantities, and the same reading applied to the other
-- nibbles should not.
--
--   love . --probe-itemballs <rom> <report>

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
  if not names or not attributes then
    log("FATAL: the item tables did not locate")
    local fh = io.open(report_path, "w")
    if fh then fh:write(table.concat(report, "\n") .. "\n") fh:close() end
    return true
  end
  names, attributes = names.records, attributes.records

  local tileset_result = tilesets.locate(rom)
  local map_result = maps.locate(rom, tileset_result.count)

  -- Gather every object, keyed by its type nibble.
  local by_kind = {}
  for _, header in ipairs(map_result.headers) do
    local decoded = not header.unparsed and events.decode(rom, header)
    if decoded then
      local bank = math.floor(header.attributes.scripts / 0x4000)
      for _, object in ipairs(decoded.objects) do
        local list = by_kind[object.kind] or {}
        by_kind[object.kind] = list
        list[#list + 1] = { object = object, bank = bank, map = header.name }
      end
    end
  end

  -- Read a script pointer as an item ball would be read, and say whether it
  -- looks like one. TERU-SAMA is the placeholder name on the unused item slots,
  -- so an item that decodes to one of those is not a real pickup.
  local function as_itemball(entry)
    local addr = entry.object.script
    if not addr or addr < 0x4000 or addr > 0x7FFF then
      return nil
    end
    local at = entry.bank * 0x4000 + (addr - 0x4000)
    if at + 1 >= rom.size then
      return nil
    end
    local item = rom:u8(at)
    local quantity = rom:u8(at + 1)
    if item < 1 or item > 255 or quantity < 1 or quantity > 99 then
      return nil
    end
    local name = names[item]
    if not name or name == "TERU-SAMA" then
      return nil
    end
    return { item = item, name = name, quantity = quantity,
             pocket = attributes[item].pocket }
  end

  local kinds = {}
  for kind in pairs(by_kind) do kinds[#kinds + 1] = kind end
  table.sort(kinds)

  log("objects by type nibble, and how each reads as an item ball:")
  for _, kind in ipairs(kinds) do
    local list = by_kind[kind]
    local plausible = 0
    for _, entry in ipairs(list) do
      if as_itemball(entry) then
        plausible = plausible + 1
      end
    end
    log("  nibble %2d: %4d objects, %4d read as an item (%d%%)", kind, #list,
      plausible, math.floor(plausible / math.max(#list, 1) * 100))
  end

  -- The filter above allows quantities 1 to 99, so "every one was 1" could be
  -- an artefact of it. This reads the second byte raw, with no filtering at
  -- all: if the nibble really means item ball then that byte is a quantity and
  -- should be tightly clustered, and for the other nibbles it is just whatever
  -- the script happens to start with.
  log("\nthe second byte at the script pointer, unfiltered:")
  for _, kind in ipairs(kinds) do
    local seen, total = {}, 0
    for _, entry in ipairs(by_kind[kind]) do
      local addr = entry.object.script
      if addr and addr >= 0x4000 and addr <= 0x7FFF then
        local at = entry.bank * 0x4000 + (addr - 0x4000)
        if at + 1 < rom.size then
          local value = rom:u8(at + 1)
          seen[value] = (seen[value] or 0) + 1
          total = total + 1
        end
      end
    end

    local ranked = {}
    for value, count in pairs(seen) do
      ranked[#ranked + 1] = { value = value, count = count }
    end
    table.sort(ranked, function(a, b) return a.count > b.count end)

    local parts = {}
    for i = 1, math.min(#ranked, 5) do
      parts[#parts + 1] = ("$%02X x%d"):format(ranked[i].value, ranked[i].count)
    end
    log("  nibble %2d: %3d distinct values over %d objects; commonest %s",
      kind, #ranked, total, table.concat(parts, ", "))
  end

  -- What the nibble-1 objects actually say.
  local list = by_kind[events.OBJECT_ITEM] or {}
  local counts, quantities = {}, {}
  local shown = 0
  log("\nwhat the nibble-%d objects name:", events.OBJECT_ITEM)
  for _, entry in ipairs(list) do
    local ball = as_itemball(entry)
    if ball then
      counts[ball.name] = (counts[ball.name] or 0) + 1
      quantities[ball.quantity] = (quantities[ball.quantity] or 0) + 1
      if shown < 16 then
        shown = shown + 1
        log("  %-22s %s x%d  (%s)", entry.map, ball.name, ball.quantity,
          ball.pocket)
      end
    end
  end

  local ranked = {}
  for name, count in pairs(counts) do
    ranked[#ranked + 1] = { name = name, count = count }
  end
  table.sort(ranked, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.name < b.name
  end)
  log("\nmost common pickups:")
  for i = 1, math.min(#ranked, 14) do
    log("  %3d x %s", ranked[i].count, ranked[i].name)
  end

  local quantity_shape = {}
  for quantity, count in pairs(quantities) do
    quantity_shape[#quantity_shape + 1] = ("x%d: %d"):format(quantity, count)
  end
  table.sort(quantity_shape)
  log("\nquantities: %s", table.concat(quantity_shape, ", "))

  rom:release()

  local fh = io.open(report_path, "w")
  if fh then
    fh:write(table.concat(report, "\n") .. "\n")
    fh:close()
  end
  return true
end

return probe
