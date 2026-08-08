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
local script_ops = require("src.rom.script_ops")

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

-- How many instructions to follow before giving up. Real scripts are far
-- shorter; this only stops a runaway walk on malformed data.
scripts.MAX_INSTRUCTIONS = 96

--- Read the text a script displays, following the bytecode rather than looking
-- at a single instruction.
--
-- Walks from the entry point, collecting every text command it passes, and
-- stops at a terminator, an unknown opcode, or a conditional branch. Branches
-- end the walk deliberately: following one arm would report dialogue the player
-- may never see, and following both would report contradictory text as though
-- it were sequential.
--
-- @param bank the bank the script pointer is relative to
-- @param addr the script's near pointer
-- @return { blocks = { {opcode_name, text_offset, block}, ... }, status } or
--         nil plus a reason
function scripts.read_text(rom, bank, addr)
  local at = resolve(bank, addr, rom)
  if not at then
    return nil, "script pointer out of range"
  end

  local widths, terminators, names = script_ops.widths()
  local blocks = {}
  local status = "ended"

  for _ = 1, scripts.MAX_INSTRUCTIONS do
    if at + 1 > rom.size then
      status = "ran past the ROM"
      break
    end

    local opcode = rom:u8(at)
    local width = widths[opcode]
    if width == nil then
      status = ("unknown opcode $%02X"):format(opcode)
      break
    end

    -- Text commands: near ones point within the script bank, far ones carry
    -- their own bank byte.
    local near = script_ops.text_commands[opcode]
    local far = script_ops.far_text_commands[opcode]
    local target

    if near then
      target = resolve(bank, rom:u16le(at + 1), rom)
    elseif far then
      local text_bank = rom:u8(at + 1)
      target = resolve(text_bank, rom:u16le(at + 2), rom)
    end

    if target then
      local block = text.decode_dialogue(rom.data, target)
      if block then
        blocks[#blocks + 1] = {
          opcode = opcode,
          opcode_name = near or far,
          text_offset = target,
          block = block,
        }
      end
    end

    at = at + 1 + width

    if terminators[opcode] then
      break
    end

    -- Conditionals fork; a linear walk cannot honestly say what happens next.
    local name = names[opcode]
    if name and (name:sub(1, 2) == "if" or name == "scall" or name == "farscall") then
      status = "branched"
      break
    end
  end

  if #blocks == 0 then
    return nil, status == "ended" and "script shows no text" or status
  end

  return { blocks = blocks, status = status }
end

--- Walk a script looking for one particular command.
--
-- The same linear walk `read_text` uses, and it stops in the same places for
-- the same reasons: a terminator, an unknown opcode, or a branch. A command
-- behind a conditional is not reached, which is why this finds most of the
-- shops in Crystal rather than all of them.
--
-- @return the offset of the command's first argument byte, or nil
function scripts.find_opcode(rom, bank, addr, wanted)
  local at = resolve(bank, addr, rom)
  if not at then
    return nil
  end

  local widths, terminators, names = script_ops.widths()

  for _ = 1, scripts.MAX_INSTRUCTIONS do
    if at + 1 > rom.size then
      return nil
    end

    local opcode = rom:u8(at)
    local width = widths[opcode]
    if width == nil then
      return nil
    end
    if opcode == wanted then
      return at + 1
    end

    at = at + 1 + width

    if terminators[opcode] then
      return nil
    end
    local name = names[opcode]
    if name and (name:sub(1, 2) == "if" or name == "scall"
      or name == "farscall") then
      return nil
    end
  end

  return nil
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
