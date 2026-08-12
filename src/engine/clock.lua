-- The time of day.
--
-- Crystal is built around it: the grass tables carry three sets of encounters,
-- and 14 scripts branch on it. The cartridge read a real-time clock on the
-- board; this reads the host's, which gives the same three-way split.
--
-- The three periods are named and ordered by the encounter tables rather than
-- here. Those tables store morning, day and night in that order, so that is the
-- order the `checktime` mask bits are in too, and there is one place the
-- ordering comes from rather than two that could drift apart.

local encounters = require("src.rom.encounters")

local clock = {}

clock.TIMES = encounters.times

-- Gen 2's boundaries. Night runs across midnight, which is why it is the one
-- that cannot be written as a single range.
clock.MORNING_FROM = 4
clock.DAY_FROM = 10
clock.NIGHT_FROM = 18

--- Which period an hour falls in.
function clock.time_of_day(hour)
  hour = hour or tonumber(os.date("%H"))
  if hour >= clock.MORNING_FROM and hour < clock.DAY_FROM then
    return clock.TIMES[1]
  elseif hour >= clock.DAY_FROM and hour < clock.NIGHT_FROM then
    return clock.TIMES[2]
  end
  return clock.TIMES[3]
end

--- The bit a period occupies in a checktime mask.
--
-- The operands in Crystal are only ever 1, 2 and 4 -- single bits, never a
-- combination -- which is what says it is a mask of three rather than an index
-- or a count.
function clock.mask_for(time)
  for index, name in ipairs(clock.TIMES) do
    if name == time then
      return 2 ^ (index - 1)
    end
  end
  return 0
end

--- Does a checktime mask include this period?
function clock.matches(mask, time)
  local bit = clock.mask_for(time)
  if bit == 0 then
    return false
  end
  return math.floor((mask or 0) / bit) % 2 == 1
end

--- The hour and minute, for showing.
function clock.now()
  return tonumber(os.date("%H")), tonumber(os.date("%M"))
end

--- How the period reads on screen.
clock.LABELS = {
  morn = "MORN",
  day = "DAY",
  nite = "NITE",
}

function clock.label(time)
  return clock.LABELS[time or clock.time_of_day()] or "?"
end

return clock
