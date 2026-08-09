-- The standard scripts.
--
-- `jumpstd` and `callstd` do not carry an address. Their operand is an index
-- into a table of the game's common routines -- the "you are in such a place"
-- signpost, the shopkeeper who checks whether you are carrying something, the
-- fanfare when an item is handed over. 278 scripts leave through one of these,
-- so without the table a sixth of the game's scripts stop dead.
--
-- The table is 52 entries of three bytes: a bank, then a near address. Every
-- entry in Crystal names bank $2F, and the table itself begins at the start of
-- that bank.
--
-- Two false tables were found before this one, and both were found because the
-- validator was too weak. "The bytes decode until a terminator" is satisfied by
-- two instructions, so any pointer landing on a byte that happens to be $91
-- passes: one candidate had all 104 of its entries aimed at the same such byte.
-- A real routine is at least a few instructions long and does something
-- recognisable, and the entries of a real table land at irregular addresses
-- rather than marching in a constant step.

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

--- Locate the table.
-- @return { offset, count, entries = { {bank, addr}, ... } } or nil plus why
function std_scripts.locate(rom)
  local widths, terminators = script_ops.widths()

  -- Every entry names the same bank, which is a much sharper constraint than
  -- "the bank byte is plausible" and is what keeps the search from wandering
  -- into unrelated pointer tables.
  local function run_from(offset)
    local bank = rom:u8(offset)
    if bank * 0x4000 >= rom.size then
      return 0
    end

    local count = 0
    local targets = {}
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
      return count, targets
    end

    -- Evenly spaced targets are records in some other table, not routines.
    local uniform = true
    for i = 3, count do
      if targets[i] - targets[i - 1] ~= targets[2] - targets[1] then
        uniform = false
        break
      end
    end
    if uniform then
      return 0
    end

    return count, targets
  end

  local best = { count = 0 }
  local offset = 0
  while offset <= rom.size - std_scripts.MINIMUM * std_scripts.RECORD_SIZE do
    local count = run_from(offset)
    if count > best.count then
      -- Only now pay for decoding, and require most of the run to be real
      -- routines rather than merely in range.
      local bank = rom:u8(offset)
      local real = 0
      for index = 0, count - 1 do
        local addr = rom:u16le(offset + index * std_scripts.RECORD_SIZE + 1)
        if std_scripts.script_at(rom, bank, addr, widths, terminators) then
          real = real + 1
        end
      end
      if real >= count * 0.5 then
        best = { count = count, offset = offset, bank = bank, real = real }
      end
    end
    offset = offset + 1
  end

  if best.count < std_scripts.MINIMUM then
    return nil, ("the longest run of standard-script pointers was %d")
      :format(best.count)
  end

  local entries = {}
  for index = 1, best.count do
    local at = best.offset + (index - 1) * std_scripts.RECORD_SIZE
    entries[index] = { bank = rom:u8(at), addr = rom:u16le(at + 1) }
  end

  return { offset = best.offset, count = best.count, bank = best.bank,
           real = best.real, entries = entries }
end

return std_scripts
