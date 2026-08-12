-- The storage boxes.
--
-- Fourteen boxes of twenty, which is what Gen 2 gives you. Nothing about the
-- layout is read from the cartridge: the boxes live in save RAM rather than in
-- the ROM, so there is no table to find. The counts are the game's, written
-- here because there is nowhere else for them to come from.
--
-- What matters for play is that catching a seventh Pokémon stops being a
-- failure. Before this the party was a hard cap and a full party meant the
-- catch was thrown away after the ball had already been spent.

local storage = {}

storage.BOX_COUNT = 14
storage.BOX_SIZE = 20

local Storage = {}
Storage.__index = Storage

function storage.new()
  local boxes = {}
  for index = 1, storage.BOX_COUNT do
    boxes[index] = {}
  end
  return setmetatable({ boxes = boxes, current = 1 }, Storage)
end

function Storage:box(index)
  return self.boxes[index or self.current]
end

function Storage:count(index)
  return #self:box(index)
end

function Storage:is_full(index)
  return self:count(index) >= storage.BOX_SIZE
end

--- Everything stored, across every box.
function Storage:total()
  local sum = 0
  for _, box in ipairs(self.boxes) do
    sum = sum + #box
  end
  return sum
end

--- Put a Pokémon away.
--
-- Into the current box if it has room, otherwise the first that does. The games
-- refuse when the current box is full and make you change it by hand; rolling
-- on is friendlier and loses nothing, and there is a message either way.
-- @return the box it went into, or nil when every box is full
function Storage:deposit(instance)
  if not self:is_full(self.current) then
    local box = self:box(self.current)
    box[#box + 1] = instance
    return self.current
  end

  for index = 1, storage.BOX_COUNT do
    if not self:is_full(index) then
      local box = self:box(index)
      box[#box + 1] = instance
      return index
    end
  end

  return nil
end

--- Take one out.
-- @return the Pokémon, or nil
function Storage:withdraw(box_index, slot)
  local box = self:box(box_index)
  if not box or not box[slot] then
    return nil
  end
  return table.remove(box, slot)
end

--- Everything stored, flattened. The dex asks this on load: a Pokémon in a box
--- is one the player owns, whichever box it happens to be sitting in.
function Storage:every()
  local out = {}
  for _, box in ipairs(self.boxes) do
    for _, instance in ipairs(box) do
      out[#out + 1] = instance
    end
  end
  return out
end

--- Which boxes have anything in them.
function Storage:used_boxes()
  local out = {}
  for index = 1, storage.BOX_COUNT do
    if #self.boxes[index] > 0 then
      out[#out + 1] = index
    end
  end
  return out
end

--- Flatten for saving: a list of { box, members }.
function Storage:to_list(pack)
  local out = {}
  for index, box in ipairs(self.boxes) do
    if #box > 0 then
      local members = {}
      for slot, instance in ipairs(box) do
        members[slot] = pack and pack(instance) or instance
      end
      out[#out + 1] = { box = index, members = members }
    end
  end
  return out
end

--- Restore from that.
function storage.from_list(list, unpack_member)
  local instance = storage.new()
  for _, entry in ipairs(list or {}) do
    local box = instance.boxes[entry.box]
    if box then
      for _, member in ipairs(entry.members or {}) do
        local restored = unpack_member and unpack_member(member) or member
        if restored then
          box[#box + 1] = restored
        end
      end
    end
  end
  return instance
end

storage.Storage = Storage

return storage
