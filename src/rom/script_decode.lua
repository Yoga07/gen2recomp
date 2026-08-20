-- Decoding scripts into something the engine can run.
--
-- The engine reads the cache and never the cartridge, so an interpreter needs
-- the bytecode decoded at import time: every reachable instruction, with its
-- operands pulled out and any text it shows already resolved.
--
-- Instructions are keyed by bank and address rather than gathered into lists
-- per script. Scripts jump into each other freely and several entry points
-- share tails, so an address-keyed table both dedupes them and makes a jump a
-- lookup rather than a search.
--
-- Traversal follows every branch. That is the difference between this and the
-- text walk, which deliberately stops at the first conditional because it
-- cannot say which arm the player will see. An interpreter does not have to
-- guess: it will know at runtime, and so it needs both arms decoded.

local script_ops = require("src.rom.script_ops")
local text = require("src.rom.text")
local movement = require("src.rom.movement")

local script_decode = {}
-- Commands are named here rather than numbered, because the number is not the
-- same on every cartridge: Crystal carries one script command that Gold does
-- not, so everything above $52 is one lower there. `applymovement` is $69 on
-- Crystal and $68 on Gold, and reading it at the wrong number does not look
-- like an error -- the movement block simply comes out of whatever bytes
-- happen to be at the operand.

-- Where a branch target sits within each command's operands.
local NEAR_TARGETS = {
  scall = 0, sjump = 0, iffalse = 0, iftrue = 0,
  ifequal = 1, ifnotequal = 1, ifgreater = 1, ifless = 1,
  sdefer = 0, stopandsjump = 0,
}

-- Same, but the target carries its own bank byte first.
local FAR_TARGETS = { farscall = 0, farsjump = 0 }

--- The opcode-keyed forms of the above, for whichever command list is in use.
-- @param names opcode -> command name, from script_ops.widths
-- @return applymovement opcode, applymovementlasttalked opcode, near, far
function script_decode.targets_for(names)
  local near, far, movement, movement_last = {}, {}
  for opcode, name in pairs(names) do
    if NEAR_TARGETS[name] ~= nil then
      near[opcode] = NEAR_TARGETS[name]
    end
    if FAR_TARGETS[name] ~= nil then
      far[opcode] = FAR_TARGETS[name]
    end
    if name == "applymovement" then
      movement = opcode
    elseif name == "applymovementlasttalked" then
      movement_last = opcode
    end
  end
  return movement, movement_last, near, far
end

-- A script that runs this long is not a script.
script_decode.MAX_INSTRUCTIONS = 4000

--- Decode every instruction reachable from a set of entry points.
--
-- @param entries list of { bank, addr }
-- @return code, stats
--   code[bank][addr] = { op, opcode, size, args = {bytes}, text = pages }
function script_decode.reachable(rom, entries)
  local widths, terminators, names = script_ops.widths()
  local applymovement, applymovement_last, near_targets, far_targets =
    script_decode.targets_for(names)

  local code = {}
  local stats = { instructions = 0, blocks = 0, failed = 0, reasons = {} }

  local queue = {}
  local queued = {}

  local function push(bank, addr)
    if not addr or addr < 0x4000 or addr > 0x7FFF then
      return
    end
    if bank < 0 or bank * 0x4000 >= rom.size then
      return
    end
    local key = bank * 0x10000 + addr
    if queued[key] then
      return
    end
    queued[key] = true
    queue[#queue + 1] = { bank = bank, addr = addr }
  end

  for _, entry in ipairs(entries) do
    push(entry.bank, entry.addr)
  end

  local function fail(reason)
    stats.failed = stats.failed + 1
    stats.reasons[reason] = (stats.reasons[reason] or 0) + 1
  end

  while #queue > 0 do
    local job = table.remove(queue)
    local bank, addr = job.bank, job.addr
    code[bank] = code[bank] or {}
    stats.blocks = stats.blocks + 1

    local guard = 0
    while addr >= 0x4000 and addr <= 0x7FFF do
      guard = guard + 1
      if guard > script_decode.MAX_INSTRUCTIONS then
        fail("block ran too long")
        break
      end

      -- Already decoded: the rest of this block is known, and so is everything
      -- it reaches.
      if code[bank][addr] then
        break
      end

      local at = bank * 0x4000 + (addr - 0x4000)
      if at + 1 > rom.size then
        fail("ran past the ROM")
        break
      end

      local opcode = rom:u8(at)
      local width = widths[opcode]
      if width == nil then
        fail(("unknown opcode $%02X"):format(opcode))
        break
      end

      local args = {}
      for i = 1, width do
        args[i] = rom:u8(at + i)
      end

      local instruction = {
        op = names[opcode],
        opcode = opcode,
        size = 1 + width,
        args = args,
        -- Carried through so the interpreter knows where linear execution
        -- stops. Without it, a command the interpreter does not implement but
        -- which ends the script -- jumpstd is the common one -- gets stepped
        -- past into bytes that were never decoded.
        ends = terminators[opcode] or nil,
      }

      -- Text is resolved now, because the engine cannot go back to the
      -- cartridge for it. Near text lives in the script's own bank; far text
      -- carries the bank it lives in.
      local near = script_ops.text_commands[opcode]
      local far = script_ops.far_text_commands[opcode]
      local text_bank, text_addr
      if near then
        text_bank, text_addr = bank, rom:u16le(at + 1)
      elseif far then
        text_bank, text_addr = rom:u8(at + 1), rom:u16le(at + 2)
      end
      if text_addr and text_addr >= 0x4000 and text_addr <= 0x7FFF then
        local flat = text_bank * 0x4000 + (text_addr - 0x4000)
        if flat < rom.size then
          local block = text.decode_dialogue(rom.data, flat)
          if block then
            instruction.text = block.pages
            instruction.prompted = block.prompted
          end
        end
      end

      -- Movement blocks are resolved here for the same reason text is: the
      -- engine reads the cache and cannot go back to the cartridge.
      local move_addr
      if opcode == applymovement then
        move_addr = rom:u16le(at + 2)
      elseif opcode == applymovement_last then
        move_addr = rom:u16le(at + 1)
      end
      if move_addr and move_addr >= 0x4000 and move_addr <= 0x7FFF then
        local flat = bank * 0x4000 + (move_addr - 0x4000)
        if flat < rom.size then
          instruction.movement = movement.decode(rom, flat)
        end
      end

      -- Branch targets, recorded as addresses so the interpreter can jump
      -- without knowing how the operands were laid out.
      local near_at = near_targets[opcode]
      if near_at then
        local target = rom:u16le(at + 1 + near_at)
        if target >= 0x4000 and target <= 0x7FFF then
          instruction.target = target
          instruction.target_bank = bank
          push(bank, target)
        end
      end

      local far_at = far_targets[opcode]
      if far_at then
        local target_bank = rom:u8(at + 1 + far_at)
        local target = rom:u16le(at + 2 + far_at)
        if target >= 0x4000 and target <= 0x7FFF then
          instruction.target = target
          instruction.target_bank = target_bank
          push(target_bank, target)
        end
      end

      code[bank][addr] = instruction
      stats.instructions = stats.instructions + 1

      if terminators[opcode] then
        break
      end

      addr = addr + instruction.size
    end
  end

  return code, stats
end

return script_decode
