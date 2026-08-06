-- The LZ variant Game Freak used for compressed graphics in Gen 1 and Gen 2.
--
-- The stream is a sequence of commands. Each starts with a control byte whose
-- top three bits select the command and whose low five bits carry a length
-- minus one. Command 7 is an escape: the real command moves down into bits 4-2
-- and the length grows to ten bits, borrowing the control byte's low two bits
-- as the high bits of the count. $FF ends the stream.
--
-- Three of the commands copy from data already emitted, which is what makes
-- this an LZ scheme rather than plain run-length encoding. Their back-reference
-- is either a one-byte offset counted backwards from the write head (high bit
-- set) or a two-byte big-endian offset from the start of the output.

local bytes = require("src.util.bytes")

local lz = {}

local CMD_LITERAL = 0   -- copy the next N bytes verbatim
local CMD_ITERATE = 1   -- repeat one byte N times
local CMD_ALTERNATE = 2 -- repeat a two-byte pattern N times
local CMD_ZERO = 3      -- emit N zero bytes
local CMD_REPEAT = 4    -- copy N bytes already emitted, forwards
local CMD_FLIP = 5      -- same, but with each byte's bits reversed
local CMD_REVERSE = 6   -- same, but walking backwards through the output
local CMD_LONG = 7      -- escape to the 10-bit length form

local TERMINATOR = 0xFF

local MAX_OUTPUT = 0x10000

--- Decompress an LZ stream.
-- @param data   Lua string holding the whole ROM (or any buffer).
-- @param offset 0-based offset of the first control byte.
-- @return decompressed string, number of compressed bytes consumed.
--         On a malformed stream returns nil plus an error message.
function lz.decompress(data, offset)
  local out = {}       -- table of single-character strings, joined at the end
  local out_len = 0
  local pos = offset
  local limit = #data

  local function read()
    if pos >= limit then
      return nil
    end
    local b = string.byte(data, pos + 1)
    pos = pos + 1
    return b
  end

  local function emit(byte_value)
    out_len = out_len + 1
    out[out_len] = string.char(byte_value)
  end

  while true do
    local control = read()
    if not control then
      return nil, ("LZ stream at 0x%06X ran off the end of the ROM"):format(offset)
    end

    if control == TERMINATOR then
      break
    end

    local command = bytes.rshift(control, 5)
    local length

    if command == CMD_LONG then
      -- Long form: command in bits 4-2, length high bits in 1-0.
      command = bytes.band(bytes.rshift(control, 2), 0x07)
      local low = read()
      if not low then
        return nil, ("truncated long-form length at 0x%06X"):format(pos)
      end
      length = bytes.lshift(bytes.band(control, 0x03), 8) + low + 1
    else
      length = bytes.band(control, 0x1F) + 1
    end

    if out_len + length > MAX_OUTPUT then
      return nil, ("LZ stream at 0x%06X expands past %d bytes; " ..
        "the offset is probably not a compressed block"):format(offset, MAX_OUTPUT)
    end

    if command == CMD_LITERAL then
      for _ = 1, length do
        local b = read()
        if not b then
          return nil, ("truncated literal run at 0x%06X"):format(pos)
        end
        emit(b)
      end

    elseif command == CMD_ITERATE then
      local b = read()
      if not b then
        return nil, ("truncated iterate byte at 0x%06X"):format(pos)
      end
      for _ = 1, length do
        emit(b)
      end

    elseif command == CMD_ALTERNATE then
      local b1, b2 = read(), read()
      if not b1 or not b2 then
        return nil, ("truncated alternate pair at 0x%06X"):format(pos)
      end
      for i = 1, length do
        emit(i % 2 == 1 and b1 or b2)
      end

    elseif command == CMD_ZERO then
      for _ = 1, length do
        emit(0)
      end

    elseif command == CMD_REPEAT or command == CMD_FLIP or command == CMD_REVERSE then
      local first = read()
      if not first then
        return nil, ("truncated back-reference at 0x%06X"):format(pos)
      end

      local source
      if bytes.band(first, 0x80) ~= 0 then
        -- One-byte relative offset, counted back from the current write head.
        source = out_len - bytes.band(first, 0x7F) - 1
      else
        local low = read()
        if not low then
          return nil, ("truncated absolute back-reference at 0x%06X"):format(pos)
        end
        source = first * 256 + low
      end

      if source < 0 or source >= out_len then
        return nil, ("back-reference at 0x%06X points outside the %d bytes " ..
          "emitted so far"):format(pos, out_len)
      end

      -- Copies read through the output as it grows, so overlapping runs are
      -- legal and are how the format expresses repeating patterns.
      for i = 0, length - 1 do
        local index
        if command == CMD_REVERSE then
          index = source - i
          if index < 0 then
            return nil, ("reverse copy at 0x%06X walked off the front of the output")
              :format(pos)
          end
        else
          index = source + i
        end

        local b = string.byte(out[index + 1])
        if command == CMD_FLIP then
          b = bytes.reverse_bits(b)
        end
        emit(b)
      end

    else
      return nil, ("unreachable LZ command %d at 0x%06X"):format(command, pos)
    end
  end

  return table.concat(out), pos - offset
end

return lz
