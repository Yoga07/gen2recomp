-- ROM container: owns the raw cartridge image and does bank/pointer arithmetic.
--
-- The image lives in memory only for the duration of an import. Nothing here
-- writes ROM bytes to disk; the importer is responsible for turning them into
-- derived assets, and the caller drops the Rom object when it is done.

local bytes = require("src.util.bytes")

local BANK_SIZE = 0x4000

local Rom = {}
Rom.__index = Rom

Rom.BANK_SIZE = BANK_SIZE

--- Load a cartridge image from an arbitrary filesystem path.
-- Uses plain Lua io rather than love.filesystem because the ROM lives wherever
-- the player keeps it, not inside the game's save directory.
-- @return Rom on success, or nil plus an error message.
function Rom.load(path)
  local fh, err = io.open(path, "rb")
  if not fh then
    return nil, ("could not open ROM: %s"):format(err or path)
  end

  local data = fh:read("*a")
  fh:close()

  if not data or #data == 0 then
    return nil, "ROM file is empty"
  end

  if #data % BANK_SIZE ~= 0 then
    return nil, ("ROM size %d is not a multiple of the 16 KiB bank size; " ..
      "this is usually a header-prefixed or truncated dump"):format(#data)
  end

  return setmetatable({
    data = data,
    size = #data,
    banks = #data / BANK_SIZE,
    path = path,
  }, Rom)
end

--- Build a Rom directly from an in-memory image (used by the tests).
function Rom.from_string(data, path)
  return setmetatable({
    data = data,
    size = #data,
    banks = math.floor(#data / BANK_SIZE),
    path = path or "<memory>",
  }, Rom)
end

--- Translate a (bank, CPU address) pair into a flat offset into the image.
--
-- The SM83 sees bank 0 at $0000-$3FFF and the currently switched bank at
-- $4000-$7FFF. Gen 2 data tables store far pointers as a bank byte plus a
-- 16-bit address that is almost always in the switchable window, but bank 0
-- addresses do occur and must not be double-counted.
function Rom:offset(bank, addr)
  if addr < 0x4000 then
    -- A bank-0 address is absolute regardless of what bank byte accompanies it.
    return addr
  end
  if addr > 0x7FFF then
    error(("address $%04X is outside the ROM window"):format(addr), 2)
  end
  return bank * BANK_SIZE + (addr - 0x4000)
end

function Rom:in_bounds(offset, length)
  return offset >= 0 and offset + (length or 1) <= self.size
end

function Rom:u8(offset)
  if not self:in_bounds(offset) then
    error(("read past end of ROM at 0x%06X"):format(offset), 2)
  end
  return bytes.u8(self.data, offset)
end

function Rom:u16le(offset)
  if not self:in_bounds(offset, 2) then
    error(("read past end of ROM at 0x%06X"):format(offset), 2)
  end
  return bytes.u16le(self.data, offset)
end

--- Read a far pointer: one bank byte followed by a little-endian address.
-- Returns the flat offset it designates, plus the raw bank and address so
-- callers can log something meaningful when a pointer looks wrong.
function Rom:far_pointer(offset)
  local bank = self:u8(offset)
  local addr = self:u16le(offset + 1)
  return self:offset(bank, addr), bank, addr
end

--- Read a 2-byte pointer that is implicitly within `bank`.
function Rom:near_pointer(bank, offset)
  local addr = self:u16le(offset)
  return self:offset(bank, addr), addr
end

--- Raw byte slice at a flat offset. Returned as a Lua string.
function Rom:read(offset, length)
  if not self:in_bounds(offset, length) then
    error(("slice [0x%06X, 0x%06X) exceeds ROM size 0x%06X")
      :format(offset, offset + length, self.size), 2)
  end
  return self.data:sub(offset + 1, offset + length)
end

--- Read up to, but not including, a terminator byte. Gen 2 text and several
-- pointer tables are terminated rather than length-prefixed.
function Rom:read_until(offset, terminator, max_length)
  max_length = max_length or 1024
  local out = {}
  for i = 0, max_length - 1 do
    local b = self:u8(offset + i)
    if b == terminator then
      return table.concat(out), i + 1
    end
    out[#out + 1] = string.char(b)
  end
  return table.concat(out), max_length
end

--- Whole-bank slice, for decoders that want to work bank-locally.
function Rom:bank(index)
  if index < 0 or index >= self.banks then
    error(("bank %d out of range (ROM has %d banks)"):format(index, self.banks), 2)
  end
  return self:read(index * BANK_SIZE, BANK_SIZE)
end

--- Drop the reference to the cartridge image. Called once an import finishes so
-- the ROM is not sitting in memory for the rest of the session.
function Rom:release()
  self.data = nil
  self.size = 0
  self.banks = 0
end

return Rom
