-- What a collision value means.
--
-- Each tileset stores four collision bytes per block, one per movement
-- quadrant. The values are global constants describing terrain rather than
-- per-tileset ids.
--
-- This replaces a provisional rule that treated $07 as wall and everything else
-- as walkable. That rule reported 58% of every map as passable, which was far
-- too generous: water, ledges, counters and cut trees are all distinct values
-- and none of them are simply walkable.
--
-- It also explains the anomaly that rule could not. A survey of what the game's
-- NPCs stand on found 466 of them apparently on $07, seemingly contradicting it
-- being a wall. The answer is that NPCs are placed on furniture and counter
-- tiles ($90-$9F) and behind blocking terrain all the time — a shop clerk
-- stands behind a counter, not on the floor — so "an NPC is here" was never
-- evidence that a tile is walkable in the first place.
--
-- Values are from pokecrystal's collision constants; which tiles carry them is
-- read from the cartridge.

local collision = {}

local function span(from, to, kind, into)
  for value = from, to do
    into[value] = kind
  end
end

-- kind -> how the player may occupy the tile.
collision.FLOOR = "floor"
collision.GRASS = "grass"          -- floor, and rolls for a wild encounter
collision.WATER = "water"          -- needs Surf; blocking on foot
collision.LEDGE = "ledge"          -- one-way hop down
collision.WARP = "warp"            -- doors, stairs, ladders
collision.FURNITURE = "furniture"  -- counters, PCs, bookshelves: face, not enter
collision.BLOCK = "block"

local kinds = {}

-- Everything not named below is blocking. Being explicit about what is passable
-- is the safer default: an unrecognised value stops the player rather than
-- letting them walk through scenery.
kinds[0x00] = collision.FLOOR

-- Tall grass, in its several forms. These are floor that rolls for encounters.
kinds[0x10] = collision.GRASS
kinds[0x14] = collision.GRASS
kinds[0x18] = collision.GRASS
kinds[0x1C] = collision.GRASS
span(0x48, 0x4C, collision.GRASS, kinds)

-- Water: whirlpools, ice, currents, buoys.
kinds[0x21] = collision.WATER
kinds[0x23] = collision.WATER
kinds[0x24] = collision.WATER
kinds[0x27] = collision.WATER
kinds[0x29] = collision.WATER
kinds[0x2B] = collision.WATER
kinds[0x2C] = collision.WATER
span(0x30, 0x3B, collision.WATER, kinds)
span(0xC0, 0xC7, collision.WATER, kinds)

-- Directional floor: ice, forced movement, and their alternates. Walkable.
span(0x40, 0x47, collision.FLOOR, kinds)
span(0x50, 0x57, collision.FLOOR, kinds)

-- Doors, warps, stairs, ladders.
span(0x70, 0x7F, collision.WARP, kinds)

-- Counters, shelves, PCs, and the rest of the interior furniture. Faced from
-- an adjacent tile rather than stood on.
span(0x90, 0x9F, collision.FURNITURE, kinds)

-- Ledges, hopped down in one direction only.
span(0xA0, 0xA7, collision.LEDGE, kinds)

collision.kinds = kinds

--- What kind of terrain is this value?
function collision.kind(value)
  return kinds[value] or collision.BLOCK
end

--- May the player stand here on foot?
function collision.walkable(value)
  local kind = collision.kind(value)
  return kind == collision.FLOOR or kind == collision.GRASS
      or kind == collision.WARP or kind == collision.LEDGE
end

--- Does standing here roll for a wild encounter?
function collision.is_grass(value)
  return collision.kind(value) == collision.GRASS
end

function collision.is_water(value)
  return collision.kind(value) == collision.WATER
end

return collision
