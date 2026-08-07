-- The text font.
--
-- Stored as 1bpp: one byte per row, one bit per pixel, no second bitplane.
-- Reading it as 2bpp is the trap — it pairs each glyph with its neighbour, one
-- into each bitplane, and produces an alphabet that is almost right. That looks
-- like a palette problem and is a format problem.
--
-- Glyphs sit in charmap order offset by a constant: a character's tile is its
-- code minus $40, so 'A' at $80 is tile 64 and the space at $7F is tile 63,
-- which is blank. The constant was measured rather than counted off a render —
-- eyeballing a 128-pixel-wide sheet gave $60 and was wrong by two rows.

local gfx = require("src.rom.gfx")

local font = {}

font.TILE_BYTES = gfx.BYTES_PER_TILE_1BPP
font.GLYPH_COUNT = 256

-- Subtract this from a character code to get its tile index.
font.CHAR_BIAS = 0x40

-- Codes whose glyphs must exist for a candidate to be the font.
font.UPPERCASE = { first = 0x80, last = 0x99 }
font.LOWERCASE = { first = 0xA0, last = 0xB9 }
font.DIGITS = { first = 0xF6, last = 0xFF }
font.SPACE = 0x7F

--- Tile index for a character code.
function font.tile_for(code)
  return code - font.CHAR_BIAS
end

local function ink_of(data, offset)
  local tile = gfx.decode_tile_1bpp(data, offset)
  if not tile then
    return nil
  end
  local set = 0
  for i = 1, 64 do
    if tile[i] ~= 0 then
      set = set + 1
    end
  end
  return set / 64
end

--- Mean horizontal agreement between neighbouring pixels across a run of
-- glyphs. Letterforms are blocky and score high; arbitrary bytes score around
-- the half mark for 1bpp. This is the same measure that separated uncompressed
-- graphics from compressed data when the overworld sprites were found.
local function coherence(data, offset, count)
  local agreements, comparisons = 0, 0
  for index = 0, count - 1 do
    local tile = gfx.decode_tile_1bpp(data, offset + index * font.TILE_BYTES)
    if not tile then
      return 0
    end
    for row = 0, 7 do
      for column = 1, 7 do
        local i = row * 8 + column
        comparisons = comparisons + 1
        if tile[i] == tile[i + 1] then
          agreements = agreements + 1
        end
      end
    end
  end
  return comparisons > 0 and agreements / comparisons or 0
end

-- Letterforms are thin strokes, so their horizontal agreement is lower than a
-- filled graphic's. Set from measurement rather than intuition: too high a bar
-- rejects the real font outright.
font.MIN_COHERENCE = 0.62

--- Is `offset` the start of the font?
--
-- Checked by ink density rather than by matching glyph shapes, which we have no
-- reference for. Every letter and digit must carry a plausible amount of ink,
-- and the space must carry none — sixty-odd constraints that together are quite
-- specific, since arbitrary data does not produce a blank byte exactly where a
-- space belongs and marks everywhere a letter belongs.
-- Two levels. The basic checks confirm a glyph layout is present: space blank,
-- every letter and digit carrying a believable amount of ink. The strict extras
-- exist only to discriminate between candidates during a blind search, and are
-- not applied when verifying a known offset — they are tuned heuristics, and
-- holding the real font to them is what rejected it.
local function looks_like_font(data, offset, strict)
  local function glyph_ink(code)
    return ink_of(data, offset + font.tile_for(code) * font.TILE_BYTES)
  end

  local space = glyph_ink(font.SPACE)
  if space == nil or space > 0 then
    return false
  end

  for _, range in ipairs { font.UPPERCASE, font.LOWERCASE, font.DIGITS } do
    for code = range.first, range.last do
      local density = glyph_ink(code)
      -- A letter is neither empty nor a solid block.
      if density == nil or density < 0.05 or density > 0.7 then
        return false
      end
    end
  end

  if not strict then
    return true
  end

  -- Ink density alone is far too weak: 28 offsets satisfy it. Coherence alone
  -- is not enough either — adding it left exactly one match, and it was the
  -- wrong one, in bank $5C rather than the font's bank.
  local first = offset + font.tile_for(font.UPPERCASE.first) * font.TILE_BYTES
  local letters = font.UPPERCASE.last - font.UPPERCASE.first + 1
  if coherence(data, first, letters) < font.MIN_COHERENCE then
    return false
  end

  -- Letterform relations. These are properties of an alphabet rather than of
  -- art in general: 'I' is a bar and carries far less ink than the dense
  -- letters, and a full stop is barely a mark at all. Arbitrary graphics that
  -- happen to be the right darkness and coherence do not also order themselves
  -- this way.
  local narrow = glyph_ink(0x88) -- I
  if not narrow then
    return false
  end

  for _, dense_code in ipairs { 0x8C, 0x96, 0x81, 0x83 } do -- M, W, B, D
    local dense = glyph_ink(dense_code)
    if not dense or narrow >= dense then
      return false
    end
  end

  return true
end

-- The one hardcoded offset in this project, and it is deliberate.
--
-- Every other table is found by search, because a wrong hardcoded offset yields
-- plausible garbage instead of an error. The font resisted that. Ink density
-- alone matches 28 offsets; adding coherence left exactly one, in bank $5C, and
-- it was wrong; adding letterform relations left three, none of them the font.
-- The difficulty is that a font has no self-validating structure — no length
-- field, no pointer that must resolve, no second record to agree with. It is
-- just pixels, and plenty of other pixels look similar by every cheap measure.
--
-- So the offset is asserted and then verified. If the glyph checks fail here,
-- the search still runs, so a cartridge this constant does not suit reports the
-- problem rather than rendering nonsense.
--
-- Established by rendering a string whose appearance is known — "ROUTE 38",
-- taken from a signpost the script decoder had already read — at every
-- plausible bias and seeing which came out legible.
font.KNOWN_OFFSETS = {
  crystal = 0x0F8000,
}

--- Locate the font.
-- @param game the identified game id, used to pick a known offset
-- @return { offset = n, verified = bool } or nil plus a reason
function font.locate(rom, game)
  local known = game and font.KNOWN_OFFSETS[game]
  if known and known + font.GLYPH_COUNT * font.TILE_BYTES <= rom.size then
    if looks_like_font(rom.data, known, false) then
      return { offset = known, verified = true, source = "known offset" }
    end
  end

  return font.search(rom)
end

--- Search for the font without an anchor. Kept because it is what would find
-- the font in a cartridge the known offsets do not cover, and because it is
-- what says loudly when that happens.
function font.search(rom)
  local matches = {}
  local highest = font.tile_for(font.DIGITS.last) * font.TILE_BYTES

  for offset = 0, rom.size - highest - font.TILE_BYTES, font.TILE_BYTES do
    if looks_like_font(rom.data, offset, true) then
      matches[#matches + 1] = offset
    end
  end

  if #matches == 0 then
    return nil, "no offset satisfies the glyph layout"
  end

  -- More than one means the test is too weak to trust, not that we should pick.
  if #matches > 1 then
    local list = {}
    for i = 1, math.min(#matches, 6) do
      list[i] = ("0x%06X"):format(matches[i])
    end
    return nil, ("%d offsets satisfy the glyph layout (%s); refusing to guess")
      :format(#matches, table.concat(list, " "))
  end

  return { offset = matches[1], verified = false, source = "search" }
end

--- Decode the whole font as tiles.
function font.decode(rom, located)
  return gfx.decode_tiles_1bpp(rom.data, located.offset, font.GLYPH_COUNT)
end

--- Render the font as a sheet, 16 glyphs across, with the background
-- transparent so text can be drawn over anything.
function font.to_image_data(tiles)
  local columns = 16
  local rows = math.ceil(#tiles / columns)
  local image = love.image.newImageData(columns * 8, rows * 8)

  for index, tile in ipairs(tiles) do
    local origin_x = ((index - 1) % columns) * 8
    local origin_y = math.floor((index - 1) / columns) * 8
    for p = 1, 64 do
      local set = tile[p] ~= 0
      image:setPixel(
        origin_x + (p - 1) % 8,
        origin_y + math.floor((p - 1) / 8),
        0, 0, 0, set and 1 or 0
      )
    end
  end

  return image
end

return font
