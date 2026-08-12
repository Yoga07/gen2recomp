-- The Pokédex entries: what the dex says about a species beyond its numbers.
--
-- Each entry is a classification, a height, a weight and two pages of text:
--
--   SEED@  CC 00  96 00  While it is young,<4E>it uses the<4E>nutrients that are@
--                        stored in the<4E>seeds on its back<4E>in order to grow.@
--
-- $CC is 204, which reads as 2'04"; $96 is 150, which reads as 15.0lb. Both are
-- Bulbasaur's, and neither took any part in finding the table.
--
-- Two things about the encoding differ from dialogue and cost the first attempt
-- everything: the line break inside an entry is **$4E**, not the $4F a text box
-- uses, and **$50 is a page break as well as the terminator**, so a record ends
-- on the second one rather than the first. A decoder written for dialogue finds
-- nothing at all here, which is at least honest.
--
-- ## How the table is found
--
-- There is no first record to encode as a signature the way BULBASAUR anchors
-- the species names, because a classification is just a word. So the search is
-- on shape, and the shape's one sharp constraint is arithmetic rather than
-- textual: **a height in feet and inches cannot carry twelve inches**. Scanning
-- the whole cartridge for the shape finds exactly 251 records -- the species
-- count, arrived at from the other end -- in four runs of 64, 64, 64 and 59.
-- That split is itself a confirmation: it is the cartridge banking its dex text
-- by species range, and nothing in this search knew about banks.
--
-- What a wrong answer would have scored is measurable here. Dropping the
-- feet-and-inches check finds 288 records rather than 251, so the constraint is
-- doing real work and the count lands exactly where it should with it in place.
-- Requiring one page instead of two puts *none* of the records back to back;
-- requiring three finds only 125. Two pages puts 247 of 251 adjacent, and the
-- four breaks are the four bank runs.
--
-- The order comes from a pointer table, found the way the marts were: a run of
-- near pointers that lands on the records and on nothing else. The longest such
-- run is 251 long and the next longest in the cartridge is **6**, which is not
-- a margin noise produces. A near pointer carries no bank, so 13 of the 251 name
-- an address that two banks both have a record at; those are resolved by
-- requiring the entries to climb, and the resolution is only accepted when it is
-- the unique one. The two structures agree completely: address order reproduces
-- pointer order at every one of the 238 pointers that were unambiguous anyway.

local text = require("src.rom.text")

local dex = {}

dex.SPECIES_COUNT = 251

-- $50 ends a page; the second one ends the record.
dex.TERMINATOR = 0x50
-- Dex text breaks lines with $4E. Dialogue uses $4F, and mixing them up is what
-- made the first search return nothing.
dex.NEXT_LINE = 0x4E
dex.PAGES = 2

-- A classification is a word or two; the longest in Crystal is "CLEAR WING".
dex.CLASS_MIN = 3
dex.CLASS_MAX = 16

-- Ceilings, not measurements. Steelix is 30'02" and Snorlax 1014.0lb, so these
-- are loose enough to be structural rather than a fit to Crystal's contents.
dex.HEIGHT_MAX = 4000
dex.WEIGHT_MAX = 30000

--------------------------------------------------------------------------------
-- Reading one record
--------------------------------------------------------------------------------

--- The classification: uppercase letters and spaces, ending at the terminator.
-- @return the word, and the offset of its terminator
function dex.read_class(data, offset)
  local out = {}
  for i = 0, dex.CLASS_MAX do
    local code = string.byte(data, offset + i + 1)
    if not code then
      return nil
    end
    if code == dex.TERMINATOR then
      if #out < dex.CLASS_MIN then
        return nil
      end
      return table.concat(out), offset + i
    end
    if code >= 0x80 and code <= 0x99 then
      out[#out + 1] = text.charmap[code]
    elseif code == 0x7F and #out > 0 then
      -- A space, but not a leading one: " SEED" is not a classification.
      out[#out + 1] = " "
    else
      return nil
    end
  end
  return nil
end

--- One page of description, as lines.
--
-- Lines carry their character codes as well as their text, the same way decoded
-- dialogue does, because the bitmap font draws codes: "é" and the POKé glyph
-- cannot be indexed back to a tile once they have been concatenated into a
-- string.
-- @return { { text = ..., codes = { ... } }, ... }, bytes consumed
function dex.read_page(data, offset, minimum)
  local lines, current, codes, letters = {}, {}, {}, 0

  local function end_line()
    lines[#lines + 1] = { text = table.concat(current), codes = codes }
    current, codes = {}, {}
  end

  for i = 0, 255 do
    local code = string.byte(data, offset + i + 1)
    if not code then
      return nil
    end
    if code == dex.TERMINATOR then
      if letters < (minimum or 1) then
        return nil
      end
      end_line()
      return lines, i + 1
    elseif code == dex.NEXT_LINE then
      end_line()
    else
      local glyph = text.charmap[code] or text.substitutions[code]
      if not glyph then
        return nil
      end
      current[#current + 1] = glyph
      for _, drawn in ipairs(text.glyph_codes(code)) do
        codes[#codes + 1] = drawn
      end
      letters = letters + 1
    end
  end
  return nil
end

--- Read a whole entry at a flat offset, or nil when the bytes are not one.
function dex.read_entry(data, offset)
  local class, terminator = dex.read_class(data, offset)
  if not class then
    return nil
  end

  local lo_h = string.byte(data, terminator + 2)
  local hi_h = string.byte(data, terminator + 3)
  local lo_w = string.byte(data, terminator + 4)
  local hi_w = string.byte(data, terminator + 5)
  if not hi_w then
    return nil
  end

  local height = lo_h + hi_h * 256
  local weight = lo_w + hi_w * 256

  -- The one constraint on these four bytes that is arithmetic rather than
  -- "looks like data": feet and inches, and there is no twelfth inch. Without
  -- it the same scan finds 288 records instead of 251.
  if height == 0 or height >= dex.HEIGHT_MAX or height % 100 >= 12 then
    return nil
  end
  if weight == 0 or weight >= dex.WEIGHT_MAX then
    return nil
  end

  local cursor = terminator + 5
  local pages = {}
  for index = 1, dex.PAGES do
    -- The first page always says something; the second is allowed to be short.
    local lines, consumed = dex.read_page(data, cursor, index == 1 and 12 or 1)
    if not lines then
      return nil
    end
    pages[index] = lines
    cursor = cursor + consumed
  end

  return {
    offset = offset,
    finish = cursor,
    class = class,
    height = height,
    weight = weight,
    pages = pages,
  }
end

--- Every entry-shaped record in the cartridge, in address order.
function dex.scan(rom)
  local data = rom.data
  local found, offset = {}, 0
  local limit = #data - 16
  while offset < limit do
    -- Cheap rejection first: an entry opens on an uppercase letter, so most
    -- offsets never reach the rest of the test.
    local first = string.byte(data, offset + 1)
    if first and first >= 0x80 and first <= 0x99 then
      local entry = dex.read_entry(data, offset)
      if entry then
        found[#found + 1] = entry
        offset = entry.finish
        goto continue
      end
    end
    offset = offset + 1
    ::continue::
  end
  return found
end

--------------------------------------------------------------------------------
-- Finding the pointer table
--------------------------------------------------------------------------------

--- Runs of consecutive words that all name one of `entries`.
-- @return array of { at, length }, longest first
local function pointer_runs(data, by_address)
  local runs = {}
  for alignment = 0, 1 do
    local offset = alignment
    while offset < #data - 2 do
      local addr = string.byte(data, offset + 1)
        + string.byte(data, offset + 2) * 256
      if by_address[addr] then
        local length, cursor = 0, offset
        while cursor < #data - 2 do
          local a = string.byte(data, cursor + 1)
            + string.byte(data, cursor + 2) * 256
          if not by_address[a] then
            break
          end
          length = length + 1
          cursor = cursor + 2
        end
        runs[#runs + 1] = { at = offset, length = length }
        offset = cursor + 2
      else
        offset = offset + 2
      end
    end
  end
  table.sort(runs, function(a, b) return a.length > b.length end)
  return runs
end

--- Resolve which bank each pointer meant.
--
-- A near pointer carries an address and no bank, so an address two banks both
-- hold an entry at is ambiguous on its own. What removes the ambiguity is that
-- the entries climb: the table is laid out in dex order. Rather than assume
-- that resolves it, both extreme monotone assignments are computed -- taking the
-- lowest feasible entry at each step, and the highest -- and the answer is
-- accepted only when they agree everywhere. Two different assignments would mean
-- the constraint is weaker than it looks, which is a refusal, not a coin toss.
-- @return array of entries, or nil plus a reason
local function resolve(pointers, by_address)
  local lowest, highest = {}, {}

  local previous = -1
  for index, addr in ipairs(pointers) do
    local pick
    for _, entry in ipairs(by_address[addr] or {}) do
      if entry.offset > previous and (not pick or entry.offset < pick.offset) then
        pick = entry
      end
    end
    if not pick then
      return nil, ("no entry for pointer %d that keeps the table in order")
        :format(index)
    end
    lowest[index] = pick
    previous = pick.offset
  end

  local following = math.huge
  for index = #pointers, 1, -1 do
    local pick
    for _, entry in ipairs(by_address[pointers[index]] or {}) do
      if entry.offset < following and (not pick or entry.offset > pick.offset) then
        pick = entry
      end
    end
    if not pick then
      return nil, ("no entry for pointer %d that keeps the table in order")
        :format(index)
    end
    highest[index] = pick
    following = pick.offset
  end

  for index = 1, #pointers do
    if lowest[index].offset ~= highest[index].offset then
      return nil, ("pointer %d could mean 0x%06X or 0x%06X and nothing in the " ..
        "table decides; refusing to guess")
        :format(index, lowest[index].offset, highest[index].offset)
    end
  end

  return lowest
end

--------------------------------------------------------------------------------
-- Spot checks
--------------------------------------------------------------------------------
--
-- None of these took any part in the search, which is what makes them evidence.
-- The classifications and measurements are the same in Gold and Silver, so this
-- is the same kind of external fact as "species 1 is BULBASAUR".

dex.spot_checks = {
  [1]   = { class = "SEED",       height = 204,  weight = 150 },
  [4]   = { class = "LIZARD",     height = 200,  weight = 190 },
  [25]  = { class = "MOUSE",      height = 104,  weight = 130 },
  [143] = { class = "SLEEPING",   height = 611,  weight = 10140 },
  [151] = { class = "NEW SPECIE", height = 104,  weight = 90 },
  [251] = { class = "TIMETRAVEL", height = 200,  weight = 110 },
}

--------------------------------------------------------------------------------

--- Locate and decode the Pokédex entries.
-- @return { offset, entries = { [1..251] = record }, banks = { ... } }
--         or nil plus a diagnostic
function dex.locate(rom)
  local data = rom.data
  local found = dex.scan(rom)

  if #found < dex.SPECIES_COUNT then
    return nil, ("only %d entry-shaped records in this cartridge; %d are needed")
      :format(#found, dex.SPECIES_COUNT)
  end

  local by_address = {}
  for _, entry in ipairs(found) do
    local addr = (entry.offset % 0x4000) + 0x4000
    by_address[addr] = by_address[addr] or {}
    table.insert(by_address[addr], entry)
  end

  local runs = pointer_runs(data, by_address)
  local long = {}
  for _, run in ipairs(runs) do
    if run.length >= dex.SPECIES_COUNT then
      long[#long + 1] = run
    end
  end

  if #long == 0 then
    return nil, ("no run of %d pointers lands on those records; the longest is %d")
      :format(dex.SPECIES_COUNT, runs[1] and runs[1].length or 0)
  end
  if #long > 1 then
    local places = {}
    for _, run in ipairs(long) do
      places[#places + 1] = ("0x%06X"):format(run.at)
    end
    return nil, ("%d runs of pointers are long enough (%s); refusing to guess")
      :format(#long, table.concat(places, ", "))
  end

  local table_at = long[1].at
  local pointers = {}
  for index = 1, dex.SPECIES_COUNT do
    local at = table_at + (index - 1) * 2
    pointers[index] = string.byte(data, at + 1) + string.byte(data, at + 2) * 256
  end

  local entries, why = resolve(pointers, by_address)
  if not entries then
    return nil, why
  end

  for index, expected in pairs(dex.spot_checks) do
    local entry = entries[index]
    if not entry then
      return nil, ("no entry decoded for species %d"):format(index)
    end
    if entry.class ~= expected.class then
      return nil, ("species %d is classified %q, expected %q")
        :format(index, entry.class, expected.class)
    end
    if entry.height ~= expected.height or entry.weight ~= expected.weight then
      return nil, ("species %d measures %d/%d, expected %d/%d")
        :format(index, entry.height, entry.weight,
          expected.height, expected.weight)
    end
  end

  -- Which bank each entry ended up in, for the report. This is derived from
  -- where the entries are, not asked for: Crystal splits its dex text into runs
  -- by species range, and the split falling out of the search is part of why the
  -- search is believable.
  local banks, order = {}, {}
  for _, entry in ipairs(entries) do
    local bank = math.floor(entry.offset / 0x4000)
    if not banks[bank] then
      banks[bank] = 0
      order[#order + 1] = bank
    end
    banks[bank] = banks[bank] + 1
  end

  return {
    offset = table_at,
    entries = entries,
    found = #found,
    banks = banks,
    bank_order = order,
    runner_up = runs[2] and runs[2].length or 0,
  }
end

--- Strip an entry down to what the cache keeps.
function dex.to_record(entry)
  return {
    class = entry.class,
    height = entry.height,
    weight = entry.weight,
    pages = entry.pages,
  }
end

--- "2'04" from 204.
--
-- The feet mark is the apostrophe at $E0, which the font settled long ago. The
-- inch mark is left off, and that is a gap rather than a style choice: the
-- height is stored as a number and formatted by the game's own assembly, so the
-- cartridge's dex text contains no inch mark to read the code off. Printing the
-- unmapped tiles below the letters -- the way $75 was settled -- turns up
-- several marks that could be one and nothing that decides between them. A
-- guessed glyph would be a wrong character on screen; the apostrophe and the
-- HT label carry the meaning without one.
function dex.height_text(height)
  return ("%d'%02d"):format(math.floor(height / 100), height % 100)
end

--- "15.0lb" from 150. Weight is stored in tenths of a pound.
function dex.weight_text(weight)
  return ("%d.%dlb"):format(math.floor(weight / 10), weight % 10)
end

return dex
