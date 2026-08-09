-- Movement blocks.
--
-- `applymovement` names an object and points at a little language of its own:
-- one byte per step, ending at $47. That terminator was not assumed -- $47 ends
-- all 307 blocks the scripts point at, within 56 bytes, while $FF (the obvious
-- guess, and the terminator everything else in this cartridge uses) never
-- appears at all. What follows the $47 is usually a text block, which is the
-- other half of the confirmation.
--
-- The commands come in fours, and the direction is the low two bits in the same
-- down-up-left-right order the object events use:
--
--   $00-$03  turn on the spot
--   $04-$07  turn and step
--   $08-$0B  step slowly
--   $0C-$0F  step
--   $10-$13  step quickly
--
-- Only the four common groups carry weight here: what matters to the engine is
-- which way the object ends up facing and where it ends up standing, not how
-- fast it got there.

local movement = {}

movement.END = 0x47
movement.MAX_STEPS = 64

-- Low two bits of a command, in the cartridge's order.
movement.DIRECTIONS = { [0] = "down", "up", "left", "right" }

movement.DELTA = {
  down = { 0, 1 },
  up = { 0, -1 },
  left = { -1, 0 },
  right = { 1, 0 },
}

-- Commands below this are turns and steps, four to a group.
movement.HIGHEST_STEP = 0x13

--- Decode a movement block.
-- @return { steps = { { facing, moves } }, facing, dx, dy, bytes } or nil
function movement.decode(rom, offset)
  if offset >= rom.size then
    return nil, "movement block starts past the ROM"
  end

  local steps = {}
  local dx, dy = 0, 0
  local facing = nil
  local unknown = nil

  for i = 0, movement.MAX_STEPS - 1 do
    local at = offset + i
    if at >= rom.size then
      return nil, "movement block runs past the ROM"
    end

    local code = rom:u8(at)
    if code == movement.END then
      return {
        steps = steps,
        facing = facing,
        dx = dx,
        dy = dy,
        bytes = i + 1,
        unknown = unknown,
      }
    end

    if code > movement.HIGHEST_STEP then
      -- Something outside the step groups. The block is kept up to here rather
      -- than thrown away: what has been read is still true.
      unknown = code
      return {
        steps = steps,
        facing = facing,
        dx = dx,
        dy = dy,
        bytes = i + 1,
        unknown = unknown,
      }
    end

    local direction = movement.DIRECTIONS[code % 4]
    -- The first group turns on the spot; every other group moves a tile.
    local moves = code >= 0x04
    facing = direction

    if moves then
      local delta = movement.DELTA[direction]
      dx = dx + delta[1]
      dy = dy + delta[2]
    end

    steps[#steps + 1] = { facing = direction, moves = moves }
  end

  return nil, "movement block did not end"
end

return movement
