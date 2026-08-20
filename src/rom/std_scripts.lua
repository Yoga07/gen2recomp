-- The standard scripts.
--
-- `jumpstd` and `callstd` do not carry an address. Their operand is an index
-- into a table of the game's common routines -- the "you are in such a place"
-- signpost, the shopkeeper who checks whether you are carrying something, the
-- fanfare when an item is handed over. 278 of Crystal's scripts leave through
-- one of these, so without the table a sixth of the game's scripts stop dead.
--
-- The table is three-byte entries of a bank and a near address. Crystal has 52
-- and Gold 46, and on both cartridges every entry names the same bank -- the
-- bank the table itself begins at the very start of. That anchoring is the
-- sharpest thing known about the table, and is what the search below turns on:
-- exactly one run in each cartridge satisfies it.
--
-- Two false tables were found before Crystal's, and both were found because the
-- validator was too weak. "The bytes decode until a terminator" is satisfied by
-- two instructions, so any pointer landing on a byte that happens to be $91
-- passes: one candidate had all 104 of its entries aimed at the same such byte.
-- `script_at` therefore demands a routine of at least three instructions that
-- does something recognisable.
--
-- That strictness is right for rejecting nonsense and wrong as a gate. Gold's
-- standard scripts are far shorter than Crystal's -- many are a single
-- `farjumptext` -- so only 13 of its 46 entries clear `script_at` where 37 of
-- Crystal's 52 do. An earlier version required half of them to clear it, and
-- threw Gold's real table away. It is a score now rather than a threshold: the
-- winner must out-score every candidate that does not overlap it, which is 13
-- against 5 on Gold and 37 against 18 on Crystal. Nothing has to be invented
-- about where between those a cutoff belongs.

local script_ops = require("src.rom.script_ops")

local std_scripts = {}

std_scripts.RECORD_SIZE = 3
-- Enough of the table to be sure it is the table. Crystal has 52.
std_scripts.MINIMUM = 40
std_scripts.MAX_ENTRIES = 128

-- Commands that make a run of bytes a routine rather than a coincidence.
std_scripts.MEANINGFUL = {
  [0x47] = true, [0x49] = true, -- opentext, closetext
  [0x4B] = true, [0x4C] = true, -- farwritetext, writetext
  [0x51] = true, [0x52] = true, [0x53] = true, -- the jumptexts
  [0x31] = true, [0x32] = true, [0x33] = true, -- checkevent, clearevent, setevent
  [0x1F] = true, [0x9E] = true, -- giveitem, verbosegiveitem
  [0x0F] = true,                -- special
  [0x54] = true, [0x55] = true, -- waitbutton, promptbutton
  [0x1C] = true,                -- readvar
}

--- Does a routine decode from here?
-- @return instruction count, or nil
function std_scripts.script_at(rom, bank, addr, widths, terminators)
  if addr < 0x4000 or addr > 0x7FFF then
    return nil
  end
  local at = bank * 0x4000 + (addr - 0x4000)
  if at >= rom.size then
    return nil
  end

  local count, meaningful = 0, false
  for _ = 1, 300 do
    if at + 1 > rom.size then
      return nil
    end
    local opcode = rom:u8(at)
    local width = widths[opcode]
    if width == nil then
      return nil
    end
    count = count + 1
    if std_scripts.MEANINGFUL[opcode] then
      meaningful = true
    end
    if terminators[opcode] then
      if count >= 3 and meaningful then
        return count
      end
      return nil
    end
    at = at + 1 + width
  end
  return nil
end

--- Does anything at all decode here?
--
-- The weak reading of the same bytes: a valid instruction sequence that reaches
-- a terminator, with no minimum length and no requirement that it do anything
-- recognisable. Too weak to find a table with -- it is the rule that let two
-- false ones through -- but the right measure of a table already found, because
-- it does not care how short a cartridge's routines are. Every one of Crystal's
-- 52 entries decodes this way and 41 of Gold's 46.
function std_scripts.decodes_at(rom, bank, addr, widths, terminators)
  if addr < 0x4000 or addr > 0x7FFF then
    return false
  end
  local at = bank * 0x4000 + (addr - 0x4000)
  if at >= rom.size then
    return false
  end
  for _ = 1, 300 do
    if at + 1 > rom.size then
      return false
    end
    local opcode = rom:u8(at)
    local width = widths[opcode]
    if width == nil then
      return false
    end
    if terminators[opcode] then
      return true
    end
    at = at + 1 + width
  end
  return false
end


--- Locate the table.
-- @return { offset, count, bank, real, entries } or nil plus why
function std_scripts.locate(rom)
  local widths, terminators = script_ops.widths()
  local banks = math.floor(rom.size / 0x4000)

  -- Every entry names the same bank, which is a much sharper constraint than
  -- "the bank byte is plausible" and is what keeps the search from wandering
  -- into unrelated pointer tables.
  local function run_from(offset)
    local bank = rom:u8(offset)
    if bank >= banks then
      return 0
    end

    local count, targets = 0, {}
    while count < std_scripts.MAX_ENTRIES do
      local at = offset + count * std_scripts.RECORD_SIZE
      if at + 2 >= rom.size then
        break
      end
      if rom:u8(at) ~= bank then
        break
      end
      local addr = rom:u16le(at + 1)
      if addr < 0x4000 or addr > 0x7FFF then
        break
      end
      count = count + 1
      targets[count] = addr
    end

    if count < std_scripts.MINIMUM then
      return count
    end

    -- Evenly spaced targets are records in some other table, not routines.
    for i = 3, count do
      if targets[i] - targets[i - 1] ~= targets[2] - targets[1] then
        return count
      end
    end
    return 0
  end

  --- How many of a run's entries read as real routines rather than merely
  -- pointing somewhere in range.
  local function routines_in(offset, count)
    local bank = rom:u8(offset)
    local real = 0
    for index = 0, count - 1 do
      local addr = rom:u16le(offset + index * std_scripts.RECORD_SIZE + 1)
      if std_scripts.script_at(rom, bank, addr, widths, terminators) then
        real = real + 1
      end
    end
    return real
  end

  local candidates, longest = {}, 0
  for offset = 0, rom.size - std_scripts.MINIMUM * std_scripts.RECORD_SIZE do
    local count = run_from(offset)
    if count > longest then
      longest = count
    end
    if count >= std_scripts.MINIMUM then
      candidates[#candidates + 1] = { offset = offset, count = count,
        bank = rom:u8(offset) }
    end
  end

  if #candidates == 0 then
    return nil, ("the longest run of standard-script pointers was %d")
      :format(longest)
  end

  for _, row in ipairs(candidates) do
    row.real = routines_in(row.offset, row.count)
  end

  -- The table begins at the start of the bank its entries name.
  local best, rival
  for _, row in ipairs(candidates) do
    if row.offset % 0x4000 == 0
      and math.floor(row.offset / 0x4000) == row.bank then
      if not best or row.real > best.real
        or (row.real == best.real and row.count > best.count) then
        rival = best
        best = row
      elseif not rival or row.real > rival.real then
        rival = row
      end
    end
  end

  if not best then
    return nil, ("no run of standard-script pointers begins at the start of " ..
      "the bank it names; the longest run was %d"):format(longest)
  end
  if rival and rival.real == best.real and rival.count == best.count then
    return nil, ("0x%06X and 0x%06X are equally good standard-script tables")
      :format(best.offset, rival.offset)
  end

  -- What a wrong answer scores. Shifted copies of the winner are the same table
  -- with its first entries shaved off and say nothing, so only runs that do not
  -- overlap it count. On both known cartridges the strongest of those is the
  -- sound-effect table, and it loses by a wide margin.
  local last = best.offset + best.count * std_scripts.RECORD_SIZE
  for _, row in ipairs(candidates) do
    local clear = row.offset >= last
      or row.offset + row.count * std_scripts.RECORD_SIZE <= best.offset
    if clear and row.real >= best.real then
      return nil, ("0x%06X reads as %d routines, no better than 0x%06X at %d")
        :format(best.offset, best.real, row.offset, row.real)
    end
  end

  local entries = {}
  for index = 1, best.count do
    local at = best.offset + (index - 1) * std_scripts.RECORD_SIZE
    entries[index] = { bank = rom:u8(at), addr = rom:u16le(at + 1) }
  end

  -- Reported alongside the strict count because it is the measure that travels
  -- between cartridges: how short a game's standard scripts happen to be moves
  -- `real` a long way and barely moves this.
  local decoded = 0
  for _, entry in ipairs(entries) do
    if std_scripts.decodes_at(rom, entry.bank, entry.addr, widths,
      terminators) then
      decoded = decoded + 1
    end
  end

  return { offset = best.offset, count = best.count, bank = best.bank,
           real = best.real, decoded = decoded, entries = entries }
end

return std_scripts
