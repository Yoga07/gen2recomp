-- Inferring Crystal's script opcode table.
--
-- There is no operand-width table to read, and 256 opcodes with unknown widths
-- is far too large to guess at. What makes it tractable is that scripts are
-- stored back to back: sorting the entry points within a bank gives each
-- script's extent from the gap to the next one.
--
-- That turns the problem into a constraint. A correct width for an opcode is
-- one where walking a script consumes its extent *exactly* and stops on an
-- instruction that ends the script. Wrong widths desynchronise and overshoot.
-- So widths can be learned rather than guessed:
--
--   * A script whose whole extent is one instruction fixes that opcode's width
--     directly, and marks it as terminating. 633 scripts are exactly three
--     bytes, which bootstraps the common openers at two operand bytes.
--   * With some widths known, a script that walks cleanly until one unknown
--     opcode at the end fixes that one too.
--   * Repeat until nothing new is learned.
--
-- Every proposal is a vote. A width is only accepted when enough scripts agree
-- and almost none disagree, so a single misread extent cannot poison the table.

local script_table = {}

-- Ends a script: identified by sitting immediately before the next script 607
-- times across the game.
script_table.END = 0x91

-- Operands are small; anything wider than this is a misread extent.
script_table.MAX_OPERANDS = 8

-- Gaps larger than this probably span a script nobody points at, so the extent
-- is not trustworthy for learning.
script_table.MAX_EXTENT = 96

-- A width needs this many agreeing scripts, and this share of the votes.
script_table.MIN_VOTES = 3
script_table.MIN_AGREEMENT = 0.9

--- Gather every script entry point, grouped by bank and sorted.
-- @return { [bank] = { sorted flat offsets } }, total
function script_table.collect_entries(rom, map_result, events)
  local sets = {}
  local total = 0

  for _, header in ipairs(map_result.headers) do
    local decoded = not header.unparsed and events.decode(rom, header)
    if decoded then
      local bank = math.floor(header.attributes.scripts / 0x4000)
      sets[bank] = sets[bank] or {}
      for _, group in ipairs { decoded.bg_events, decoded.objects } do
        for _, item in ipairs(group) do
          if item.script and item.script >= 0x4000 and item.script <= 0x7FFF then
            local flat = bank * 0x4000 + (item.script - 0x4000)
            if flat < rom.size and not sets[bank][flat] then
              sets[bank][flat] = true
              total = total + 1
            end
          end
        end
      end
    end
  end

  local sorted = {}
  for bank, set in pairs(sets) do
    local list = {}
    for flat in pairs(set) do
      list[#list + 1] = flat
    end
    table.sort(list)
    sorted[bank] = list
  end

  return sorted, total
end

--- Scripts whose extent is known, as { offset, extent }.
function script_table.extents(sorted)
  local out = {}
  for _, list in pairs(sorted) do
    for i = 1, #list - 1 do
      local extent = list[i + 1] - list[i]
      if extent > 0 and extent <= script_table.MAX_EXTENT then
        out[#out + 1] = { offset = list[i], extent = extent }
      end
    end
  end
  return out
end

--- Walk a script under a candidate table.
--
-- @return status, instructions
--   "ended"    hit a terminating instruction
--   "unknown"  reached an opcode with no known width
--   "overrun"  walked past the limit without ending
local function walk(rom, offset, limit, widths, terminators)
  local instructions = {}
  local at = offset

  while at < limit do
    local opcode = rom:u8(at)
    local width = widths[opcode]
    if width == nil then
      return "unknown", instructions, at
    end

    instructions[#instructions + 1] = { offset = at, opcode = opcode, width = width }
    at = at + 1 + width

    if terminators[opcode] then
      return "ended", instructions, at
    end
  end

  return "overrun", instructions, at
end

script_table.walk = walk


--- Infer the opcode table.
-- @return { widths, terminators, learned, rounds }
function script_table.infer(rom, sorted)
  local widths = { [script_table.END] = 0 }
  local terminators = { [script_table.END] = true }

  local extents = script_table.extents(sorted)
  local rounds = 0

  repeat
    rounds = rounds + 1
    -- Votes are kept separately for the two things an opcode can be, because
    -- the evidence for each is different in kind.
    local ending_votes, passing_votes = {}, {}
    local learned = false

    for _, script in ipairs(extents) do
      local limit = script.offset + script.extent
      local status, _, position = walk(rom, script.offset, limit, widths, terminators)

      if status == "unknown" then
        local opcode = rom:u8(position)

        -- Case one: the unknown opcode accounts for the whole rest of the
        -- script. The leftover bytes are its operands, and reaching the
        -- boundary means it ends the script.
        local width = limit - position - 1
        if width >= 0 and width <= script_table.MAX_OPERANDS then
          ending_votes[opcode] = ending_votes[opcode] or {}
          ending_votes[opcode][width] = (ending_votes[opcode][width] or 0) + 1
        end

        -- Case two: the opcode sits mid-script and everything after it is
        -- already known. Try each width and keep those under which the
        -- remainder walks cleanly to the boundary. Only an unambiguous fit
        -- counts; if two widths both work this script says nothing.
        --
        -- Note what this deliberately does not do: solve for two unknowns at
        -- once. That was tried and it fails badly — see the architecture notes.
        local fits, fit_count = nil, 0
        for candidate = 0, script_table.MAX_OPERANDS do
          local resume = position + 1 + candidate
          if resume < limit then
            local rest_status, _, rest_end =
              walk(rom, resume, limit, widths, terminators)
            if rest_status == "ended" and rest_end == limit then
              fits, fit_count = candidate, fit_count + 1
            end
          end
        end

        if fit_count == 1 then
          passing_votes[opcode] = passing_votes[opcode] or {}
          passing_votes[opcode][fits] = (passing_votes[opcode][fits] or 0) + 1
        end
      end
    end

    --- Accept a width only where the evidence is lopsided.
    local function adopt(votes, terminating)
      for opcode, tally in pairs(votes) do
        if widths[opcode] == nil then
          local best, best_count, total = nil, 0, 0
          for width, count in pairs(tally) do
            total = total + count
            if count > best_count then
              best, best_count = width, count
            end
          end

          if best_count >= script_table.MIN_VOTES
            and best_count / total >= script_table.MIN_AGREEMENT then
            widths[opcode] = best
            terminators[opcode] = terminating
            learned = true
          end
        end
      end
    end

    -- Mid-script evidence is the stronger of the two: it requires the whole
    -- remainder of the script to walk cleanly, whereas the end-of-script case
    -- assumes termination rather than demonstrating it. So it goes first, and
    -- an opcode it explains is never also treated as a terminator.
    adopt(passing_votes, false)
    adopt(ending_votes, true)
  until not learned or rounds > 16

  local learned_count = 0
  for _ in pairs(widths) do
    learned_count = learned_count + 1
  end

  return {
    widths = widths,
    terminators = terminators,
    learned = learned_count,
    rounds = rounds,
  }
end

--- How well a table explains the scripts it was learned from.
function script_table.score(rom, sorted, inferred)
  local counts = { ended = 0, unknown = 0, overrun = 0, exact = 0 }

  for _, script in ipairs(script_table.extents(sorted)) do
    local limit = script.offset + script.extent
    local status, _, position =
      walk(rom, script.offset, limit, inferred.widths, inferred.terminators)
    counts[status] = counts[status] + 1
    if status == "ended" and position == limit then
      counts.exact = counts.exact + 1
    end
  end

  return counts
end

return script_table
