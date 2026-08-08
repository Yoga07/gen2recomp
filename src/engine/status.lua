-- Status conditions.
--
-- A Pokémon carries at most one of these at a time, and each one does two
-- things: it may stop the holder acting, and it may cost health at the end of
-- a turn. Two of them also change a stat outright rather than through the stage
-- system — burn halves attack and paralysis quarters speed — which is why those
-- are applied where the stats are read rather than stored as stages.

local status = {}

status.SLEEP = "sleep"
status.POISON = "poison"
status.TOXIC = "toxic"
status.BURN = "burn"
status.FREEZE = "freeze"
status.PARALYSIS = "paralysis"

-- Poison and burn cost this fraction of maximum health each turn.
status.RESIDUAL_DIVISOR = 8

-- Toxic climbs instead, by this fraction per turn it has been active.
status.TOXIC_DIVISOR = 16

-- Paralysis stops the holder acting this often, out of 256.
status.PARALYSIS_FAIL = 64

status.SLEEP_MIN = 1
status.SLEEP_MAX = 7

--- Give a Pokémon a status. One at a time: a Pokémon that already has one
-- cannot take another, which is why a second Toxic does not stack.
-- @return true when it took hold
function status.apply(instance, kind, random)
  if instance.status then
    return false
  end
  if instance.hp <= 0 then
    return false
  end

  instance.status = kind
  if kind == status.SLEEP then
    random = random or math.random
    instance.sleep_turns = random(status.SLEEP_MIN, status.SLEEP_MAX)
  elseif kind == status.TOXIC then
    instance.toxic_counter = 1
  end
  return true
end

function status.clear(instance)
  instance.status = nil
  instance.sleep_turns = nil
  instance.toxic_counter = nil
end

--- May this Pokémon act this turn?
-- @return true, or false plus a message
function status.can_act(instance, random)
  random = random or math.random

  if instance.status == status.SLEEP then
    instance.sleep_turns = (instance.sleep_turns or 1) - 1
    if instance.sleep_turns <= 0 then
      status.clear(instance)
      return true, "woke up!"
    end
    return false, "is fast asleep!"
  end

  if instance.status == status.FREEZE then
    -- Gen 2 freeze does not thaw on its own; it takes a fire move.
    return false, "is frozen solid!"
  end

  if instance.status == status.PARALYSIS then
    if random(0, 255) < status.PARALYSIS_FAIL then
      return false, "is fully paralysed!"
    end
  end

  return true
end

--- Damage taken at the end of a turn.
-- @return damage, message
function status.residual(instance)
  if instance.hp <= 0 then
    return 0
  end

  if instance.status == status.POISON then
    return math.max(1, math.floor(instance.stats.hp / status.RESIDUAL_DIVISOR)),
      "is hurt by poison!"
  end

  if instance.status == status.BURN then
    return math.max(1, math.floor(instance.stats.hp / status.RESIDUAL_DIVISOR)),
      "is hurt by its burn!"
  end

  if instance.status == status.TOXIC then
    local counter = instance.toxic_counter or 1
    local damage = math.max(1,
      math.floor(instance.stats.hp * counter / status.TOXIC_DIVISOR))
    instance.toxic_counter = counter + 1
    return damage, "is hurt by poison!"
  end

  return 0
end

--- Burn halves attack; this is separate from the stage system.
function status.attack_factor(instance)
  return instance.status == status.BURN and 0.5 or 1
end

--- Paralysis quarters speed, which is what makes it change turn order.
function status.speed_factor(instance)
  return instance.status == status.PARALYSIS and 0.25 or 1
end

--- A fire move thaws its target.
function status.thaw_on_hit(instance, move_type)
  if instance.status == status.FREEZE and move_type == "fire" then
    status.clear(instance)
    return true
  end
  return false
end

status.messages = {
  [status.SLEEP] = "fell asleep!",
  [status.POISON] = "was poisoned!",
  [status.TOXIC] = "was badly poisoned!",
  [status.BURN] = "was burned!",
  [status.FREEZE] = "was frozen solid!",
  [status.PARALYSIS] = "was paralysed!",
}

return status
