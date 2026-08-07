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

local FACING_DELTA = {
  up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 },
}

-- Text box geometry, in the 160x144 the hardware rendered.
local BOX_HEIGHT = 48
local BOX_MARGIN = 6

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
  -- The canvas is only 160 wide, so the box needs a font sized for it. The
  -- cartridge's own font lives in bank $3E and is not wired up yet.
  instance.font = love.graphics.newFont(8)
  -- The cartridge's own font, when the import produced one. Falls back to
  -- LOVE's font rather than refusing to show text.
  instance.bitmap_font = require("src.engine.bitmap_font").load(game_id)

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

--- Jump to the first signpost in the game that has text and read it.
-- Used by the screenshot mode to check the whole path from cartridge to
-- text box without a human at the keyboard.
-- @return true when it found one
function game:show_first_sign()
  for index = 1, self.world:map_count() do
    local map = self.world:map(index)
    if not map.unparsed then
      for _, bg in ipairs(map.bg_events or {}) do
        if bg.text and #bg.text > 0 then
          self:enter(index, bg.x, bg.y + 1, "up")
          -- Standing below it, facing up, is how a sign is read.
          self.dialogue = { pages = bg.text, page = 1 }
          return true
        end
      end
    end
  end
  return false
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

--- What the player is facing, if it has something to say.
-- @return pages, kind
function game:facing_text()
  local delta = FACING_DELTA[self.player.facing]
  local x = self.player.cell_x + delta[1]
  local y = self.player.cell_y + delta[2]

  -- Signposts are read by facing them; NPCs are talked to the same way.
  for _, bg in ipairs(self.map.bg_events or {}) do
    if bg.x == x and bg.y == y and bg.text then
      return bg.text, "sign"
    end
  end
  for _, object in ipairs(self.map.objects or {}) do
    if object.x == x and object.y == y and object.text then
      return object.text, "person"
    end
  end
  return nil
end

--- Interact with whatever is in front of the player, or advance the dialogue
-- already on screen.
function game:interact()
  if self.dialogue then
    self.dialogue.page = self.dialogue.page + 1
    if self.dialogue.page > #self.dialogue.pages then
      self.dialogue = nil
    end
    return
  end

  if self.player.moving then
    return
  end

  local pages = self:facing_text()
  if pages then
    self.dialogue = { pages = pages, page = 1 }
  end
end

function game:update(dt)
  -- Movement stops while the text box is up, the way it does in the original.
  if self.dialogue then
    return
  end

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

  -- The text box, drawn inside the canvas so it scales with everything else.
  if self.dialogue then
    local top = game.SCREEN_HEIGHT - BOX_HEIGHT
    love.graphics.setColor(1, 1, 1)
    love.graphics.rectangle("fill", 0, top, game.SCREEN_WIDTH, BOX_HEIGHT)
    love.graphics.setColor(0.1, 0.1, 0.1)
    love.graphics.rectangle("line", 2.5, top + 2.5,
      game.SCREEN_WIDTH - 5, BOX_HEIGHT - 5)

    local page = self.dialogue.pages[self.dialogue.page] or {}

    if self.bitmap_font then
      local line_height = self.bitmap_font:height() + 4
      for i, line in ipairs(page) do
        self.bitmap_font:draw_codes(line.codes, BOX_MARGIN,
          top + 8 + (i - 1) * line_height)
      end
    else
      local previous_font = love.graphics.getFont()
      love.graphics.setFont(self.font)
      local line_height = self.font:getHeight() + 1
      for i, line in ipairs(page) do
        love.graphics.print(line.text, BOX_MARGIN, top + 6 + (i - 1) * line_height)
      end
      love.graphics.setFont(previous_font)
    end

    -- The little marker showing there is more to read.
    if self.dialogue.page < #self.dialogue.pages then
      love.graphics.setColor(0.1, 0.1, 0.1)
      love.graphics.rectangle("fill", game.SCREEN_WIDTH - 10,
        game.SCREEN_HEIGHT - 10, 4, 4)
    end
    love.graphics.setColor(1, 1, 1)
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
