-- Byte and bit helpers shared by the ROM decoders.
--
-- LOVE ships LuaJIT, so the `bit` library is available and is a lot faster than
-- arithmetic emulation. We still keep the surface small so the decoders read
-- like the hardware documentation they were written from.

local bit = require("bit")

local bytes = {}

bytes.band = bit.band
bytes.bor = bit.bor
bytes.bxor = bit.bxor
bytes.lshift = bit.lshift
bytes.rshift = bit.rshift

-- Reverse the bit order within a byte. Used by the LZ "flip" copy command,
-- which mirrors previously emitted graphics data horizontally.
local reverse_lut = {}
for b = 0, 255 do
  local r = 0
  for i = 0, 7 do
    if bit.band(b, bit.lshift(1, i)) ~= 0 then
      r = bit.bor(r, bit.lshift(1, 7 - i))
    end
  end
  reverse_lut[b] = r
end

function bytes.reverse_bits(b)
  return reverse_lut[b]
end

-- Read a byte from a 1-indexed Lua string at a 0-based ROM offset.
function bytes.u8(str, offset)
  return string.byte(str, offset + 1)
end

-- Little-endian 16-bit read. The SM83 is little-endian for everything except
-- the LZ back-reference offsets, which are big-endian.
function bytes.u16le(str, offset)
  local lo = string.byte(str, offset + 1)
  local hi = string.byte(str, offset + 2)
  return lo + hi * 256
end

function bytes.u16be(str, offset)
  local hi = string.byte(str, offset + 1)
  local lo = string.byte(str, offset + 2)
  return hi * 256 + lo
end

-- Format a 0-based ROM offset the way a debugger would: bank:address.
function bytes.hex_offset(offset)
  local bank = math.floor(offset / 0x4000)
  local addr = offset % 0x4000
  if bank > 0 then
    addr = addr + 0x4000
  end
  return string.format("%02X:%04X", bank, addr)
end

return bytes
