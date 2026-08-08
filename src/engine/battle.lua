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
local stages = require("src.engine.stages")
local status = require("src.engine.status")
local move_effects = require("src.engine.move_effects")

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
  local attack_stat = physical and "attack" or "special_attack"
  local defence_stat = physical and "defense" or "special_defense"

  -- Stage multipliers apply to the raw stat, and burn halves physical attack
  -- on top of that. Burn is not a stage — it is a separate factor the game
  -- applies where the stat is read.
  local attack = stages.apply(attacker.stats[attack_stat],
    attacker.stages and attacker.stages[attack_stat])
  local defence = stages.apply(defender.stats[defence_stat],
    defender.stages and defender.stages[defence_stat])

  if physical then
    attack = math.max(1, math.floor(attack * status.attack_factor(attacker)))
  end

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
  -- Speed as it is in the moment: stage-adjusted, and quartered by paralysis.
  -- This is what makes paralysis change who acts first rather than only how
  -- often they act at all.
  local function speed_of(entry)
    local value = stages.apply(entry.pokemon.stats.speed,
      entry.pokemon.stages and entry.pokemon.stages.speed)
    return math.max(1, math.floor(value * status.speed_factor(entry.pokemon)))
  end

  local a_speed, b_speed = speed_of(a), speed_of(b)
  if a_speed > b_speed then
    return a, b
  elseif b_speed > a_speed then
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
  -- Stages are per battle, not per Pokémon, so they start fresh here and are
  -- discarded when the battle ends. Status is not: it persists.
  player.stages = stages.new()
  opponent.stages = stages.new()

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
--- Apply a move's non-damage effect: a status, or a stat stage.
function battle:apply_effect(attacker, defender, move, options)
  local entry = move_effects.lookup(move.effect)
  if not entry then
    return
  end

  if not move_effects.fires(entry, move, options and options.effect_roll) then
    return
  end

  local target = entry.target == "self" and attacker or defender
  if target.hp <= 0 then
    return
  end

  if entry.kind == "status" then
    if status.apply(target, entry.status, options and options.status_random) then
      self:say("%s %s", self:name_of(target), status.messages[entry.status])
    end
  else
    local _, moved = stages.shift(target.stages, entry.stat, entry.delta)
    self:say("%s's %s", self:name_of(target),
      stages.describe(entry.stat, entry.delta, moved))
  end
end

function battle:strike(attacker, defender, move_id, options)
  local move = self.moves[move_id]
  local name = self.move_names[move_id] or ("move " .. move_id)

  if not move then
    self:say("%s has no move!", self:name_of(attacker))
    return
  end

  -- Sleep, freeze and paralysis can stop the attacker before anything else.
  local acting, why = status.can_act(attacker, options and options.status_random)
  if why then
    self:say("%s %s", self:name_of(attacker), why)
  end
  if not acting then
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

  -- A fire move thaws whatever it hits, before the damage lands.
  if status.thaw_on_hit(defender, move.type) then
    self:say("%s thawed out!", self:name_of(defender))
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
    return
  end

  -- Status and stat changes land after the damage, and only if the target
  -- survived it.
  self:apply_effect(attacker, defender, move, options)
end

--- Poison and burn bite at the end of the turn.
function battle:residual(instance)
  local damage, message = status.residual(instance)
  if damage <= 0 then
    return
  end

  instance.hp = math.max(0, instance.hp - damage)
  self:say("%s %s", self:name_of(instance), message)

  if instance.hp <= 0 then
    self:say("%s fainted!", self:name_of(instance))
    self.over = true
    self.winner = (instance == self.player) and "opponent" or "player"
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

  -- End of turn, in the same order the sides acted.
  for _, actor in ipairs { first, second } do
    if not self.over then
      self:residual(actor.pokemon)
    end
  end

  return self.log
end

return battle
