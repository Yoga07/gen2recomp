-- Drawing text with the cartridge's own font.
--
-- The importer writes the font as a 16-glyph-wide sheet of 8x8 tiles with the
-- background transparent. A character's tile is its code minus $40, so drawing
-- a line is a quad lookup per character and nothing more.
--
-- Lines arrive as arrays of character codes rather than strings, because the
-- rendered glyphs include multi-byte ones — "é", "♀", "PK" — that cannot be
-- indexed back to a tile once concatenated.

local cache = require("src.import.cache")
local font_rom = require("src.rom.font")

local bitmap_font = {}
bitmap_font.__index = bitmap_font

bitmap_font.GLYPH = 8
bitmap_font.COLUMNS = 16

--- Load a game's font from the cache.
-- @return instance, or nil when the import did not produce one
function bitmap_font.load(game)
  local path = ("%s/font.png"):format(cache.dir(game))
  if not love.filesystem.getInfo(path) then
    return nil, "no font in the cache"
  end

  local image = love.graphics.newImage(path)
  image:setFilter("nearest", "nearest")

  local columns = math.floor(image:getWidth() / bitmap_font.GLYPH)
  local rows = math.floor(image:getHeight() / bitmap_font.GLYPH)
  local quads = {}
  for index = 0, columns * rows - 1 do
    quads[index] = love.graphics.newQuad(
      (index % columns) * bitmap_font.GLYPH,
      math.floor(index / columns) * bitmap_font.GLYPH,
      bitmap_font.GLYPH, bitmap_font.GLYPH,
      image:getDimensions())
  end

  return setmetatable({
    image = image,
    quads = quads,
    batch = love.graphics.newSpriteBatch(image, 256, "stream"),
  }, bitmap_font)
end

--- Draw a line of character codes.
function bitmap_font:draw_codes(codes, x, y)
  self.batch:clear()
  for i, code in ipairs(codes) do
    local quad = self.quads[code - font_rom.CHAR_BIAS]
    if quad then
      self.batch:add(quad, x + (i - 1) * bitmap_font.GLYPH, y)
    end
  end
  love.graphics.draw(self.batch)
end

function bitmap_font:height()
  return bitmap_font.GLYPH
end

return bitmap_font
