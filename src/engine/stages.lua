-- Stat stages.
--
-- A stat can sit between -6 and +6, and the multiplier is a fraction the game
-- stores as a numerator and denominator so the whole calculation stays in
-- integers. Halving is 50/100 rather than 0.5, which matters because the
-- truncation is part of the result.
--
-- The stages are not symmetric: +1 is 150% but -1 is 66%, not 75%. Anyone
-- deriving them from a formula rather than the table gets the negative half
-- subtly wrong.

local stages = {}

stages.MIN = -6
stages.MAX = 6

-- Indexed by stage, so stages.multipliers[0] is the neutral one.
stages.multipliers = {
  [-6] = { 25, 100 },
  [-5] = { 28, 100 },
  [-4] = { 33, 100 },
  [-3] = { 40, 100 },
  [-2] = { 50, 100 },
  [-1] = { 66, 100 },
  [0]  = { 1, 1 },
  [1]  = { 15, 10 },
  [2]  = { 2, 1 },
  [3]  = { 25, 10 },
  [4]  = { 3, 1 },
  [5]  = { 35, 10 },
  [6]  = { 4, 1 },
}

stages.NAMES = { "attack", "defense", "speed", "special_attack",
                 "special_defense", "accuracy", "evasion" }

--- A fresh set of stages, all neutral.
function stages.new()
  local set = {}
  for _, name in ipairs(stages.NAMES) do
    set[name] = 0
  end
  return set
end

--- Apply a stage to a raw value.
function stages.apply(value, stage)
  local pair = stages.multipliers[math.max(stages.MIN,
    math.min(stages.MAX, stage or 0))]
  return math.max(1, math.floor(value * pair[1] / pair[2]))
end

--- Shift a stat, clamped.
-- @return the new stage, and whether it actually moved
function stages.shift(set, name, delta)
  local before = set[name] or 0
  local after = math.max(stages.MIN, math.min(stages.MAX, before + delta))
  set[name] = after
  return after, after ~= before
end

--- How the game announces a change.
function stages.describe(name, delta, moved)
  local label = name:gsub("_", " ")
  if not moved then
    return delta > 0 and ("%s won't go higher!"):format(label)
      or ("%s won't go lower!"):format(label)
  end
  if delta >= 2 then
    return ("%s rose sharply!"):format(label)
  elseif delta > 0 then
    return ("%s rose!"):format(label)
  elseif delta <= -2 then
    return ("%s fell harshly!"):format(label)
  end
  return ("%s fell!"):format(label)
end

return stages
