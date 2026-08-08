-- Items.
--
-- An item is a name and seven bytes of attributes. The names live in their own
-- bank, packed with the terminator between them like the move names; the
-- attributes are a flat stride-7 table starting at the Master Ball.
--
--   0..1  price, little endian
--   2     held effect
--   3     parameter, which the effect reads
--   4     property bits: $40 cannot be registered, $80 cannot be tossed
--   5     pocket: 1 items, 2 key items, 3 balls, 4 machines
--   6     menu: high nibble is what it does in the field, low nibble in battle
--
-- The field order was read off the cartridge rather than assumed. Four items
-- whose pocket is not in doubt disagree in exactly one column, and the column
-- that holds the pocket takes only the values 1 to 4 across all 255 items.
-- Potion's parameter is 20 and Berry's is 10, which is how much HP each
-- restores, so byte 3 identifies itself.

local text = require("src.rom.text")

local items = {}

-- Items are numbered from 1, and 255 of them have names. The table is followed
-- by unrelated bytes, so the count is a real boundary rather than a guess: the
-- 256th read stops on $FA.
items.COUNT = 255
items.NAME_MAX = 20
items.RECORD_SIZE = 7

items.pockets = {
  [1] = "items",
  [2] = "key",
  [3] = "balls",
  [4] = "machines",
}

items.CANT_SELECT = 0x40
items.CANT_TOSS = 0x80

-- What the low nibble of the menu byte means in battle, and the high nibble in
-- the field. Only the values that actually occur are named; anything else is
-- kept as a number so an unknown stays visible instead of being rounded off to
-- the nearest thing we recognise.
items.uses = {
  [0] = "none",
  [5] = "heal",
  [6] = "ball",
}

-- Records are read straight out of the cartridge image as a string, the same
-- way the base stats and moves are, so the table locator can validate a
-- candidate before anything has been decoded.
local function u8(data, offset)
  return string.byte(data, offset + 1)
end

--- Decode one attribute record.
function items.decode(data, offset)
  local property = u8(data, offset + 4)
  local pocket = u8(data, offset + 5)
  local menu = u8(data, offset + 6)

  return {
    price = u8(data, offset) + u8(data, offset + 1) * 256,
    held_effect = u8(data, offset + 2),
    parameter = u8(data, offset + 3),
    property = property,
    selectable = property % 0x80 < items.CANT_SELECT,
    tossable = property < items.CANT_TOSS,
    pocket = items.pockets[pocket] or pocket,
    menu = menu,
    field_use = items.uses[math.floor(menu / 16)] or math.floor(menu / 16),
    battle_use = items.uses[menu % 16] or menu % 16,
  }
end

--- True when the seven bytes at `offset` could be an item.
-- The pocket and the property bits are the parts worth constraining. Price and
-- parameter span most of their range and rule almost nothing out.
function items.plausible(data, offset)
  if offset + items.RECORD_SIZE > #data then
    return false
  end
  local property = string.byte(data, offset + 5)
  local pocket = string.byte(data, offset + 6)
  if not items.pockets[pocket] then
    return false
  end
  -- Only the top two bits are ever set.
  if property % 0x40 ~= 0 then
    return false
  end
  return true
end

--- Is this item a Poke Ball of some kind?
-- Read from the cartridge rather than from a list of names, so the Heavy, Lure
-- and Friend balls come along without being enumerated here.
function items.is_ball(record)
  return record.pocket == "balls"
end

--- Decode the whole attribute table.
function items.decode_all(data, offset)
  local records = {}
  for index = 1, items.COUNT do
    records[index] = items.decode(data, offset + (index - 1) * items.RECORD_SIZE)
  end
  return records
end

--- Names, decoded from a located table. Substitution codes appear in item
-- names -- item 5 is POKe BALL, stored with the $54 that the text engine
-- expands -- so they have to be resolved rather than escaped.
function items.decode_names(data, offset)
  local names, at = {}, offset
  for index = 1, items.COUNT do
    local name, consumed = text.decode_terminated(data, at, items.NAME_MAX, true)
    if not name then
      return nil, ("item %d has no terminated name"):format(index)
    end
    names[index] = name
    at = at + consumed
  end
  return names, at - offset
end

return items
