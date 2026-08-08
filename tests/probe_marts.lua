-- Diagnostic: where are the mart inventories?
--
-- A mart list is a count, that many item ids, then $FF. That shape is common
-- enough in two megabytes that finding one proves nothing; what should give the
-- real table away is that the real ones sit together in a block, and that a run
-- of near pointers elsewhere points at them.
--
-- Nothing here presumes which mart comes first, so the search does not depend
-- on remembering Cherrygrove's stock.
--
--   love . --probe-marts <rom> <report>

local Rom = require("src.rom.rom")
local locate = require("src.rom.locate")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

probe.MIN_ITEMS = 2
probe.MAX_ITEMS = 16
probe.TERMINATOR = 0xFF

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

  -- What a shop can plausibly sell: a real item with a real price. The unused
  -- slots and the things with no price are what rule most candidates out.
  local function sellable(item)
    if item < 1 or item > 255 then
      return false
    end
    local record = attributes[item]
    local name = names[item]
    if not record or not name or name == "TERU-SAMA" then
      return false
    end
    return record.price > 0
  end

  local function read_mart(offset)
    local count = rom:u8(offset)
    if count < probe.MIN_ITEMS or count > probe.MAX_ITEMS then
      return nil
    end
    if offset + count + 1 >= rom.size then
      return nil
    end
    if rom:u8(offset + count + 1) ~= probe.TERMINATOR then
      return nil
    end

    local list, seen = {}, {}
    for i = 1, count do
      local item = rom:u8(offset + i)
      if not sellable(item) then
        return nil
      end
      -- A shop does not stock the same thing twice.
      if seen[item] then
        return nil
      end
      seen[item] = true
      list[#list + 1] = item
    end
    return list
  end

  local hits = {}
  for offset = 0, rom.size - 2 do
    local list = read_mart(offset)
    if list then
      hits[#hits + 1] = { offset = offset, items = list }
    end
  end
  log("%d offsets read as a mart list", #hits)

  -- Group them: consecutive lists that sit end to end, which is how a table of
  -- them would be laid out.
  local clusters = {}
  local current = nil
  for _, hit in ipairs(hits) do
    local ends_at = hit.offset + #hit.items + 2
    if current and hit.offset == current.ends_at then
      current.count = current.count + 1
      current.ends_at = ends_at
      current.lists[#current.lists + 1] = hit
    else
      current = { start = hit.offset, ends_at = ends_at, count = 1,
                  lists = { hit } }
      clusters[#clusters + 1] = current
    end
  end

  table.sort(clusters, function(a, b) return a.count > b.count end)
  log("\nlongest runs of back-to-back lists:")
  for i = 1, math.min(#clusters, 8) do
    local cluster = clusters[i]
    log("  0x%06X: %d lists, ending 0x%06X", cluster.start, cluster.count,
      cluster.ends_at)
  end

  -- Now look for a pointer table. A mart index resolves through a run of near
  -- pointers, so scan for runs of words that land on offsets that read as a
  -- mart list within the same bank.
  local function by_offset(target)
    for _, hit in ipairs(hits) do
      if hit.offset == target then
        return hit
      end
    end
    return nil
  end

  local best = { count = 0 }
  local offset = 0
  while offset <= rom.size - 2 do
    local bank = math.floor(offset / 0x4000)
    local count, at = 0, offset
    while at <= rom.size - 2 do
      local addr = rom:u16le(at)
      if addr < 0x4000 or addr > 0x7FFF then
        break
      end
      local flat = bank * 0x4000 + (addr - 0x4000)
      if not by_offset(flat) then
        break
      end
      count = count + 1
      at = at + 2
    end
    if count > best.count then
      best = { count = count, offset = offset }
    end
    offset = offset + (count > 0 and count * 2 or 1)
  end

  log("\nlongest run of pointers landing on mart lists: %d at 0x%06X",
    best.count, best.offset)

  if best.count > 0 then
    local bank = math.floor(best.offset / 0x4000)
    log("\nwhat that table resolves to:")
    for index = 1, math.min(best.count, 40) do
      local addr = rom:u16le(best.offset + (index - 1) * 2)
      local flat = bank * 0x4000 + (addr - 0x4000)
      local hit = by_offset(flat)
      local parts = {}
      for _, item in ipairs(hit.items) do
        parts[#parts + 1] = names[item]
      end
      log("  %2d 0x%06X  %s", index, flat, table.concat(parts, ", "))
    end
  end

  -- Which map opens which mart. The script command is $94 with three argument
  -- bytes, so walking every map script and recording what it carries says
  -- whether those bytes are a mart index and, if so, how they are laid out.
  local tilesets = require("src.rom.tilesets")
  local maps = require("src.rom.maps")
  local events = require("src.rom.events")
  local script_ops = require("src.rom.script_ops")

  local POKEMART = 0x94
  local widths, terminators, op_names = script_ops.widths()

  local function walk_for_mart(bank, addr, found)
    if not addr or addr < 0x4000 or addr > 0x7FFF then
      return
    end
    local at = bank * 0x4000 + (addr - 0x4000)
    for _ = 1, 200 do
      if at + 1 > rom.size then
        return
      end
      local opcode = rom:u8(at)
      local width = widths[opcode]
      if width == nil then
        return
      end
      if opcode == POKEMART then
        found[#found + 1] = {
          offset = at,
          first = rom:u8(at + 1),
          word = rom:u16le(at + 2),
        }
      end
      at = at + 1 + width
      if terminators[opcode] then
        return
      end
      local name = op_names[opcode]
      if name and (name:sub(1, 2) == "if" or name == "scall"
        or name == "farscall") then
        return
      end
    end
  end

  local tileset_result = tilesets.locate(rom)
  local map_result = maps.locate(rom, tileset_result.count)

  local found = {}
  for _, header in ipairs(map_result.headers) do
    local decoded = not header.unparsed and events.decode(rom, header)
    if decoded then
      local bank = math.floor(header.attributes.scripts / 0x4000)
      for _, bg in ipairs(decoded.bg_events) do
        walk_for_mart(bank, bg.script, found)
      end
      for _, object in ipairs(decoded.objects) do
        if object.kind ~= events.OBJECT_TRAINER
          and object.kind ~= events.OBJECT_ITEM then
          walk_for_mart(bank, object.script, found)
        end
      end
      for _, coord in ipairs(decoded.coord_events) do
        walk_for_mart(bank, coord.script, found)
      end
    end
  end

  log("\n%d pokemart commands reached by a linear walk", #found)
  local firsts, words = {}, {}
  for _, hit in ipairs(found) do
    firsts[hit.first] = (firsts[hit.first] or 0) + 1
    words[hit.word] = (words[hit.word] or 0) + 1
  end

  local function shape(counts, label)
    local ranked = {}
    for value, count in pairs(counts) do
      ranked[#ranked + 1] = { value = value, count = count }
    end
    table.sort(ranked, function(a, b) return a.value < b.value end)
    local parts = {}
    for i = 1, math.min(#ranked, 20) do
      parts[#parts + 1] = ("%d x%d"):format(ranked[i].value, ranked[i].count)
    end
    log("  %s: %d distinct -- %s", label, #ranked, table.concat(parts, ", "))
  end
  shape(firsts, "first byte")
  shape(words, "following word")

  rom:release()

  local fh = io.open(report_path, "w")
  if fh then
    fh:write(table.concat(report, "\n") .. "\n")
    fh:close()
  end
  return true
end

return probe
