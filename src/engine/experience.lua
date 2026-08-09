-- Experience and levelling.
--
-- Six growth curves, named in the base-stat records and ordered the same way
-- the cartridge orders them. Each says how much experience a Pokemon must have
-- accumulated to stand at a given level.
--
-- These are cubics rather than tables, and they are checkable: the totals at
-- level 100 are round, well-known numbers that were not derived from this code
-- -- a million for the medium-fast curve, 800,000 for fast, 1,250,000 for slow.
-- The tests assert those, so a mistyped coefficient shows up immediately rather
-- than as a Pokemon that levels slightly wrong for fifty hours.
--
-- Two of the six curves are defined by the hardware but used by nothing in Gen
-- 2. They are implemented anyway: leaving a hole in a table indexed by
-- cartridge data is how a rare species crashes the game.

local experience = {}

experience.MAX_LEVEL = 100

-- Experience to be *at* a level. Level 1 is always nothing.
local CURVES = {
  medium_fast = function(n)
    return n * n * n
  end,
  slightly_fast = function(n)
    return math.floor(3 * n * n * n / 4 + 10 * n * n - 30)
  end,
  slightly_slow = function(n)
    return math.floor(3 * n * n * n / 4 + 20 * n * n - 70)
  end,
  medium_slow = function(n)
    return math.floor(6 * n * n * n / 5 - 15 * n * n + 100 * n - 140)
  end,
  fast = function(n)
    return math.floor(4 * n * n * n / 5)
  end,
  slow = function(n)
    return math.floor(5 * n * n * n / 4)
  end,
}

experience.CURVE_NAMES = {
  "medium_fast", "slightly_fast", "slightly_slow", "medium_slow", "fast",
  "slow",
}

--- Total experience needed to stand at `level`.
function experience.total_for(growth_rate, level)
  local curve = CURVES[growth_rate] or CURVES.medium_fast
  if level <= 1 then
    return 0
  end
  -- The medium-slow cubic dips below zero at the bottom of its range, which is
  -- an artefact of the polynomial rather than a real amount owed.
  return math.max(0, curve(math.min(level, experience.MAX_LEVEL)))
end

--- The level a given amount of experience buys.
function experience.level_for(growth_rate, total)
  local level = 1
  for candidate = 2, experience.MAX_LEVEL do
    if total >= experience.total_for(growth_rate, candidate) then
      level = candidate
    else
      break
    end
  end
  return level
end

--- Experience awarded for defeating something.
--
-- The base is the fainted Pokemon's own base experience scaled by its level and
-- divided by seven, split between however many took part. A trainer's Pokemon
-- is worth half as much again as a wild one.
-- @param options participants, trainer
function experience.gain(base_exp, level, options)
  options = options or {}
  local participants = math.max(options.participants or 1, 1)

  local amount = math.floor((base_exp or 0) * level / 7)
  if options.trainer then
    amount = math.floor(amount * 3 / 2)
  end
  return math.max(math.floor(amount / participants), 1)
end

--- Add experience and report the levels crossed.
--
-- Returns the new level and every level gained, so the caller can hand out the
-- moves learned at each one rather than only at the level landed on. Skipping
-- the intermediate levels is how a Pokemon that jumps three levels at once
-- silently misses two moves.
-- @return new level, list of levels gained
function experience.award(instance, growth_rate, amount)
  instance.exp = (instance.exp or 0) + amount

  local was = instance.level
  local now = experience.level_for(growth_rate, instance.exp)
  if now <= was then
    return was, {}
  end

  local gained = {}
  for level = was + 1, now do
    gained[#gained + 1] = level
  end
  instance.level = now
  return now, gained
end

return experience
