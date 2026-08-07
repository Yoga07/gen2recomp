-- Type effectiveness.
--
-- Multipliers are kept in tenths, the way the game stores them, so the whole
-- damage calculation can stay in integers: 20 is double, 5 is half, 0 is no
-- effect, and anything unlisted is 10.
--
-- Gen 2 decides physical versus special by the move's *type*, not per move.
-- Everything from normal through steel is physical; fire onwards is special.
-- That is why Gen 2 Hyper Beam is physical and Gen 2 Bite is special, which
-- looks wrong to anyone used to later games.

local types = {}

types.NORMAL = 10
types.SUPER = 20
types.NOT_VERY = 5
types.NONE = 0

-- Chart from pokecrystal's type matchups. Only the entries that are not 1x are
-- listed, which is how the cartridge stores it too.
local chart = {
  normal =   { rock = 5, steel = 5, ghost = 0 },
  fire =     { fire = 5, water = 5, grass = 20, ice = 20, bug = 20, rock = 5,
               dragon = 5, steel = 20 },
  water =    { fire = 20, water = 5, grass = 5, ground = 20, rock = 20,
               dragon = 5 },
  electric = { water = 20, electric = 5, grass = 5, ground = 0, flying = 20,
               dragon = 5 },
  grass =    { fire = 5, water = 20, grass = 5, poison = 5, ground = 20,
               flying = 5, bug = 5, rock = 20, dragon = 5, steel = 5 },
  ice =      { water = 5, grass = 20, ice = 5, ground = 20, flying = 20,
               dragon = 20, steel = 5, fire = 5 },
  fighting = { normal = 20, ice = 20, poison = 5, flying = 5, psychic = 5,
               bug = 5, rock = 20, dark = 20, steel = 20, ghost = 0 },
  poison =   { grass = 20, poison = 5, ground = 5, rock = 5, ghost = 5,
               steel = 0 },
  ground =   { fire = 20, electric = 20, grass = 5, poison = 20, flying = 0,
               bug = 5, rock = 20, steel = 20 },
  flying =   { electric = 5, grass = 20, fighting = 20, bug = 20, rock = 5,
               steel = 5 },
  psychic =  { fighting = 20, poison = 20, psychic = 5, dark = 0, steel = 5 },
  bug =      { fire = 5, grass = 20, fighting = 5, poison = 5, flying = 5,
               psychic = 20, ghost = 5, dark = 20, steel = 5 },
  rock =     { fire = 20, ice = 20, fighting = 5, ground = 5, flying = 20,
               bug = 20, steel = 5 },
  ghost =    { normal = 0, psychic = 20, dark = 5, steel = 5, ghost = 20 },
  dragon =   { dragon = 20, steel = 5 },
  dark =     { fighting = 5, psychic = 20, ghost = 20, dark = 5, steel = 5 },
  steel =    { fire = 5, water = 5, electric = 5, ice = 20, rock = 20,
               steel = 5 },
}

types.chart = chart

-- Physical types. The rest are special. `unknown` is the ??? type Curse uses.
local physical = {
  normal = true, fighting = true, flying = true, poison = true, ground = true,
  rock = true, bird = true, bug = true, ghost = true, steel = true,
  unknown = true,
}

function types.is_physical(type_name)
  return physical[type_name] == true
end

--- Multiplier in tenths for one attacking type against one defending type.
function types.against(attacking, defending)
  if not attacking or not defending then
    return types.NORMAL
  end
  local row = chart[attacking]
  if not row then
    return types.NORMAL
  end
  return row[defending] or types.NORMAL
end

--- Combined multiplier against a defender's one or two types, in hundredths so
-- that a double weakness stays exact.
function types.effectiveness(attacking, defender_types)
  local total = 10
  local seen = {}
  for _, defending in ipairs(defender_types) do
    -- A dual type listing the same type twice must only count once.
    if defending and not seen[defending] then
      seen[defending] = true
      total = total * types.against(attacking, defending) / 10
    end
  end
  return total
end

--- How the game describes the result.
function types.describe(multiplier)
  if multiplier == 0 then
    return "no effect"
  elseif multiplier > 10 then
    return "super effective"
  elseif multiplier < 10 then
    return "not very effective"
  end
  return nil
end

return types
