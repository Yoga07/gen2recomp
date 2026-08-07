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

-- Buildings, cliffs and ledges all carry this value, confirmed by tinting it
-- across whole maps and seeing it land exactly on solid geometry.
--
-- PROVISIONAL. Treating everything else as walkable is too permissive: doors,
-- water and rock faces are distinct values that are not all passable, and the
-- occupancy survey found 466 NPCs apparently standing on $07, which contradicts
-- it being a wall and is not yet explained. Good enough to walk around with,
-- not yet correct. See docs/architecture.md.
world.WALL_COLLISION = 0x07

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
    images = {},   -- tileset index -> Image
    quads = {},    -- tileset index -> array of Quads, one per tile
    batches = {},  -- tileset index -> SpriteBatch
  }, world)
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
  return value ~= world.WALL_COLLISION
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
