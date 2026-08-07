-- The player: grid movement with collision, in the style the original used.
--
-- Movement is one cell at a time and cannot be interrupted mid-step, which is
-- what makes the overworld feel like Gen 2 rather than like a free-roaming
-- character. Holding a direction turns first and only then walks, so tapping a
-- key to face something does not move you.

local player = {}
player.__index = player

-- Frames a single step takes, at the 60 Hz the hardware ran at.
local STEP_SECONDS = 16 / 60
-- Held for less than this, a direction press only turns.
local TURN_SECONDS = 6 / 60

local DIRECTIONS = {
  up = { x = 0, y = -1 },
  down = { x = 0, y = 1 },
  left = { x = -1, y = 0 },
  right = { x = 1, y = 0 },
}

function player.new(cell_x, cell_y)
  return setmetatable({
    cell_x = cell_x,
    cell_y = cell_y,
    facing = "down",
    -- While stepping, where we came from and how far along we are.
    moving = false,
    from_x = cell_x,
    from_y = cell_y,
    progress = 0,
    turn_timer = 0,
  }, player)
end

--- Pixel position, interpolated during a step.
function player:pixel_position(cell_pixels)
  if not self.moving then
    return self.cell_x * cell_pixels, self.cell_y * cell_pixels
  end
  local t = self.progress / STEP_SECONDS
  return (self.from_x + (self.cell_x - self.from_x) * t) * cell_pixels,
         (self.from_y + (self.cell_y - self.from_y) * t) * cell_pixels
end

--- Advance the player.
-- @param held    direction name currently pressed, or nil
-- @param can_walk function(cell_x, cell_y) -> boolean
-- @return "arrived" and the cell just entered, when a step completes
function player:update(dt, held, can_walk)
  if self.moving then
    self.progress = self.progress + dt
    if self.progress >= STEP_SECONDS then
      self.moving = false
      self.progress = 0
      return "arrived", self.cell_x, self.cell_y
    end
    return nil
  end

  if not held then
    self.turn_timer = 0
    return nil
  end

  -- Turning in place is free and instant; walking needs the key held.
  if self.facing ~= held then
    self.facing = held
    self.turn_timer = 0
    return nil
  end

  self.turn_timer = self.turn_timer + dt
  if self.turn_timer < TURN_SECONDS then
    return nil
  end

  local delta = DIRECTIONS[held]
  local target_x, target_y = self.cell_x + delta.x, self.cell_y + delta.y
  if not can_walk(target_x, target_y) then
    return nil
  end

  self.from_x, self.from_y = self.cell_x, self.cell_y
  self.cell_x, self.cell_y = target_x, target_y
  self.moving = true
  self.progress = 0
  return nil
end

--- Put the player somewhere without animating, used when a warp fires.
function player:place(cell_x, cell_y, facing)
  self.cell_x, self.cell_y = cell_x, cell_y
  self.from_x, self.from_y = cell_x, cell_y
  self.moving = false
  self.progress = 0
  self.turn_timer = 0
  if facing then
    self.facing = facing
  end
end

return player
