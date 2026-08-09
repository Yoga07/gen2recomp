-- Level-up learnsets and evolutions.
--
-- Each species has one block: its evolutions, a zero, then the moves it learns
-- by level as (level, move) pairs, then another zero. Blocks sit back to back
-- in species order, so 251 consecutive well-formed blocks is a signature
-- nothing else in the cartridge matches.
--
-- Evolution entries are three bytes except EVOLVE_STAT, which carries an extra
-- comparison byte:
--
--   1 EVOLVE_LEVEL      method, level, species
--   2 EVOLVE_ITEM       method, item, species
--   3 EVOLVE_TRADE      method, held item, species
--   4 EVOLVE_HAPPINESS  method, time of day, species
--   5 EVOLVE_STAT       method, level, which stat, species
--
-- This replaces the moveset stand-in the battle engine was using, which picked
-- damaging moves by type and produced Pokémon that could fight but knew the
-- wrong things.

local learnsets = {}

learnsets.SPECIES_COUNT = 251
learnsets.MOVE_COUNT = 251
learnsets.MAX_LEVEL = 100
learnsets.TERMINATOR = 0

learnsets.methods = {
  [1] = { name = "level", size = 3 },
  [2] = { name = "item", size = 3 },
  [3] = { name = "trade", size = 3 },
  [4] = { name = "happiness", size = 3 },
  [5] = { name = "stat", size = 4 },
}

-- A species learns a good number of moves but never dozens.
learnsets.MAX_MOVES = 32
learnsets.MAX_EVOLUTIONS = 8

--- Decode one species' block.
-- @return record, bytes consumed, or nil plus a reason
function learnsets.decode(rom, offset)
  local at = offset
  local evolutions = {}

  while true do
    if at >= rom.size then
      return nil, "evolutions run past the ROM"
    end

    local method = rom:u8(at)
    if method == learnsets.TERMINATOR then
      at = at + 1
      break
    end

    local kind = learnsets.methods[method]
    if not kind then
      return nil, ("evolution method %d is unknown"):format(method)
    end
    if #evolutions >= learnsets.MAX_EVOLUTIONS then
      return nil, "too many evolutions"
    end
    if at + kind.size > rom.size then
      return nil, "evolution runs past the ROM"
    end

    -- The species evolved into is always the last byte of the entry.
    local into = rom:u8(at + kind.size - 1)
    if into < 1 or into > learnsets.SPECIES_COUNT then
      return nil, ("evolves into species %d, which does not exist"):format(into)
    end

    local record = { method = kind.name, into = into }
    if method == 1 or method == 5 then
      record.level = rom:u8(at + 1)
      if record.level < 2 or record.level > learnsets.MAX_LEVEL then
        return nil, ("evolution level %d is out of range"):format(record.level)
      end
    else
      record.parameter = rom:u8(at + 1)
    end

    evolutions[#evolutions + 1] = record
    at = at + kind.size
  end

  local moves = {}
  while true do
    if at >= rom.size then
      return nil, "moves run past the ROM"
    end

    local level = rom:u8(at)
    if level == learnsets.TERMINATOR then
      at = at + 1
      break
    end

    if level > learnsets.MAX_LEVEL then
      return nil, ("learn level %d is out of range"):format(level)
    end
    if #moves >= learnsets.MAX_MOVES then
      return nil, "too many level-up moves"
    end
    if at + 2 > rom.size then
      return nil, "move entry runs past the ROM"
    end

    local move = rom:u8(at + 1)
    if move < 1 or move > learnsets.MOVE_COUNT then
      return nil, ("move %d does not exist"):format(move)
    end

    moves[#moves + 1] = { level = level, move = move }
    at = at + 2
  end

  -- Every species learns something.
  if #moves == 0 then
    return nil, "no level-up moves"
  end

  return { offset = offset, evolutions = evolutions, moves = moves },
         at - offset
end

--- Locate the learnset table: 251 consecutive blocks.
-- @return { offset, records } or nil plus a reason
function learnsets.locate(rom)
  local offset = 0
  while offset < rom.size do
    local first = learnsets.decode(rom, offset)
    if first then
      local records = {}
      local at = offset
      local ok = true

      for _ = 1, learnsets.SPECIES_COUNT do
        local record, consumed = learnsets.decode(rom, at)
        if not record then
          ok = false
          break
        end
        records[#records + 1] = record
        at = at + consumed
      end

      if ok and #records == learnsets.SPECIES_COUNT then
        return { offset = offset, records = records }
      end
    end
    offset = offset + 1
  end

  return nil, ("no run of %d learnset blocks found"):format(learnsets.SPECIES_COUNT)
end

--- The four moves a Pokémon of this species would know at a given level.
--
-- The game teaches moves in order and pushes the oldest out once four are
-- known, so the last four learned at or below the level is the right answer.
--- The moves learned on reaching exactly this level.
--
-- Distinct from moves_at, which is everything known by then. Levelling several
-- times at once has to hand out each level's moves separately or the ones in
-- between are silently skipped.
function learnsets.moves_learned_at(record, level)
  local learned = {}
  for _, entry in ipairs(record and record.moves or {}) do
    if entry.level == level then
      learned[#learned + 1] = entry.move
    end
  end
  return learned
end

--- The evolution triggered by reaching a level, if there is one.
function learnsets.evolution_at(record, level)
  for _, entry in ipairs(record and record.evolutions or {}) do
    -- Stat-based evolutions also happen at a level; which branch is taken
    -- depends on a comparison the engine does not model yet, so the first is
    -- taken and the fact is recorded rather than hidden.
    if (entry.method == "level" or entry.method == "stat")
      and entry.level and level >= entry.level then
      return entry
    end
  end
  return nil
end

function learnsets.moves_at(record, level)
  local known = {}
  for _, entry in ipairs(record.moves) do
    if entry.level <= level then
      -- Learning a move already known does not duplicate it.
      local seen = false
      for index, existing in ipairs(known) do
        if existing == entry.move then
          seen = true
          -- It moves to the end of the queue.
          table.remove(known, index)
          known[#known + 1] = entry.move
          break
        end
      end
      if not seen then
        known[#known + 1] = entry.move
        if #known > 4 then
          table.remove(known, 1)
        end
      end
    end
  end
  return known
end

return learnsets
