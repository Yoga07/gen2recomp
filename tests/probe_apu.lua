-- Diagnostic: does the sound chip do what the hardware documentation says?
--
-- Every other probe here asks a question about the cartridge. This one asks a
-- question about our own code, because a sound chip has a failure mode the rest
-- of the project does not: **it makes a noise either way**. "I hear something"
-- is the audio equivalent of the metrics this project keeps a list of — the
-- extent measure that scored a table of zeros perfectly, the gate measure that
-- counted a fence as a doorway. Something coming out of the speakers says
-- nothing about whether it is the right something.
--
-- So nothing here is judged by ear. Ask for 440 Hz and the output is measured
-- for 440 Hz. Ask for a 12.5% duty cycle and the output is measured for how
-- long it stays high. Ask for a falling envelope and the amplitude is measured
-- in successive windows. The shift register's period is counted exactly.
--
-- It also draws the waveform and writes a WAV, because a number can be right
-- while the shape is wrong, and because somebody with ears should be able to
-- check the result of all this arithmetic.
--
--   love . --probe-apu <ignored> <report>

local apu = require("src.audio.apu")

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

probe.RATE = 44100

--- The frequency the hardware produces for a square register value.
function probe.square_hz(frequency)
  return 131072 / (2048 - frequency)
end

--- ...and the register value for a frequency, which is what a tune needs.
function probe.square_register(hz)
  return math.floor(2048 - 131072 / hz + 0.5)
end

--- Count zero crossings and turn them into a frequency.
-- Two crossings to a period, so the count halves.
local function measure_hz(samples, rate)
  local crossings, previous = 0, nil
  -- Left channel only; the interleaving is left, right, left, right.
  for index = 1, #samples, 2 do
    local value = samples[index]
    if previous and ((previous < 0) ~= (value < 0)) then
      crossings = crossings + 1
    end
    previous = value
  end
  local seconds = (#samples / 2) / rate
  return crossings / 2 / seconds
end

--- What fraction of the time the wave sits above zero.
local function measure_duty(samples)
  local high, total = 0, 0
  for index = 1, #samples, 2 do
    if samples[index] > 0 then
      high = high + 1
    end
    total = total + 1
  end
  return high / total
end

--- Peak-to-peak swing across a span of the output.
--
-- Peak-to-peak rather than largest absolute value, because that is what "how
-- loud is this" means regardless of where the waveform happens to sit. A
-- measure that took the largest magnitude would report a constant for a
-- falling envelope on a chip with no output capacitor, which is exactly the
-- bug it is here to catch.
local function peak(samples, from, to)
  local low, high = math.huge, -math.huge
  for index = from, math.min(to, #samples), 2 do
    local value = samples[index]
    low = math.min(low, value)
    high = math.max(high, value)
  end
  if low > high then
    return 0
  end
  return high - low
end

--- A square wave on channel 2, set up and triggered.
local function square_tone(chip, frequency, duty, volume)
  chip:write(0xFF26, 0x80)          -- power on
  chip:write(0xFF24, 0x77)          -- full volume both sides
  chip:write(0xFF25, 0xFF)          -- everything to both sides
  chip:write(0xFF16, duty * 64)     -- duty, length 0
  chip:write(0xFF17, volume * 16)   -- volume, no envelope
  chip:write(0xFF18, frequency % 256)
  chip:write(0xFF19, 0x80 + math.floor(frequency / 256))
end

--------------------------------------------------------------------------------

--- A 16-bit stereo WAV, so somebody with ears can check the arithmetic.
local function wav(samples, rate)
  local data = {}
  for index = 1, #samples do
    local value = math.max(-1, math.min(1, samples[index]))
    local scaled = math.floor(value * 32000)
    if scaled < 0 then
      scaled = scaled + 65536
    end
    data[#data + 1] = string.char(scaled % 256, math.floor(scaled / 256))
  end
  local body = table.concat(data)

  local function u32(value)
    return string.char(value % 256,
      math.floor(value / 256) % 256,
      math.floor(value / 65536) % 256,
      math.floor(value / 16777216) % 256)
  end
  local function u16(value)
    return string.char(value % 256, math.floor(value / 256) % 256)
  end

  return "RIFF" .. u32(36 + #body) .. "WAVE"
    .. "fmt " .. u32(16) .. u16(1) .. u16(2) .. u32(rate)
    .. u32(rate * 4) .. u16(4) .. u16(16)
    .. "data" .. u32(#body) .. body
end

--- Draw the waveform, because a frequency can be right while the shape is not.
local function oscilloscope(samples, width, height, span)
  local image = love.image.newImageData(width, height)
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      image:setPixel(x, y, 1, 1, 1, 1)
    end
  end
  -- The zero line.
  for x = 0, width - 1 do
    image:setPixel(x, math.floor(height / 2), 0.7, 0.7, 0.7, 1)
  end

  local middle = (height - 1) / 2
  local previous
  for x = 0, width - 1 do
    local index = 1 + math.floor(x / width * span) * 2
    local value = samples[index] or 0
    local y = math.floor(middle - value * middle + 0.5)
    y = math.max(0, math.min(height - 1, y))
    if previous then
      for step = math.min(previous, y), math.max(previous, y) do
        image:setPixel(x, step, 0.1, 0.1, 0.1, 1)
      end
    else
      image:setPixel(x, y, 0.1, 0.1, 0.1, 1)
    end
    previous = y
  end
  return image
end

function probe.run(_, report_path)
  report = {}

  log("== the frequency it was asked for ==")
  log("  register | wanted | measured | error")
  local worst = 0
  for _, wanted in ipairs({ 110, 220, 440, 880, 1760 }) do
    local register = probe.square_register(wanted)
    local chip = apu.new(probe.RATE)
    square_tone(chip, register, 2, 15)
    local samples = chip:generate(probe.RATE)  -- one second
    local measured = measure_hz(samples, probe.RATE)
    local expected = probe.square_hz(register)
    local error_pct = math.abs(measured - expected) / expected * 100
    worst = math.max(worst, error_pct)
    log("   %6d | %6d | %8.2f | %.3f%% (hardware gives %.2f)",
      register, wanted, measured, error_pct, expected)
  end
  log("  worst error against what the hardware would produce: %.3f%%", worst)

  log("\n== the duty cycle it was asked for ==")
  -- Measured at 110 Hz rather than 440, because the resolution of "what
  -- fraction of samples are above zero" is one sample per transition: at 440 Hz
  -- a period is 100 samples and two of them straddle an edge, which is a whole
  -- percent of slop. Two octaves down there are four times as many samples in a
  -- period and the same slop is a quarter of a percent.
  log("  duty | nominal | measured")
  local nominal = { [0] = 0.125, 0.25, 0.5, 0.75 }
  for duty = 0, 3 do
    local chip = apu.new(probe.RATE)
    square_tone(chip, probe.square_register(110), duty, 15)
    local samples = chip:generate(probe.RATE / 2)
    log("  %4d | %7.3f | %.4f", duty, nominal[duty], measure_duty(samples))
  end

  log("\n== the envelope falling ==")
  do
    local chip = apu.new(probe.RATE)
    chip:write(0xFF26, 0x80)
    chip:write(0xFF24, 0x77)
    chip:write(0xFF25, 0xFF)
    chip:write(0xFF16, 2 * 64)
    -- Full volume, falling, period 1: one step every 1/64 of a second, so
    -- fifteen steps to silence in just under a quarter second.
    chip:write(0xFF17, 0xF1)
    local register = probe.square_register(440)
    chip:write(0xFF18, register % 256)
    chip:write(0xFF19, 0x80 + math.floor(register / 256))

    local samples = chip:generate(probe.RATE / 2)
    local window = math.floor(probe.RATE / 16)
    log("  window | peak amplitude")
    for step = 0, 7 do
      local from = step * window * 2 + 1
      log("  %6d | %.4f", step, peak(samples, from, from + window * 2))
    end
    log("  (it should fall to nothing a little before a quarter of a second)")
  end

  log("\n== the noise register's period ==")
  do
    -- What repeats is the *audible* sequence, which is not the same as the
    -- whole register returning to where it started. In seven-bit mode bits 0
    -- to 6 form a closed shift register and bits 7 to 14 become a delay line
    -- with no feedback into it, fed by a sequence whose longest run of ones is
    -- shorter than eight. So the full fifteen bits can never all be set again
    -- and never revisit the triggered value, while the output carries on
    -- repeating every 127 shifts. Measuring the whole register says 7-bit mode
    -- has no period at all, which is a fact about the measure.
    for _, width_7 in ipairs({ false, true }) do
      local chip = apu.new(probe.RATE)
      chip:write(0xFF26, 0x80)
      chip:write(0xFF21, 0xF0)
      chip:write(0xFF22, width_7 and 0x08 or 0x00)
      chip:write(0xFF23, 0x80)

      local mask = width_7 and 0x7F or 0x7FFF
      local start = chip.noise.lfsr % (mask + 1)
      local steps = 0
      repeat
        -- Advance exactly one shift by running the noise timer out.
        chip:advance(chip.noise.timer)
        steps = steps + 1
      until chip.noise.lfsr % (mask + 1) == start or steps > 40000
      log("  %d-bit mode repeats after %d shifts (hardware: %d)",
        width_7 and 7 or 15, steps, width_7 and 127 or 32767)
    end
  end

  log("\n== the wave channel plays what is in wave RAM ==")
  do
    local chip = apu.new(probe.RATE)
    chip:write(0xFF26, 0x80)
    chip:write(0xFF24, 0x77)
    chip:write(0xFF25, 0xFF)
    -- A ramp: nibbles 0,1,2,...,15,15,...,0 would be a triangle, but a plain
    -- ascending ramp is easier to read back.
    for index = 0, 15 do
      chip:write(0xFF30 + index, index * 16 + index)
    end
    chip:write(0xFF1A, 0x80)   -- DAC on
    chip:write(0xFF1C, 0x20)   -- full volume
    local register = probe.square_register(440)
    chip:write(0xFF1D, register % 256)
    chip:write(0xFF1E, 0x80 + math.floor(register / 256))

    local seen = {}
    for _ = 1, 4096 do
      chip:advance(chip.wave.timer)
      seen[chip.wave.sample] = true
    end
    local distinct = 0
    for _ in pairs(seen) do
      distinct = distinct + 1
    end
    log("  a ramp in wave RAM produces %d distinct sample values (expect 16)",
      distinct)
  end

  -- Look at it, and let somebody listen to it.
  love.filesystem.createDirectory("dump/audio")

  do
    local chip = apu.new(probe.RATE)
    square_tone(chip, probe.square_register(440), 2, 15)
    local samples = chip:generate(1024)
    local shape = oscilloscope(samples, 600, 200, 300)
    love.filesystem.write("dump/audio/square50.png",
      shape:encode("png"):getString())
  end

  do
    local chip = apu.new(probe.RATE)
    square_tone(chip, probe.square_register(440), 0, 15)
    local samples = chip:generate(1024)
    local shape = oscilloscope(samples, 600, 200, 300)
    love.filesystem.write("dump/audio/square12.png",
      shape:encode("png"):getString())
  end

  -- A demonstration that exercises every channel, for listening to.
  do
    local chip = apu.new(probe.RATE)
    chip:write(0xFF26, 0x80)
    chip:write(0xFF24, 0x77)
    chip:write(0xFF25, 0xFF)
    for index = 0, 15 do
      chip:write(0xFF30 + index, index * 16 + (15 - index))
    end

    local out = {}
    local function append(more)
      for _, value in ipairs(more) do
        out[#out + 1] = value
      end
    end

    -- An arpeggio on square 1, with a sweep on the last note.
    local scale = { 262, 330, 392, 523, 392, 330 }
    for step, hz in ipairs(scale) do
      local register = probe.square_register(hz)
      chip:write(0xFF11, 2 * 64)
      chip:write(0xFF12, 0xF3)
      chip:write(0xFF13, register % 256)
      chip:write(0xFF14, 0x80 + math.floor(register / 256))
      append(chip:generate(math.floor(probe.RATE / 6)))
      if step == #scale then
        chip:write(0xFF10, 0x17)
      end
    end

    -- The wave channel, an octave down.
    chip:write(0xFF12, 0x00)
    local register = probe.square_register(131)
    chip:write(0xFF1A, 0x80)
    chip:write(0xFF1C, 0x20)
    chip:write(0xFF1D, register % 256)
    chip:write(0xFF1E, 0x80 + math.floor(register / 256))
    append(chip:generate(math.floor(probe.RATE / 2)))

    -- And a noise hit to finish.
    chip:write(0xFF1A, 0x00)
    chip:write(0xFF21, 0xF2)
    chip:write(0xFF22, 0x35)
    chip:write(0xFF23, 0x80)
    append(chip:generate(math.floor(probe.RATE / 2)))

    love.filesystem.write("dump/audio/demo.wav", wav(out, probe.RATE))
    log("\n== written ==")
    log("  %s/dump/audio", love.filesystem.getSaveDirectory())
    log("  square50.png, square12.png -- the waveform, to look at")
    log("  demo.wav -- %.1f seconds exercising all four channels, to listen to",
      #out / 2 / probe.RATE)
  end

  write(report_path)
  return true
end

return probe
