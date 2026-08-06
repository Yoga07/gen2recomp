-- The Gen 2 text encoding.
--
-- Game Freak used a custom character set rather than ASCII: letters start at
-- $80, lower case at $A0, digits at $F6, and a scatter of single-byte glyphs
-- cover the punctuation and the contractions English needed to fit in one tile
-- ("'d", "'ll", and friends). $50 terminates a string and $7F is a space.
--
-- Only the English tables are here. The European releases reassign parts of the
-- high range for accented characters, so a non-English dump will decode names
-- with the wrong glyphs until a matching table is added.

local text = {}

text.TERMINATOR = 0x50

local charmap = {}

local function assign_range(first, last, characters)
  local index = 1
  for code = first, last do
    charmap[code] = characters:sub(index, index)
    index = index + 1
  end
end

assign_range(0x80, 0x99, "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
assign_range(0xA0, 0xB9, "abcdefghijklmnopqrstuvwxyz")
assign_range(0xF6, 0xFF, "0123456789")

charmap[0x7F] = " "
charmap[0x9A] = "("
charmap[0x9B] = ")"
charmap[0x9C] = ":"
charmap[0x9D] = ";"
charmap[0x9E] = "["
charmap[0x9F] = "]"
charmap[0xBA] = "é"
charmap[0xBB] = "'d"
charmap[0xBC] = "'l"
charmap[0xBD] = "'s"
charmap[0xBE] = "'t"
charmap[0xBF] = "'v"
charmap[0xE0] = "'"
charmap[0xE1] = "PK"
charmap[0xE2] = "MN"
charmap[0xE3] = "-"
charmap[0xE4] = "'r"
charmap[0xE5] = "'m"
charmap[0xE6] = "?"
charmap[0xE7] = "!"
charmap[0xE8] = "."
-- The gender symbols sit just below the digit block. Nidoran's two forms are
-- distinguished only by these, so a charmap missing them fails on species 29.
charmap[0xEF] = "♂"
charmap[0xF0] = "¥"
charmap[0xF1] = "×"
charmap[0xF3] = "/"
charmap[0xF4] = ","
charmap[0xF5] = "♀"

text.charmap = charmap

--- Decode a fixed-width name field, stopping at the terminator.
-- Species and move names are stored padded to a fixed length rather than
-- packed, so the caller passes the field width and we trim.
function text.decode(data, offset, length)
  local out = {}
  for i = 0, length - 1 do
    local code = string.byte(data, offset + i + 1)
    if not code or code == text.TERMINATOR then
      break
    end
    -- Unmapped bytes are shown as an escape so a wrong offset is obvious in the
    -- output instead of silently producing plausible-looking mojibake.
    out[#out + 1] = charmap[code] or ("<%02X>"):format(code)
  end
  return table.concat(out)
end

--- Decode a terminator-delimited string.
--
-- Not every name table is fixed width. Species names are padded to ten bytes,
-- but move names are packed back to back with only the terminator between them,
-- so reading them needs the length back as well as the text.
-- @return decoded string, bytes consumed including the terminator, or nil when
--         no terminator appears within `max_length`.
function text.decode_terminated(data, offset, max_length)
  max_length = max_length or 32
  local out = {}
  for i = 0, max_length - 1 do
    local code = string.byte(data, offset + i + 1)
    if not code then
      return nil
    end
    if code == text.TERMINATOR then
      return table.concat(out), i + 1
    end
    out[#out + 1] = charmap[code] or ("<%02X>"):format(code)
  end
  return nil
end

--- True when a terminated string is made entirely of mapped glyphs.
-- @return ok, bytes consumed
function text.is_plausible_terminated(data, offset, max_length)
  max_length = max_length or 32
  local letters = 0
  for i = 0, max_length - 1 do
    local code = string.byte(data, offset + i + 1)
    if not code then
      return false
    end
    if code == text.TERMINATOR then
      return letters > 0, i + 1
    end
    if not charmap[code] then
      return false
    end
    letters = letters + 1
  end
  return false
end

--- True when every byte in a fixed-width field is either a mapped glyph or the
-- terminator. Used by the table locator to score candidate offsets.
function text.is_plausible_name(data, offset, length)
  local seen_terminator = false
  local letters = 0
  for i = 0, length - 1 do
    local code = string.byte(data, offset + i + 1)
    if not code then
      return false
    end
    if code == text.TERMINATOR then
      seen_terminator = true
    elseif seen_terminator then
      -- Padding after the terminator is allowed, but it must stay padding.
      if code ~= text.TERMINATOR then
        return false
      end
    elseif not charmap[code] then
      return false
    else
      letters = letters + 1
    end
  end
  return letters > 0
end

return text
