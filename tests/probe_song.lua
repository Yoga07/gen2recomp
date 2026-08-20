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
local locate = require("src.rom.locate")

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

  -- A song with sound effects fired over it, which is the thing that cannot be
  -- checked any way but listening: an effect has to interrupt the channel it
  -- uses and hand it back, and either of those going wrong sounds obviously
  -- broken while measuring nothing.
  log("\n== a song with effects over it ==")
  do
    local music_engine = require("src.engine.music")
    local cache = require("src.import.cache")
    local game_id
    for _, entry in ipairs(cache.list_games()) do
      if entry.current then
        game_id = entry.game
      end
    end

    local player = game_id and music_engine.load(game_id)
    if not player then
      log("  SKIP  no current import in the cache")
    else
      player:play(12)
      local chosen = {}
      for slot, entry in ipairs(player.effects) do
        if not entry.unparsed and #chosen < 6 then
          chosen[#chosen + 1] = slot - 1
        end
      end

      local out = {}
      for step = 1, 8 do
        if chosen[step] then
          player:play_sound(chosen[step])
        end
        for _, sample in ipairs(player:render(math.floor(probe.RATE * 0.9))) do
          out[#out + 1] = sample
        end
      end

      love.filesystem.write("dump/audio/song_with_effects.wav",
        wav(out, probe.RATE))
      log("  song 12 with effects %s fired over it -> " ..
        "dump/audio/song_with_effects.wav", table.concat(chosen, ", "))

      -- Which commands the effects put through, kept for the count below.
      -- Sound effects are not short songs: they drive the other channel set
      -- and lean on a different mix of commands, so what an ear has actually
      -- checked is the union of the two rather than the songs on their own.
      probe.effect_commands = {}
      for opcode, times in pairs(player.effect.executed or {}) do
        probe.effect_commands[opcode] = times
      end
    end
  end


  -- Cries, which are the thing pitch and length exist for: 251 species out of
  -- 68 sounds, separated only by those two numbers. An evolution family is the
  -- demonstration — same sound, lower and longer each time.
  log("\n== cries ==")
  do
    local music_engine = require("src.engine.music")
    local cache = require("src.import.cache")
    local game_id
    for _, entry in ipairs(cache.list_games()) do
      if entry.current and entry.game == "crystal" then
        game_id = entry.game
      end
    end
    local player = game_id and music_engine.load(game_id)
    if not player or not player.cries then
      log("  SKIP  no cries in the cache")
    else
      local names = {}
      local n = locate.table(locate.descriptors.species_names, rom)
      names = n and n.records or {}
      local out = {}
      local wanted = { 1, 2, 3, 4, 6, 25, 129, 130, 143, 150 }
      for _, species in ipairs(wanted) do
        player:play_cry(species)
        local record = player.cries.species[species]
        log("  %3d %-11s cry %2d  pitch %6d  length %4d", species,
          names[species] or "?", record.cry, record.pitch, record.length)
        for _, sample in ipairs(player:render(math.floor(probe.RATE * 1.1))) do
          out[#out + 1] = sample
        end
      end
      love.filesystem.write("dump/audio/cries.wav", wav(out, probe.RATE))
      -- Cries run through the same sequencer, and they are shorter and simpler
      -- than either a song or an effect, so what they exercise is worth
      -- counting separately rather than assuming it is a subset.
      probe.cry_commands = {}
      for opcode, times in pairs(player.effect.executed or {}) do
        probe.cry_commands[opcode] = times
      end
      log("  -> dump/audio/cries.wav")
    end
  end
  -- How much of the width table has an ear actually had a chance to check?
  --
  -- Widths are bounded from above by the byte layout and from below only by
  -- listening, because a width one too small is read as a note and plays a
  -- spurious pitch rather than desynchronising. So the commands the rendered
  -- songs *executed* are the ones that have been checked in both directions,
  -- and the rest have not. Saying which is the difference between "the music
  -- sounds right" and a claim somebody can act on.
  log("\n== which commands the rendered songs actually put through ==")
  do
    local music_ops = require("src.rom.music_ops")
    local heard = {}
    for _, index in ipairs(wanted) do
      local song = located.songs[index + 1]
      if song and not song.unparsed then
        local chip = { rate = probe.RATE }
        function chip:write() end
        function chip:generate() return {} end
        local player = sequencer.new(rom.data, chip)
        local channels = {}
        for slot, address in ipairs(song.channels) do
          channels[slot] = song.bank * 0x4000 + (address - 0x4000)
        end
        player:play(channels, song.bank)
        for _ = 1, math.floor(20 * sequencer.FRAME_RATE) do
          if not player:frame() then
            break
          end
        end
        for opcode, times in pairs(player.executed) do
          heard[opcode] = (heard[opcode] or 0) + times
        end
      end
    end

    -- And the whole corpus, for comparison.
    local corpus = {}
    for _, song in ipairs(located.songs) do
      if not song.unparsed then
        local chip = { rate = probe.RATE }
        function chip:write() end
        function chip:generate() return {} end
        local player = sequencer.new(rom.data, chip)
        local channels = {}
        for slot, address in ipairs(song.channels) do
          channels[slot] = song.bank * 0x4000 + (address - 0x4000)
        end
        player:play(channels, song.bank)
        for _ = 1, 900 do
          if not player:frame() then
            break
          end
        end
        for opcode in pairs(player.executed) do
          corpus[opcode] = true
        end
      end
    end

    local listed, in_corpus, in_heard = 0, 0, 0
    local unheard = {}
    for opcode, entry in pairs(music_ops.commands) do
      listed = listed + 1
      if corpus[opcode] then
        in_corpus = in_corpus + 1
        if heard[opcode] then
          in_heard = in_heard + 1
        else
          unheard[#unheard + 1] = entry[1]
        end
      end
    end
    table.sort(unheard)

    log("  %d commands in the table", listed)
    log("  %d of them are executed anywhere in the corpus", in_corpus)
    log("  %d of those were executed by the songs that were rendered", in_heard)
    log("  executed in the corpus but not in the rendered songs: %s",
      #unheard > 0 and table.concat(unheard, ", ") or "none")

    -- The effects were listened to as well, and they are not short songs: they
    -- drive the other channel set and use a different mix of commands. So the
    -- set an ear has checked is the union, and the interesting number is how
    -- many commands the effects add that no song reached.
    local effects_only, both = {}, 0
    for opcode in pairs(probe.effect_commands or {}) do
      if music_ops.commands[opcode] then
        if heard[opcode] then
          both = both + 1
        else
          effects_only[#effects_only + 1] = music_ops.commands[opcode][1]
        end
      end
    end
    table.sort(effects_only)
    log("  the effects that were listened to add %d command(s) no song " ..
      "reached: %s", #effects_only,
      #effects_only > 0 and table.concat(effects_only, ", ") or "none")
    log("  and share %d with them", both)

    -- And the cries, listened to as well.
    local cries_only = {}
    for opcode in pairs(probe.cry_commands or {}) do
      if music_ops.commands[opcode] and not heard[opcode]
        and not (probe.effect_commands or {})[opcode] then
        cries_only[#cries_only + 1] = music_ops.commands[opcode][1]
      end
    end
    table.sort(cries_only)
    log("  the cries add %d command(s) neither songs nor effects reached: %s",
      #cries_only,
      #cries_only > 0 and table.concat(cries_only, ", ") or "none")
  end

  rom:release()
  write(report_path)
  return true
end

return probe
