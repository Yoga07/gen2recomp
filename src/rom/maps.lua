-- Overworld maps.
--
-- A map's description is split across two records. The nine-byte header names
-- the tileset, the environment and the music, and points at a twelve-byte
-- attributes record holding the dimensions, the block data, the script and
-- event pointers, and which edges connect to other maps.
--
--   header      0    bank of the attributes record
--               1    tileset id
--               2    environment
--               3-4  pointer to the attributes record
--               5    location / landmark
--               6    music
--               7    time-of-day palette flag
--               8    fishing group
--
--   attributes  0    border block, drawn outside the map's edges
--               1    height in blocks
--               2    width in blocks
--               3-5  far pointer to block data
--               6-8  far pointer to the script header
--               9-10 pointer to the event header, in the script bank
--               11   connection mask: north, south, west, east
--
-- Block data is width * height bytes, one block id per cell, row-major. Each
-- block expands through the tileset into 4x4 tiles, so a map cell is 32x32
-- pixels on screen.
--
-- The two records validate each other, which is what makes the tables findable
-- without hardcoded offsets: a header is only credible if its attributes record
-- has sane dimensions and a block pointer that resolves, and the whole thing is
-- confirmed by every block id landing inside the tileset the header names.

local maps = {}

maps.HEADER_SIZE = 9
maps.ATTRIBUTES_SIZE = 12

-- Only needs to reject nonsense rather than be tight; Crystal's largest maps
-- are comfortably inside this.
maps.MAX_DIMENSION = 64

-- A map cell is one block: 4x4 tiles of 8x8 pixels.
maps.BLOCK_PIXELS = 32

maps.environments = {
  [0] = "unknown_0", "town", "route", "indoor", "cave", "unknown_5",
  "gate", "dungeon",
}

maps.connection_bits = { north = 0x08, south = 0x04, west = 0x02, east = 0x01 }

local function far(rom, bank, addr)
  if addr < 0x4000 or addr > 0x7FFF then
    return nil
  end
  local flat = bank * 0x4000 + (addr - 0x4000)
  if flat < 0 or flat >= rom.size then
    return nil
  end
  return flat
end

--- Decode an attributes record, returning nil when it is not credible.
function maps.decode_attributes(rom, offset)
  if offset + maps.ATTRIBUTES_SIZE > rom.size then
    return nil
  end

  local height = rom:u8(offset + 1)
  local width = rom:u8(offset + 2)
  if height < 1 or height > maps.MAX_DIMENSION then
    return nil
  end
  if width < 1 or width > maps.MAX_DIMENSION then
    return nil
  end

  local block_data = far(rom, rom:u8(offset + 3), rom:u16le(offset + 4))
  if not block_data or block_data + width * height > rom.size then
    return nil
  end

  local script_bank = rom:u8(offset + 6)
  local scripts = far(rom, script_bank, rom:u16le(offset + 7))
  if not scripts then
    return nil
  end

  -- The event header lives in the same bank as the script header.
  local events = far(rom, script_bank, rom:u16le(offset + 9))
  if not events then
    return nil
  end

  local connections = rom:u8(offset + 11)
  if connections > 0x0F then
    return nil
  end

  return {
    offset = offset,
    border_block = rom:u8(offset),
    height = height,
    width = width,
    block_data = block_data,
    scripts = scripts,
    events = events,
    connections = connections,
  }
end

--- Decode a map header, returning nil when it is not credible.
-- @param tileset_count upper bound on valid tileset ids
function maps.decode_header(rom, offset, tileset_count)
  if offset + maps.HEADER_SIZE > rom.size then
    return nil
  end

  local tileset = rom:u8(offset + 1)
  if tileset < 1 or tileset > tileset_count then
    return nil
  end

  local environment = rom:u8(offset + 2)
  if environment > 8 then
    return nil
  end

  local attributes_at = far(rom, rom:u8(offset), rom:u16le(offset + 3))
  if not attributes_at then
    return nil
  end

  local attributes = maps.decode_attributes(rom, attributes_at)
  if not attributes then
    return nil
  end

  return {
    offset = offset,
    tileset = tileset,
    environment = environment,
    environment_name = maps.environments[environment],
    attributes_at = attributes_at,
    attributes = attributes,
    location = rom:u8(offset + 5),
    music = rom:u8(offset + 6),
    palette_flag = rom:u8(offset + 7),
    fishing_group = rom:u8(offset + 8),
  }
end

--- Locate the map headers.
--
-- Headers sit contiguously within a map group, so they show up as runs. Groups
-- are not necessarily adjacent and a header that fails validation breaks a run,
-- so the result is the union of every run long enough to be real rather than
-- one continuous table.
--
-- @return { headers = {...}, runs = {...} } or nil plus a reason
function maps.locate(rom, tileset_count)
  local runs = {}
  local headers = {}

  local offset = 0
  while offset <= rom.size - maps.HEADER_SIZE do
    if maps.decode_header(rom, offset, tileset_count) then
      local start = offset
      local count = 0
      while offset <= rom.size - maps.HEADER_SIZE do
        local header = maps.decode_header(rom, offset, tileset_count)
        if not header then
          break
        end
        count = count + 1
        offset = offset + maps.HEADER_SIZE
      end

      -- Four in a row is already far beyond chance given each one requires a
      -- second record to validate as well.
      if count >= 4 then
        runs[#runs + 1] = { offset = start, count = count }
        for i = 0, count - 1 do
          headers[#headers + 1] =
            maps.decode_header(rom, start + i * maps.HEADER_SIZE, tileset_count)
        end
      end
    else
      offset = offset + 1
    end
  end

  if #headers == 0 then
    return nil, "no runs of consecutive map headers found"
  end

  table.sort(headers, function(a, b) return a.offset < b.offset end)
  return { headers = headers, runs = runs }
end

--- Read a map's block data as a row-major grid of block ids.
function maps.decode_block_data(rom, header)
  local attributes = header.attributes
  local grid = {}
  for row = 0, attributes.height - 1 do
    local line = {}
    for column = 0, attributes.width - 1 do
      line[column + 1] = rom:u8(attributes.block_data + row * attributes.width + column)
    end
    grid[row + 1] = line
  end
  return grid
end

--- Which edges connect to another map.
function maps.connection_list(attributes)
  local result = {}
  for name, bit in pairs(maps.connection_bits) do
    if attributes.connections % (bit * 2) >= bit then
      result[#result + 1] = name
    end
  end
  table.sort(result)
  return result
end

--- Render a map to an ImageData by expanding every block through the tileset.
-- @param tiles  decoded tile graphics for the map's tileset
-- @param blocks decoded block table for the map's tileset
function maps.render(rom, header, tiles, blocks, palette)
  local gfx = require("src.rom.gfx")
  palette = palette or gfx.GREYSCALE

  local attributes = header.attributes
  local grid = maps.decode_block_data(rom, header)

  local image = love.image.newImageData(
    attributes.width * maps.BLOCK_PIXELS,
    attributes.height * maps.BLOCK_PIXELS
  )

  for row = 1, attributes.height do
    for column = 1, attributes.width do
      local block = blocks[grid[row][column] + 1]
      local origin_x = (column - 1) * maps.BLOCK_PIXELS
      local origin_y = (row - 1) * maps.BLOCK_PIXELS

      if block then
        for i, tile_index in ipairs(block) do
          local tile = tiles[tile_index + 1]
          local tile_x = origin_x + ((i - 1) % 4) * gfx.TILE_WIDTH
          local tile_y = origin_y + math.floor((i - 1) / 4) * gfx.TILE_HEIGHT
          if tile then
            for p = 1, 64 do
              local color = palette[tile[p] + 1]
              image:setPixel(
                tile_x + (p - 1) % 8,
                tile_y + math.floor((p - 1) / 8),
                color[1], color[2], color[3], 1
              )
            end
          end
        end
      end
    end
  end

  return image
end

return maps
