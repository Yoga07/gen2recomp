-- The game loop: an overworld you can walk around.
--
-- Renders at the Game Boy's 160x144 to a canvas and scales that up by whole
-- numbers, so every source pixel covers the same number of screen pixels. Any
-- other scaling produces uneven tile edges, which on this art is very visible.

local world = require("src.engine.world")
local player = require("src.engine.player")
local cache = require("src.import.cache")

local game = {}
game.__index = game

game.SCREEN_WIDTH = 160
game.SCREEN_HEIGHT = 144

local KEYS = {
  up = "up", down = "down", left = "left", right = "right",
  w = "up", s = "down", a = "left", d = "right",
}

--- Start a game on a cached import.
-- @param start_index which map to spawn on; defaults to the largest town
function game.new(game_id, start_index)
  local loaded, why = world.load(game_id)
  if not loaded then
    return nil, why
  end

  local instance = setmetatable({
    world = loaded,
    groups = cache.read(game_id, "map_groups") or {},
    canvas = love.graphics.newCanvas(game.SCREEN_WIDTH, game.SCREEN_HEIGHT),
    message = nil,
    message_timer = 0,
  }, game)
  instance.canvas:setFilter("nearest", "nearest")

  instance:enter(start_index or instance:default_map())
  return instance
end

--- Somewhere interesting to start: the biggest town, falling back to the
-- biggest map of any kind.
function game:default_map()
  local best, best_area, fallback, fallback_area = nil, -1, nil, -1
  for index = 1, self.world:map_count() do
    local map = self.world:map(index)
    if not map.unparsed then
    local area = map.width * map.height
    if area > fallback_area then
      fallback, fallback_area = index, area
    end
    if map.environment == "town" and area > best_area then
      best, best_area = index, area
    end
    end
  end
  return best or fallback
end

--- Put the player on a map, on a walkable cell near the middle if no spawn is
-- given. Real spawn points come from warps once you arrive through one.
function game:enter(map_index, cell_x, cell_y, facing)
  self.map_index = map_index
  self.map = self.world:map(map_index)

  if not cell_x then
    cell_x, cell_y = self:find_spawn()
  end

  if self.player then
    self.player:place(cell_x, cell_y, facing)
  else
    self.player = player.new(cell_x, cell_y)
  end
end

--- Nearest walkable cell to the map's centre, searched outwards.
function game:find_spawn()
  local centre_x = math.floor(self.map.width * world.CELLS_PER_BLOCK / 2)
  local centre_y = math.floor(self.map.height * world.CELLS_PER_BLOCK / 2)

  for radius = 0, math.max(self.map.width, self.map.height) * 2 do
    for dy = -radius, radius do
      for dx = -radius, radius do
        -- Only test the ring at this radius, not the filled square.
        if math.abs(dx) == radius or math.abs(dy) == radius then
          local x, y = centre_x + dx, centre_y + dy
          if self.world:walkable(self.map, x, y) then
            return x, y
          end
        end
      end
    end
  end
  return centre_x, centre_y
end

function game:held_direction()
  for key, direction in pairs(KEYS) do
    if love.keyboard.isDown(key) then
      return direction
    end
  end
  return nil
end

function game:notify(text)
  self.message = text
  self.message_timer = 2.5
end

function game:update(dt)
  if self.message_timer > 0 then
    self.message_timer = self.message_timer - dt
    if self.message_timer <= 0 then
      self.message = nil
    end
  end

  local event, cell_x, cell_y = self.player:update(dt, self:held_direction(),
    function(x, y)
      return self.world:walkable(self.map, x, y)
    end)

  if event == "arrived" then
    local warp = self.world:warp_at(self.map, cell_x, cell_y)
    if warp then
      self:take_warp(warp)
    end
  end
end

--- Follow a warp to its destination.
--
-- Warps name their target by map group and number plus which warp on that map
-- to arrive at, so this needs the group table the importer extracted. Without
-- it the destination cannot be resolved and the warp is reported instead of
-- taken.
function game:take_warp(warp)
  local group_start = self.groups[warp.destination_group]
  if not group_start then
    self:notify(("warp to group %d map %d: group table missing")
      :format(warp.destination_group, warp.destination_map))
    return
  end

  local index = group_start + warp.destination_map - 1
  local destination = self.world:map(index)
  if not destination or destination.unparsed then
    self:notify(("warp to group %d map %d: map did not decode")
      :format(warp.destination_group, warp.destination_map))
    return
  end

  -- Arrive standing on the warp the destination names.
  local arrival = (destination.warps or {})[warp.destination_warp]
  if arrival then
    self:enter(index, arrival.x, arrival.y)
  else
    self:enter(index)
  end
  self:notify(("map %d  %dx%d  %s"):format(index, destination.width,
    destination.height, destination.environment or "?"))
end

function game:draw(scale)
  local map = self.map

  local px, py = self.player:pixel_position(world.CELL_PIXELS)
  -- Centre the player, then clamp so the view never runs off the map.
  local camera_x = px - game.SCREEN_WIDTH / 2 + world.CELL_PIXELS / 2
  local camera_y = py - game.SCREEN_HEIGHT / 2 + world.CELL_PIXELS / 2
  camera_x = math.max(0, math.min(camera_x,
    map.width * world.BLOCK_PIXELS - game.SCREEN_WIDTH))
  camera_y = math.max(0, math.min(camera_y,
    map.height * world.BLOCK_PIXELS - game.SCREEN_HEIGHT))
  camera_x, camera_y = math.floor(camera_x), math.floor(camera_y)

  love.graphics.setCanvas(self.canvas)
  love.graphics.clear(0, 0, 0)
  love.graphics.setColor(1, 1, 1)

  self.world:draw(map, camera_x, camera_y, game.SCREEN_WIDTH, game.SCREEN_HEIGHT)

  -- Warps, so doors are visible before overworld sprites exist.
  love.graphics.setColor(1, 0.4, 0.4, 0.5)
  for _, warp in ipairs(map.warps or {}) do
    love.graphics.rectangle("line",
      warp.x * world.CELL_PIXELS - camera_x + 0.5,
      warp.y * world.CELL_PIXELS - camera_y + 0.5,
      world.CELL_PIXELS - 1, world.CELL_PIXELS - 1)
  end

  -- NPCs. Sprites stand a little taller than their cell, so they are drawn
  -- shifted up by half a tile the way the original did.
  love.graphics.setColor(1, 1, 1)
  for _, object in ipairs(map.objects or {}) do
    local ox = object.x * world.CELL_PIXELS - camera_x
    local oy = object.y * world.CELL_PIXELS - camera_y - 4
    if not self.world:draw_ow_sprite(object.sprite, ox, oy, "down") then
      love.graphics.setColor(0.4, 0.6, 1, 0.75)
      love.graphics.rectangle("fill", ox + 3, oy + 7,
        world.CELL_PIXELS - 6, world.CELL_PIXELS - 6)
      love.graphics.setColor(1, 1, 1)
    end
  end

  -- The player. Sprite 1 is the player character.
  love.graphics.setColor(1, 1, 1)
  if not self.world:draw_ow_sprite(1, px - camera_x, py - camera_y - 4,
    self.player.facing) then
    love.graphics.rectangle("fill",
      px - camera_x + 2, py - camera_y + 2,
      world.CELL_PIXELS - 4, world.CELL_PIXELS - 4)
    love.graphics.setColor(0.1, 0.1, 0.1)
    local notch = {
      up = { 6, 0 }, down = { 6, 10 }, left = { 0, 6 }, right = { 10, 6 },
    }
    local offset = notch[self.player.facing]
    love.graphics.rectangle("fill",
      px - camera_x + 3 + offset[1], py - camera_y + 3 + offset[2], 4, 4)
  end

  love.graphics.setCanvas()

  -- Scale up by whole pixels only.
  love.graphics.setColor(1, 1, 1)
  local offset_x = math.floor((love.graphics.getWidth() - game.SCREEN_WIDTH * scale) / 2)
  local offset_y = math.floor((love.graphics.getHeight() - game.SCREEN_HEIGHT * scale) / 2)
  love.graphics.draw(self.canvas, offset_x, offset_y, 0, scale, scale)

  if self.message then
    love.graphics.setColor(0, 0, 0, 0.7)
    love.graphics.rectangle("fill", 0, love.graphics.getHeight() - 28,
      love.graphics.getWidth(), 28)
    love.graphics.setColor(1, 1, 1)
    love.graphics.print(self.message, 10, love.graphics.getHeight() - 20)
  end
end

return game
