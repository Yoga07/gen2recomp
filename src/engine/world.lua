-- The world: cached map and tileset data, plus the drawing and collision
-- queries the game loop needs.
--
-- Nothing here touches a cartridge. The engine reads only what the importer
-- wrote, which is the rule that keeps the two halves separable: a decoder bug
-- shows up as a failed import rather than as a subtly wrong game.
--
-- Coordinates come in three flavours and mixing them up is the easiest mistake
-- to make here:
--
--   block  32x32 px, what map data is indexed in
--   cell   16x16 px, what the player walks on, 2x2 per block
--   pixel  what gets drawn
--
-- Collision is stored per cell, four bytes per block.

local cache = require("src.import.cache")

local world = {}
world.__index = world

world.BLOCK_PIXELS = 32
world.CELL_PIXELS = 16
world.CELLS_PER_BLOCK = 2
world.TILE_PIXELS = 8
world.TILES_PER_BLOCK_EDGE = 4

local collision = require("src.rom.collision")

--- Load a game's cache.
-- @return world instance, or nil plus a reason
function world.load(game)
  local maps = cache.read(game, "maps")
  if not maps then
    return nil, ("no cached maps for %s; run an import first"):format(game)
  end

  local tilesets = cache.read(game, "tilesets")
  if not tilesets then
    return nil, ("no cached tilesets for %s"):format(game)
  end

  return setmetatable({
    game = game,
    maps = maps,
    tilesets = tilesets,
    -- Overworld sprites are optional: without them the engine draws
    -- placeholders rather than refusing to run.
    ow_sprites = cache.read(game, "ow_sprites") or {},
    images = {},   -- tileset index -> Image
    quads = {},    -- tileset index -> array of Quads, one per tile
    batches = {},  -- tileset index -> SpriteBatch
    ow_images = {},
    ow_quads = {},
  }, world)
end

-- Frame order within a standard overworld sprite. Left is the side view
-- mirrored, which is how the original saved a frame.
local FACING_FRAME = { down = 0, up = 1, right = 2, left = 2 }

--- Load an overworld sprite sheet and its per-frame quads.
-- @return image, quads or nil when that sprite id has no graphics
function world:ow_sprite(id)
  if self.ow_images[id] == nil then
    local record = self.ow_sprites[id]
    local path = ("%s/ow/%03d.png"):format(cache.dir(self.game), id)
    if not record or not love.filesystem.getInfo(path) then
      self.ow_images[id] = false
    else
      local image = love.graphics.newImage(path)
      image:setFilter("nearest", "nearest")

      local quads = {}
      for frame = 0, record.frames - 1 do
        quads[frame] = love.graphics.newQuad(frame * 16, 0, 16, 16,
          image:getDimensions())
      end
      self.ow_images[id] = image
      self.ow_quads[id] = quads
    end
  end

  if not self.ow_images[id] then
    return nil
  end
  return self.ow_images[id], self.ow_quads[id]
end

--- Draw an overworld sprite at a pixel position, facing a direction.
-- @return true when it drew, false when the caller should fall back
function world:draw_ow_sprite(id, x, y, facing)
  local image, quads = self:ow_sprite(id)
  if not image then
    return false
  end

  local frame = FACING_FRAME[facing or "down"] or 0
  local quad = quads[frame] or quads[0]
  if not quad then
    return false
  end

  -- Sprites are 16 wide but stand on a 16-pixel cell, so they need no
  -- horizontal offset; the mirror for facing left flips about the centre.
  if facing == "left" then
    love.graphics.draw(image, quad, x + 16, y, 0, -1, 1)
  else
    love.graphics.draw(image, quad, x, y)
  end
  return true
end

--- Lazily load a tileset's tilesheet and build one quad per tile.
function world:tileset(index)
  if self.images[index] == nil then
    local path = ("%s/tilesets/%02d_tiles.png"):format(cache.dir(self.game), index)
    if not love.filesystem.getInfo(path) then
      self.images[index] = false
    else
      local image = love.graphics.newImage(path)
      image:setFilter("nearest", "nearest")

      local columns = math.floor(image:getWidth() / world.TILE_PIXELS)
      local rows = math.floor(image:getHeight() / world.TILE_PIXELS)
      local quads = {}
      for i = 0, columns * rows - 1 do
        quads[i] = love.graphics.newQuad(
          (i % columns) * world.TILE_PIXELS,
          math.floor(i / columns) * world.TILE_PIXELS,
          world.TILE_PIXELS, world.TILE_PIXELS,
          image:getDimensions()
        )
      end

      self.images[index] = image
      self.quads[index] = quads
      self.batches[index] = love.graphics.newSpriteBatch(image, 4096, "stream")
    end
  end
  return self.images[index] or nil
end

--- A species' front sprite, as written by the importer.
function world:species_sprite(species)
  self.species_images = self.species_images or {}
  if self.species_images[species] == nil then
    local path = ("%s/sprites/%03d_front.png"):format(cache.dir(self.game), species)
    if not love.filesystem.getInfo(path) then
      self.species_images[species] = false
    else
      local image = love.graphics.newImage(path)
      image:setFilter("nearest", "nearest")
      self.species_images[species] = image
    end
  end
  return self.species_images[species] or nil
end

function world:map(index)
  return self.maps[index]
end

function world:map_count()
  return #self.maps
end

--- Block id at a block coordinate, or nil outside the map.
function world:block_at(map, block_x, block_y)
  if block_x < 0 or block_x >= map.width or block_y < 0 or block_y >= map.height then
    return nil
  end
  return map.blocks[block_y * map.width + block_x + 1]
end

--- Collision value at a cell coordinate, or nil outside the map.
function world:collision_at(map, cell_x, cell_y)
  local block_x = math.floor(cell_x / world.CELLS_PER_BLOCK)
  local block_y = math.floor(cell_y / world.CELLS_PER_BLOCK)
  local block_id = self:block_at(map, block_x, block_y)
  if not block_id then
    return nil
  end

  local tileset = self.tilesets[map.tileset]
  local entry = tileset and tileset.collision[block_id + 1]
  if not entry then
    return nil
  end

  local quadrant = (cell_y % world.CELLS_PER_BLOCK) * world.CELLS_PER_BLOCK
    + (cell_x % world.CELLS_PER_BLOCK)
  return entry[quadrant + 1]
end

--- May the player stand on this cell?
function world:walkable(map, cell_x, cell_y)
  local value = self:collision_at(map, cell_x, cell_y)
  -- Off-map is blocked. Maps connect through explicit connection records rather
  -- than by walking off the edge into nothing.
  if not value then
    return false
  end
  return collision.walkable(value)
end

--- Which edge, if any, a cell lies beyond.
function world:edge_beyond(map, cell_x, cell_y)
  local width = map.width * world.CELLS_PER_BLOCK
  local height = map.height * world.CELLS_PER_BLOCK

  if cell_y < 0 then
    return "north"
  elseif cell_y >= height then
    return "south"
  elseif cell_x < 0 then
    return "west"
  elseif cell_x >= width then
    return "east"
  end
  return nil
end

--- The connection covering the edge this cell lies beyond, if there is one.
function world:connection_beyond(map, cell_x, cell_y)
  local edge = self:edge_beyond(map, cell_x, cell_y)
  if not edge then
    return nil
  end
  for _, connection in ipairs(map.connections or {}) do
    if connection.direction == edge then
      return connection, edge
    end
  end
  return nil
end

--- Where the player lands after crossing a connection.
--
-- The record's offset along the axis of travel is the arrival coordinate — a
-- west connection to a ten-block map gives 19, its rightmost cell — while the
-- perpendicular offset aligns the two maps and is added to where the player
-- was.
-- @return cell_x, cell_y on the destination map
function world.arrival(connection, cell_x, cell_y)
  if connection.direction == "north" or connection.direction == "south" then
    return cell_x + connection.x_offset, connection.y_offset
  end
  return connection.x_offset, cell_y + connection.y_offset
end

--- May the player move onto this cell?
--
-- Not the same as walkable. A door is a wall tile with a warp on it — 544 of
-- Crystal's 1300 warps sit on $07 — and the player enters it, triggering the
-- warp, rather than standing on it. So a warp overrides terrain.
function world:can_enter(map, cell_x, cell_y)
  if self:warp_at(map, cell_x, cell_y) then
    return true
  end

  -- Walking off an edge is allowed where a connection continues the world;
  -- the transfer happens once the step completes.
  if self:connection_beyond(map, cell_x, cell_y) then
    return true
  end

  return self:walkable(map, cell_x, cell_y)
end

--- Does this cell roll for a wild encounter when stepped on?
function world:is_grass(map, cell_x, cell_y)
  local value = self:collision_at(map, cell_x, cell_y)
  return value ~= nil and collision.is_grass(value)
end

--- What kind of terrain a cell is, for the engine to reason about.
function world:terrain(map, cell_x, cell_y)
  local value = self:collision_at(map, cell_x, cell_y)
  return value and collision.kind(value) or nil
end

--- The warp on this cell, if any.
function world:warp_at(map, cell_x, cell_y)
  for _, warp in ipairs(map.warps or {}) do
    if warp.x == cell_x and warp.y == cell_y then
      return warp
    end
  end
  return nil
end

--- Draw the visible part of a map.
--
-- Only the blocks overlapping the camera are queued, so cost tracks screen size
-- rather than map size. Everything goes through one SpriteBatch per tileset.
-- @param camera_x,camera_y top-left of the view, in pixels
function world:draw(map, camera_x, camera_y, view_width, view_height)
  local image = self:tileset(map.tileset)
  if not image then
    return
  end

  local batch = self.batches[map.tileset]
  local quads = self.quads[map.tileset]
  local tileset = self.tilesets[map.tileset]
  batch:clear()

  local first_block_x = math.max(0, math.floor(camera_x / world.BLOCK_PIXELS))
  local first_block_y = math.max(0, math.floor(camera_y / world.BLOCK_PIXELS))
  local last_block_x = math.min(map.width - 1,
    math.floor((camera_x + view_width) / world.BLOCK_PIXELS))
  local last_block_y = math.min(map.height - 1,
    math.floor((camera_y + view_height) / world.BLOCK_PIXELS))

  for block_y = first_block_y, last_block_y do
    for block_x = first_block_x, last_block_x do
      local block_id = self:block_at(map, block_x, block_y)
      local block = block_id and tileset.blocks[block_id + 1]
      if block then
        local origin_x = block_x * world.BLOCK_PIXELS - camera_x
        local origin_y = block_y * world.BLOCK_PIXELS - camera_y

        for i, tile_index in ipairs(block) do
          local quad = quads[tile_index]
          if quad then
            batch:add(quad,
              origin_x + ((i - 1) % world.TILES_PER_BLOCK_EDGE) * world.TILE_PIXELS,
              origin_y + math.floor((i - 1) / world.TILES_PER_BLOCK_EDGE) * world.TILE_PIXELS)
          end
        end
      end
    end
  end

  love.graphics.draw(batch)
end

return world
