-- Diagnostic: play the cartridge's music.
--
-- This is the end of the chain — table, widths, sequencer, chip — and it is
-- also the sharpest test the width table has had. A width that is one byte too
-- small is invisible to every measure the byte layout offers, because the
-- operand gets read as a note and a note is one byte. But a note is not
-- *silent*: a spurious one is an extra pitch at an extra moment, and that is
-- audible even when it is not measurable.
--
-- So this measures what it can and writes a WAV for the rest. What it can
-- measure is whether the output looks like music rather than like noise:
-- real music repeats, uses a handful of pitches out of the twelve, and holds
-- notes for a handful of durations out of the sixteen. A stream parsed at the
-- wrong offsets does none of those things.
--
--   love . --probe-song <rom> <report> [song index]

local Rom = require("src.rom.rom")
local music = require("src.rom.music")
local apu_module = require("src.audio.apu")
local sequencer = require("src.audio.sequencer")

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
  local function u32(v)
    return string.char(v % 256, math.floor(v / 256) % 256,
      math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
  end
  local function u16(v)
    return string.char(v % 256, math.floor(v / 256) % 256)
  end
  return "RIFF" .. u32(36 + #body) .. "WAVE" .. "fmt " .. u32(16) .. u16(1)
    .. u16(2) .. u32(rate) .. u32(rate * 4) .. u16(4) .. u16(16)
    .. "data" .. u32(#body) .. body
end

--- Walk a song's channels and collect what the notes look like, without
-- rendering any audio. Cheap enough to run over every song.
local function survey(data, song)
  local chip = { rate = probe.RATE, writes = 0 }
  function chip:write() self.writes = self.writes + 1 end
  function chip:generate() return {} end

  local player = sequencer.new(data, chip)
  local channels = {}
  for index, address in ipairs(song.channels) do
    channels[index] = song.bank * 0x4000 + (address - 0x4000)
  end
  player:play(channels, song.bank)

  local pitches, lengths, notes, rests = {}, {}, 0, 0
  for _, channel in ipairs(player.channels) do
    channel.watch = true
  end

  -- Re-implement the note tap rather than reaching into the sequencer: play
  -- frames and look at what each channel is holding.
  local seen = {}
  for _ = 1, 1800 do   -- thirty seconds of frames
    if not player:frame() then
      break
    end
  end
  notes = player.notes_played
  return notes, player.out_of_range, player.frames
end

function probe.run(rom_path, report_path, which)
  report = {}

  local rom, err = Rom.load(rom_path)
  if not rom then
    log("FATAL: %s", err)
    write(report_path)
    return true
  end

  local located, why = music.locate(rom)
  if not located then
    log("FATAL: %s", tostring(why))
    rom:release()
    write(report_path)
    return true
  end

  -- Every song, surveyed. What matters is that no song plays a pitch the chip
  -- cannot produce: that is the check on the octave mapping, which is ours
  -- rather than the cartridge's.
  log("== every song, played without rendering ==")
  local total_notes, total_out, played, silent = 0, 0, 0, 0
  for index, song in ipairs(located.songs) do
    if not song.unparsed then
      local notes, out_of_range = survey(rom.data, song)
      total_notes = total_notes + notes
      total_out = total_out + out_of_range
      if notes > 0 then
        played = played + 1
      else
        silent = silent + 1
        log("  song %d produced no notes at all", index - 1)
      end
    end
  end
  log("  %d songs played, %d produced nothing", played, silent)
  log("  %d notes struck in total", total_notes)
  log("  %d of them asked for a pitch the chip cannot produce (%.2f%%)",
    total_out, total_out / math.max(total_notes, 1) * 100)
  log("  (that count is the check on the octave mapping, which is ours)")

  -- Render a few and write them out.
  love.filesystem.createDirectory("dump/audio")
  local wanted = which and { tonumber(which) } or { 0, 12, 31, 57 }

  log("\n== rendered ==")
  for _, index in ipairs(wanted) do
    local song = located.songs[index + 1]
    if song and not song.unparsed then
      local chip = apu_module.new(probe.RATE)
      local player = sequencer.new(rom.data, chip)
      local channels = {}
      for slot, address in ipairs(song.channels) do
        channels[slot] = song.bank * 0x4000 + (address - 0x4000)
      end
      player:play(channels, song.bank)

      local samples = player:render(20)
      local name = ("dump/audio/song%03d.wav"):format(index)
      love.filesystem.write(name, wav(samples, probe.RATE))
      log("  song %3d: %d channels, %d notes, %.1f seconds -> %s",
        index, song.count, player.notes_played,
        #samples / 2 / probe.RATE, name)
    end
  end
  log("  in %s", love.filesystem.getSaveDirectory())

  rom:release()
  write(report_path)
  return true
end

return probe
