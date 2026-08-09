-- Reading a real cartridge save.
--
-- A Game Boy save is 32 KiB of battery-backed RAM. Everything about where
-- things sit inside it differs between Gold, Silver and Crystal, and between
-- localisations, so this does not use offsets at all. It searches, the same way
-- everything else in this project searches, and it validates by a much sharper
-- rule than "these bytes look plausible".
--
-- A party member stores its DVs, its stat experience, its level -- and its
-- computed stats. Those are not independent: the stats follow from the rest by
-- the same formula the battle engine uses. A run of bytes where all five stats
-- reproduce from the DVs and level is not a coincidence, and a run where they
-- do not is not a party, whatever else it looks like.
--
-- That check needs the base stats, which means a cartridge has to have been
-- imported first. Without them there is nothing to validate against and this
-- refuses rather than guessing.

local pokemon = require("src.engine.pokemon")

local sav = {}

sav.SIZE = 32 * 1024
sav.PARTY_LIMIT = 6
sav.MEMBER_SIZE = 48
sav.SPECIES_TERMINATOR = 0xFF
sav.MAX_SPECIES = 251
sav.MAX_LEVEL = 100

-- Where each field sits inside a 48-byte party member.
sav.OFFSETS = {
  species = 0x00,
  held_item = 0x01,
  moves = 0x02,
  statexp = 0x0B,
  dvs = 0x15,
  pp = 0x17,
  friendship = 0x1B,
  level = 0x1F,
  status = 0x20,
  hp = 0x22,
  max_hp = 0x24,
  attack = 0x26,
  defense = 0x28,
  speed = 0x2A,
  special_attack = 0x2C,
  special_defense = 0x2E,
}

-- The order the stats are stored in, after max HP.
sav.STAT_ORDER = { "attack", "defense", "speed", "special_attack",
                   "special_defense" }

-- The base-stat records name the two special stats differently from the
-- computed ones, so the bridge is spelled out rather than assumed.
sav.BASE_FIELD = {
  hp = "hp",
  attack = "attack",
  defense = "defense",
  speed = "speed",
  special_attack = "sp_attack",
  special_defense = "sp_defense",
}

local function u8(data, at)
  return string.byte(data, at + 1)
end

local function u16(data, at)
  return u8(data, at) * 256 + u8(data, at + 1)
end

--- Split the two DV bytes into the four values.
function sav.dvs_at(data, at)
  local first, second = u8(data, at), u8(data, at + 1)
  return {
    attack = math.floor(first / 16),
    defense = first % 16,
    speed = math.floor(second / 16),
    special = second % 16,
  }
end

--- Read one party member, checking its stats against the formula.
-- @return the member, or nil plus the reason it was rejected
function sav.member_at(data, at, base_stats)
  if at + sav.MEMBER_SIZE > #data then
    return nil, "member runs past the end of the save"
  end

  local species = u8(data, at + sav.OFFSETS.species)
  if species < 1 or species > sav.MAX_SPECIES then
    return nil, "species out of range"
  end
  local base = base_stats and base_stats[species]
  if not base then
    return nil, "no base stats for that species"
  end

  local level = u8(data, at + sav.OFFSETS.level)
  if level < 1 or level > sav.MAX_LEVEL then
    return nil, "level out of range"
  end

  local dvs = sav.dvs_at(data, at + sav.OFFSETS.dvs)

  -- Stat experience, five two-byte values in the same order as the stats.
  local statexp = {}
  local names = { "hp", "attack", "defense", "speed", "special" }
  for index, name in ipairs(names) do
    statexp[name] = u16(data, at + sav.OFFSETS.statexp + (index - 1) * 2)
  end

  -- The check that makes this worth anything: every stat has to come back out
  -- of the formula.
  local stats = {}
  local expected_hp = pokemon.stat(base.hp, pokemon.dv_for(dvs, "hp"), level,
    "hp", statexp.hp)
  local stored_hp = u16(data, at + sav.OFFSETS.max_hp)
  if stored_hp ~= expected_hp then
    return nil, ("max HP is %d, the formula gives %d")
      :format(stored_hp, expected_hp)
  end
  stats.hp = stored_hp

  for index, name in ipairs(sav.STAT_ORDER) do
    local stored = u16(data, at + sav.OFFSETS.attack + (index - 1) * 2)
    -- Special attack and special defence share the special stat experience.
    local pool = name:find("special") and statexp.special or statexp[name]
    local expected = pokemon.stat(base[sav.BASE_FIELD[name]],
      pokemon.dv_for(dvs, name), level, name, pool)
    if stored ~= expected then
      return nil, ("%s is %d, the formula gives %d"):format(name, stored,
        expected)
    end
    stats[name] = stored
  end

  local moves = {}
  for index = 1, 4 do
    local move = u8(data, at + sav.OFFSETS.moves + index - 1)
    if move > 0 then
      moves[#moves + 1] = move
    end
  end

  return {
    species = species,
    level = level,
    dvs = dvs,
    statexp = statexp,
    stats = stats,
    moves = moves,
    hp = u16(data, at + sav.OFFSETS.hp),
    held_item = u8(data, at + sav.OFFSETS.held_item),
    friendship = u8(data, at + sav.OFFSETS.friendship),
    status = u8(data, at + sav.OFFSETS.status),
    shiny = pokemon.is_shiny(dvs),
  }
end

--- Is there a party at this offset?
--
-- The layout is a count, then the species in order terminated by $FF, then the
-- members themselves. The species list is always six long whatever the count,
-- so the members begin at a fixed distance.
-- @return list of members, or nil plus a reason
function sav.party_at(data, at, base_stats)
  local count = u8(data, at)
  if not count or count < 1 or count > sav.PARTY_LIMIT then
    return nil, "count out of range"
  end

  local species = {}
  for index = 1, count do
    local value = u8(data, at + index)
    if value < 1 or value > sav.MAX_SPECIES then
      return nil, "species list holds something that is not a species"
    end
    species[index] = value
  end
  -- The species list is six slots wide however many are filled, and the
  -- terminator sits after all six rather than after the last one used.
  if u8(data, at + 1 + sav.PARTY_LIMIT) ~= sav.SPECIES_TERMINATOR then
    return nil, "species list is not terminated"
  end

  local members = {}
  local base = at + 2 + sav.PARTY_LIMIT
  for index = 1, count do
    local member, why = sav.member_at(data,
      base + (index - 1) * sav.MEMBER_SIZE, base_stats)
    if not member then
      return nil, ("member %d: %s"):format(index, why)
    end
    -- The list and the members must agree about what is in the party.
    if member.species ~= species[index] then
      return nil, ("member %d is species %d but the list says %d")
        :format(index, member.species, species[index])
    end
    members[index] = member
  end

  return members
end

--- Find the party in a save.
--
-- Nothing is assumed about where it sits. Every offset is tried and the first
-- one whose members all reproduce their own stats wins; on a real save there is
-- exactly one such place, because the formula agreeing five times over for
-- several Pokemon at once does not happen by accident.
-- @return members, offset, or nil plus a reason
function sav.find_party(data, base_stats)
  if #data ~= sav.SIZE then
    return nil, ("a save is %d bytes; this is %d"):format(sav.SIZE, #data)
  end
  if not base_stats then
    return nil, "no base stats to check the party against; import a cartridge first"
  end

  local found = {}
  for at = 0, #data - (2 + sav.PARTY_LIMIT + sav.MEMBER_SIZE) do
    local members = sav.party_at(data, at, base_stats)
    if members then
      found[#found + 1] = { at = at, members = members }
    end
  end

  if #found == 0 then
    return nil, "no party found: no offset holds members whose stats check out"
  end

  -- More than one would mean the check is weaker than it looks, so say so
  -- rather than taking the first.
  if #found > 1 then
    local places = {}
    for _, entry in ipairs(found) do
      places[#places + 1] = ("0x%04X"):format(entry.at)
    end
    return nil, ("%d offsets look like a party (%s); refusing to guess")
      :format(#found, table.concat(places, ", "))
  end

  return found[1].members, found[1].at
end

--- Turn read members into the party the engine plays with.
--
-- The stats come from the save rather than being recomputed, which matters for
-- a Pokemon carrying stat experience: recomputing from level alone would quietly
-- weaken it. They agreed with the formula on the way in, so this is not
-- trusting the file, it is keeping what was already checked.
function sav.to_party(members, base_stats, learnset_records)
  local party = {}
  for index, member in ipairs(members) do
    local base = base_stats[member.species]
    local instance = pokemon.new(member.species, base, {
      level = member.level,
      dvs = member.dvs,
      statexp = member.statexp,
      moves = member.moves,
    })
    instance.stats = member.stats
    instance.hp = math.min(member.hp, member.stats.hp)
    instance.held_item = member.held_item > 0 and member.held_item or nil
    instance.friendship = member.friendship
    if #instance.moves == 0 then
      instance.moves = pokemon.moves_from_learnset(instance, learnset_records)
    end
    party[index] = instance
  end
  return party
end

--- Load a save file from disk.
function sav.load(path, base_stats)
  local file = io.open(path, "rb")
  if not file then
    return nil, ("could not open %s"):format(tostring(path))
  end
  local data = file:read("*all")
  file:close()

  return sav.find_party(data, base_stats)
end

return sav
