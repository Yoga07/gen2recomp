-- Individual Pokémon: stats, and the values they are derived from.
--
-- A Pokémon is its species' base stats plus per-individual DVs, scaled by
-- level. Gen 2 stores four DVs — attack, defence, speed and special — of four
-- bits each, and does not store an HP DV at all: it is assembled from the low
-- bit of each of the other four. That is also what determines shininess and,
-- for most species, gender, which is why one sixteen-bit value ends up
-- controlling so much.
--
--   HP    = ((base + DV) * 2 + statexp) * level / 100 + level + 10
--   other = ((base + DV) * 2 + statexp) * level / 100 + 5
--
-- Stat experience is zero for a freshly met wild Pokémon, so it is carried but
-- contributes nothing until something trains it.

local pokemon = {}

pokemon.MAX_DV = 15
pokemon.STATS = { "hp", "attack", "defense", "speed", "special_attack",
                  "special_defense" }

--- Assemble the HP DV from the low bit of the other four.
function pokemon.hp_dv(dvs)
  return (dvs.attack % 2) * 8
       + (dvs.defense % 2) * 4
       + (dvs.speed % 2) * 2
       + (dvs.special % 2)
end

--- Gen 2 keeps one special DV; the two special stats share it.
function pokemon.dv_for(dvs, stat)
  if stat == "hp" then
    return pokemon.hp_dv(dvs)
  elseif stat == "special_attack" or stat == "special_defense" then
    return dvs.special
  end
  return dvs[stat]
end

--- Stat experience contributes the square root of what is stored, quartered.
local function statexp_term(statexp)
  if not statexp or statexp <= 0 then
    return 0
  end
  return math.floor(math.floor(math.sqrt(statexp)) / 4)
end

--- Compute one stat.
function pokemon.stat(base, dv, level, stat, statexp)
  local core = math.floor(((base + dv) * 2 + statexp_term(statexp)) * level / 100)
  if stat == "hp" then
    return core + level + 10
  end
  return core + 5
end

--- Shiny in Gen 2 is a property of the DVs rather than a separate flag: speed,
-- defence and special all at 10, and attack from a particular set.
local SHINY_ATTACK = { [2] = true, [3] = true, [6] = true, [7] = true,
                       [10] = true, [11] = true, [14] = true, [15] = true }

function pokemon.is_shiny(dvs)
  return dvs.defense == 10 and dvs.speed == 10 and dvs.special == 10
     and SHINY_ATTACK[dvs.attack] == true
end

--- Gender comes from the attack DV against the species' gender ratio. A ratio
-- of 255 means genderless.
function pokemon.gender(dvs, gender_ratio)
  if gender_ratio == 255 then
    return "genderless"
  end
  -- The ratio is the chance of being female, scaled to the DV's range.
  return (dvs.attack * 17) < gender_ratio and "female" or "male"
end

function pokemon.random_dvs(random)
  random = random or math.random
  return {
    attack = random(0, pokemon.MAX_DV),
    defense = random(0, pokemon.MAX_DV),
    speed = random(0, pokemon.MAX_DV),
    special = random(0, pokemon.MAX_DV),
  }
end

--- Build a Pokémon.
-- @param base the species' base-stat record from the cache
-- @param options level, dvs, moves
function pokemon.new(species, base, options)
  options = options or {}
  local level = options.level or 5
  local dvs = options.dvs or pokemon.random_dvs()

  local instance = {
    species = species,
    level = level,
    dvs = dvs,
    statexp = options.statexp or {},
    stats = {},
    types = { base.type_1, base.type_2 },
    shiny = pokemon.is_shiny(dvs),
    gender = pokemon.gender(dvs, base.gender_ratio),
    moves = options.moves or {},
  }

  local bases = {
    hp = base.hp,
    attack = base.attack,
    defense = base.defense,
    speed = base.speed,
    special_attack = base.sp_attack,
    special_defense = base.sp_defense,
  }

  for _, stat in ipairs(pokemon.STATS) do
    instance.stats[stat] = pokemon.stat(bases[stat],
      pokemon.dv_for(dvs, stat), level, stat, instance.statexp[stat])
  end

  instance.hp = instance.stats.hp
  return instance
end

--- A wild Pokémon: random DVs, no held item, no stat experience.
function pokemon.wild(species, base, level, random)
  return pokemon.new(species, base, {
    level = level,
    dvs = pokemon.random_dvs(random),
  })
end

function pokemon.is_fainted(instance)
  return instance.hp <= 0
end

-- Struggle, which every Pokémon can always use.
pokemon.STRUGGLE = 165

--- Choose a plausible moveset.
--
-- A STAND-IN. Level-up learnsets are not extracted yet, so this picks damaging
-- moves whose type the species shares, strongest first, and falls back to
-- Struggle. The result is a Pokémon that can fight; it is not the moveset the
-- real game would give it, and swapping this for real learnsets is the next
-- piece of work on the battle side.
function pokemon.default_moves(instance, moves)
  local candidates = {}
  for id, move in ipairs(moves) do
    if move.power and move.power > 0 and id ~= pokemon.STRUGGLE then
      for _, own in ipairs(instance.types) do
        if move.type == own then
          candidates[#candidates + 1] = { id = id, power = move.power }
          break
        end
      end
    end
  end

  -- Strongest first, but capped by level so a level 5 does not open with
  -- something devastating.
  table.sort(candidates, function(a, b) return a.power > b.power end)
  local ceiling = 30 + instance.level * 2

  local chosen = {}
  for _, candidate in ipairs(candidates) do
    if candidate.power <= ceiling and #chosen < 4 then
      chosen[#chosen + 1] = candidate.id
    end
  end

  if #chosen == 0 then
    chosen[1] = pokemon.STRUGGLE
  end
  return chosen
end

return pokemon
