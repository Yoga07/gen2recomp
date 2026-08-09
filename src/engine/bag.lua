-- The bag.
--
-- Gen 2 splits the bag into four pockets and the cartridge says which pocket
-- each item belongs to, so nothing is enumerated here: the pocket, whether an
-- item can be tossed, and what it does in battle all come from the attribute
-- table. That is what keeps the Heavy, Lure and Friend balls working without
-- being named anywhere in the engine.
--
-- Quantities are capped at 99 per stack the way the games cap them, and an
-- item that runs out leaves the pocket rather than sitting there at zero.

local bag = {}

bag.MAX_STACK = 99
bag.POCKETS = { "items", "balls", "machines", "key" }

local Bag = {}
Bag.__index = Bag

--- @param attributes the decoded item attribute table, indexed by item id
--- @param names the item name table, indexed by item id
function bag.new(attributes, names)
  return setmetatable({
    attributes = attributes or {},
    names = names or {},
    stacks = {},
  }, Bag)
end

function Bag:attribute(item)
  return self.attributes[item]
end

function Bag:name(item)
  return self.names[item] or ("item %d"):format(item)
end

--- Which pocket an item belongs in, straight from the cartridge.
function Bag:pocket_of(item)
  local record = self.attributes[item]
  return record and record.pocket or "items"
end

function Bag:count(item)
  return self.stacks[item] or 0
end

--- Add `quantity` of an item.
-- @return how many were actually taken, which is less than asked for when the
--         stack is already at the cap.
function Bag:add(item, quantity)
  quantity = quantity or 1
  local held = self.stacks[item] or 0
  local taken = math.min(quantity, bag.MAX_STACK - held)
  if taken > 0 then
    self.stacks[item] = held + taken
  end
  return taken
end

--- Remove `quantity` of an item.
-- @return true when there was enough to remove; the bag is left alone if not.
function Bag:remove(item, quantity)
  quantity = quantity or 1
  local held = self.stacks[item] or 0
  if held < quantity then
    return false
  end
  local left = held - quantity
  -- An empty stack is absent rather than zero, so the pocket listing does not
  -- have to filter it out everywhere.
  self.stacks[item] = left > 0 and left or nil
  return true
end

--- Everything in one pocket, in item order.
-- @return array of { item, name, count, record }
function Bag:pocket(which)
  local out = {}
  for item, count in pairs(self.stacks) do
    if self:pocket_of(item) == which then
      out[#out + 1] = {
        item = item,
        name = self:name(item),
        count = count,
        record = self.attributes[item],
      }
    end
  end
  table.sort(out, function(a, b) return a.item < b.item end)
  return out
end

--- Which pockets currently hold anything, so empty ones can be skipped.
function Bag:used_pockets()
  local out = {}
  for _, which in ipairs(bag.POCKETS) do
    if #self:pocket(which) > 0 then
      out[#out + 1] = which
    end
  end
  return out
end

-- A shop pays half what it charges. The halving is a game rule rather than
-- something the cartridge stores: there is one price per item, and the counter
-- divides it.
bag.SELL_DIVISOR = 2

--- What a shop pays for one of an item.
function Bag:sell_price(item)
  local record = self.attributes[item]
  if not record then
    return 0
  end
  return math.floor(record.price / bag.SELL_DIVISOR)
end

--- Can this item be sold at all?
--
-- Two conditions, both read off the cartridge. It has to have a price, and it
-- has to be something the player is allowed to part with — the same bit that
-- stops the Bicycle, the Card Key and the HMs being tossed stops them being
-- sold, which is why no list of key items appears here.
function Bag:can_sell(item)
  local record = self.attributes[item]
  if not record then
    return false
  end
  return record.price > 0 and record.tossable
end

--- Everything in the bag a shop would take, in item order.
function Bag:sellable()
  local out = {}
  for item, count in pairs(self.stacks) do
    if self:can_sell(item) then
      out[#out + 1] = {
        item = item,
        name = self:name(item),
        count = count,
        price = self:sell_price(item),
        record = self.attributes[item],
      }
    end
  end
  table.sort(out, function(a, b) return a.item < b.item end)
  return out
end

--- The first ball in the bag, which is what a battle reaches for.
function Bag:first_ball()
  local balls = self:pocket("balls")
  return balls[1]
end

function Bag:total()
  local sum = 0
  for _, count in pairs(self.stacks) do
    sum = sum + count
  end
  return sum
end

--- Restore from a saved list of { item, count } pairs.
function bag.from_list(attributes, names, list)
  local instance = bag.new(attributes, names)
  for _, entry in ipairs(list or {}) do
    instance.stacks[entry.item] = math.min(entry.count, bag.MAX_STACK)
  end
  return instance
end

--- Flatten to a list of { item, count } pairs, for saving.
function Bag:to_list()
  local out = {}
  for item, count in pairs(self.stacks) do
    out[#out + 1] = { item = item, count = count }
  end
  table.sort(out, function(a, b) return a.item < b.item end)
  return out
end

bag.Bag = Bag

return bag
