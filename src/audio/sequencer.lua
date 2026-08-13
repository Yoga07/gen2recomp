-- Playing a channel stream: commands in, register writes out.
--
-- This is the layer between the bytecode in `src/rom/music_ops.lua` and the
-- chip in `src/audio/apu.lua`. It runs on the hardware's own clock — the sound
-- engine was called once per frame, 59.7 times a second — and each channel
-- counts down a note's duration in frames, parsing the next commands when it
-- reaches zero.
--
-- ## What is faithful and what is a stand-in
--
-- Being honest about this matters more than usual, because unlike a wrong
-- decoder a wrong sequencer still produces music and the difference is a matter
-- of taste until somebody checks.
--
-- **Faithful**: the command stream, the per-channel state it maintains, the
-- call/loop/jump control flow, the volume envelopes and duty cycles, which all
-- come straight out of the cartridge.
--
-- **Ours**: the pitch of a note. The cartridge's own frequency table was looked
-- for and not found — see `--probe-pitch`, which searches four readings of
-- twelve consecutive words and fits every offset in the ROM as an octave of
-- periods, with the best fit anywhere landing at 14% off. So pitches here are
-- computed from equal temperament instead. The octave mapping is not free:
-- Gen 2 octave 1 has to be playable on a chip whose lowest note is 64 Hz, which
-- rules out anything below scientific octave 2, and the tests assert that every
-- note in the whole corpus lands inside the chip's register range.
--
-- **Stand-ins**: the wave channel's instrument and the noise channel's drum
-- kit. Both are selected by tables this project has not located, so channel 3
-- gets one fixed waveform and channel 4 a fixed noise setting. The melody and
-- harmony live on the two pulse channels and those are real.

local music_ops = require("src.rom.music_ops")
local bit = require("src.util.bytes")

local sequencer = {}
sequencer.__index = sequencer

-- The sound engine ran once per rendered frame.
sequencer.FRAME_RATE = 4194304 / 70224

-- Gen 2 octave n is scientific octave n+1. Not a free choice: octave 1 is used
-- 247 times in this cartridge and the chip cannot produce scientific octave 1
-- at all, so the mapping cannot sit any lower than this.
sequencer.OCTAVE_BASE = 1

-- Where each channel's registers start, and which of them exist.
local CHANNEL_REGISTERS = {
  [1] = { sweep = 0xFF10, duty = 0xFF11, envelope = 0xFF12,
          low = 0xFF13, high = 0xFF14 },
  [2] = { duty = 0xFF16, envelope = 0xFF17, low = 0xFF18, high = 0xFF19 },
  [3] = { power = 0xFF1A, length = 0xFF1B, level = 0xFF1C,
          low = 0xFF1D, high = 0xFF1E },
  [4] = { length = 0xFF20, envelope = 0xFF21, noise = 0xFF22, high = 0xFF23 },
}

-- A stand-in instrument for the wave channel: one cycle of a triangle, which is
-- what a wavetable channel with no pattern table sounds least wrong as.
local WAVE_PATTERN = {
  0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
  0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32, 0x10,
}

--- The frequency register value for a note.
-- @param pitch 1 to 12, C to B
-- @param octave 1 to 8 as the cartridge counts them
-- @return the eleven-bit register value, or nil when it is out of the chip's
--         range, which the caller should treat as a fault rather than clamp
function sequencer.frequency(pitch, octave, transpose_octave, transpose_pitch)
  local semitone = (pitch - 1) + (transpose_pitch or 0)
  local scientific = octave + sequencer.OCTAVE_BASE + (transpose_octave or 0)
  -- MIDI note 60 is middle C, which is scientific octave 4.
  local midi = 12 * (scientific + 1) + semitone
  local hz = 440 * 2 ^ ((midi - 69) / 12)
  local period = 131072 / hz
  if period >= 2048 or period < 1 then
    return nil
  end
  local value = math.floor(2048 - period + 0.5)
  if value < 0 or value > 2047 then
    return nil
  end
  return value
end

--- @param data the cartridge image as a string
-- @param apu something with :write(address, value)
function sequencer.new(data, apu)
  return setmetatable({
    data = data,
    apu = apu,
    channels = {},
    tempo = 256,
    frames = 0,
    -- Counted rather than asserted: a note the chip cannot play is a fault in
    -- the pitch mapping, and the tests bound it.
    out_of_range = 0,
    notes_played = 0,
  }, sequencer)
end

--- Start a song. `channels` is a list of flat offsets, one per channel.
function sequencer:play(channels, bank)
  self.channels = {}
  self.tempo = 256
  for index, offset in ipairs(channels) do
    self.channels[index] = {
      number = index,
      pc = offset,
      bank = bank,
      playing = true,
      duration = 0,
      octave = 4,
      speed = 8,
      envelope = 0xF0,
      duty = 2,
      transpose_octave = 0,
      transpose_pitch = 0,
      calls = {},
      loops = {},
      fraction = 0,
    }
  end

  -- The chip has to be on, at full volume, with everything routed both ways
  -- until a stereo_panning command says otherwise.
  self.apu:write(0xFF26, 0x80)
  self.apu:write(0xFF24, 0x77)
  self.apu:write(0xFF25, 0xFF)
  for index, value in ipairs(WAVE_PATTERN) do
    self.apu:write(0xFF30 + index - 1, value)
  end
end

function sequencer:byte(channel)
  local value = string.byte(self.data, channel.pc + 1) or 0xFF
  channel.pc = channel.pc + 1
  return value
end

function sequencer:address(channel)
  local low = self:byte(channel)
  local high = self:byte(channel)
  local addr = low + high * 256
  if addr < 0x4000 or addr > 0x7FFF then
    return nil
  end
  return channel.bank * 0x4000 + (addr - 0x4000)
end

--- Turn a note into register writes.
function sequencer:strike(channel, pitch, frames)
  local registers = CHANNEL_REGISTERS[channel.number]
  self.notes_played = self.notes_played + 1

  -- A rest silences the channel rather than sounding anything.
  if pitch == 0 then
    if registers.envelope then
      self.apu:write(registers.envelope, 0x00)
    elseif registers.power then
      self.apu:write(registers.power, 0x00)
    end
    return
  end

  if channel.number == 4 then
    -- No drum kit table, so a fixed noise colour that at least tracks pitch.
    self.apu:write(registers.envelope, channel.envelope)
    self.apu:write(registers.noise,
      bit.bor(bit.lshift(math.min(13, 13 - math.floor(pitch / 2)), 4), 0x01))
    self.apu:write(registers.high, 0x80)
    return
  end

  local value = sequencer.frequency(pitch, channel.octave,
    channel.transpose_octave, channel.transpose_pitch)
  if not value then
    self.out_of_range = self.out_of_range + 1
    return
  end

  if channel.number == 3 then
    self.apu:write(registers.power, 0x80)
    self.apu:write(registers.level, 0x20)
  else
    self.apu:write(registers.duty, bit.lshift(channel.duty, 6))
    self.apu:write(registers.envelope, channel.envelope)
  end

  self.apu:write(registers.low, bit.band(value, 0xFF))
  self.apu:write(registers.high,
    bit.bor(0x80, bit.band(bit.rshift(value, 8), 0x07)))
end

--- How many frames a note of this length lasts.
--
-- The length nibble counts from one, scaled by whatever `note_type` set as the
-- channel's speed, then by the tempo. The remainder is carried into the next
-- note so a tempo that does not divide evenly does not drift.
function sequencer:duration_for(channel, length)
  local units = (length + 1) * channel.speed * self.tempo + channel.fraction
  local frames = math.floor(units / 256)
  channel.fraction = units - frames * 256
  return math.max(1, frames)
end

--- Parse commands until this channel has a note to hold, or stops.
function sequencer:advance(channel)
  for _ = 1, 256 do
    if not channel.playing then
      return
    end

    local opcode = self:byte(channel)

    if opcode < music_ops.FIRST_COMMAND then
      -- A note: pitch in the high nibble, length in the low one.
      local pitch = bit.band(bit.rshift(opcode, 4), 0x0F)
      local length = bit.band(opcode, 0x0F)
      channel.duration = self:duration_for(channel, length)
      self:strike(channel, pitch, channel.duration)
      return
    end

    if opcode >= music_ops.FIRST_OCTAVE and opcode <= music_ops.LAST_OCTAVE then
      channel.octave = 8 - (opcode - music_ops.FIRST_OCTAVE)

    elseif opcode == 0xD8 then           -- note_type / drum_speed
      channel.speed = self:byte(channel)
      if channel.number ~= 4 then
        channel.envelope = self:byte(channel)
      end

    elseif opcode == 0xD9 then           -- transpose
      local packed = self:byte(channel)
      channel.transpose_octave = -bit.band(bit.rshift(packed, 4), 0x0F)
      channel.transpose_pitch = bit.band(packed, 0x0F)

    elseif opcode == 0xDA then           -- tempo
      local high = self:byte(channel)
      local low = self:byte(channel)
      self.tempo = high * 256 + low
      if self.tempo == 0 then
        self.tempo = 256
      end

    elseif opcode == 0xDB then           -- duty_cycle
      channel.duty = bit.band(self:byte(channel), 0x03)

    elseif opcode == 0xDC then           -- volume_envelope
      channel.envelope = self:byte(channel)

    elseif opcode == 0xDD or opcode == 0xDE or opcode == 0xE2
        or opcode == 0xE7 or opcode == 0xE8 or opcode == 0xE9
        or opcode == 0xEF or opcode == 0xE4 then
      -- Sweep, duty patterns, panning and the unnamed ones: one operand each,
      -- read and stepped over. Panning in particular is deliberately not
      -- applied, because a channel routed to one side in a two-channel mix is
      -- much more confusing to listen to than a centred one.
      self:byte(channel)

    elseif opcode == 0xE0 or opcode == 0xE1 or opcode == 0xE6
        or opcode == 0xEA or opcode == 0xEB or opcode == 0xEE then
      -- Pitch slide, vibrato, pitch offset, restart, new song: two operands.
      self:byte(channel)
      self:byte(channel)

    elseif opcode == 0xE5 then           -- volume
      local packed = self:byte(channel)
      self.apu:write(0xFF24, packed)

    elseif opcode == 0xFA then           -- set_condition
      channel.condition = self:byte(channel)

    elseif opcode == 0xFB then           -- sound_jump_if
      self:byte(channel)
      local target = self:address(channel)
      if target then
        channel.pc = target
      end

    elseif opcode == 0xFC then           -- sound_jump
      local target = self:address(channel)
      if not target then
        channel.playing = false
        return
      end
      channel.pc = target

    elseif opcode == 0xFD then           -- sound_loop
      local count = self:byte(channel)
      local target = self:address(channel)
      if not target then
        channel.playing = false
        return
      end
      local key = channel.pc
      if count == 0 then
        -- A count of zero loops forever. Playing forever is correct and
        -- useless for rendering, so the caller bounds the run instead.
        channel.pc = target
      else
        channel.loops[key] = (channel.loops[key] or count) - 1
        if channel.loops[key] > 0 then
          channel.pc = target
        else
          channel.loops[key] = nil
        end
      end

    elseif opcode == 0xFE then           -- sound_call
      local target = self:address(channel)
      if not target then
        channel.playing = false
        return
      end
      channel.calls[#channel.calls + 1] = channel.pc
      channel.pc = target

    elseif opcode == 0xFF then           -- sound_ret
      if #channel.calls > 0 then
        channel.pc = table.remove(channel.calls)
      else
        channel.playing = false
        return
      end
    end
    -- Everything else takes no operand and does nothing here.
  end

  -- 256 commands without producing a note is a runaway, not a long intro.
  channel.playing = false
end

--- One frame of the sound engine.
function sequencer:frame()
  self.frames = self.frames + 1
  local any = false
  for _, channel in ipairs(self.channels) do
    if channel.playing then
      any = true
      channel.duration = channel.duration - 1
      if channel.duration <= 0 then
        self:advance(channel)
      end
    end
  end
  return any
end

--- Render a song to interleaved stereo samples.
-- @param seconds how long to play for; a looping song never ends on its own
function sequencer:render(seconds)
  local out = {}
  local per_frame = math.floor(self.apu.rate / sequencer.FRAME_RATE)
  local frames = math.floor(seconds * sequencer.FRAME_RATE)
  for _ = 1, frames do
    if not self:frame() then
      break
    end
    for _, sample in ipairs(self.apu:generate(per_frame)) do
      out[#out + 1] = sample
    end
  end
  return out
end

return sequencer
