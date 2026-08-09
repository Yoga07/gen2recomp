-- The script interpreter.
--
-- Gen 2 scripts are a small bytecode with two pieces of state worth naming: a
-- carry flag, set by the check commands, and a one-byte working register that
-- setval and friends load. `iftrue` and `iffalse` test the carry; `ifequal` and
-- `ifnotequal` compare the register. Getting that split wrong makes conditional
-- branches go the wrong way while every instruction still decodes, which is the
-- failure mode to watch for.
--
-- Execution is a coroutine-free step machine: `resume` runs until the script
-- either finishes or asks for something the engine has to draw, at which point
-- it yields and waits to be resumed. That keeps text boxes and menus in the
-- engine's hands rather than the interpreter's.
--
-- Commands fall into three groups.
--
--   * Implemented — control flow, text, event flags, items, money. These carry
--     real semantics and the tests check them.
--   * Ignored — movement, music, emotes, camera. The script continues as though
--     they had happened. An NPC will not walk, but the conversation that
--     follows the walking still runs, which is the difference between a script
--     that works and one that stops dead.
--   * Refused — battles, warps, trades, giving Pokemon. These change the world
--     in ways the engine cannot yet honour, so the script stops rather than
--     pretending. A silent no-op here would look like a working script that
--     quietly did nothing.

local vm = {}

vm.MAX_STEPS = 2000

local VM = {}
VM.__index = VM

-- Commands whose effect the engine cannot honour yet. Stopping is the honest
-- response: the alternative is a script that appears to run and does not.
vm.REFUSED = {
  startbattle = true,
  warp = true,
  warpfacing = true,
  newloadmap = true,
  trade = true,
  givepoke = true,
  giveegg = true,
  halloffame = true,
  credits = true,
  catchtutorial = true,
  elevator = true,
}

--- @param host the game, which supplies the world the script acts on
function vm.new(host, code)
  return setmetatable({
    host = host,
    code = code or {},
    bank = nil,
    pc = nil,
    stack = {},
    carry = false,
    value = 0,
    -- What the engine has to deal with before the script can go on.
    pending = nil,
    status = "idle",
    steps = 0,
    -- Commands that were reached but not implemented, so coverage can be
    -- reported rather than guessed at.
    ignored = {},
  }, VM)
end

function VM:instruction()
  local bank = self.code[self.bank]
  return bank and bank[self.pc]
end

--- Point the interpreter at a script and make it ready to run.
function VM:start(bank, addr)
  self.bank, self.pc = bank, addr
  self.stack = {}
  self.carry = false
  self.value = 0
  self.pending = nil
  self.steps = 0
  self.ignored = {}
  self.said_something = false
  self.ended_by = nil
  self.status = self:instruction() and "running" or "no script"
  return self.status == "running"
end

--- Jump, but only somewhere that was actually decoded.
--
-- A target can be missing for honest reasons: the operand is not a valid
-- address, or it is a far call into a bank the decoder declined. Landing there
-- anyway leaves the interpreter reading nothing, which used to be reported as
-- "lost" and looked like a decoder bug rather than a script doing something we
-- do not follow.
-- @return true when the jump was taken
function VM:jump(bank, addr, op)
  bank = bank or self.bank
  local block = addr and self.code[bank]
  if not block or not block[addr] then
    self.status = "ended"
    self.ended_by = op and (op .. " into undecoded ground") or "a bad jump"
    return false
  end
  self.bank, self.pc = bank, addr
  return true
end

--- Step to the next instruction in sequence, if there is one to step to.
--
-- The command after this one is missing when the decoder could not read it --
-- an opcode outside the table stops decoding, and the byte after the last good
-- command is never recorded. Ending here names that; letting the program
-- counter land on nothing reports it as the interpreter losing its place,
-- which is a different and much more alarming thing.
function VM:advance()
  local at = self.next_pc
  local block = self.code[self.bank]
  if not block or not block[at] then
    self.status = "ended"
    self.ended_by = "the next command could not be read"
    return
  end
  self.pc = at
end

function VM:call(bank, addr, op)
  self.stack[#self.stack + 1] = { bank = self.bank, pc = self.next_pc }
  if not self:jump(bank, addr, op) then
    table.remove(self.stack)
    return false
  end
  return true
end

function VM:ret()
  local frame = table.remove(self.stack)
  if not frame then
    self.status = "ended"
    return
  end
  -- The return address can be undecoded when the command after the call was
  -- one the decoder could not read, so it gets the same check a jump does.
  self:jump(frame.bank, frame.pc, "returning")
end

-- Two-byte little-endian operand at `index` within the args.
local function word(instruction, index)
  local args = instruction.args
  return (args[index] or 0) + (args[index + 1] or 0) * 256
end

--- One instruction. Sets self.status and self.pending as needed.
function VM:step()
  local instruction = self:instruction()
  if not instruction then
    self.status = "lost"
    self.lost_at = ("bank %s pc %s after %s"):format(tostring(self.bank),
      self.pc and ("$%04X"):format(self.pc) or "nil", tostring(self.last_op))
    return
  end
  self.last_op = instruction.op

  local op = instruction.op
  self.next_pc = self.pc + instruction.size
  local host = self.host

  -- Control flow ----------------------------------------------------------
  if op == "end" or op == "endall" or op == "endcallback"
    or op == "reloadend" then
    -- A plain end returns to the caller if there is one, the way a called
    -- script hands control back.
    if op == "end" and #self.stack > 0 then
      self:ret()
    else
      self.status = "ended"
    end
    return
  end

  if op == "sjump" or op == "farsjump" or op == "stopandsjump" then
    self:jump(instruction.target_bank, instruction.target, op)
    return
  end

  if op == "scall" or op == "farscall" then
    self:call(instruction.target_bank, instruction.target, op)
    return
  end

  if op == "iftrue" or op == "iffalse" then
    local take = (op == "iftrue") == (self.carry == true)
    if take and instruction.target then
      self:jump(instruction.target_bank, instruction.target, op)
    else
      self:advance()
    end
    return
  end

  if op == "ifequal" or op == "ifnotequal" or op == "ifgreater"
    or op == "ifless" then
    local operand = instruction.args[1] or 0
    local take
    if op == "ifequal" then
      take = self.value == operand
    elseif op == "ifnotequal" then
      take = self.value ~= operand
    elseif op == "ifgreater" then
      take = self.value > operand
    else
      take = self.value < operand
    end
    if take and instruction.target then
      self:jump(instruction.target_bank, instruction.target, op)
    else
      self:advance()
    end
    return
  end

  -- Text ------------------------------------------------------------------
  if op == "writetext" or op == "farwritetext" then
    if instruction.text then
      self.pending = { kind = "text", pages = instruction.text }
      self.status = "waiting"
      self.said_something = true
    end
    self:advance()
    return
  end

  if op == "jumptext" or op == "farjumptext" or op == "jumptextfaceplayer" then
    if op == "jumptextfaceplayer" and host and host.face_player then
      host:face_player()
    end
    -- These end the script once the text is done. Where the text did not
    -- decode there is nothing to wait for, so the script simply ends.
    if instruction.text then
      self.pending = { kind = "text", pages = instruction.text }
      self.status = "waiting"
      self.said_something = true
      self.pc = nil
      self.finish_after_text = true
    else
      self.status = "ended"
      self.ended_by = op .. " with no readable text"
    end
    return
  end

  if op == "waitbutton" or op == "promptbutton" then
    self.pending = { kind = "prompt" }
    self.status = "waiting"
    self:advance()
    return
  end

  if op == "opentext" or op == "closetext" or op == "closewindow" then
    -- The engine owns the text box, and it opens one when there is something
    -- to show. Nothing to do here beyond carrying on.
    self:advance()
    return
  end

  -- Event flags -------------------------------------------------------------
  -- Events and flags are two separate spaces in Gen 2, not two names for one.
  -- Merging them would let event 5 and flag 5 collide, which would show up as
  -- a script taking the wrong branch long after the mistake was made.
  if op == "checkevent" or op == "checkflag" then
    local space = op == "checkevent" and "event" or "flag"
    self.carry = host and host:script_flag(space, word(instruction, 1)) or false
    self:advance()
    return
  end

  if op == "setevent" or op == "setflag" or op == "clearevent"
    or op == "clearflag" then
    local space = (op == "setevent" or op == "clearevent") and "event" or "flag"
    local on = op == "setevent" or op == "setflag"
    if host then host:set_script_flag(space, word(instruction, 1), on) end
    self:advance()
    return
  end

  -- The working register --------------------------------------------------
  if op == "setval" then
    self.value = instruction.args[1] or 0
    self:advance()
    return
  end

  if op == "addval" then
    self.value = (self.value + (instruction.args[1] or 0)) % 256
    self:advance()
    return
  end

  if op == "random" then
    local bound = instruction.args[1] or 1
    self.value = bound > 0 and math.random(0, bound - 1) or 0
    self:advance()
    return
  end

  -- Items and money -------------------------------------------------------
  if op == "checkitem" then
    self.carry = host and host:script_has_item(instruction.args[1] or 0) or false
    self:advance()
    return
  end

  if op == "giveitem" or op == "verbosegiveitem" then
    local item = instruction.args[1] or 0
    local quantity = instruction.args[2] or 1
    self.carry = host and host:script_give_item(item, quantity, op ==
      "verbosegiveitem") or false
    self:advance()
    return
  end

  if op == "takeitem" then
    self.carry = host and host:script_take_item(instruction.args[1] or 0,
      instruction.args[2] or 1) or false
    self:advance()
    return
  end

  if op == "pocketisfull" then
    self.carry = host and host:script_pocket_full() or false
    self:advance()
    return
  end

  -- Money is three bytes, big-endian, after a one-byte account selector.
  if op == "givemoney" or op == "takemoney" or op == "checkmoney" then
    local args = instruction.args
    local amount = (args[2] or 0) * 65536 + (args[3] or 0) * 256 + (args[4] or 0)
    if op == "givemoney" then
      if host then host:script_add_money(amount) end
    elseif op == "takemoney" then
      if host then host:script_add_money(-amount) end
    else
      self.carry = host and host:script_money() >= amount or false
    end
    self:advance()
    return
  end

  if op == "faceplayer" then
    if host and host.face_player then host:face_player() end
    self:advance()
    return
  end

  -- Anything left ---------------------------------------------------------
  if vm.REFUSED[op] then
    self.status = "unsupported"
    self.stopped_on = op
    return
  end

  -- A command that ends the script has to end it even when we do not implement
  -- what it does. jumpstd is the one that matters: it transfers control into
  -- the standard-script table, which is not decoded, and the decoder stops
  -- after it. Stepping past it lands in bytes that were never decoded, which is
  -- how 621 scripts came to jump into nothing.
  if instruction.ends then
    self.status = "ended"
    self.ended_by = op
    return
  end

  -- Ignored: the world does not change, but the script goes on.
  self.ignored[op] = (self.ignored[op] or 0) + 1
  self:advance()
end

--- Run until the script finishes or needs the engine.
-- @return status: "ended", "waiting", "unsupported", or "lost"
function VM:resume()
  if self.status == "waiting" then
    self.pending = nil
    self.status = "running"
    if self.finish_after_text then
      self.finish_after_text = false
      self.status = "ended"
      return self.status
    end
  end

  while self.status == "running" do
    self.steps = self.steps + 1
    if self.steps > vm.MAX_STEPS then
      self.status = "runaway"
      break
    end
    self:step()
  end

  return self.status
end

vm.VM = VM

return vm
