-- Mart inventories.
--
-- A mart list is a count, that many item ids, then $FF. A run of near pointers
-- indexes them, and a script reaches one by index through the `pokemart`
-- command.
--
-- The shape alone is far too common to search for: 320 offsets in Crystal read
-- as a mart list, most of them coincidence. What identifies the real table is
-- that its lists sit back to back in one block, that a run of pointers lands on
-- them and nothing else, and -- the part that settles it -- that the pointer
-- table ends exactly where the first list begins. A table of n pointers whose
-- own end is the first thing it points at is not something noise produces.

local marts = {}

marts.TERMINATOR = 0xFF
-- A shop with one item is possible in principle but does not occur, and
-- allowing it triples the number of coincidental matches.
marts.MIN_ITEMS = 2
marts.MAX_ITEMS = 16

--- Read one mart list.
-- @param sellable a predicate saying whether an item id can be stocked
-- @return array of item ids, bytes consumed, or nil
function marts.decode(rom, offset, sellable)
  local count = rom:u8(offset)
  if count < marts.MIN_ITEMS or count > marts.MAX_ITEMS then
    return nil
  end
  if offset + count + 1 >= rom.size then
    return nil
  end
  if rom:u8(offset + count + 1) ~= marts.TERMINATOR then
    return nil
  end

  local list, seen = {}, {}
  for i = 1, count do
    local item = rom:u8(offset + i)
    if not sellable(item) then
      return nil
    end
    -- A shop does not stock the same thing twice, and requiring that removes
    -- most of the runs of repeated bytes that otherwise pass.
    if seen[item] then
      return nil
    end
    seen[item] = true
    list[i] = item
  end

  return list, count + 2
end

--- Build the predicate that says what a shop can sell.
-- Read from the item tables rather than listed here: a real item, with a name
-- that is not one of the unused placeholder slots, that has a price.
function marts.sellable_predicate(names, attributes)
  return function(item)
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
end

-- The script command that opens a shop, and how its arguments sit. The opcode
-- table gives it three argument bytes; a walk over every map script shows the
-- first is 0 in 27 of the 29 reachable cases and the rest carry an index that
-- is different every time, which is what a mart id looks like and what a
-- dialogue variant does not.
marts.POKEMART = 0x94

--- Which mart a script opens, if it opens one.
-- @param count how many marts there are, so an out-of-range index is rejected
-- @return a 1-based mart index, or nil
function marts.for_script(rom, scripts, bank, addr, count)
  local args = scripts.find_opcode(rom, bank, addr, marts.POKEMART)
  if not args then
    return nil
  end

  -- The index is stored in the word after the dialogue byte, and is 0-based.
  local index = rom:u16le(args + 1) + 1
  if index < 1 or index > count then
    return nil
  end
  return index
end

--- Locate the mart table.
-- @return { offset, count, lists = { {item, ...}, ... } } or nil plus a reason
function marts.locate(rom, names, attributes)
  local sellable = marts.sellable_predicate(names, attributes)

  -- Every offset that reads as a list, so the pointer scan can test membership
  -- in constant time rather than re-decoding.
  local is_list = {}
  local any = false
  for offset = 0, rom.size - 2 do
    if marts.decode(rom, offset, sellable) then
      is_list[offset] = true
      any = true
    end
  end

  if not any then
    return nil, "no offset in the ROM reads as a mart list"
  end

  -- The longest run of near pointers that all land on lists in their own bank.
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
      if not is_list[bank * 0x4000 + (addr - 0x4000)] then
        break
      end
      count = count + 1
      at = at + 2
    end
    if count > best.count then
      best = { count = count, offset = offset }
    end
    -- Skip past what was just consumed; a shorter run starting inside a longer
    -- one cannot beat it.
    offset = offset + (count > 0 and count * 2 or 1)
  end

  if best.count < 8 then
    return nil, ("the longest run of mart pointers was %d, too short to trust")
      :format(best.count)
  end

  local bank = math.floor(best.offset / 0x4000)
  local lists, offsets = {}, {}
  for index = 1, best.count do
    local addr = rom:u16le(best.offset + (index - 1) * 2)
    local flat = bank * 0x4000 + (addr - 0x4000)
    offsets[index] = flat
    lists[index] = (marts.decode(rom, flat, sellable))
  end

  -- The table ends where its data begins. This is the check that separates a
  -- real find from a plausible one, and it is not something the search was
  -- built to satisfy.
  local table_end = best.offset + best.count * 2
  local first = math.huge
  for _, flat in ipairs(offsets) do
    first = math.min(first, flat)
  end
  if first ~= table_end then
    return nil, ("the pointer table ends at 0x%06X but its first list is at " ..
      "0x%06X"):format(table_end, first)
  end

  return {
    offset = best.offset,
    count = best.count,
    lists = lists,
    offsets = offsets,
  }
end

return marts
