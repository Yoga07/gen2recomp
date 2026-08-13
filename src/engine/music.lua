-- Music while you walk around.
--
-- Owns a sound chip and a sequencer, and keeps LÖVE's audio queue fed from
-- them. Everything it plays comes out of the cache: the song table, and the
-- banks the channel data lives in. It never sees a cartridge, which is the same
-- rule the rest of the engine follows.
--
-- ## Why it generates in sequencer frames
--
-- Two clocks have to stay in step. The sound engine ran once per rendered
-- frame, 59.7 times a second, and the chip produces samples at 44100. Rather
-- than track both separately and let them drift, this generates in units of one
-- sequencer frame: tick the sequencer, then ask the chip for exactly the number
-- of samples that frame is worth. The remainder carries, so a rate that does
-- not divide evenly does not slowly slide out of time.

local cache = require("src.import.cache")
local apu_module = require("src.audio.apu")
local sequencer = require("src.audio.sequencer")

local music = {}
music.__index = music

-- The Game Boy's own output was well under this, and the top octave reaches
-- 8 kHz, so 44100 leaves room above everything the chip can make.
music.RATE = 44100

-- How much audio to hand LÖVE at a time. Small enough that starting a new song
-- is not audibly late, large enough that the per-buffer overhead is not the
-- expensive part.
music.CHUNK = 2048
music.BUFFERS = 8

--- Load the cached music for a game.
-- @return instance, or nil plus a reason
function music.load(game_id)
  local songs = cache.read(game_id, "music")
  if not songs then
    return nil, "no music in the cache"
  end
  local encoded = cache.read(game_id, "music_banks")
  if not encoded then
    return nil, "no music banks in the cache; re-import"
  end

  -- Hex back to bytes, once, at load.
  local banks = {}
  for key, hex in pairs(encoded) do
    banks[tonumber(key)] = (hex:gsub("%x%x", function(pair)
      return string.char(tonumber(pair, 16))
    end))
  end

  local instance = setmetatable({
    songs = songs,
    banks = banks,
    apu = apu_module.new(music.RATE),
    playing = nil,
    frame_debt = 0,
    samples_per_frame = music.RATE / sequencer.FRAME_RATE,
  }, music)

  -- The sequencer reads through this rather than from an image, because the
  -- engine holds a handful of banks and not a cartridge.
  instance.sequencer = sequencer.new(function(offset)
    local bank = banks[math.floor(offset / 0x4000)]
    if not bank then
      return nil
    end
    return string.byte(bank, (offset % 0x4000) + 1)
  end, instance.apu)

  return instance
end

--- Start a song by its index in the table, as `playmusic` and a map header
--- name it. Playing the one already playing is ignored, so walking between two
--- maps that share a song does not restart it at every doorway.
-- @return true when something started
function music:play(index)
  if index == nil or index == self.playing then
    return self.playing ~= nil
  end

  local song = self.songs[index + 1]
  if not song or song.unparsed then
    -- Deliberately leaves whatever is playing alone rather than falling silent.
    --
    -- One id does this and only one: **189**, named by five maps, all indoor
    -- and consecutive in the map table, so it is one building rather than a
    -- scatter. Every other id any map or script asks for is inside the table.
    -- A single out-of-range value used by one contiguous place is a sentinel,
    -- not a truncation — the table was already checked for that and ends where
    -- bank $C0 begins — but what it is a sentinel *for* is not established
    -- here. Carrying on with the current tune is the behaviour that is least
    -- wrong under either reading.
    return false
  end

  local channels = {}
  for slot, address in ipairs(song.channels) do
    channels[slot] = song.bank * 0x4000 + (address - 0x4000)
  end

  self.apu:reset()
  self.sequencer:play(channels, song.bank)
  self.playing = index
  self.frame_debt = 0
  self.finished = false
  return true
end

function music:stop()
  self.playing = nil
  self.finished = true
  if self.source then
    self.source:stop()
  end
  self.apu:reset()
end

--- Produce `count` interleaved stereo samples, ticking the sequencer as the
--- audio needs it. Pure arithmetic: no LÖVE, so it can be tested.
function music:render(count)
  local out = {}
  local written = 0

  while written < count do
    if self.frame_debt <= 0 then
      if self.finished or not self.sequencer:frame() then
        self.finished = true
        -- Silence for whatever is left, so the caller always gets a full
        -- buffer and the queue never starves mid-song.
        for slot = written * 2 + 1, count * 2 do
          out[slot] = 0
        end
        return out
      end
      self.frame_debt = self.frame_debt + self.samples_per_frame
    end

    local take = math.min(count - written, math.floor(self.frame_debt))
    if take < 1 then
      take = 1
    end
    self.apu:generate_into(out, written * 2, take)
    written = written + take
    self.frame_debt = self.frame_debt - take
  end

  return out
end

--- Keep LÖVE's queue fed. Called every frame from the game loop.
function music:update()
  if not self.playing or self.finished then
    return
  end
  if not love or not love.audio then
    return
  end

  if not self.source then
    self.source = love.audio.newQueueableSource(music.RATE, 16, 2,
      music.BUFFERS)
  end

  while self.source:getFreeBufferCount() > 0 do
    local samples = self:render(music.CHUNK)
    local data = love.sound.newSoundData(music.CHUNK, music.RATE, 16, 2)
    for index = 1, music.CHUNK * 2 do
      data:setSample(index - 1, samples[index] or 0)
    end
    self.source:queue(data)
    if self.finished then
      break
    end
  end

  if not self.source:isPlaying() then
    self.source:play()
  end
end

return music
