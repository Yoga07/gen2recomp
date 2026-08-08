-- A list with a cursor.
--
-- Deliberately has no idea what it is listing or how anything is drawn: it owns
-- the cursor, the wrapping and the scroll window, and nothing else. Every menu
-- screen in the game is one of these with a different painter, which keeps the
-- navigation behaviour identical everywhere without repeating it.

local menu = {}
menu.__index = menu

--- @param items array of anything
-- @param visible how many rows fit on screen at once
function menu.new(items, visible)
  return setmetatable({
    items = items or {},
    cursor = 1,
    offset = 0,
    visible = visible or 4,
  }, menu)
end

function menu:count()
  return #self.items
end

function menu:selected()
  return self.items[self.cursor]
end

function menu:is_empty()
  return #self.items == 0
end

--- Move the cursor, wrapping at both ends the way the original does.
function menu:move(delta)
  if #self.items == 0 then
    return
  end

  self.cursor = ((self.cursor - 1 + delta) % #self.items) + 1

  -- Keep the cursor inside the scroll window. Wrapping from the last item to
  -- the first has to jump the window rather than nudge it.
  if self.cursor <= self.offset then
    self.offset = self.cursor - 1
  elseif self.cursor > self.offset + self.visible then
    self.offset = self.cursor - self.visible
  end

  self.offset = math.max(0, math.min(self.offset, math.max(0, #self.items - self.visible)))
end

--- The rows currently on screen, with their real indices.
-- @return array of { index, item, selected }
function menu:window()
  local rows = {}
  for position = 1, math.min(self.visible, #self.items) do
    local index = self.offset + position
    local item = self.items[index]
    if item then
      rows[#rows + 1] = {
        index = index,
        item = item,
        selected = index == self.cursor,
      }
    end
  end
  return rows
end

return menu
