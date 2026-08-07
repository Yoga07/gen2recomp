-- Trainer parties.
--
-- A trainer is a name in the game's own character encoding terminated by $50,
-- then a type byte saying what each party member carries, then one to six
-- members, then $FF.
--
--   0  normal      level, species
--   1  moves       level, species, four move ids
--   2  item        level, species, held item
--   3  item+moves  level, species, held item, four move ids
--
-- Trainers of the same class sit together, so they come back as runs. The
-- structure is documented in pokecrystal; where the table lives is found here
-- by search, so Gold and Silver work from the same code.
--
-- The signature is strong for the same reason the encounter tables' is: a
-- trainer constrains its name to decodable characters, its type to four values,
-- and every member's level and species to real ranges, all at once.

local text = require("src.rom.text")

local trainers = {}

trainers.TERMINATOR = 0xFF
trainers.NAME_TERMINATOR = 0x50
trainers.MAX_NAME = 12
trainers.MAX_PARTY = 6
trainers.SPECIES_COUNT = 251
trainers.MOVE_COUNT = 251
trainers.MAX_LEVEL = 100

trainers.types = {
  [0] = { name = "normal", extra = 0 },
  [1] = { name = "moves", extra = 4 },
  [2] = { name = "item", extra = 1 },
  [3] = { name = "item_moves", extra = 5 },
}

--- Read one trainer at `offset`.
-- @return record, bytes consumed, or nil plus a reason
function trainers.decode(rom, offset)
  -- Name.
  local name_length = nil
  for i = 0, trainers.MAX_NAME do
    if offset + i >= rom.size then
      return nil, "name runs past the ROM"
    end
    local code = rom:u8(offset + i)
    if code == trainers.NAME_TERMINATOR then
      name_length = i
      break
    end
    if not text.charmap[code] then
      return nil, ("byte $%02X in the name is not a character"):format(code)
    end
  end

  if not name_length or name_length == 0 then
    return nil, "no usable name"
  end

  local at = offset + name_length + 1
  if at >= rom.size then
    return nil, "type byte runs past the ROM"
  end

  local type_id = rom:u8(at)
  local kind = trainers.types[type_id]
  if not kind then
    return nil, ("party type %d is not one of the four"):format(type_id)
  end
  at = at + 1

  -- Party members. Level and species are the fields worth constraining; items
  -- and moves span most of a byte's range and rule little out.
  local party = {}
  while true do
    if at >= rom.size then
      return nil, "party runs past the ROM"
    end

    if rom:u8(at) == trainers.TERMINATOR then
      at = at + 1
      break
    end

    if #party >= trainers.MAX_PARTY then
      return nil, "party exceeds six members"
    end

    local level = rom:u8(at)
    local species = rom:u8(at + 1)
    if level < 1 or level > trainers.MAX_LEVEL then
      return nil, ("level %d is out of range"):format(level)
    end
    if species < 1 or species > trainers.SPECIES_COUNT then
      return nil, ("species %d does not exist"):format(species)
    end

    local member = { level = level, species = species }
    local cursor = at + 2

    if type_id == 2 or type_id == 3 then
      member.item = rom:u8(cursor)
      cursor = cursor + 1
    end

    if type_id == 1 or type_id == 3 then
      member.moves = {}
      for i = 1, 4 do
        local move = rom:u8(cursor)
        if move > trainers.MOVE_COUNT then
          return nil, ("move %d does not exist"):format(move)
        end
        member.moves[i] = move
        cursor = cursor + 1
      end
    end

    party[#party + 1] = member
    at = cursor
  end

  if #party == 0 then
    return nil, "trainer has no party"
  end

  return {
    offset = offset,
    name = text.decode(rom.data, offset, name_length),
    type_id = type_id,
    type_name = kind.name,
    party = party,
  }, at - offset
end

--- Locate the trainer party tables.
--
-- @return list of { offset, count, entries } or nil plus a reason
function trainers.locate(rom, minimum)
  minimum = minimum or 6
  local runs = {}

  local offset = 0
  while offset < rom.size do
    local first = trainers.decode(rom, offset)
    if first then
      local start = offset
      local entries = {}
      while offset < rom.size do
        local record, consumed = trainers.decode(rom, offset)
        if not record then
          break
        end
        entries[#entries + 1] = record
        offset = offset + consumed
      end

      if #entries >= minimum then
        runs[#runs + 1] = { offset = start, count = #entries, entries = entries }
      end
    else
      offset = offset + 1
    end
  end

  if #runs == 0 then
    return nil, "no run of trainer parties found"
  end

  table.sort(runs, function(a, b) return a.count > b.count end)
  return runs
end

return trainers
