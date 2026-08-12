-- Wild encounters.
--
-- Stepping onto a grass tile rolls against the map's encounter rate for the
-- current time of day. If it hits, one of seven slots is chosen from a fixed
-- probability spread, and that slot names the species and level.
--
-- The rate is a fraction of 255 rather than a percentage: a "2 percent" rate is
-- stored as 5.

local wild = {}

-- Slot odds, as the running total out of 100. The first two slots account for
-- most encounters and the last is rare.
wild.SLOT_ODDS = { 30, 60, 80, 90, 95, 99, 100 }

wild.RATE_SCALE = 255

-- Environments where wild Pokémon appear on ordinary floor rather than in
-- grass. This is why two thirds of the maps carrying an encounter table have no
-- grass tiles on them at all: caves and dungeons roll on every step.
wild.FLOOR_ENCOUNTER_ENVIRONMENTS = {
  cave = true,
  dungeon = true,
}

--- Should stepping onto this terrain roll for an encounter?
-- @param terrain the collision kind of the cell
-- @param environment the map's environment
function wild.rolls_here(terrain, environment)
  if terrain == "grass" then
    return true
  end
  return terrain == "floor"
     and wild.FLOOR_ENCOUNTER_ENVIRONMENTS[environment] == true
end

--- Which encounter table applies right now.
--
-- The clock lives in its own module now, because the scripts branch on the time
-- as well and both have to agree about where morning ends.
function wild.time_of_day(hour)
  return require("src.engine.clock").time_of_day(hour)
end

--- Roll for an encounter on a map.
-- @param encounters the map's { rates, slots } record, or nil
-- @param time optional time of day, for tests
-- @return { species, level, slot, time } or nil
function wild.roll(encounters, time, random)
  if not encounters then
    return nil
  end

  random = random or math.random
  time = time or wild.time_of_day()

  local rate = encounters.rates[time]
  local slots = encounters.slots[time]
  if not rate or not slots or rate == 0 then
    return nil
  end

  -- One roll decides whether anything appears at all.
  if random(0, wild.RATE_SCALE - 1) >= rate then
    return nil
  end

  -- A second decides which slot.
  local pick = random(1, 100)
  for index, threshold in ipairs(wild.SLOT_ODDS) do
    if pick <= threshold then
      local slot = slots[index]
      if slot then
        return {
          species = slot.species,
          level = slot.level,
          slot = index,
          time = time,
        }
      end
      return nil
    end
  end

  return nil
end

return wild
