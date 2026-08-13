-- The channel command language.
--
-- Bytes below $D0 are notes: a pitch in the high nibble and a length in the
-- low one, one byte and no operands. From $D0 up they are commands, and this
-- says how many operand bytes each takes.
--
-- ## Where these numbers come from, and why that is allowed
--
-- The operand widths are read from the pokecrystal disassembly's audio macros,
-- exactly as the script opcode table in `script_ops.lua` was. Nothing is
-- vendored: what is borrowed is a fact per opcode — a number — and every one of
-- them is then checked against this cartridge.
--
-- That check is available and sharp, and it is the reason this route is worth
-- taking at all. Channel data is contiguous, so a walk through a channel must
-- land **exactly** on where the next channel begins. There are 256 such
-- boundaries. A width table taken from outside either satisfies all of them or
-- it does not, and unlike a search it cannot bend itself to fit.
--
-- That distinction is the whole point. The same measure was useless when a
-- search was doing the deciding: with width zero admissible, a table of all
-- zeros lands on every boundary, and hill-climbing produced four different
-- answers at four near-identical scores. Vacuous as an objective to optimise;
-- perfectly sound as a test of a fixed hypothesis. It is exactly what happened
-- with the script opcodes, where inference reported zero overruns while getting
-- 13 of 24 widths wrong, and the real widths made the number mean something.
--
-- ## Two commands whose width is not fixed
--
-- `toggle_noise` and `sfx_toggle_noise` take a drum-kit byte or nothing at all,
-- depending on how they are written. Those are left for the extents to settle
-- rather than assumed; see `--probe-musicops`.
--
-- `note_type` is the third, and it is not ambiguous, only context-dependent: on
-- the noise channel it is `drum_speed` and carries one byte instead of two.
-- Which channel a stream is is known, so this takes it as an argument.

local music_ops = {}

-- Below this, a byte is a note rather than a command.
music_ops.FIRST_COMMAND = 0xD0

-- The octave commands occupy eight opcodes and carry no operand: the octave is
-- the opcode. That is why they are the commonest bytes in the whole corpus.
music_ops.FIRST_OCTAVE = 0xD0
music_ops.LAST_OCTAVE = 0xD7

music_ops.NOTE_TYPE = 0xD8
music_ops.TOGGLE_NOISE = 0xE3
music_ops.SFX_TOGGLE_NOISE = 0xF0
music_ops.SOUND_RET = 0xFF

-- Opcode -> { name, operand bytes }. Anything absent is unknown rather than
-- zero, so a walk stops on it instead of silently sailing past.
music_ops.commands = {
  [0xD8] = { "note_type", 2 },        -- one byte on the noise channel
  [0xD9] = { "transpose", 1 },
  [0xDA] = { "tempo", 2 },
  [0xDB] = { "duty_cycle", 1 },
  [0xDC] = { "volume_envelope", 1 },
  [0xDD] = { "pitch_sweep", 1 },
  [0xDE] = { "duty_cycle_pattern", 1 },
  [0xDF] = { "toggle_sfx", 0 },
  [0xE0] = { "pitch_slide", 2 },
  [0xE1] = { "vibrato", 2 },
  [0xE2] = { "unknown_e2", 1 },
  [0xE3] = { "toggle_noise", nil },   -- settled by the extents
  [0xE4] = { "force_stereo_panning", 1 },
  [0xE5] = { "volume", 1 },
  [0xE6] = { "pitch_offset", 2 },
  [0xE7] = { "unknown_e7", 1 },
  [0xE8] = { "unknown_e8", 1 },
  [0xE9] = { "tempo_relative", 1 },
  [0xEA] = { "restart_channel", 2 },
  [0xEB] = { "new_song", 2 },
  [0xEC] = { "sfx_priority_on", 0 },
  [0xED] = { "sfx_priority_off", 0 },
  [0xEE] = { "unknown_ee", 2 },
  [0xEF] = { "stereo_panning", 1 },
  [0xF0] = { "sfx_toggle_noise", nil },  -- settled by the extents
  [0xF1] = { "music_f1", 0 },
  [0xF2] = { "music_f2", 0 },
  [0xF3] = { "music_f3", 0 },
  [0xF4] = { "music_f4", 0 },
  [0xF5] = { "music_f5", 0 },
  [0xF6] = { "music_f6", 0 },
  [0xF7] = { "music_f7", 0 },
  [0xF8] = { "music_f8", 0 },
  [0xF9] = { "unknown_f9", 0 },
  [0xFA] = { "set_condition", 1 },
  [0xFB] = { "sound_jump_if", 3 },
  [0xFC] = { "sound_jump", 2 },
  [0xFD] = { "sound_loop", 3 },
  [0xFE] = { "sound_call", 2 },
  [0xFF] = { "sound_ret", 0 },
}

-- The commands that end a stream rather than continuing it. Only sound_ret and
-- an unconditional jump; a call comes back, and a loop falls through when its
-- count runs out.
music_ops.terminators = {
  [0xFF] = true,   -- sound_ret
  [0xFC] = true,   -- sound_jump
}

--- How many operand bytes an opcode takes on a given channel.
-- @param channel 1 to 4; channel 4 is the noise channel
-- @param overrides optional map of opcode -> width, which wins over the table.
--        Used to fill in the two commands the macros leave open, and to
--        perturb a single width when asking whether the cartridge pins it.
-- @return width, or nil when it is not known
function music_ops.width(opcode, channel, overrides)
  if opcode < music_ops.FIRST_COMMAND then
    return 0
  end
  -- Overrides come before the octave shortcut, not after it. An octave command
  -- carries no operand because the octave is the opcode, but "what if that were
  -- wrong" still has to be askable, and a check the perturbation cannot reach
  -- reports every octave as unfalsifiable for the wrong reason.
  if overrides and overrides[opcode] ~= nil then
    return overrides[opcode]
  end

  if opcode >= music_ops.FIRST_OCTAVE and opcode <= music_ops.LAST_OCTAVE then
    return 0
  end

  -- On the noise channel `note_type` is `drum_speed` and drops the envelope
  -- byte. Nothing else changes shape by channel.
  if opcode == music_ops.NOTE_TYPE then
    return channel == 4 and 1 or 2
  end

  local entry = music_ops.commands[opcode]
  if not entry then
    return nil
  end
  return entry[2]
end

function music_ops.name(opcode)
  if opcode < music_ops.FIRST_COMMAND then
    return "note"
  end
  if opcode >= music_ops.FIRST_OCTAVE and opcode <= music_ops.LAST_OCTAVE then
    return ("octave%d"):format(8 - (opcode - music_ops.FIRST_OCTAVE))
  end
  local entry = music_ops.commands[opcode]
  return entry and entry[1] or ("unknown_%02X"):format(opcode)
end

-- The commands that carry a two-byte address, and where that address sits
-- among their operands. These are what make a wrong parse *visible*: an
-- address read from the wrong offset is arbitrary bytes, and arbitrary bytes
-- are usually not a pointer into the switchable bank window.
music_ops.transfers = {
  [0xFB] = 1,   -- sound_jump_if: condition, then address
  [0xFC] = 0,   -- sound_jump
  [0xFD] = 1,   -- sound_loop: count, then address
  [0xFE] = 0,   -- sound_call
}

--- Walk a channel from `from` up to `limit`.
-- @return { landed, at, overran, counts, starts, targets }
--   `starts` is the set of offsets a decoded instruction began at, and
--   `targets` the addresses the control-transfer commands named.
function music_ops.walk(rom, from, limit, channel, overrides)
  local at = from
  local counts, starts, targets = {}, {}, {}
  while at < limit do
    local opcode = rom:u8(at)
    counts[opcode] = (counts[opcode] or 0) + 1
    starts[at] = true
    local width = music_ops.width(opcode, channel, overrides)
    if width == nil then
      return { landed = false, at = at, unknown = opcode, counts = counts,
               starts = starts, targets = targets }
    end

    local slot = music_ops.transfers[opcode]
    if slot and at + 1 + slot + 1 < limit + 4 then
      targets[#targets + 1] = rom:u16le(at + 1 + slot)
    end

    at = at + 1 + width
  end
  return {
    landed = at == limit,
    at = at,
    overran = at > limit,
    counts = counts,
    starts = starts,
    targets = targets,
    -- What the last instruction was, so "did it stop on something that ends a
    -- channel" can be asked as well as "did it stop in the right place".
    last = at == limit and rom:u8(limit - 1) or nil,
  }
end

return music_ops
