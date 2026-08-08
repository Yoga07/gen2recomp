-- Catching.
--
-- The chance rests on how hurt the target is, its species' catch rate, and the
-- ball. Integer arithmetic again, and the ordering matters:
--
--   a = (3*maxHP - 2*curHP) * rate * ball / (3*maxHP)
--   a = max(a, 1)
--   a = a + status bonus
--   caught when a >= 255, otherwise when random(0..255) < a
--
-- The status bonus carries a Gen 2 quirk worth preserving rather than tidying.
-- Sleep and freeze are meant to give +10 and the other statuses +5, but the
-- check is written so that *everything else* takes the +5 branch — including a
-- perfectly healthy target. Fixing that would make the game harder than the one
-- being reimplemented.

local catching = {}

catching.MAX_RATE = 255

-- Ball multipliers, as numerator and denominator so the maths stays integer.
catching.balls = {
  poke =   { name = "POKé BALL",   numerator = 1, denominator = 1 },
  great =  { name = "GREAT BALL",  numerator = 3, denominator = 2 },
  ultra =  { name = "ULTRA BALL",  numerator = 2, denominator = 1 },
  master = { name = "MASTER BALL", guaranteed = true },
}

--- Which multiplier a ball uses, worked out from its name.
--
-- The bag holds item ids, and those ids are the same in Gold, Silver and
-- Crystal, but reading the name keeps this working off what the cartridge
-- actually says rather than a list of numbers written down here. Balls with
-- conditional rules -- Heavy, Level, Lure, Fast, Love, Moon -- fall through to
-- the plain multiplier, which is what they are worth when their condition is
-- not met.
function catching.kind_for_name(name)
  name = tostring(name or ""):upper()
  if name:find("MASTER", 1, true) then
    return "master"
  elseif name:find("ULTRA", 1, true) then
    return "ultra"
  elseif name:find("GREAT", 1, true) then
    return "great"
  end
  return "poke"
end

catching.SLEEP_FREEZE_BONUS = 10
catching.OTHER_BONUS = 5

--- The catch value for a target, before the roll.
-- @param target  the Pokémon being thrown at
-- @param rate    its species' catch rate
-- @param ball    a key into catching.balls
-- @param status  "sleep", "freeze", or nil
function catching.value(target, rate, ball, status)
  local kind = catching.balls[ball] or catching.balls.poke
  if kind.guaranteed then
    return catching.MAX_RATE, true
  end

  local max_hp = math.max(target.stats.hp, 1)
  local current = math.max(target.hp, 0)

  local numerator = 3 * max_hp - 2 * current
  local denominator = 3 * max_hp

  local value = math.floor(numerator * rate * kind.numerator
    / (denominator * kind.denominator))
  value = math.max(value, 1)

  -- The quirk: only sleep and freeze are supposed to reach the larger bonus,
  -- but every other case takes the smaller one rather than none.
  if status == "sleep" or status == "freeze" then
    value = value + catching.SLEEP_FREEZE_BONUS
  else
    value = value + catching.OTHER_BONUS
  end

  return math.min(value, catching.MAX_RATE), false
end

--- Throw a ball.
-- @return caught, value
function catching.attempt(target, rate, ball, status, roll)
  local value, guaranteed = catching.value(target, rate, ball, status)
  if guaranteed or value >= catching.MAX_RATE then
    return true, value
  end

  roll = roll or math.random(0, catching.MAX_RATE)
  return roll < value, value
end

--- How close it came, for the wobble message.
function catching.shakes(value)
  if value >= 200 then
    return 3
  elseif value >= 120 then
    return 2
  elseif value >= 60 then
    return 1
  end
  return 0
end

return catching
