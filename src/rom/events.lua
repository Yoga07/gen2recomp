-- Map event headers: warps, triggers, signposts and NPCs.
--
-- Every map's attributes record points at an event header, which is four
-- counted arrays in a fixed order behind two filler bytes. Each array is a
-- one-byte count followed by that many fixed-size records.
--
--   filler       2 bytes
--   warps        count, then 5 bytes each
--   coord events count, then 8 bytes each   (position triggers)
--   bg events    count, then 5 bytes each   (signposts, shelves, plaques)
--   object events count, then 13 bytes each (NPCs and items on the ground)
--
-- The record sizes were established by trying every plausible combination
-- against all 384 maps and keeping the one where every warp and every NPC lands
-- inside its own map's bounds. Only this layout does; the near-misses stay in
-- sync for a while and then desynchronise onto garbage. The script-pointer
-- offsets were found the same way, by looking for the byte position that reads
-- as a valid ROM address essentially every time.
--
-- Coordinates are in tiles, and a block is 2x2 tiles, so a map's walkable
-- extent is twice its block dimensions. Object coordinates are stored with 4
-- added to them; warps and signposts are not biased.

local events = {}

events.FILLER = 2
events.WARP_SIZE = 5
events.COORD_SIZE = 8
events.BG_SIZE = 5
events.OBJECT_SIZE = 13

-- Objects store their position offset by this much.
events.OBJECT_COORD_BIAS = 4

-- A sanity ceiling, not a real limit; no Gen 2 map comes close.
events.MAX_COUNT = 64

-- Two movement tiles per block edge.
events.TILES_PER_BLOCK = 2

-- Object type nibbles.
events.OBJECT_SCRIPT = 0
events.OBJECT_ITEM = 1
events.OBJECT_TRAINER = 2

-- A trainer object's script points at this instead of bytecode:
--   0-1  event flag, set once the trainer has been beaten
--   2    trainer class
--   3    trainer id within that class
--   4-5  what they say on sight
--   6-7  what they say on losing
--   8-9  script to run on losing, often absent
--   10-11 what they say afterwards
events.TRAINER_BLOCK = 12

-- Crystal has 67 trainer classes, and no class holds anywhere near this many.
events.MAX_TRAINER_CLASS = 67
events.MAX_TRAINER_ID = 64

--- Read the trainer block a trainer object points at.
-- @param bank the bank the object's script pointer is relative to
function events.decode_trainer(rom, bank, addr)
  if addr < 0x4000 or addr > 0x7FFF then
    return nil, "script pointer out of range"
  end
  local at = bank * 0x4000 + (addr - 0x4000)
  if at + events.TRAINER_BLOCK > rom.size then
    return nil, "trainer block runs past the ROM"
  end

  -- Bounds matter here. Without them almost any script's opening bytes pass:
  -- checking only that class and id are non-zero accepted 812 of the 1134
  -- non-trainer objects, which would have made the type nibble look useless.
  local class = rom:u8(at + 2)
  local id = rom:u8(at + 3)
  if class < 1 or class > events.MAX_TRAINER_CLASS then
    return nil, ("class %d is out of range"):format(class)
  end
  if id < 1 or id > events.MAX_TRAINER_ID then
    return nil, ("id %d is out of range"):format(id)
  end

  local function pointer(index)
    local value = rom:u16le(at + 4 + index * 2)
    if value == 0 then
      return nil
    end
    return (value >= 0x4000 and value <= 0x7FFF) and value or nil
  end

  return {
    offset = at,
    flag = rom:u16le(at),
    class = class,
    id = id,
    seen_text = pointer(0),
    beaten_text = pointer(1),
    loss_script = pointer(2),
    after_text = pointer(3),
  }
end

-- An item ball's script points at two bytes rather than at bytecode: which
-- item, and how many. Every item ball in Crystal holds exactly one.
events.ITEM_BLOCK = 2

--- Read the item block an item-ball object points at.
-- @param bank the bank the object's script pointer is relative to
-- @return { item, quantity } or nil plus a reason
function events.decode_item(rom, bank, addr)
  if not addr or addr < 0x4000 or addr > 0x7FFF then
    return nil, "script pointer out of range"
  end
  local at = bank * 0x4000 + (addr - 0x4000)
  if at + events.ITEM_BLOCK > rom.size then
    return nil, "item block runs past the ROM"
  end

  local item = rom:u8(at)
  local quantity = rom:u8(at + 1)
  if item < 1 then
    return nil, "item 0 does not exist"
  end
  -- The quantity is bounded by what the bag can hold in one stack. Nothing in
  -- Crystal exceeds one, but the field is a byte and a wider game might.
  if quantity < 1 or quantity > 99 then
    return nil, ("quantity %d is out of range"):format(quantity)
  end

  return { offset = at, item = item, quantity = quantity }
end

events.bg_types = {
  [0] = "read", "up", "down", "right", "left", "if_set", "if_not_set",
  "item", "copy",
}

local function near_pointer(rom, offset)
  local addr = rom:u16le(offset)
  if addr < 0x4000 or addr > 0x7FFF then
    return nil, addr
  end
  return addr, addr
end

--- Decode a map's event header.
--
-- Script pointers are returned as raw 16-bit addresses rather than flat
-- offsets: they are near pointers into whichever bank the map's script header
-- lives in, which the attributes record already records.
--
-- @return table of arrays, or nil plus a reason
function events.decode(rom, header)
  local attributes = header.attributes
  local tile_height = attributes.height * events.TILES_PER_BLOCK
  local tile_width = attributes.width * events.TILES_PER_BLOCK

  local at = attributes.events + events.FILLER

  local function take_count(what)
    if at + 1 > rom.size then
      return nil, ("%s count runs past the end of the ROM"):format(what)
    end
    local n = rom:u8(at)
    at = at + 1
    if n > events.MAX_COUNT then
      return nil, ("%s count of %d is implausible"):format(what, n)
    end
    return n
  end

  local function in_bounds(y, x, bias)
    bias = bias or 0
    return y >= bias and y < tile_height + bias
       and x >= bias and x < tile_width + bias
  end

  -- Warps.
  local warp_count, why = take_count("warp")
  if not warp_count then
    return nil, why
  end
  local warps = {}
  for i = 1, warp_count do
    if at + events.WARP_SIZE > rom.size then
      return nil, "warps run past the end of the ROM"
    end
    local y, x = rom:u8(at), rom:u8(at + 1)
    if not in_bounds(y, x) then
      return nil, ("warp %d at (%d,%d) is outside a %dx%d map")
        :format(i, x, y, tile_width, tile_height)
    end
    warps[i] = {
      y = y,
      x = x,
      -- Which warp on the destination map this one arrives at.
      destination_warp = rom:u8(at + 2),
      destination_group = rom:u8(at + 3),
      destination_map = rom:u8(at + 4),
    }
    at = at + events.WARP_SIZE
  end

  -- Coordinate triggers: fire when the player steps on a tile, gated by the
  -- map's current scene.
  local coord_count
  coord_count, why = take_count("coord event")
  if not coord_count then
    return nil, why
  end
  local coord_events = {}
  for i = 1, coord_count do
    coord_events[i] = {
      scene = rom:u8(at),
      y = rom:u8(at + 1),
      x = rom:u8(at + 2),
      script = near_pointer(rom, at + 4),
    }
    at = at + events.COORD_SIZE
  end

  -- Background events: signposts and anything else interacted with by facing
  -- it rather than standing on it.
  local bg_count
  bg_count, why = take_count("bg event")
  if not bg_count then
    return nil, why
  end
  local bg_events = {}
  for i = 1, bg_count do
    local kind = rom:u8(at + 2)
    bg_events[i] = {
      y = rom:u8(at),
      x = rom:u8(at + 1),
      kind = kind,
      kind_name = events.bg_types[kind],
      script = near_pointer(rom, at + 3),
    }
    at = at + events.BG_SIZE
  end

  -- Object events: NPCs, and items lying on the ground.
  local object_count
  object_count, why = take_count("object event")
  if not object_count then
    return nil, why
  end
  local objects = {}
  for i = 1, object_count do
    if at + events.OBJECT_SIZE > rom.size then
      return nil, "objects run past the end of the ROM"
    end
    local y, x = rom:u8(at + 1), rom:u8(at + 2)
    -- Out-of-bounds objects are flagged, not rejected. Object count and record
    -- size are both fixed, so a stray position cannot desynchronise the parse;
    -- the bounds test earned its keep by discriminating between candidate
    -- layouts, and one Crystal map really does place an NPC outside its own
    -- dimensions. Failing the whole map over that would lose it entirely.
    local outside = not in_bounds(y, x, events.OBJECT_COORD_BIAS)
    local radius = rom:u8(at + 4)
    objects[i] = {
      sprite = rom:u8(at),
      y = y - events.OBJECT_COORD_BIAS,
      x = x - events.OBJECT_COORD_BIAS,
      movement = rom:u8(at + 3),
      -- How far the NPC may wander, packed as two nibbles.
      radius_y = radius % 16,
      radius_x = math.floor(radius / 16),
      hour = rom:u8(at + 5),
      time_of_day = rom:u8(at + 6),
      -- One byte holding two nibbles: palette above, object type below.
      --
      -- Type 1 is an item ball and type 2 a trainer. The item ball is the one
      -- that can be shown rather than argued: its script pointer leads to two
      -- bytes, an item and a quantity, and across all 178 of them the quantity
      -- byte takes exactly one value, $01. The 898 type-0 objects take 209
      -- different values in that position. Reading a byte pair as an item is
      -- weak on its own — 85% of the trainers pass it too — so it is that
      -- uniformity, not the plausibility, that identifies the type.
      colour_function = rom:u8(at + 7),
      palette = math.floor(rom:u8(at + 7) / 16),
      kind = rom:u8(at + 7) % 16,
      sight_range = rom:u8(at + 8),
      script = near_pointer(rom, at + 9),
      event_flag = rom:u16le(at + 11),
      out_of_bounds = outside or nil,
    }
    at = at + events.OBJECT_SIZE
  end

  return {
    offset = attributes.events,
    size = at - attributes.events,
    warps = warps,
    coord_events = coord_events,
    bg_events = bg_events,
    objects = objects,
  }
end

return events
