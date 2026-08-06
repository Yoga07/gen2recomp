-- Record layouts for the Gen 2 data tables.
--
-- These describe the *shape* of each table, which is identical across Gold,
-- Silver, and Crystal. Where each table *starts* is version specific and is
-- resolved at import time by src/rom/locate.lua rather than hardcoded here, so
-- that revision differences and non-US dumps do not silently decode garbage.

local text = require("src.rom.text")

local structs = {}

structs.SPECIES_COUNT = 251
structs.MOVE_COUNT = 251

-- Type IDs as stored in the base-stat records. Gen 2 split the special stat in
-- two and slotted the three new types in above the physical/special divide at
-- $14, which is why the numbering has a gap.
structs.types = {
  [0x00] = "normal", [0x01] = "fighting", [0x02] = "flying", [0x03] = "poison",
  [0x04] = "ground", [0x05] = "rock",
  -- $06 is the unused "bird" type carried over from Gen 1. Nothing legitimate
  -- has it, but it is a valid constant and rejecting it would be wrong.
  [0x06] = "bird",
  [0x07] = "bug",    [0x08] = "ghost",  [0x09] = "steel",
  -- $13 is the ??? type. Curse uses it in Gen 2, which is why it must be here:
  -- without it the move table fails to validate at record 174.
  [0x13] = "unknown",
  [0x14] = "fire",     [0x15] = "water",  [0x16] = "grass",
  [0x17] = "electric", [0x18] = "psychic", [0x19] = "ice",   [0x1A] = "dragon",
  [0x1B] = "dark",
}

structs.growth_rates = {
  [0] = "medium_fast", "slightly_fast", "slightly_slow", "medium_slow",
  "fast", "slow",
}

structs.egg_groups = {
  [0x01] = "monster", [0x02] = "water_1", [0x03] = "bug", [0x04] = "flying",
  [0x05] = "field",   [0x06] = "fairy",   [0x07] = "grass", [0x08] = "human_like",
  [0x09] = "water_3", [0x0A] = "mineral", [0x0B] = "amorphous", [0x0C] = "water_2",
  [0x0D] = "ditto",   [0x0E] = "dragon",  [0x0F] = "no_eggs",
}

-- Base stats: 32 bytes per species, indexed by National Dex number.
structs.BASE_STATS_SIZE = 32

--- Decode one base-stat record.
function structs.decode_base_stats(data, offset)
  local function u8(i)
    return string.byte(data, offset + i + 1)
  end

  local gender = u8(13)
  local egg_byte = u8(23)

  return {
    dex_number   = u8(0),
    hp           = u8(1),
    attack       = u8(2),
    defense      = u8(3),
    speed        = u8(4),
    sp_attack    = u8(5),
    sp_defense   = u8(6),
    type_1       = structs.types[u8(7)],
    type_2       = structs.types[u8(8)],
    catch_rate   = u8(9),
    base_exp     = u8(10),
    -- Wild members of the species hold one of these; item_2 is the rare slot.
    held_item_1  = u8(11),
    held_item_2  = u8(12),
    gender_ratio = gender,
    egg_cycles   = u8(15),
    -- Front sprite size in tiles, packed as two nibbles.
    sprite_width  = math.floor(u8(17) / 16),
    sprite_height = u8(17) % 16,
    growth_rate  = structs.growth_rates[u8(22)],
    egg_group_1  = structs.egg_groups[math.floor(egg_byte / 16)],
    egg_group_2  = structs.egg_groups[egg_byte % 16],
    -- Trailing 8 bytes are the TM/HM learnset bitfield.
    tm_hm_bitfield = data:sub(offset + 25, offset + 32),
  }
end

--- A base-stat record is plausible if its stats are in range and its types are
-- ones that exist. Used to score candidate table offsets.
function structs.base_stats_plausible(data, offset)
  if offset + structs.BASE_STATS_SIZE > #data then
    return false
  end
  local function u8(i)
    return string.byte(data, offset + i + 1)
  end
  -- No Gen 2 species has a base stat of 0 or above 255-by-construction; the
  -- real ceiling is Blissey's 255 HP, and the floor is Shedinja-like 1.
  for i = 1, 6 do
    local v = u8(i)
    if v == 0 then
      return false
    end
  end
  if not structs.types[u8(7)] or not structs.types[u8(8)] then
    return false
  end
  if u8(9) == 0 then -- catch rate
    return false
  end
  if not structs.growth_rates[u8(22)] then
    return false
  end
  return true
end

-- Moves: 7 bytes per move.
structs.MOVE_SIZE = 7

structs.move_targets = {} -- filled in when the effect table is decoded

function structs.decode_move(data, offset)
  local function u8(i)
    return string.byte(data, offset + i + 1)
  end
  return {
    animation     = u8(0),
    effect        = u8(1),
    power         = u8(2),
    type          = structs.types[u8(3)],
    -- Accuracy is stored as a fraction of 255, not a percentage.
    accuracy      = u8(4),
    accuracy_pct  = math.floor(u8(4) / 255 * 100 + 0.5),
    pp            = u8(5),
    effect_chance = u8(6),
  }
end

function structs.move_plausible(data, offset)
  if offset + structs.MOVE_SIZE > #data then
    return false
  end
  local function u8(i)
    return string.byte(data, offset + i + 1)
  end
  if not structs.types[u8(3)] then
    return false
  end
  -- PP is capped at 40 in Gen 2 and no move has 0 base PP.
  local pp = u8(5)
  if pp == 0 or pp > 40 then
    return false
  end
  return true
end

-- Species names are padded to a fixed ten bytes. Move names are not padded at
-- all; they are packed back to back with only the terminator between them, so
-- what matters is the longest one rather than a stride.
structs.SPECIES_NAME_LENGTH = 10
structs.MOVE_NAME_MAX = 20

function structs.decode_name(data, offset, length)
  return text.decode(data, offset, length)
end

return structs
