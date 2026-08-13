-- Diagnostic: where is the pitch table, and what do its numbers mean?
--
-- A sequencer has to turn a note's pitch and octave into the eleven-bit value
-- the sound chip's frequency registers take. Somewhere in the cartridge there
-- are twelve numbers, one per semitone.
--
-- Twelve numbers in equal temperament are an extremely sharp signature and one
-- that needs nothing borrowed: each is the one before it times the twelfth root
-- of two. Nothing else in a ROM looks like that by accident.
--
-- What the numbers *mean* is the second question and is deliberately not
-- assumed. A summary of the sound engine claimed the octave is applied by
-- right-shifting the table entry, which cannot be right: the chip's registers
-- hold 2048 minus a period, so halving that value does not halve the pitch. So
-- this prints the table and checks each candidate reading against the
-- frequencies real notes actually have.
--
--   love . --probe-pitch <rom> <report>

local Rom = require("src.rom.rom")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

local function write(path)
  local fh = io.open(path, "w")
  if fh then
    fh:write(table.concat(report, "\n") .. "\n")
    fh:close()
  end
end

probe.SEMITONE = 2 ^ (1 / 12)
probe.TOLERANCE = 0.004

-- Concert A, and the note names, so the table can be read against something a
-- musician would recognise rather than against itself.
probe.NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }

--- What the sound chip actually produces for a frequency register value.
local function chip_hz(value)
  if value >= 2048 then
    return 0
  end
  return 131072 / (2048 - value)
end

function probe.run(rom_path, report_path)
  report = {}

  local rom, err = Rom.load(rom_path)
  if not rom then
    log("FATAL: %s", err)
    write(report_path)
    return true
  end

  -- Four readings, because what the stored number *is* is exactly the question.
  -- If the table holds the register value then 2048 minus it is the quantity in
  -- equal temperament, not the value; if it holds the period then the value is.
  -- And a table may run up the scale or down it.
  local readings = {
    { name = "the value itself, rising", pitch = function(v) return v end,
      up = true },
    { name = "the value itself, falling", pitch = function(v) return v end,
      up = false },
    { name = "2048 minus the value, rising",
      pitch = function(v) return 2048 - v end, up = true },
    { name = "2048 minus the value, falling",
      pitch = function(v) return 2048 - v end, up = false },
  }

  -- Rounding to whole numbers makes the relative error large where the numbers
  -- are small, so the step tolerance is generous and the octave across all
  -- twelve is what has to be tight.
  local STEP_TOLERANCE = 0.03
  local SPAN_TOLERANCE = 0.02

  log("== twelve numbers a semitone apart ==")
  local hits = {}
  local longest, longest_at, longest_reading = 0, nil, nil

  for _, reading in ipairs(readings) do
    local wanted = reading.up and probe.SEMITONE or (1 / probe.SEMITONE)
    local run, run_start = 1, 0
    for offset = 0, rom.size - 4, 2 do
      local a = reading.pitch(rom:u16le(offset))
      local b = reading.pitch(rom:u16le(offset + 2))
      local ok = a and b and a > 8 and b > 8 and a < 2048 and b < 2048
        and math.abs(b / a - wanted) / wanted < STEP_TOLERANCE
      if ok then
        run = run + 1
        if run > longest then
          longest, longest_at, longest_reading = run, run_start, reading.name
        end
        if run >= 12 then
          -- Confirm the whole octave, which is the part rounding cannot fake.
          local first = reading.pitch(rom:u16le(run_start))
          local last = reading.pitch(rom:u16le(run_start + 11 * 2))
          local span = reading.up and (last / first) or (first / last)
          if math.abs(span - 2 ^ (11 / 12)) / 2 ^ (11 / 12) < SPAN_TOLERANCE then
            hits[#hits + 1] = { offset = run_start, reading = reading }
          end
        end
      else
        run = 1
        run_start = offset + 2
      end
    end
  end

  log("  %d offset(s) hold twelve numbers in equal temperament", #hits)
  log("  the longest run of consecutive semitone steps anywhere is %d,", longest)
  log("  at 0x%06X under \"%s\"", longest_at or 0, longest_reading or "-")

  -- Thresholds on each step are the wrong tool where the numbers are small:
  -- a period of 31 rounds to a whole number and the error against the true
  -- ratio can reach several percent per step while the sequence is perfectly
  -- good equal temperament. So fit instead of threshold. If twelve consecutive
  -- words are one octave of periods, then p[i] * 2^(i/12) is the same number
  -- for every i, and the spread of that number says how good the fit is.
  log("\n== fitting twelve words as an octave of periods ==")
  do
    local best = {}
    for offset = 0, rom.size - 26, 2 do
      local sum, worst, ok = 0, 0, true
      local normalised = {}
      for step = 0, 11 do
        local value = rom:u16le(offset + step * 2)
        if value < 10 or value > 2047 then
          ok = false
          break
        end
        normalised[step + 1] = value * 2 ^ (step / 12)
        sum = sum + normalised[step + 1]
      end
      if ok then
        local mean = sum / 12
        for _, value in ipairs(normalised) do
          worst = math.max(worst, math.abs(value - mean) / mean)
        end
        best[#best + 1] = { offset = offset, worst = worst, mean = mean }
      end
    end
    table.sort(best, function(a, b) return a.worst < b.worst end)

    log("  the five best fits anywhere in the cartridge:")
    for index = 1, math.min(#best, 5) do
      local fit = best[index]
      local values = {}
      for step = 0, 11 do
        values[#values + 1] = tostring(rom:u16le(fit.offset + step * 2))
      end
      log("    0x%06X  worst deviation %.2f%%  %s", fit.offset,
        fit.worst * 100, table.concat(values, " "))
    end
    log("  (a real octave of periods fits to within a percent or so;")
    log("   anything above a few percent is not one)")
  end

  -- Print it whatever it is. A run that passes every step and fails the octave
  -- is a smooth ramp that is not equal temperament, and the numbers say which.
  if longest_at then
    log("\n  what is actually at 0x%06X:", longest_at)
    local values, ratios = {}, {}
    for step = 0, 15 do
      local value = rom:u16le(longest_at + step * 2)
      values[#values + 1] = ("%d"):format(value)
      if step > 0 then
        local previous = rom:u16le(longest_at + (step - 1) * 2)
        ratios[#ratios + 1] = ("%.4f"):format(previous > 0 and value / previous
          or 0)
      end
    end
    log("    values: %s", table.concat(values, " "))
    log("    ratios: %s", table.concat(ratios, " "))
    log("    a semitone is %.4f; twelve of them double", probe.SEMITONE)
  end

  for index, hit in ipairs(hits) do
    if index > 4 then
      break
    end
    local offset = hit.offset
    log("\n  0x%06X (bank $%02X), reading: %s", offset,
      math.floor(offset / 0x4000), hit.reading.name)
    local values = {}
    for step = 0, 11 do
      values[step + 1] = rom:u16le(offset + step * 2)
    end
    local parts = {}
    for step, value in ipairs(values) do
      parts[#parts + 1] = ("%s=%d"):format(probe.NAMES[step], value)
    end
    log("    %s", table.concat(parts, " "))

    -- What do these numbers mean? Try the readings that are possible and see
    -- which produces the frequencies of actual notes.
    --
    -- The chip's register holds 2048 minus a period, so the two candidate
    -- readings are "this is the register value" and "this is 2048 minus it",
    -- and only one of them can put the twelve semitones an octave apart in a
    -- way that matches equal temperament.
    log("    read straight as a frequency register:")
    local line = {}
    for step, value in ipairs(values) do
      line[#line + 1] = ("%s=%.1fHz"):format(probe.NAMES[step],
        chip_hz(value % 2048))
    end
    log("      %s", table.concat(line, " "))

    log("    read as 2048 minus the register value:")
    line = {}
    for step, value in ipairs(values) do
      line[#line + 1] = ("%s=%.1fHz"):format(probe.NAMES[step],
        chip_hz(2048 - (value % 2048)))
    end
    log("      %s", table.concat(line, " "))

    -- And what an octave shift does under each reading, since that is the part
    -- the engine summary got wrong.
    log("    the same entries shifted right one place, as registers:")
    line = {}
    for step, value in ipairs(values) do
      line[#line + 1] = ("%s=%.1fHz"):format(probe.NAMES[step],
        chip_hz(math.floor(value / 2) % 2048))
    end
    log("      %s", table.concat(line, " "))
  end

  rom:release()
  write(report_path)
  return true
end

return probe
