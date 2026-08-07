-- Battles.
--
-- The Gen 2 damage formula, with integer arithmetic throughout because the
-- original ran on hardware that had no other kind and the truncation is
-- load-bearing — rounding differently produces damage that is close but wrong.
--
--   base   = (2 * level / 5 + 2) * power * attack / defence / 50
--   crit   doubles that
--   +2
--   STAB   x1.5 when the move shares a type with its user
--   type   x2 or x0.5 per defending type, or x0
--   spread x(217..255) / 255
--   at least 1, unless the type chart said no effect
--
-- Physical or special is decided by the move's type, not per move: everything
-- from normal through steel uses attack and defence, fire onwards uses the
-- special stats.

local types = require("src.engine.types")

local battle = {}
battle.__index = battle

-- One in sixteen, the base rate before any high-crit move or item.
battle.CRIT_CHANCE = 16

-- The damage spread the game applies to every hit.
battle.SPREAD_LOW = 217
battle.SPREAD_HIGH = 255

battle.ACCURACY_SCALE = 255

--- Damage for one hit.
--
-- @param attacker, defender  Pokémon instances
-- @param move                a move record: power, type, accuracy
-- @param options             crit, spread — supplied by tests for determinism
-- @return damage, effectiveness (tenths), critical
function battle.damage(attacker, defender, move, options)
  options = options or {}

  local effectiveness = types.effectiveness(move.type, defender.types)
  if effectiveness == 0 then
    return 0, 0, false
  end

  if not move.power or move.power == 0 then
    return 0, effectiveness, false
  end

  local physical = types.is_physical(move.type)
  local attack = physical and attacker.stats.attack or attacker.stats.special_attack
  local defence = physical and defender.stats.defense or defender.stats.special_defense

  local critical = options.crit
  if critical == nil then
    critical = math.random(1, battle.CRIT_CHANCE) == 1
  end

  local level = attacker.level
  local base = math.floor(2 * level / 5 + 2)
  base = math.floor(base * move.power * attack / math.max(defence, 1) / 50)

  if critical then
    base = base * 2
  end
  base = base + 2

  -- Same-type attack bonus.
  for _, own in ipairs(attacker.types) do
    if own == move.type then
      base = math.floor(base * 3 / 2)
      break
    end
  end

  base = math.floor(base * effectiveness / 10)

  local spread = options.spread
    or math.random(battle.SPREAD_LOW, battle.SPREAD_HIGH)
  base = math.floor(base * spread / battle.SPREAD_HIGH)

  return math.max(base, 1), effectiveness, critical
end

--- Does the move connect?
function battle.hits(move, roll)
  local accuracy = move.accuracy or battle.ACCURACY_SCALE
  if accuracy >= battle.ACCURACY_SCALE then
    return true
  end
  roll = roll or math.random(0, battle.ACCURACY_SCALE - 1)
  return roll < accuracy
end

--- Who moves first. Faster goes first; a tie is broken at random.
-- Move priority is not modelled yet — the priority of a move lives in its
-- effect byte, which needs the effect table this does not have.
function battle.order(a, b, coin)
  if a.pokemon.stats.speed > b.pokemon.stats.speed then
    return a, b
  elseif b.pokemon.stats.speed > a.pokemon.stats.speed then
    return b, a
  end
  coin = coin or math.random(0, 1)
  if coin == 0 then
    return a, b
  end
  return b, a
end

--- Start a battle between two Pokémon.
function battle.new(player, opponent, moves, move_names, species_names)
  return setmetatable({
    player = player,
    opponent = opponent,
    moves = moves or {},
    move_names = move_names or {},
    species_names = species_names or {},
    log = {},
    over = false,
    winner = nil,
  }, battle)
end

function battle:name_of(instance)
  return self.species_names[instance.species] or ("#" .. instance.species)
end

function battle:say(fmt, ...)
  self.log[#self.log + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

--- One Pokémon attacks another with one move.
function battle:strike(attacker, defender, move_id, options)
  local move = self.moves[move_id]
  local name = self.move_names[move_id] or ("move " .. move_id)

  if not move then
    self:say("%s has no move!", self:name_of(attacker))
    return
  end

  self:say("%s used %s!", self:name_of(attacker), name)

  if not battle.hits(move, options and options.accuracy_roll) then
    self:say("It missed!")
    return
  end

  local damage, effectiveness, critical = battle.damage(attacker, defender,
    move, options)

  if effectiveness == 0 then
    self:say("It doesn't affect %s.", self:name_of(defender))
    return
  end

  defender.hp = math.max(0, defender.hp - damage)

  if critical then
    self:say("A critical hit!")
  end

  local description = types.describe(effectiveness)
  if description then
    self:say("It's %s!", description)
  end

  self:say("%s took %d damage. HP %d/%d", self:name_of(defender), damage,
    defender.hp, defender.stats.hp)

  if defender.hp <= 0 then
    self:say("%s fainted!", self:name_of(defender))
    self.over = true
    self.winner = (defender == self.player) and "opponent" or "player"
  end
end

--- One full turn: both sides act, faster first, and a fainted Pokémon does not
-- get to retaliate.
function battle:turn(player_move, opponent_move, options)
  options = options or {}
  self.log = {}

  if self.over then
    return self.log
  end

  local first, second = battle.order(
    { pokemon = self.player, move = player_move, side = "player" },
    { pokemon = self.opponent, move = opponent_move, side = "opponent" },
    options.coin)

  for _, actor in ipairs { first, second } do
    if not self.over then
      local defender = actor.side == "player" and self.opponent or self.player
      self:strike(actor.pokemon, defender, actor.move, options)
    end
  end

  return self.log
end

return battle
