-- Diagnostic: which status does each curing item undo?
--
-- An item record carries a parameter that says *how much* — a Potion's 20, a
-- Super Potion's 60 — and the engine reads it without knowing which item is
-- which. The status cures break that: an Antidote's parameter is 0, because
-- what it does is not a quantity. Something else has to say "poison", and the
-- engine currently refuses those items rather than guessing.
--
-- Two possibilities, and they are distinguishable rather than a matter of
-- taste. Either there is a small table pairing item ids with status masks, in
-- which case the ids appear as bytes near each other and can be found; or each
-- item's behaviour is a routine reached through a jump table indexed by item id,
-- in which case the ids appear nowhere at all and this is not recoverable from
-- data. This probe tells those apart.
--
-- The known content is the same kind used everywhere else here: an Antidote
-- cures poison and a Burn Heal cures a burn, in every game ever made. The item
-- *ids* are not assumed — they come from the cartridge's own name table.
--
--   love . --probe-cures <rom> <report>

local Rom = require("src.rom.rom")
local locate = require("src.rom.locate")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

local function write(path)
  local fh = io.open(path, "w")
  if fh then
    fh:write(table.concat(report, "\n") .. "\n")
    fh:close()
  end
end

-- What each of these undoes is not in dispute anywhere.
probe.CURES = {
  { "ANTIDOTE", "poison" },
  { "BURN HEAL", "burn" },
  { "ICE HEAL", "freeze" },
  { "AWAKENING", "sleep" },
  { "PARLYZ HEAL", "paralysis" },
  { "FULL HEAL", "everything" },
}

--- Offsets where every id in `wanted` appears among the first `depth` entries
-- of a stride-`step` walk. A table of records has its ids at a constant stride;
-- a coincidence does not.
local function stride_hits(data, wanted, step, depth)
  local hits = {}
  local target_count = 0
  for _ in pairs(wanted) do
    target_count = target_count + 1
  end

  for offset = 0, #data - step * depth - 1 do
    local seen, found = {}, 0
    for index = 0, depth - 1 do
      local value = string.byte(data, offset + index * step + 1)
      if wanted[value] and not seen[value] then
        seen[value] = true
        found = found + 1
      end
    end
    if found == target_count then
      hits[#hits + 1] = offset
    end
  end
  return hits
end

function probe.run(rom_path, report_path)
  report = {}

  local rom, err = Rom.load(rom_path)
  if not rom then
    log("FATAL: %s", err)
    write(report_path)
    return true
  end
  local data = rom.data

  local names = locate.table(locate.descriptors.item_names, rom)
  if not names then
    log("FATAL: the item names did not locate")
    rom:release()
    write(report_path)
    return true
  end
  names = names.records

  local id_of = {}
  for index, name in ipairs(names) do
    id_of[name] = index
  end

  log("== the items whose effect is not a quantity ==")
  local wanted, labels, missing = {}, {}, 0
  for _, entry in ipairs(probe.CURES) do
    local name, cures = entry[1], entry[2]
    local id = id_of[name]
    if id then
      wanted[id] = name
      labels[id] = cures
      log("  %-12s id %3d, cures %s", name, id, cures)
    else
      missing = missing + 1
      log("  %-12s NOT IN THIS CARTRIDGE'S NAME TABLE", name)
    end
  end
  if missing > 0 then
    log("  (%d of the names did not match; the search below is weaker for it)",
      missing)
  end

  -- The attribute records, to show what is and is not already known.
  local attributes = locate.table(locate.descriptors.item_attributes, rom)
  if attributes then
    log("\n== what their attribute records already say ==")
    for id, name in pairs(wanted) do
      local record = attributes.records[id]
      log("  %-12s parameter %3d, field %s, battle %s", name,
        record.parameter, tostring(record.field_use),
        tostring(record.battle_use))
    end
  end

  -- "Are these six ids near each other" is a far weaker question than it looks,
  -- and the reason is the ids themselves: the five single-status cures are
  -- 9, 10, 11, 12 and 13. They are *consecutive*, so every ascending run of
  -- bytes in the cartridge contains all five, and so does every mart that
  -- stocks a Pokémon Centre's worth of medicine.
  --
  -- So the control has to match the shape of the target and not merely its
  -- size. Scoring five consecutive ids starting at every k says exactly how
  -- unremarkable the real five are.
  log("\n== how unusual is a run containing ids 9 to 13? ==")
  -- Sampled every eighth starting id rather than all 250: each score is a full
  -- pass over two megabytes, and the shape of the distribution is what matters
  -- here, not its last decimal place.
  for _, step in ipairs({ 1, 2, 3 }) do
    local mine, better, total, samples = nil, 0, 0, 0
    local scores = {}

    local function score_for(k)
      local set = {}
      for i = 0, 4 do
        set[k + i] = true
      end
      return #stride_hits(data, set, step, 16)
    end

    mine = score_for(9)
    for k = 1, #names - 5, 8 do
      local score = score_for(k)
      scores[#scores + 1] = score
      total = total + score
      samples = samples + 1
      if score >= mine then
        better = better + 1
      end
    end
    log("  stride %d: ids 9-13 score %d; %d of %d sampled five-runs score at " ..
      "least as well (mean %.0f)", step, mine, better, samples, total / samples)
  end

  -- The question that is actually sharp: is each cure id accompanied by
  -- something that reads as a status?
  --
  -- The Gen 2 status byte packs sleep into the low three bits and gives poison,
  -- burn, freeze and paralysis one bit each above them. A mask therefore has
  -- very few bits set. That is treated as the hypothesis rather than as fact:
  -- the search only demands that the six accompanying bytes be distinct and
  -- sparse, and prints them so the values can be read rather than assumed.
  local function popcount(value)
    local count = 0
    while value > 0 do
      count = count + value % 2
      value = math.floor(value / 2)
    end
    return count
  end

  log("\n== is each cure id sitting next to something shaped like a status? ==")
  local found_any = false
  for step = 2, 4 do
    for distance = 1, step - 1 do
      local hits = {}
      for offset = 0, #data - step * 24 - 1 do
        local at, seen = {}, 0
        for index = 0, 23 do
          local value = string.byte(data, offset + index * step + 1)
          if wanted[value] and not at[value] then
            at[value] = offset + index * step + distance
            seen = seen + 1
          end
        end
        if seen == 6 then
          local masks, distinct, sparse = {}, {}, true
          local count = 0
          for id in pairs(at) do
            local mask = string.byte(data, at[id] + 1)
            masks[id] = mask
            local bits = popcount(mask)
            if bits == 0 or (bits > 3 and bits < 8) then
              sparse = false
            end
            if not distinct[mask] then
              distinct[mask] = true
              count = count + 1
            end
          end
          if sparse and count == 6 then
            hits[#hits + 1] = { offset = offset, masks = masks }
          end
        end
      end
      if #hits > 0 then
        found_any = true
        log("  stride %d, mask at +%d: %d candidate(s)", step, distance, #hits)
        for index = 1, math.min(#hits, 5) do
          local hit = hits[index]
          local parts = {}
          for id, name in pairs(wanted) do
            parts[#parts + 1] = ("%s=%02X"):format(name, hit.masks[id])
          end
          log("    0x%06X  %s", hit.offset, table.concat(parts, " "))
        end
      end
    end
  end

  if not found_any then
    log("  Nothing. At no stride and no distance is every cure id accompanied")
    log("  by a distinct, sparse byte.")
  end

  -- Read the whole table off, rather than only the six records that found it.
  -- Walking outwards from a hit until the records stop being credible is how
  -- the standard-script table and the music table were sized, and it is what
  -- says whether the six known cures are all of it or only the part we could
  -- name from outside.
  log("\n== the table, walked outwards from the hit ==")
  do
    local anchor = nil
    for offset = 0, #data - 3 do
      if string.byte(data, offset + 1) == 9
        and string.byte(data, offset + 3) == 0x08
        and string.byte(data, offset + 4) == 10
        and string.byte(data, offset + 6) == 0x10 then
        anchor = offset
        break
      end
    end

    if not anchor then
      log("  the anchor pair did not reoccur; nothing to walk")
    else
      local function credible(offset)
        local item = string.byte(data, offset + 1)
        local mask = string.byte(data, offset + 3)
        if not item or not mask then
          return false
        end
        if item < 1 or item > #names then
          return false
        end
        local bits = popcount(mask)
        return bits == 1 or bits == 3 or bits == 8
      end

      local first = anchor
      while first >= 3 and credible(first - 3) do
        first = first - 3
      end
      local last = anchor
      while credible(last + 3) do
        last = last + 3
      end

      log("  table runs 0x%06X..0x%06X (bank $%02X), %d records of 3 bytes",
        first, last + 2, math.floor(first / 0x4000), (last - first) / 3 + 1)
      log("  the byte after it is $%02X",
        string.byte(data, last + 4) or 0)
      log("")
      log("  item                  mid  mask   reads as")
      local MEANING = {
        [0x07] = "sleep", [0x08] = "poison", [0x10] = "burn",
        [0x20] = "freeze", [0x40] = "paralysis", [0xFF] = "everything",
      }
      for offset = first, last, 3 do
        local item = string.byte(data, offset + 1)
        local mid = string.byte(data, offset + 2)
        local mask = string.byte(data, offset + 3)
        log("  %3d %-16s  $%02X  $%02X   %s", item, names[item] or "?", mid,
          mask, MEANING[mask] or "not a single status")
      end
    end
  end

  rom:release()
  write(report_path)
  return true
end

return probe
