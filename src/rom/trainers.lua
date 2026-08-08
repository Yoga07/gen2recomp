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
-- Long enough for the longest trainer name in the game. Twelve was too tight
-- and rejected real entries, which then truncated the class they belonged to.
trainers.MAX_NAME = 16
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

-- An upper bound for the search, not the answer. The trainer *pic* table has 67
-- entries, but the party class table is shorter — Crystal's runs to 57 — and
-- reading to 67 walks off the end into code. The real length is found by
-- reading until a pointer stops resolving.
trainers.MAX_CLASSES = 80

--- Locate the table that says where each trainer class's parties begin.
--
-- A trainer names its party by class and id, and the parties are stored one
-- class after another, so without this the flat list cannot be indexed. The
-- table is a run of near pointers landing on trainer entries — the same shape
-- as the map group table.
--
-- @param entries every decoded trainer, used to know where entries start
-- @return { offset, classes = { flat offset per class } } or nil plus a reason
function trainers.locate_groups(rom, entries)
  -- The entries are used only to learn which bank the parties live in; the
  -- pointers themselves are validated by decoding, not by membership.
  local bank
  for _, entry in ipairs(entries) do
    bank = bank or math.floor(entry.offset / 0x4000)
  end

  if not bank then
    return nil, "no trainer entries to anchor against"
  end

  -- A pointer is good if a trainer entry decodes where it lands. Requiring it
  -- to match an entry the flat scan already found is too strict: that scan
  -- comes back as separate runs with a gap, and every class beginning inside
  -- the gap would be rejected — 56 of 67 resolved that way.
  local function target(offset)
    local addr = rom:u16le(offset)
    if addr < 0x4000 or addr > 0x7FFF then
      return nil
    end
    local flat = bank * 0x4000 + (addr - 0x4000)
    if flat >= rom.size then
      return nil
    end
    return trainers.decode(rom, flat) and flat or nil
  end

  -- Find the longest run of pointers that land on entry starts and march
  -- forward, then read the full class count from where it begins. The run is
  -- only used to locate the table: a class whose pointer happens to go
  -- backwards would truncate the run but is still a real class.
  local best = { count = 0 }
  local offset = 0
  while offset <= rom.size - 2 do
    if target(offset) then
      local start, count, previous = offset, 0, -1
      while offset <= rom.size - 2 do
        local flat = target(offset)
        if not flat or flat <= previous then
          break
        end
        count = count + 1
        previous = flat
        offset = offset + 2
      end
      if count > best.count then
        best = { count = count, offset = start }
      end
    else
      offset = offset + 1
    end
  end

  if best.count < 20 then
    return nil, ("longest run of class pointers was %d, too short")
      :format(best.count)
  end

  -- Read forward, tolerating gaps. Stopping at the first pointer that does not
  -- resolve truncates the table at any single awkward entry — doing that cut
  -- Crystal off at 50 classes when classes 55 to 57 are plainly real. Several
  -- failures in a row is what actually marks the end.
  local classes = {}
  local count, misses = 0, 0
  for class = 1, trainers.MAX_CLASSES do
    local at = best.offset + (class - 1) * 2
    if at + 2 > rom.size then
      break
    end

    local resolved = target(at)
    if resolved then
      classes[class] = resolved
      count = count + 1
      misses = 0
    else
      misses = misses + 1
      if misses >= 4 then
        break
      end
    end
  end

  return { offset = best.offset, classes = classes, count = count,
           run = best.count }
end

--- The party for one trainer, by class and id.
--
-- Trainers within a class are stored back to back, so the id-th is reached by
-- walking forward from the class's first entry.
function trainers.party_for(rom, groups, class, id)
  local start = groups.classes[class]
  if not start then
    return nil, ("class %d has no entry"):format(class)
  end

  local at = start
  for index = 1, id do
    local record, consumed = trainers.decode(rom, at)
    if not record then
      return nil, ("class %d entry %d did not decode"):format(class, index)
    end
    if index == id then
      return record
    end
    at = at + consumed
  end

  return nil, "ran past the class"
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
