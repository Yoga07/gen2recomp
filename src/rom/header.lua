-- Cartridge header parsing and Gen 2 version identification.
--
-- Every Game Boy cartridge carries a 0x50-byte header at $0100. We use it to
-- work out which game we were handed before touching anything version specific,
-- and to reject dumps that are obviously not a Gen 2 cartridge (wrong mapper,
-- wrong size, copier header still attached).

local Rom = require("src.rom.rom")

local header = {}

local TITLE_OFFSET = 0x134
local TITLE_LENGTH = 11        -- CGB carts shortened the title to make room
local GAME_CODE_OFFSET = 0x13F -- 4 chars, e.g. "AAUE" for Gold (US)
local CGB_FLAG_OFFSET = 0x143
local CART_TYPE_OFFSET = 0x147
local ROM_SIZE_OFFSET = 0x148
local RAM_SIZE_OFFSET = 0x149
local HEADER_CHECKSUM_OFFSET = 0x14D
local GLOBAL_CHECKSUM_OFFSET = 0x14E

-- Gen 2 shipped on MBC3 with a real-time clock; the day/night system and
-- Pokémon breeding both depend on it.
local MBC3_TIMER_RAM_BATTERY = 0x10

local CART_TYPE_NAMES = {
  [0x0F] = "MBC3+TIMER+BATTERY",
  [0x10] = "MBC3+TIMER+RAM+BATTERY",
  [0x11] = "MBC3",
  [0x12] = "MBC3+RAM",
  [0x13] = "MBC3+RAM+BATTERY",
}

--- Decode the ROM-size header byte into a byte count.
-- The encoding is 32 KiB shifted left by the stored value.
local function rom_size_from_code(code)
  if code > 0x08 then
    return nil
  end
  return 0x8000 * (2 ^ code)
end

local RAM_SIZES = {
  [0x00] = 0,
  [0x01] = 2 * 1024,
  [0x02] = 8 * 1024,
  [0x03] = 32 * 1024, -- 4 banks; what Gen 2 uses for its save
  [0x04] = 128 * 1024,
  [0x05] = 64 * 1024,
}

--- Recompute the header checksum the boot ROM verifies.
-- Sum of $0134-$014C, subtracted rather than added, low byte only.
local function compute_header_checksum(rom)
  local sum = 0
  for offset = 0x134, 0x14C do
    sum = (sum - rom:u8(offset) - 1) % 256
  end
  return sum
end

--- Recompute the 16-bit global checksum: every byte except the two that store
-- the checksum itself. Nothing on real hardware checks this, but a mismatch is
-- a strong signal that the dump was trimmed, patched, or over-dumped.
local function compute_global_checksum(rom)
  local sum = 0
  local data = rom.data
  for i = 1, #data do
    sum = sum + string.byte(data, i)
  end
  sum = sum - rom:u8(GLOBAL_CHECKSUM_OFFSET) - rom:u8(GLOBAL_CHECKSUM_OFFSET + 1)
  return sum % 65536
end

local function read_ascii(rom, offset, length)
  local out = {}
  for i = 0, length - 1 do
    local b = rom:u8(offset + i)
    if b == 0 then
      break
    end
    out[#out + 1] = string.char(b)
  end
  return table.concat(out)
end

--- Parse the cartridge header. Returns a table describing the cartridge; it
-- never fails on unusual values, it just reports them so callers can decide.
function header.parse(rom)
  local cart_type = rom:u8(CART_TYPE_OFFSET)
  local rom_size_code = rom:u8(ROM_SIZE_OFFSET)
  local ram_size_code = rom:u8(RAM_SIZE_OFFSET)

  local declared_rom_size = rom_size_from_code(rom_size_code)
  local stored_header_checksum = rom:u8(HEADER_CHECKSUM_OFFSET)
  local stored_global_checksum = rom:u16le(GLOBAL_CHECKSUM_OFFSET)
  -- The global checksum is the one big-endian field in the header.
  stored_global_checksum = rom:u8(GLOBAL_CHECKSUM_OFFSET) * 256
    + rom:u8(GLOBAL_CHECKSUM_OFFSET + 1)

  return {
    title = read_ascii(rom, TITLE_OFFSET, TITLE_LENGTH),
    game_code = read_ascii(rom, GAME_CODE_OFFSET, 4),
    cgb_flag = rom:u8(CGB_FLAG_OFFSET),
    cart_type = cart_type,
    cart_type_name = CART_TYPE_NAMES[cart_type],
    rom_size_code = rom_size_code,
    declared_rom_size = declared_rom_size,
    actual_rom_size = rom.size,
    ram_size_code = ram_size_code,
    ram_size = RAM_SIZES[ram_size_code],
    banks = rom.banks,
    header_checksum = stored_header_checksum,
    header_checksum_ok = stored_header_checksum == compute_header_checksum(rom),
    global_checksum = stored_global_checksum,
    global_checksum_ok = stored_global_checksum == compute_global_checksum(rom),
  }
end

--- Structural sanity checks that apply to any Gen 2 cartridge, independent of
-- which of the three games it is. Returns a list of human-readable problems;
-- an empty list means the dump looks structurally sound.
function header.validate(info)
  local problems = {}

  if info.cart_type ~= MBC3_TIMER_RAM_BATTERY then
    problems[#problems + 1] = ("cartridge type is $%02X (%s), expected $10 " ..
      "MBC3+TIMER+RAM+BATTERY"):format(info.cart_type, info.cart_type_name or "unknown")
  end

  if info.declared_rom_size and info.declared_rom_size ~= info.actual_rom_size then
    problems[#problems + 1] = ("header declares a %d KiB ROM but the file is " ..
      "%d KiB"):format(info.declared_rom_size / 1024, info.actual_rom_size / 1024)
  end

  if not info.header_checksum_ok then
    problems[#problems + 1] = "header checksum does not match; the dump is corrupt or patched"
  end

  if not info.global_checksum_ok then
    problems[#problems + 1] = "global checksum does not match; the dump is modified, " ..
      "trimmed, or over-dumped"
  end

  if info.cgb_flag ~= 0x80 and info.cgb_flag ~= 0xC0 then
    problems[#problems + 1] = ("CGB flag is $%02X; Gen 2 cartridges are Color-aware")
      :format(info.cgb_flag)
  end

  return problems
end

return header
