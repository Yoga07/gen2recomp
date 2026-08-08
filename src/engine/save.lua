-- Saved games.
--
-- This is the engine's own state, not the cartridge's SRAM layout. Emulating
-- SRAM would mean building a format for data the engine does not have yet —
-- boxes, badges, money, the Pokédex — and would tie the save to Crystal's
-- structure before there is anything to put in it. Reading a real .sav so a
-- player can import their own progress is a worthwhile separate feature.
--
-- Saves live beside the cache but are not part of it: the cache is derived from
-- a cartridge and can be rebuilt at any time by re-importing, while a save is
-- the only copy of what the player did. Clearing one must never clear the other.
--
-- Stats are deliberately NOT stored. A Pokémon is its species, level and DVs,
-- and everything else follows from those, so recomputing on load keeps saves
-- small and means a correction to the stat formula reaches saves already
-- written rather than baking the old numbers in forever.

local cache = require("src.import.cache")
local pokemon = require("src.engine.pokemon")

local save = {}

-- Bump when the shape below changes. An older save is refused rather than
-- half-read.
save.FORMAT_VERSION = 1

local ROOT = "saves"

function save.path(game)
  return ("%s/%s.lua"):format(ROOT, game)
end

function save.exists(game)
  return love.filesystem.getInfo(save.path(game)) ~= nil
end

function save.location()
  return love.filesystem.getSaveDirectory() .. "/" .. ROOT
end

--- Reduce a Pokémon to what cannot be derived.
local function pack(instance)
  return {
    species = instance.species,
    level = instance.level,
    dvs = instance.dvs,
    hp = instance.hp,
    statexp = instance.statexp,
    moves = instance.moves,
  }
end

--- Rebuild a Pokémon from a saved record.
-- @return instance, or nil when the species is not in this cache
local function unpack_member(record, base_stats)
  local base = base_stats and base_stats[record.species]
  if not base then
    return nil
  end

  local instance = pokemon.new(record.species, base, {
    level = record.level,
    dvs = record.dvs,
    statexp = record.statexp,
    moves = record.moves,
  })

  -- Current HP is state, not derivation, so it is restored rather than reset.
  -- Clamped in case a stat correction lowered the maximum since saving.
  instance.hp = math.min(record.hp or instance.stats.hp, instance.stats.hp)
  return instance
end

--- Write a save.
-- @param state { map_index, cell_x, cell_y, facing, party }
-- @return true, or nil plus a reason
function save.write(game, state)
  local ok, err = love.filesystem.createDirectory(ROOT)
  if not ok then
    return nil, ("could not create %s: %s"):format(ROOT, tostring(err))
  end

  local party = {}
  for index, member in ipairs(state.party or {}) do
    party[index] = pack(member)
  end

  local record = {
    format_version = save.FORMAT_VERSION,
    game = game,
    map_index = state.map_index,
    cell_x = state.cell_x,
    cell_y = state.cell_y,
    facing = state.facing,
    party = party,
    -- Which trainers have been beaten. Serialised as a list because the keys
    -- are sparse numbers and a list survives the round trip more predictably.
    beaten = (function()
      local flags = {}
      for flag in pairs(state.beaten or {}) do
        flags[#flags + 1] = flag
      end
      table.sort(flags)
      return flags
    end)(),
    -- The bag, as { item, count } pairs. Only what is held is written, so an
    -- empty bag costs nothing and a save from before items existed still reads.
    bag = state.bag or {},
    saved_at = os.time(),
  }

  local source = "-- gen2recomp save. Generated; edit at your own risk.\nreturn "
    .. cache.serialize(record) .. "\n"

  local written, write_err = love.filesystem.write(save.path(game), source)
  if not written then
    return nil, ("could not write the save: %s"):format(tostring(write_err))
  end
  return true
end

--- Read a save back.
-- @return state, or nil plus a reason
function save.read(game, base_stats)
  local path = save.path(game)
  if not love.filesystem.getInfo(path) then
    return nil, "no save"
  end

  local chunk, load_err = love.filesystem.load(path)
  if not chunk then
    return nil, ("the save is corrupt: %s"):format(tostring(load_err))
  end

  local ok, record = pcall(chunk)
  if not ok or type(record) ~= "table" then
    return nil, "the save did not load"
  end

  if record.format_version ~= save.FORMAT_VERSION then
    return nil, ("the save is version %s; this build reads version %d")
      :format(tostring(record.format_version), save.FORMAT_VERSION)
  end

  local party = {}
  for _, member in ipairs(record.party or {}) do
    local instance = unpack_member(member, base_stats)
    if instance then
      party[#party + 1] = instance
    end
  end

  local beaten = {}
  for _, flag in ipairs(record.beaten or {}) do
    beaten[flag] = true
  end

  return {
    map_index = record.map_index,
    cell_x = record.cell_x,
    cell_y = record.cell_y,
    facing = record.facing,
    party = party,
    beaten = beaten,
    bag = record.bag,
    saved_at = record.saved_at,
  }
end

function save.remove(game)
  return love.filesystem.remove(save.path(game))
end

return save
