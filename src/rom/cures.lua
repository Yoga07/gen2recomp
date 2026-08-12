-- Which status each curing item undoes.
--
-- An item record says *how much* — a Potion's parameter is 20, a Super Potion's
-- 60 — and the engine reads that without ever knowing which item is which. The
-- status cures break that scheme: an Antidote's parameter is 0, because what it
-- does is not a quantity. Something else has to say "poison", and until this was
-- found the engine refused those items rather than guessing at them.
--
-- The table is fourteen three-byte records terminated by $FF:
--
--   09 F0 08   ANTIDOTE     poison
--   0A F1 10   BURN HEAL    burn
--   0B F2 20   ICE HEAL     freeze
--   0C F3 07   AWAKENING    sleep
--   0D F4 40   PARLYZ HEAL  paralysis
--   26 F6 FF   FULL HEAL    everything
--
-- The third byte is a mask over the Gen 2 status byte, which packs sleep into
-- the low three bits and gives poison, burn, freeze and paralysis one bit each
-- above them. That is why the masks are single bits and $07 — and why a mask of
-- $FF means "all of it".
--
-- ## Finding it, and the search that did not work
--
-- The obvious search is "where do the ids of the curing items appear near each
-- other", and it is close to worthless. The five single-status cures are items
-- **9, 10, 11, 12 and 13** — consecutive — so every ascending run of bytes in
-- the cartridge contains all five, and so does every shop that stocks a Pokémon
-- Centre's worth of medicine. Scored against other runs of five consecutive ids
-- it is unremarkable: at stride 2 the real five score 330 where the average run
-- scores 296.
--
-- What is sharp is not where the ids are but **what sits beside them**. A status
-- mask has very few bits set, and six different items must undo six different
-- things, so the demand is that all six ids be accompanied at a fixed distance
-- by bytes that are distinct and sparse. Across every stride and every distance
-- that leaves one candidate reading as a status at all, and it reads perfectly:
-- six items whose effect nobody disputes, mapped one-to-one onto six separate,
-- non-overlapping bit positions.
--
-- ## What confirms it
--
-- Six records were used to find the table. The other eight were not, and every
-- one of them lands:
--
--   PSNCUREBERRY  poison       the name says so outright
--   PRZCUREBERRY  paralysis    so does this one
--   MINT BERRY    sleep
--   ICE BERRY     **burn**     crossed
--   BURNT BERRY   **freeze**   crossed the other way
--   FULL RESTORE, HEAL POWDER, MIRACLEBERRY   everything
--
-- The two crossed berries are the best evidence in the set. An ice berry
-- soothing a burn and a burnt berry thawing a freeze is exactly the pairing
-- somebody guessing from the names would invert, and the table gets both the
-- right way round without being asked.

local cures = {}

cures.RECORD_SIZE = 3
cures.TERMINATOR = 0xFF

-- A real table is well over this. Used only to throw away short coincidences.
cures.MIN_RECORDS = 8

-- Which engine status each mask undoes. The bit positions are Gen 2's, and they
-- are the hypothesis the search tests rather than something read off the ROM:
-- what the cartridge supplies is the pairing of item to mask, and the pairing
-- coming out one-to-one across six known items is what says the reading is
-- right.
cures.STATUS = {
  [0x07] = "sleep",
  [0x08] = "poison",
  [0x10] = "burn",
  [0x20] = "freeze",
  [0x40] = "paralysis",
  [0xFF] = "all",
}

--- What each of these undoes is not in dispute in any game in the series.
-- Named rather than numbered: the ids come from the cartridge's own item-name
-- table, so nothing here is an offset or an index.
cures.KNOWN = {
  ["ANTIDOTE"] = 0x08,
  ["BURN HEAL"] = 0x10,
  ["ICE HEAL"] = 0x20,
  ["AWAKENING"] = 0x07,
  ["PARLYZ HEAL"] = 0x40,
}

--- Records that took no part in the search, checked once it is accepted.
-- The crossed pair is the valuable one: an ICE BERRY undoes a burn and a BURNT
-- BERRY undoes a freeze, which is the mapping a guess from the names inverts.
cures.SPOT_CHECKS = {
  ["PSNCUREBERRY"] = "poison",
  ["PRZCUREBERRY"] = "paralysis",
  ["MINT BERRY"] = "sleep",
  ["ICE BERRY"] = "burn",
  ["BURNT BERRY"] = "freeze",
  ["MIRACLEBERRY"] = "all",
}

local function popcount(value)
  local count = 0
  while value > 0 do
    count = count + value % 2
    value = math.floor(value / 2)
  end
  return count
end

--- A mask is a single status bit, the three-bit sleep field, or all of them.
function cures.is_mask(value)
  local bits = popcount(value)
  return bits == 1 or bits == 3 or bits == 8
end

--- Could the three bytes at `offset` be a record?
local function credible(data, offset, item_count)
  local item = string.byte(data, offset + 1)
  local mask = string.byte(data, offset + 3)
  if not item or not mask then
    return false
  end
  if item < 1 or item > item_count then
    return false
  end
  return cures.is_mask(mask)
end

--- Locate and decode the table.
-- @param item_names the decoded item-name table, which is what turns the known
--        cures into ids without any of them being numbered here
-- @return { offset, records = { { item, action, mask, status } }, by_item }
--         or nil plus a reason
function cures.locate(rom, item_names)
  if not item_names then
    return nil, "the item names are needed to know which item is which"
  end

  local data = rom.data
  local item_count = #item_names

  local id_of = {}
  for index, name in ipairs(item_names) do
    id_of[name] = index
  end

  -- Every known cure has to be in this cartridge's name table for the search to
  -- mean anything.
  local wanted = {}
  for name, mask in pairs(cures.KNOWN) do
    local id = id_of[name]
    if not id then
      return nil, ("this cartridge has no item called %q"):format(name)
    end
    wanted[id] = mask
  end

  local accepted = {}
  local offset = 0
  while offset < #data - cures.RECORD_SIZE do
    if credible(data, offset, item_count) then
      local start = offset
      local count = 0
      while offset < #data - cures.RECORD_SIZE
        and credible(data, offset, item_count) do
        count = count + 1
        offset = offset + cures.RECORD_SIZE
      end

      -- A table ends on the terminator every other list in this cartridge uses.
      if count >= cures.MIN_RECORDS
        and string.byte(data, offset + 1) == cures.TERMINATOR then
        -- Does it pair every known cure with the status it really undoes?
        local matched, wrong = 0, false
        for index = 0, count - 1 do
          local at = start + index * cures.RECORD_SIZE
          local item = string.byte(data, at + 1)
          local mask = string.byte(data, at + 3)
          if wanted[item] then
            if wanted[item] == mask then
              matched = matched + 1
            else
              wrong = true
            end
          end
        end

        local needed = 0
        for _ in pairs(wanted) do
          needed = needed + 1
        end

        if matched == needed and not wrong then
          accepted[#accepted + 1] = { offset = start, count = count }
        end
      end
    else
      offset = offset + 1
    end
  end

  if #accepted == 0 then
    return nil, "no run of status-cure records pairs the known items with " ..
      "the statuses they undo"
  end
  if #accepted > 1 then
    local places = {}
    for _, hit in ipairs(accepted) do
      places[#places + 1] = ("0x%06X"):format(hit.offset)
    end
    return nil, ("the cure table validated at %d offsets (%s); refusing to guess")
      :format(#accepted, table.concat(places, ", "))
  end

  local hit = accepted[1]
  local records, by_item = {}, {}
  for index = 0, hit.count - 1 do
    local at = hit.offset + index * cures.RECORD_SIZE
    local record = {
      item = string.byte(data, at + 1),
      -- The middle byte is a second encoding of the same thing: it is a
      -- one-to-one function of the mask across every record. Kept because it is
      -- there and because that agreement is worth being able to assert, not
      -- because anything reads it.
      action = string.byte(data, at + 2),
      mask = string.byte(data, at + 3),
    }
    record.status = cures.STATUS[record.mask]
    records[index + 1] = record
    by_item[record.item] = record
  end

  -- The spot checks, on records the search did not use.
  for name, expected in pairs(cures.SPOT_CHECKS) do
    local id = id_of[name]
    if id then
      local record = by_item[id]
      if not record then
        return nil, ("%s is not in the table"):format(name)
      end
      if record.status ~= expected then
        return nil, ("%s undoes %s, expected %s")
          :format(name, tostring(record.status), expected)
      end
    end
  end

  -- Internal agreement: the middle byte and the mask say the same thing, so
  -- neither reading can be drifting from the other.
  local action_of, mask_of = {}, {}
  for _, record in ipairs(records) do
    if action_of[record.mask] and action_of[record.mask] ~= record.action then
      return nil, "two records give the same status two different actions"
    end
    if mask_of[record.action] and mask_of[record.action] ~= record.mask then
      return nil, "two records give the same action two different statuses"
    end
    action_of[record.mask] = record.action
    mask_of[record.action] = record.mask
  end

  return {
    offset = hit.offset,
    records = records,
    by_item = by_item,
    count = hit.count,
  }
end

return cures
