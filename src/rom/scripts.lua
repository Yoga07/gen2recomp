-- Map scripts.
--
-- Every signpost and NPC carries a pointer to a script: a bytecode program the
-- game runs when the player interacts with it. Interpreting the whole language
-- is a large job, and this is not that. It reads the one thing that makes the
-- overworld talk — which text a script shows — and reports honestly when a
-- script does something it does not understand.
--
-- The text opcode was found by taking the 792 signpost scripts the event
-- decoder produced, looking for a two-byte pointer in their opening bytes that
-- landed on a string the text scanner had already found, and asking what byte
-- preceded it. $53 accounts for 193 of 211 hits and $4C for 15 more.
--
-- Script pointers are near pointers, resolved against the bank holding the
-- map's script header, which the map attributes record supplies.

local text = require("src.rom.text")

local scripts = {}

-- Opcodes whose two-byte operand is a text pointer.
--
-- Which these are was settled statistically rather than from a specification.
-- Across every script in the game, the fraction of each opcode's operands that
-- decode as dialogue is:
--
--   $53  215 of 289   74%
--   $51  144 of 351   41%
--   $6B   40 of 316   13%
--   $47    8 of  96    8%
--   $0C    1 of 152   0.7%
--
-- $0C sets the baseline. Its operand is plainly not an address — the values are
-- small ids — so its 0.7% is how often arbitrary bytes happen to decode as
-- dialogue. Against that, $53 and $51 are unambiguous.
--
-- $6B and $47 are left out. Thirteen percent is well above the noise floor and
-- they may well take a text pointer in some forms, but at that rate a
-- meaningful share of what they produced would be wrong, and wrong dialogue
-- attributed to the wrong character is worse than absent dialogue.
--
-- Names are descriptive, not authoritative. $53 shows a message and ends the
-- script, which is what a signpost does. $51's exact semantics are unknown
-- beyond that its operand is a text pointer.
scripts.JUMPTEXT = 0x53
scripts.SHOWTEXT_51 = 0x51
scripts.WRITETEXT = 0x4C

scripts.text_opcodes = {
  [scripts.JUMPTEXT] = "jumptext",
  [scripts.SHOWTEXT_51] = "showtext_51",
  [scripts.WRITETEXT] = "writetext",
}

-- Ends a script. Identified by being the byte immediately before the next
-- script begins, 607 times across the game.
scripts.END = 0x91

--- Resolve a near pointer against a bank.
local function resolve(bank, addr, rom)
  if addr < 0x4000 or addr > 0x7FFF then
    return nil
  end
  local flat = bank * 0x4000 + (addr - 0x4000)
  if flat < 0 or flat >= rom.size then
    return nil
  end
  return flat
end

--- Read the text a script displays, if it starts by displaying one.
--
-- Deliberately shallow: it looks at the first instruction only. A script that
-- begins with a conditional, a movement, or anything else returns nil rather
-- than a guess, and the caller records that the script was not understood.
--
-- @param bank the bank the script pointer is relative to
-- @param addr the script's near pointer
-- @return { opcode, opcode_name, text_offset, block } or nil plus a reason
function scripts.read_text(rom, bank, addr)
  local at = resolve(bank, addr, rom)
  if not at then
    return nil, "script pointer out of range"
  end

  local opcode = rom:u8(at)
  local name = scripts.text_opcodes[opcode]
  if not name then
    return nil, ("opcode $%02X is not a text instruction"):format(opcode)
  end

  local target = resolve(bank, rom:u16le(at + 1), rom)
  if not target then
    return nil, "text pointer out of range"
  end

  local block = text.decode_dialogue(rom.data, target)
  if not block then
    return nil, ("no dialogue at 0x%06X"):format(target)
  end

  return {
    script_offset = at,
    opcode = opcode,
    opcode_name = name,
    text_offset = target,
    block = block,
  }
end

--- Read the text for every signpost and NPC on a map.
--
-- @param header a decoded map header
-- @param decoded_events the map's decoded event header
-- @return { bg = { [i] = result }, objects = { [i] = result }, understood, total }
function scripts.read_map_text(rom, header, decoded_events)
  local bank = math.floor(header.attributes.scripts / 0x4000)
  local result = { bg = {}, objects = {}, understood = 0, total = 0 }

  for index, bg in ipairs(decoded_events.bg_events) do
    if bg.script then
      result.total = result.total + 1
      local found = scripts.read_text(rom, bank, bg.script)
      if found then
        result.bg[index] = found
        result.understood = result.understood + 1
      end
    end
  end

  for index, object in ipairs(decoded_events.objects) do
    if object.script then
      result.total = result.total + 1
      local found = scripts.read_text(rom, bank, object.script)
      if found then
        result.objects[index] = found
        result.understood = result.understood + 1
      end
    end
  end

  return result
end

return scripts
