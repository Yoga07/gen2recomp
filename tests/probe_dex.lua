-- Diagnostic: the Pokédex entry table.
--
-- The first shape guessed at -- a class word, some bytes, then a description --
-- found nothing at any gap from 0 to 8, so the guessing stopped and the bytes
-- around a classification the dex is known to contain were dumped instead. They
-- say the record plainly:
--
--   SEED@  CC 00  96 00  While it is young,<4E>it uses the<4E>nutrients that are@
--                        stored in the<4E>seeds on its back<4E>in order to grow.@
--
-- A class word terminated by $50, a height word, a weight word, then two pages
-- of text each terminated by $50. Two things the first attempt had wrong: the
-- line break inside a dex entry is $4E, not the $4F dialogue uses, and $50 is a
-- page break as well as the terminator, so a record ends on the second one.
--
-- 204 is 2'04" and 150 is 15.0lb, which is Bulbasaur. This probe measures the
-- rest rather than taking that on faith: how many pages a record really has,
-- how many records the shape finds, whether they sit back to back, and whether
-- a run of pointers names them in dex order.
--
--   love . --probe-dex <rom> <report>

local Rom = require("src.rom.rom")
local text = require("src.rom.text")
local locate = require("src.rom.locate")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

local function write(path)
  local fh = io.open(path, "w")
  if fh then
    fh:write(table.concat(report, "\n") .. "\n")
    fh:close()
  end
end

local TERMINATOR = 0x50
local NEXT_LINE = 0x4E

--- A run of uppercase letters and spaces ending in the terminator.
local function class_word(data, offset)
  local out = {}
  for i = 0, 15 do
    local code = string.byte(data, offset + i + 1)
    if not code then
      return nil
    end
    if code == TERMINATOR then
      if #out < 3 then
        return nil
      end
      return table.concat(out), offset + i
    end
    if code >= 0x80 and code <= 0x99 then
      out[#out + 1] = text.charmap[code]
    elseif code == 0x7F and #out > 0 then
      out[#out + 1] = " "
    else
      return nil
    end
  end
  return nil
end

--- One page: readable text up to the next $50.
-- @return the text, bytes consumed, letters counted
local function page(data, offset, minimum)
  local out, letters = {}, 0
  for i = 0, 255 do
    local code = string.byte(data, offset + i + 1)
    if not code then
      return nil
    end
    if code == TERMINATOR then
      if letters < minimum then
        return nil
      end
      return table.concat(out), i + 1
    elseif code == NEXT_LINE then
      out[#out + 1] = " / "
    else
      local glyph = text.charmap[code] or text.substitutions[code]
      if not glyph then
        return nil
      end
      out[#out + 1] = glyph
      letters = letters + 1
    end
  end
  return nil
end

--- Try to read a whole record at `offset`, with `pages` pages of text.
-- `loose` drops the feet-and-inches constraint, so the shape can be scored
-- against what it finds without its sharpest check.
local function record_at(data, offset, pages, loose)
  local word, terminator = class_word(data, offset)
  if not word then
    return nil
  end
  local numbers = terminator + 1
  local height = string.byte(data, numbers + 1)
  local height_hi = string.byte(data, numbers + 2)
  local weight = string.byte(data, numbers + 3)
  local weight_hi = string.byte(data, numbers + 4)
  if not weight_hi then
    return nil
  end
  height = height + height_hi * 256
  weight = weight + weight_hi * 256

  -- A height in feet and inches cannot carry twelve inches, which is the one
  -- sharp constraint available on these four bytes.
  if not loose then
    if height == 0 or height >= 4000 or height % 100 >= 12 then
      return nil
    end
    if weight == 0 or weight >= 30000 then
      return nil
    end
  end

  local cursor = numbers + 4
  local body = {}
  for index = 1, pages do
    local content, consumed = page(data, cursor, index == 1 and 12 or 1)
    if not content then
      return nil
    end
    body[#body + 1] = content
    cursor = cursor + consumed
  end

  return {
    offset = offset,
    class = word,
    height = height,
    weight = weight,
    pages = body,
    finish = cursor,
  }
end

--- Every record the shape finds, walking forward past each hit.
local function scan(data, pages, loose)
  local found, offset = {}, 0
  while offset < #data - 16 do
    local record = record_at(data, offset, pages, loose)
    if record then
      found[#found + 1] = record
      offset = record.finish
    else
      offset = offset + 1
    end
  end
  return found
end

function probe.run(rom_path, report_path)
  report = {}

  local rom, err = Rom.load(rom_path)
  if not rom then
    log("FATAL: %s", err)
    write(report_path)
    return true
  end
  local data = rom.data

  -- How many pages does a record carry? Measured rather than assumed: a wrong
  -- page count desynchronises the walk, so the right one finds the most records
  -- and packs them into the fewest runs.
  log("== how many pages a record carries ==")
  local by_pages = {}
  for pages = 1, 4 do
    local found = scan(data, pages)
    -- Contiguity: how many records begin exactly where the last one ended.
    local touching = 0
    for i = 2, #found do
      if found[i].offset == found[i - 1].finish then
        touching = touching + 1
      end
    end
    by_pages[pages] = found
    log("  %d page(s): %4d records, %4d of them back to back",
      pages, #found, touching)
  end

  local best, best_touching = 1, -1
  for pages = 1, 4 do
    local found = by_pages[pages]
    local touching = 0
    for i = 2, #found do
      if found[i].offset == found[i - 1].finish then
        touching = touching + 1
      end
    end
    if touching > best_touching then
      best, best_touching = pages, touching
    end
  end
  log("  -> %d pages puts the most records back to back", best)

  local found = by_pages[best]

  -- What would a wrong answer have scored? The four bytes between the class
  -- word and the text are the only part of this shape that is not just "looks
  -- like text", and a height in feet and inches cannot carry twelve inches.
  -- Dropping that check says how much of the work it is doing.
  log("\n== the noise floor ==")
  local loose = scan(data, best, true)
  log("  with the feet-and-inches check: %d records", #found)
  log("  without it:                     %d records", #loose)

  log("\n== where they sit ==")
  local runs, current = {}, nil
  for _, record in ipairs(found) do
    if current and record.offset == current.finish then
      current.count = current.count + 1
      current.finish = record.finish
    else
      current = { start = record.offset, finish = record.finish, count = 1,
                  first = record }
      runs[#runs + 1] = current
    end
  end
  table.sort(runs, function(a, b) return a.count > b.count end)
  log("  %d records in %d runs", #found, #runs)
  for i = 1, math.min(#runs, 10) do
    local run = runs[i]
    log("  run %2d: %3d records at 0x%06X..0x%06X (bank $%02X), first is %s",
      i, run.count, run.start, run.finish,
      math.floor(run.start / 0x4000), run.first.class)
  end

  -- The pointer table. A near pointer carries only an address, so every bank
  -- holding a record at that address is a candidate and the record set is what
  -- picks the bank -- the same trick the marts needed, where the pointers land
  -- on the lists and on nothing else.
  log("\n== a run of pointers naming them ==")
  local by_address = {}
  for _, record in ipairs(found) do
    local addr = (record.offset % 0x4000) + 0x4000
    by_address[addr] = by_address[addr] or {}
    table.insert(by_address[addr], record)
  end

  local best_at, best_len = nil, 0
  local lengths = {}
  for start = 0, 1 do
    local offset = start
    while offset < #data - 2 do
      local addr = string.byte(data, offset + 1)
        + string.byte(data, offset + 2) * 256
      if by_address[addr] then
        local length, cursor = 0, offset
        while cursor < #data - 2 do
          local a = string.byte(data, cursor + 1)
            + string.byte(data, cursor + 2) * 256
          if not by_address[a] then break end
          length = length + 1
          cursor = cursor + 2
        end
        lengths[#lengths + 1] = { at = offset, length = length }
        if length > best_len then
          best_len, best_at = length, offset
        end
        offset = cursor + 2
      else
        offset = offset + 2
      end
    end
  end
  log("  longest run of words pointing at a record: %d, at 0x%06X",
    best_len, best_at or 0)

  -- One long run is only evidence beside how long the others get. If the second
  -- longest is a handful, the winner is not something noise produced.
  table.sort(lengths, function(a, b) return a.length > b.length end)
  local runners = {}
  for i = 2, math.min(#lengths, 6) do
    runners[#runners + 1] = ("%d at 0x%06X"):format(lengths[i].length,
      lengths[i].at)
  end
  log("  next longest: %s", table.concat(runners, ", "))
  local long = 0
  for _, entry in ipairs(lengths) do
    if entry.length >= 100 then long = long + 1 end
  end
  log("  runs of 100 or more: %d", long)

  if best_at then
    -- How ambiguous is a near pointer here? If most addresses name exactly one
    -- record the bank falls out; if not, this needs a bank table as well.
    local single, multiple = 0, 0
    for index = 1, best_len do
      local at = best_at + (index - 1) * 2
      local addr = string.byte(data, at + 1) + string.byte(data, at + 2) * 256
      if #by_address[addr] == 1 then single = single + 1 else multiple = multiple + 1 end
    end
    log("  of those %d pointers, %d name exactly one record and %d are ambiguous",
      best_len, single, multiple)

    local names = locate.table(locate.descriptors.species_names, rom)
    names = names and names.records or {}
    log("\n== what the run names, against the species table ==")
    for _, index in ipairs({ 1, 2, 3, 4, 7, 25, 143, 151, 152, 155, 191, 245,
                             251, 252 }) do
      if index <= best_len then
        local at = best_at + (index - 1) * 2
        local addr = string.byte(data, at + 1) + string.byte(data, at + 2) * 256
        local places = {}
        for _, record in ipairs(by_address[addr] or {}) do
          places[#places + 1] = ("%s %d'%02d\" %.1flb @0x%06X"):format(
            record.class, math.floor(record.height / 100), record.height % 100,
            record.weight / 10, record.offset)
        end
        log("  %3d %-11s -> %s", index, names[index] or "?",
          table.concat(places, " | "))
      end
    end

    -- Does the pointer order agree with the address order? If the entries are
    -- laid out in dex order then sorting by offset reproduces the table, and
    -- two structures agreeing is worth more than either alone.
    local sorted = {}
    for _, record in ipairs(found) do sorted[#sorted + 1] = record end
    table.sort(sorted, function(a, b) return a.offset < b.offset end)
    local agree, checked = 0, 0
    for index = 1, best_len do
      local at = best_at + (index - 1) * 2
      local addr = string.byte(data, at + 1) + string.byte(data, at + 2) * 256
      local candidates = by_address[addr] or {}
      if #candidates == 1 and sorted[index] then
        checked = checked + 1
        if sorted[index].offset == candidates[1].offset then
          agree = agree + 1
        end
      end
    end
    log("\n  address order reproduces pointer order %d of %d times",
      agree, checked)
  end

  -- The dex prints a height as feet and inches, and the inch mark is a glyph
  -- this project's charmap does not have. Rather than guess a code or quietly
  -- drop the character, print the tiles the unmapped codes draw and look: the
  -- same way $75 was settled as a control rather than a letter.
  log("\n== what the unmapped codes below the letters draw ==")
  local font = require("src.rom.font")
  local gfx = require("src.rom.gfx")
  local located = font.locate(rom, "crystal")
  if located then
    local tiles = gfx.decode_tiles_1bpp(data, located.offset, 256)
    for code = 0x60, 0x7E do
      if not text.charmap[code] and not text.substitutions[code] then
        local tile = tiles[font.tile_for(code) + 1]
        if tile then
          -- A tile is a flat 64-entry array of palette indices, row-major.
          local ink = 0
          for _, pixel in ipairs(tile) do
            if pixel > 0 then ink = ink + 1 end
          end
          if ink > 0 then
            local art = {}
            for row = 0, 7 do
              local line = {}
              for column = 1, 8 do
                line[#line + 1] = tile[row * 8 + column] > 0 and "#" or "."
              end
              art[#art + 1] = table.concat(line)
            end
            log("  $%02X (%2d ink): %s", code, ink, table.concat(art, " "))
          end
        end
      end
    end
  else
    log("  the font did not locate")
  end

  rom:release()
  write(report_path)
  return true
end

return probe
