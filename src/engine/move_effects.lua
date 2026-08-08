-- What a move does beyond damage.
--
-- Every move record carries an effect byte and an effect chance. The byte
-- selects one of a hundred-odd behaviours; this covers the ones that inflict a
-- status or move a stat stage, which between them account for most of what the
-- battle system needs, and reports the rest as unhandled rather than silently
-- doing nothing.
--
-- The distinction that matters in the table below is *_HIT versus not. A plain
-- effect is the move's whole purpose and always happens — Thunder Wave only
-- paralyses. A _HIT effect rides along with damage and fires on a chance.

local status = require("src.engine.status")

local move_effects = {}

-- kind: "status" or "stat"
-- always: the effect is the move's purpose, not a side effect
-- target: "target" or "self"
local table_ = {
  -- Status, as the move's whole purpose.
  [1]  = { kind = "status", status = status.SLEEP, always = true, target = "target" },
  [33] = { kind = "status", status = status.TOXIC, always = true, target = "target" },
  [65] = { kind = "status", status = status.POISON, always = true, target = "target" },
  [66] = { kind = "status", status = status.PARALYSIS, always = true, target = "target" },

  -- Status riding along with damage.
  [2]  = { kind = "status", status = status.POISON, target = "target" },
  [4]  = { kind = "status", status = status.BURN, target = "target" },
  [5]  = { kind = "status", status = status.FREEZE, target = "target" },
  [6]  = { kind = "status", status = status.PARALYSIS, target = "target" },

  -- Raising the user's own stats, as the move's purpose.
  [10] = { kind = "stat", stat = "attack", delta = 1, always = true, target = "self" },
  [11] = { kind = "stat", stat = "defense", delta = 1, always = true, target = "self" },
  [12] = { kind = "stat", stat = "speed", delta = 1, always = true, target = "self" },
  [13] = { kind = "stat", stat = "special_attack", delta = 1, always = true, target = "self" },
  [14] = { kind = "stat", stat = "special_defense", delta = 1, always = true, target = "self" },
  [15] = { kind = "stat", stat = "accuracy", delta = 1, always = true, target = "self" },
  [16] = { kind = "stat", stat = "evasion", delta = 1, always = true, target = "self" },

  -- Lowering the target's stats, as the move's purpose.
  [18] = { kind = "stat", stat = "attack", delta = -1, always = true, target = "target" },
  [19] = { kind = "stat", stat = "defense", delta = -1, always = true, target = "target" },
  [20] = { kind = "stat", stat = "speed", delta = -1, always = true, target = "target" },
  [21] = { kind = "stat", stat = "special_attack", delta = -1, always = true, target = "target" },
  [22] = { kind = "stat", stat = "special_defense", delta = -1, always = true, target = "target" },
  [23] = { kind = "stat", stat = "accuracy", delta = -1, always = true, target = "target" },
  [24] = { kind = "stat", stat = "evasion", delta = -1, always = true, target = "target" },

  -- Lowering the target's stats on a chance, alongside damage.
  [67] = { kind = "stat", stat = "attack", delta = -1, target = "target" },
  [68] = { kind = "stat", stat = "defense", delta = -1, target = "target" },
  [69] = { kind = "stat", stat = "speed", delta = -1, target = "target" },
  [70] = { kind = "stat", stat = "special_attack", delta = -1, target = "target" },
  [71] = { kind = "stat", stat = "special_defense", delta = -1, target = "target" },
  [72] = { kind = "stat", stat = "accuracy", delta = -1, target = "target" },
  [73] = { kind = "stat", stat = "evasion", delta = -1, target = "target" },

  -- Raising the user's stats on a chance, alongside damage.
  [87] = { kind = "stat", stat = "defense", delta = 1, target = "self" },
  [88] = { kind = "stat", stat = "attack", delta = 1, target = "self" },
}

move_effects.table = table_

move_effects.NORMAL_HIT = 0

--- What a move does, or nil when the effect is not modelled.
function move_effects.lookup(effect)
  return table_[effect]
end

--- Does this effect fire?
--
-- A move whose whole purpose is the effect always applies it; a side effect
-- rolls against the move's effect chance, which is out of 255.
function move_effects.fires(entry, move, roll)
  if entry.always then
    return true
  end
  local chance = move.effect_chance or 0
  if chance <= 0 then
    return false
  end
  roll = roll or math.random(0, 255)
  return roll < chance
end

return move_effects
