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
-- $BA to $BF were mapped to the accent and the English contractions, copied
-- from Gen 1. In Crystal those font tiles are blank, so whatever they are they
-- are not glyphs that draw. Left mapped so text containing them still decodes
-- rather than being rejected wholesale, but they are not to be trusted.
--
-- The contractions really live at $D0 to $D6, found later and confirmed in
-- context; the accent is at $EA. Nothing needs these six.
charmap[0xBA] = "<BA>"
charmap[0xBB] = "'d"
charmap[0xBC] = "'l"
charmap[0xBD] = "'s"
charmap[0xBE] = "'t"
charmap[0xBF] = "'v"
-- The English contractions, each one glyph in the font. These were mapped at
-- $BA to $BF for a long time, copied from Gen 1, where those tiles are blank in
-- Crystal. They are really here, in alphabetical order, and finding them fixed
-- a third of the game's dialogue: 784 text blocks stopped decoding at one of
-- these bytes.
--
-- Read straight off the cartridge rather than assumed. "That<D4> a NUGGET"
-- gives 's, "didn<D5>" gives 't, "they<D3>e" gives 're, "I<D6>e got" gives 've.
charmap[0xD0] = "'d"
charmap[0xD1] = "'l"
charmap[0xD2] = "'m"
charmap[0xD3] = "'r"
charmap[0xD4] = "'s"
charmap[0xD5] = "'t"
charmap[0xD6] = "'v"
charmap[0xE0] = "'"
charmap[0xE1] = "PK"
charmap[0xE2] = "MN"
charmap[0xE3] = "-"
charmap[0xE4] = "'r"
charmap[0xE5] = "'m"
charmap[0xE6] = "?"
charmap[0xE7] = "!"
charmap[0xE8] = "."
-- "&" continues the punctuation run after ? ! and the full stop, and its
-- absence stopped a class walk dead: the twins are stored as "AMY & MAY", so
-- one missing glyph truncated every trainer after them in that class.
charmap[0xE9] = "&"
-- The accent lives here, not at $BA. Both were candidates; the font settles it,
-- since tile $EA - $40 carries ink and tile $BA - $40 is blank.
charmap[0xEA] = "é"
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

-- Dialogue is itself a small bytecode rather than a bare string. $00 opens a
-- block, the terminators close it, and the rest control how the text box
-- behaves: where lines break, when the box clears, when it waits for the
-- player. Rendering these as plain newlines loses the distinction between a
-- line break and a new box, so they are kept as structure.
text.START = 0x00
text.LINE = 0x4F      -- continue on the next line
text.PARAGRAPH = 0x51 -- clear the box and carry on
text.CONTINUE = 0x55  -- scroll and carry on
text.DONE = 0x57      -- end of the block
text.PROMPT = 0x58    -- wait for the player, then end

-- Codes the text engine replaces with something at display time: names the
-- player chose, and a few words that are one glyph in the font or too long to
-- store repeatedly. They sit in the same range as the layout controls, so a
-- decoder that does not know them rejects any line containing one — which is
-- most of the interesting dialogue in the game.
text.substitutions = {
  [0x4A] = "PKMN",
  [0x52] = "<PLAYER>",
  [0x53] = "<RIVAL>",
  [0x54] = "POKé",
  [0x56] = "……",
  [0x59] = "<TARGET>",
  [0x5A] = "<USER>",
  [0x5B] = "PC",
  [0x5C] = "TM",
  [0x5D] = "TRAINER",
  [0x5E] = "ROCKET",
}

-- Codes that draw nothing and take no operand.
--
-- $75 is the one that mattered: 377 text blocks stopped dead on it. It is not a
-- glyph. Its font tile is a solid block four rows deep rather than a letter,
-- it turns up at 172 different positions rather than in one fixed spot, and
-- every block containing it reads as correct English once it is passed over.
-- What it actually instructs the text engine to do is not known here, so it is
-- named for what it does on screen, which is nothing.
text.silent = {
  [0x75] = true,
}

-- Codes that print a string the game holds elsewhere, with the length of the
-- operand that follows.
--
-- $01 gives itself away: the bytes after it read $D099, which is Game Boy work
-- RAM, so it prints a name out of a buffer. $14 takes no operand and sits
-- exactly where a name belongs -- "Hello, <14>!" -- so it names a buffer of its
-- own. Neither is resolved to a real name yet; the save file would have to say.
text.ram_strings = {
  [0x01] = 2,
  [0x14] = 0,
}

text.controls = {
  [text.START] = "start",
  [text.LINE] = "line",
  [text.PARAGRAPH] = "paragraph",
  [text.CONTINUE] = "continue",
  [text.DONE] = "done",
  [text.PROMPT] = "prompt",
  [text.TERMINATOR] = "done",
}

--- Decode a dialogue block into pages of lines.
--
-- A page is what fits in the text box at once; a paragraph control starts a new
-- one. Returns nil when the bytes at `offset` are not dialogue, which is how
-- callers tell a real text pointer from a coincidence.
-- @return { pages = { { line, ... }, ... }, bytes = n, prompted = bool }
function text.decode_dialogue(data, offset, max_bytes)
  max_bytes = max_bytes or 2048

  local pages, lines, current, current_codes = {}, {}, {}, {}
  local letters = 0
  local prompted = false

  -- Each line keeps both the rendered string and the raw character codes. The
  -- string is for logs and tests; the codes are what a bitmap font needs, since
  -- glyphs like "é" and "♀" are multi-byte once rendered and cannot be indexed
  -- back to a tile.
  local function end_line()
    lines[#lines + 1] = { text = table.concat(current), codes = current_codes }
    current, current_codes = {}, {}
  end

  local function end_page()
    end_line()
    pages[#pages + 1] = lines
    lines = {}
  end

  -- Operand bytes belonging to a preceding command are stepped over rather
  -- than read as characters.
  local skip = 0

  for i = 0, max_bytes - 1 do
    local at = offset + i + 1
    local code = string.byte(data, at)
    if not code then
      return nil
    end

    if skip > 0 then
      skip = skip - 1
      goto continue
    end

    if text.silent[code] then
      goto continue
    end

    if text.ram_strings[code] then
      skip = text.ram_strings[code]
      -- Drawn as a placeholder, the same way the player's name is. The codes
      -- have to be spelled out too, because the bitmap font draws codes and a
      -- placeholder has no glyph of its own.
      current[#current + 1] = "<NAME>"
      for letter = 1, 4 do
        current_codes[#current_codes + 1] = 0x80 + ("NAME"):byte(letter) - 65
      end
      letters = letters + 1
      goto continue
    end

    local control = text.controls[code]
    if control == "start" then
      -- Only meaningful as the first byte; elsewhere it is not dialogue.
      if i > 0 then
        return nil
      end
    elseif control == "line" then
      end_line()
    elseif control == "continue" then
      end_line()
    elseif control == "paragraph" then
      end_page()
    elseif control == "done" or control == "prompt" then
      prompted = control == "prompt"
      end_page()
      -- A block with no readable characters is not dialogue.
      if letters == 0 then
        return nil
      end
      return { pages = pages, bytes = i + 1, prompted = prompted }
    else
      local glyph = charmap[code] or text.substitutions[code]
      if not glyph then
        return nil
      end
      current[#current + 1] = glyph
      -- Substitutions have no single glyph to draw, so their codes are spelled
      -- out as the characters of the placeholder. The engine draws what it is
      -- given; resolving these to real names is the save file's job.
      if charmap[code] then
        current_codes[#current_codes + 1] = code
      else
        local i = 1
        while i <= #glyph do
          -- "é" is two bytes in UTF-8 and is a glyph in its own right. Walking
          -- this a byte at a time and keeping only A to Z dropped it, so
          -- "POKéMON" reached the font as "POKMON".
          if glyph:byte(i) == 0xC3 and glyph:byte(i + 1) == 0xA9 then
            current_codes[#current_codes + 1] = 0xEA
            i = i + 2
          else
            local letter = glyph:sub(i, i):upper()
            local byte_value = letter:byte()
            if letter >= "A" and letter <= "Z" then
              current_codes[#current_codes + 1] = 0x80 + byte_value - 65
            elseif letter == " " then
              current_codes[#current_codes + 1] = 0x7F
            end
            i = i + 1
          end
        end
      end
      letters = letters + 1
    end

    ::continue::
  end

  return nil
end

--- Flatten a decoded block to a single string, for logging and tests.
function text.flatten(block, separator)
  separator = separator or " / "
  local parts = {}
  for _, page in ipairs(block.pages) do
    for _, line in ipairs(page) do
      if line.text ~= "" then
        parts[#parts + 1] = line.text
      end
    end
  end
  return table.concat(parts, separator)
end

--- Decode a terminator-delimited string.
--
-- Not every name table is fixed width. Species names are padded to ten bytes,
-- but move names are packed back to back with only the terminator between them,
-- so reading them needs the length back as well as the text.
-- @return decoded string, bytes consumed including the terminator, or nil when
--         no terminator appears within `max_length`.
-- @param substitutions when true, the codes the text engine expands are
--        resolved as well. Item names need this: item 5 is stored as $54 then
--        " BALL", the $54 being the single glyph that reads POKe.
function text.decode_terminated(data, offset, max_length, substitutions)
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
    out[#out + 1] = charmap[code]
      or (substitutions and text.substitutions[code])
      or ("<%02X>"):format(code)
  end
  return nil
end

--- True when a terminated string is made entirely of mapped glyphs.
-- @return ok, bytes consumed
function text.is_plausible_terminated(data, offset, max_length, substitutions)
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
    if not charmap[code]
      and not (substitutions and text.substitutions[code]) then
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
