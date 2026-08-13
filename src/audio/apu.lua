-- The Game Boy sound chip.
--
-- Four channels: two square waves, a 32-sample wavetable, and a noise
-- generator. This is the one part of the audio problem that needs no reverse
-- engineering at all — the hardware is documented, so it can be written from
-- the specification and then *measured* rather than guessed at.
--
-- It is deliberately independent of everything else here. It takes register
-- writes and produces samples; it knows nothing about the cartridge, the
-- channel bytecode that is still unsolved, or LÖVE. That means it can be tested
-- as arithmetic, which is what the test suite does: set a frequency and count
-- the zero crossings, set a duty cycle and measure how long the wave is high,
-- set an envelope and watch the amplitude fall.
--
-- ## Why it is not stepped one clock at a time
--
-- The master clock is 4194304 Hz and the output is 44100, so a cycle-accurate
-- loop would run 95 iterations per sample and 4.2 million per second of audio.
-- Instead each unit keeps a countdown and the chip advances in chunks to the
-- next event, which for a 440 Hz square is a few thousand steps a second rather
-- than millions.
--
-- That has a second benefit worth more than the speed. Because a chunk is a
-- span over which nothing changes, the output level can be accumulated
-- multiplied by its duration and divided at the end of the sample — an exact
-- box filter over the sample period, for free. Point-sampling a square wave at
-- 44.1 kHz produces audible aliasing; this does not.

local bit = require("src.util.bytes")

local apu = {}
apu.__index = apu

apu.CLOCK = 4194304

-- The frame sequencer runs at 512 Hz and drives everything that is not the
-- waveform itself: lengths at 256 Hz, sweep at 128 Hz, envelopes at 64 Hz.
apu.FRAME_SEQUENCER_PERIOD = apu.CLOCK / 512

-- The four duty cycles, as the hardware's own bit patterns: 12.5%, 25%, 50%
-- and 75%. Note that duty 3 is high six eighths of the time — it is the
-- inverse of duty 1, and sounds identical on hardware because the ear cannot
-- hear absolute phase.
apu.DUTY = {
  [0] = { 0, 0, 0, 0, 0, 0, 0, 1 },
  [1] = { 1, 0, 0, 0, 0, 0, 0, 1 },
  [2] = { 1, 0, 0, 0, 0, 1, 1, 1 },
  [3] = { 0, 1, 1, 1, 1, 1, 1, 0 },
}

-- The noise channel's divisor codes. Code 0 means half of 16 rather than 0,
-- which is the one entry that does not follow the pattern.
apu.NOISE_DIVISOR = { [0] = 8, 16, 32, 48, 64, 80, 96, 112 }

-- Wave channel output is shifted right by this much for each volume code, so
-- code 0 is silence and codes 1..3 are full, half and quarter.
apu.WAVE_SHIFT = { [0] = 4, 0, 1, 2 }

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function square_channel(with_sweep)
  return {
    enabled = false,
    dac = false,
    duty = 0,
    position = 0,
    timer = 8192,
    frequency = 0,
    length = 0,
    length_enabled = false,
    volume = 0,
    envelope_initial = 0,
    envelope_add = false,
    envelope_period = 0,
    envelope_timer = 0,
    sweep = with_sweep and {
      period = 0, negate = false, shift = 0,
      timer = 0, enabled = false, shadow = 0,
    } or nil,
  }
end

--- @param rate output sample rate, in Hz
function apu.new(rate)
  rate = rate or 44100
  local instance = setmetatable({
    rate = rate,
    cycle_debt = 0,
    -- The output capacitor, which blocks DC. See `apu:generate`.
    charge = 0.999958 ^ (apu.CLOCK / rate),
    capacitor_left = 0,
    capacitor_right = 0,
    sequencer_timer = apu.FRAME_SEQUENCER_PERIOD,
    sequencer_step = 0,
    power = true,
    left_volume = 7,
    right_volume = 7,
    panning = 0xFF,
    square1 = square_channel(true),
    square2 = square_channel(false),
    wave = {
      enabled = false,
      dac = false,
      timer = 8192,
      frequency = 0,
      position = 0,
      sample = 0,
      length = 0,
      length_enabled = false,
      volume_code = 0,
      ram = {},
    },
    noise = {
      enabled = false,
      dac = false,
      timer = 8,
      lfsr = 0x7FFF,
      width_7 = false,
      clock_shift = 0,
      divisor_code = 0,
      length = 0,
      length_enabled = false,
      volume = 0,
      envelope_initial = 0,
      envelope_add = false,
      envelope_period = 0,
      envelope_timer = 0,
    },
  }, apu)

  for index = 0, 15 do
    instance.wave.ram[index] = 0
  end
  instance:unpack_mix()
  return instance
end

--------------------------------------------------------------------------------
-- Register writes
--------------------------------------------------------------------------------
--
-- Addressed the way the hardware is, $FF10 to $FF3F, so a trace taken from an
-- emulator can be replayed into this without translation.

local function square_frequency_timer(frequency)
  -- A period of (2048 - frequency) ticks, four clocks each. Frequency 2048 is
  -- not reachable through the registers, but guard anyway: a zero timer would
  -- make the chunked stepping loop forever.
  local period = (2048 - frequency) * 4
  return period > 0 and period or 4
end

local function trigger_envelope(channel)
  channel.volume = channel.envelope_initial
  channel.envelope_timer = channel.envelope_period
end

--- Is a channel's digital-to-analogue converter powered?
-- Turning the DAC off silences the channel outright, which is how the games
-- mute a voice without stopping it.
local function square_dac_on(channel)
  return channel.envelope_initial > 0 or channel.envelope_add
end

function apu:write(address, value)
  value = bit.band(value, 0xFF)

  -- Wave RAM is writable whether or not the chip is powered.
  if address >= 0xFF30 and address <= 0xFF3F then
    self.wave.ram[address - 0xFF30] = value
    return
  end

  -- With the chip powered down only NR52 responds. This matters: the sound
  -- engine powers the chip off between tracks and writes rubbish elsewhere.
  if not self.power and address ~= 0xFF26 then
    return
  end

  local square1, square2 = self.square1, self.square2
  local wave, noise = self.wave, self.noise

  if address == 0xFF10 then
    square1.sweep.period = bit.band(bit.rshift(value, 4), 0x07)
    square1.sweep.negate = bit.band(value, 0x08) ~= 0
    square1.sweep.shift = bit.band(value, 0x07)

  elseif address == 0xFF11 or address == 0xFF16 then
    local channel = address == 0xFF11 and square1 or square2
    channel.duty = bit.band(bit.rshift(value, 6), 0x03)
    channel.length = 64 - bit.band(value, 0x3F)

  elseif address == 0xFF12 or address == 0xFF17 then
    local channel = address == 0xFF12 and square1 or square2
    channel.envelope_initial = bit.band(bit.rshift(value, 4), 0x0F)
    channel.envelope_add = bit.band(value, 0x08) ~= 0
    channel.envelope_period = bit.band(value, 0x07)
    channel.dac = square_dac_on(channel)
    if not channel.dac then
      channel.enabled = false
    end

  elseif address == 0xFF13 or address == 0xFF18 then
    local channel = address == 0xFF13 and square1 or square2
    channel.frequency = bit.bor(bit.band(channel.frequency, 0x700), value)

  elseif address == 0xFF14 or address == 0xFF19 then
    local channel = address == 0xFF14 and square1 or square2
    channel.frequency = bit.bor(bit.band(channel.frequency, 0xFF),
      bit.lshift(bit.band(value, 0x07), 8))
    channel.length_enabled = bit.band(value, 0x40) ~= 0
    if bit.band(value, 0x80) ~= 0 then
      self:trigger_square(channel)
    end

  elseif address == 0xFF1A then
    wave.dac = bit.band(value, 0x80) ~= 0
    if not wave.dac then
      wave.enabled = false
    end

  elseif address == 0xFF1B then
    -- The wave channel counts to 256 rather than 64, so its length is a whole
    -- byte instead of six bits.
    wave.length = 256 - value

  elseif address == 0xFF1C then
    wave.volume_code = bit.band(bit.rshift(value, 5), 0x03)

  elseif address == 0xFF1D then
    wave.frequency = bit.bor(bit.band(wave.frequency, 0x700), value)

  elseif address == 0xFF1E then
    wave.frequency = bit.bor(bit.band(wave.frequency, 0xFF),
      bit.lshift(bit.band(value, 0x07), 8))
    wave.length_enabled = bit.band(value, 0x40) ~= 0
    if bit.band(value, 0x80) ~= 0 then
      self:trigger_wave()
    end

  elseif address == 0xFF20 then
    noise.length = 64 - bit.band(value, 0x3F)

  elseif address == 0xFF21 then
    noise.envelope_initial = bit.band(bit.rshift(value, 4), 0x0F)
    noise.envelope_add = bit.band(value, 0x08) ~= 0
    noise.envelope_period = bit.band(value, 0x07)
    noise.dac = square_dac_on(noise)
    if not noise.dac then
      noise.enabled = false
    end

  elseif address == 0xFF22 then
    noise.clock_shift = bit.band(bit.rshift(value, 4), 0x0F)
    noise.width_7 = bit.band(value, 0x08) ~= 0
    noise.divisor_code = bit.band(value, 0x07)

  elseif address == 0xFF23 then
    noise.length_enabled = bit.band(value, 0x40) ~= 0
    if bit.band(value, 0x80) ~= 0 then
      self:trigger_noise()
    end

  elseif address == 0xFF24 then
    self.right_volume = bit.band(value, 0x07)
    self.left_volume = bit.band(bit.rshift(value, 4), 0x07)
    self:unpack_mix()

  elseif address == 0xFF25 then
    self.panning = value
    self:unpack_mix()

  elseif address == 0xFF26 then
    local on = bit.band(value, 0x80) ~= 0
    if not on and self.power then
      -- Powering down clears every register, which is why a sound engine can
      -- rely on a clean slate after switching the chip off and on.
      local rate, ram = self.rate, self.wave.ram
      local fresh = apu.new(rate)
      fresh.wave.ram = ram
      fresh.power = false
      for key, field in pairs(fresh) do
        self[key] = field
      end
    end
    self.power = on
  end
end

--------------------------------------------------------------------------------
-- Triggering
--------------------------------------------------------------------------------

--- Recompute a sweep step, and disable the channel if it overflows.
-- The overflow check is part of the sweep rather than a safety net: it is how
-- a rising sweep ends, and games rely on the channel cutting out.
function apu:sweep_frequency(channel)
  local sweep = channel.sweep
  local delta = bit.rshift(sweep.shadow, sweep.shift)
  local next_frequency = sweep.negate and (sweep.shadow - delta)
    or (sweep.shadow + delta)
  if next_frequency > 2047 then
    channel.enabled = false
  end
  return next_frequency
end

function apu:trigger_square(channel)
  channel.enabled = channel.dac
  if channel.length == 0 then
    channel.length = 64
  end
  channel.timer = square_frequency_timer(channel.frequency)
  trigger_envelope(channel)

  local sweep = channel.sweep
  if sweep then
    sweep.shadow = channel.frequency
    sweep.timer = sweep.period > 0 and sweep.period or 8
    sweep.enabled = sweep.period > 0 or sweep.shift > 0
    -- A trigger with a shift set runs the overflow check immediately, so a
    -- sweep that would already be out of range never sounds at all.
    if sweep.shift > 0 then
      self:sweep_frequency(channel)
    end
  end
end

function apu:trigger_wave()
  local wave = self.wave
  wave.enabled = wave.dac
  if wave.length == 0 then
    wave.length = 256
  end
  local period = (2048 - wave.frequency) * 2
  wave.timer = period > 0 and period or 2
  wave.position = 0
end

function apu:trigger_noise()
  local noise = self.noise
  noise.enabled = noise.dac
  if noise.length == 0 then
    noise.length = 64
  end
  local divisor = apu.NOISE_DIVISOR[noise.divisor_code]
  noise.timer = bit.lshift(divisor, noise.clock_shift)
  if noise.timer < 1 then
    noise.timer = 1
  end
  -- All fifteen bits set: the shift register has to start somewhere other than
  -- zero, or it would never leave it.
  noise.lfsr = 0x7FFF
  trigger_envelope(noise)
end

--------------------------------------------------------------------------------
-- The frame sequencer
--------------------------------------------------------------------------------

local function clock_length(channel)
  if channel.length_enabled and channel.length > 0 then
    channel.length = channel.length - 1
    if channel.length == 0 then
      channel.enabled = false
    end
  end
end

local function clock_envelope(channel)
  if channel.envelope_period == 0 then
    return
  end
  channel.envelope_timer = channel.envelope_timer - 1
  if channel.envelope_timer > 0 then
    return
  end
  channel.envelope_timer = channel.envelope_period
  if channel.envelope_add and channel.volume < 15 then
    channel.volume = channel.volume + 1
  elseif not channel.envelope_add and channel.volume > 0 then
    channel.volume = channel.volume - 1
  end
end

function apu:clock_sweep()
  local channel = self.square1
  local sweep = channel.sweep
  sweep.timer = sweep.timer - 1
  if sweep.timer > 0 then
    return
  end
  sweep.timer = sweep.period > 0 and sweep.period or 8
  if not sweep.enabled or sweep.period == 0 then
    return
  end

  local next_frequency = self:sweep_frequency(channel)
  if next_frequency <= 2047 and sweep.shift > 0 then
    sweep.shadow = next_frequency
    channel.frequency = next_frequency
    -- The hardware runs the check a second time with the new shadow value,
    -- and the channel can cut out on that one too.
    self:sweep_frequency(channel)
  end
end

--- One tick of the 512 Hz sequencer. Lengths on the even steps, sweep on 2 and
-- 6, envelopes on 7 — so lengths run at 256 Hz, sweep at 128 and envelopes
-- at 64.
function apu:clock_sequencer()
  local step = self.sequencer_step

  if step % 2 == 0 then
    clock_length(self.square1)
    clock_length(self.square2)
    clock_length(self.wave)
    clock_length(self.noise)
  end

  if step == 2 or step == 6 then
    self:clock_sweep()
  end

  if step == 7 then
    clock_envelope(self.square1)
    clock_envelope(self.square2)
    clock_envelope(self.noise)
  end

  self.sequencer_step = (step + 1) % 8
end

--------------------------------------------------------------------------------
-- Advancing
--------------------------------------------------------------------------------

--- How many clocks may pass before something changes.
function apu:next_event()
  local soonest = self.sequencer_timer
  local function consider(timer)
    if timer > 0 and timer < soonest then
      soonest = timer
    end
  end
  consider(self.square1.timer)
  consider(self.square2.timer)
  consider(self.wave.timer)
  consider(self.noise.timer)
  return soonest > 0 and soonest or 1
end

--- Advance every timer by `cycles`, which must not exceed `next_event`.
function apu:advance(cycles)
  local square1, square2 = self.square1, self.square2
  local wave, noise = self.wave, self.noise

  square1.timer = square1.timer - cycles
  if square1.timer <= 0 then
    square1.timer = square1.timer + square_frequency_timer(square1.frequency)
    square1.position = (square1.position + 1) % 8
  end

  square2.timer = square2.timer - cycles
  if square2.timer <= 0 then
    square2.timer = square2.timer + square_frequency_timer(square2.frequency)
    square2.position = (square2.position + 1) % 8
  end

  wave.timer = wave.timer - cycles
  if wave.timer <= 0 then
    local period = (2048 - wave.frequency) * 2
    wave.timer = wave.timer + (period > 0 and period or 2)
    wave.position = (wave.position + 1) % 32
    -- Two four-bit samples to a byte, high nibble first.
    local byte = wave.ram[math.floor(wave.position / 2)] or 0
    if wave.position % 2 == 0 then
      wave.sample = bit.band(bit.rshift(byte, 4), 0x0F)
    else
      wave.sample = bit.band(byte, 0x0F)
    end
  end

  noise.timer = noise.timer - cycles
  if noise.timer <= 0 then
    local divisor = apu.NOISE_DIVISOR[noise.divisor_code]
    local period = bit.lshift(divisor, noise.clock_shift)
    noise.timer = noise.timer + (period > 0 and period or 1)

    -- A fifteen-bit shift register fed by the exclusive-or of its bottom two
    -- bits. In seven-bit mode the same result is also written to bit 6, which
    -- shortens the period from 32767 to 127 and turns hiss into a rasp.
    local low = bit.band(noise.lfsr, 0x01)
    local next_bit = bit.bxor(low, bit.band(bit.rshift(noise.lfsr, 1), 0x01))
    noise.lfsr = bit.bor(bit.rshift(noise.lfsr, 1), bit.lshift(next_bit, 14))
    if noise.width_7 then
      noise.lfsr = bit.bor(bit.band(noise.lfsr, 0x7FBF),
        bit.lshift(next_bit, 6))
    end
  end

  self.sequencer_timer = self.sequencer_timer - cycles
  if self.sequencer_timer <= 0 then
    self.sequencer_timer = self.sequencer_timer + apu.FRAME_SEQUENCER_PERIOD
    self:clock_sequencer()
  end
end

--------------------------------------------------------------------------------
-- Output
--------------------------------------------------------------------------------

--- Unpack the routing and volume registers into what the mixer actually needs.
--
-- NR51's low nibble routes each channel right and its high nibble left, and
-- NR50 holds a volume of 0 to 7 per side meaning one eighth to full. Both
-- change rarely and are read once per sample, so they are turned into plain
-- fields when written instead of being decoded in the inner loop.
function apu:unpack_mix()
  local panning = self.panning
  self.right1 = bit.band(panning, 0x01) ~= 0
  self.right2 = bit.band(panning, 0x02) ~= 0
  self.right3 = bit.band(panning, 0x04) ~= 0
  self.right4 = bit.band(panning, 0x08) ~= 0
  self.left1 = bit.band(panning, 0x10) ~= 0
  self.left2 = bit.band(panning, 0x20) ~= 0
  self.left3 = bit.band(panning, 0x40) ~= 0
  self.left4 = bit.band(panning, 0x80) ~= 0
  self.left_gain = (self.left_volume + 1) / 8 / 4
  self.right_gain = (self.right_volume + 1) / 8 / 4
end

--- What each channel is putting out right now, 0 to 15.
function apu:levels()
  local square1, square2 = self.square1, self.square2
  local wave, noise = self.wave, self.noise

  local one = (square1.enabled and square1.dac
    and apu.DUTY[square1.duty][square1.position + 1] == 1) and square1.volume or 0
  local two = (square2.enabled and square2.dac
    and apu.DUTY[square2.duty][square2.position + 1] == 1) and square2.volume or 0

  local three = 0
  if wave.enabled and wave.dac then
    three = bit.rshift(wave.sample, apu.WAVE_SHIFT[wave.volume_code])
  end

  local four = 0
  if noise.enabled and noise.dac then
    -- The output is the *inverted* bottom bit, which is why a freshly
    -- triggered register of all ones starts silent rather than at full volume.
    if bit.band(noise.lfsr, 0x01) == 0 then
      four = noise.volume
    end
  end

  return one, two, three, four
end

--- Mix to two analogue channels in the range -1 to 1.
--
-- Written without allocating anything, and deliberately so. This runs at least
-- once per output sample, so the two small tables an earlier version built here
-- came to some ninety thousand allocations per second of audio and were most of
-- the cost of the whole chip. The panning bits are unpacked when NR51 is
-- written rather than re-tested eight times a sample for the same reason.
function apu:mix()
  if not self.power then
    return 0, 0
  end

  local one, two, three, four = self:levels()
  local square1, square2 = self.square1, self.square2
  local wave, noise = self.wave, self.noise

  -- Each channel's DAC maps 0..15 onto the full analogue range. A channel whose
  -- DAC is off contributes nothing rather than sitting at -1 and shoving the
  -- mix off centre.
  local dac1 = (square1.enabled and square1.dac) and (one / 7.5 - 1) or 0
  local dac2 = (square2.enabled and square2.dac) and (two / 7.5 - 1) or 0
  local dac3 = (wave.enabled and wave.dac) and (three / 7.5 - 1) or 0
  local dac4 = (noise.enabled and noise.dac) and (four / 7.5 - 1) or 0

  local left, right = 0, 0
  if self.left1 then left = left + dac1 end
  if self.left2 then left = left + dac2 end
  if self.left3 then left = left + dac3 end
  if self.left4 then left = left + dac4 end
  if self.right1 then right = right + dac1 end
  if self.right2 then right = right + dac2 end
  if self.right3 then right = right + dac3 end
  if self.right4 then right = right + dac4 end

  -- Four channels summed, then the master volume, which is a value of 0 to 7
  -- meaning one eighth to full.
  return left * self.left_gain, right * self.right_gain
end

--- Produce `frames` stereo samples.
--
-- Each output sample is the average of the analogue level over the span it
-- covers, weighted by how long each level lasted. That falls out of the
-- chunked stepping for nothing and is what keeps a square wave from aliasing
-- into a mess of inharmonic tones.
-- @return a flat array, left and right interleaved
function apu:generate(frames)
  local out = {}
  self:generate_into(out, 0, frames)
  return out
end

--- The same, writing into a buffer the caller already has.
--
-- Worth having separately rather than being tidy about it: the game generates
-- audio inside its own frame, and building one table here only to copy it into
-- another was costing more than the synthesis itself.
-- @param base how many entries are already in `out`
function apu:generate_into(out, base, frames)
  local per_frame = apu.CLOCK / self.rate

  for index = 0, frames - 1 do
    self.cycle_debt = self.cycle_debt + per_frame
    local budget = math.floor(self.cycle_debt)
    self.cycle_debt = self.cycle_debt - budget

    local sum_left, sum_right, total = 0, 0, 0
    while budget > 0 do
      local step = self:next_event()
      if step > budget then
        step = budget
      end
      local left, right = self:mix()
      sum_left = sum_left + left * step
      sum_right = sum_right + right * step
      total = total + step
      self:advance(step)
      budget = budget - step
    end

    if total == 0 then
      total = 1
    end

    -- The output capacitor, and it is not a refinement.
    --
    -- A channel whose digital level is 0 is not silent: its DAC holds a steady
    -- voltage at the bottom of its range. What makes that silence is the
    -- capacitor on the way out of the chip, which passes changes and blocks
    -- anything constant. Leaving it out was measurable rather than theoretical
    -- -- a falling envelope kept a constant peak amplitude, because the wave
    -- was not shrinking towards zero, it was sliding downwards towards a floor
    -- that never moved. Every channel switching on or off would also have
    -- stepped the whole mix and clicked.
    local left = sum_left / total
    local right = sum_right / total
    local filtered_left = left - self.capacitor_left
    local filtered_right = right - self.capacitor_right
    self.capacitor_left = left - filtered_left * self.charge
    self.capacitor_right = right - filtered_right * self.charge

    out[base + index * 2 + 1] = filtered_left
    out[base + index * 2 + 2] = filtered_right
  end

  return frames * 2
end

--- Silence everything without powering the chip down.
function apu:reset()
  local rate, ram = self.rate, self.wave.ram
  local fresh = apu.new(rate)
  fresh.wave.ram = ram
  for key, field in pairs(fresh) do
    self[key] = field
  end
end

return apu
