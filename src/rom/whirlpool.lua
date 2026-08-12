-- Which collision value is a whirlpool.
--
-- This was open for a long time, and the earlier note said why: about two dozen
-- values are water, and nothing about a value's number distinguishes one of
-- them. Asking "which of these is the whirlpool" has no answer, because the
-- question is about the value rather than about what it does.
--
-- What a whirlpool must be is three things, and they can all be measured:
--
--   rare      you need Whirlpool in a handful of places, not everywhere
--   isolated  it is one cell sitting in water, not a stretch of coastline
--   in water  it has water on opposite sides, because you cross it
--
-- Measured across every water value on every map, exactly one satisfies all
-- three, and it is not close. The full table is in `--probe-whirlpool`; the
-- part that matters is the second column:
--
--   value  cells  maps  clusters  mean cluster  in a channel
--    $21      64     2        18          3.6            0%
--    $23     714    13        29         24.6            0%
--    $24      29     4        29          1.0           89%
--    $27    1809    47       250          7.2           43%
--    $29   11263    73       496         22.7            2%
--    $33      18     4         6          3.0            0%
--
-- **$24 is the only value whose every occurrence is a single isolated cell** —
-- 29 cells in 29 clusters — and the only rare one that sits in open water. $32
-- also has mean cluster size 1, on three cells, but none of them has water on
-- both sides, so it is not something you would ever cross.
--
-- ## The measure is a fit; the art is the evidence
--
-- All of the above is a statistic about where a value sits, and this section of
-- the notes exists because that kind of statistic has produced two confident
-- wrong answers already: the cut tree that "gated a path" 62% of the time was a
-- fence, and the obstacle detector's first answer was the Pokémon Centre nurse.
-- Both were caught by rendering the thing and looking at it.
--
-- So that is what settled this. Rendering every block that carries each
-- candidate value shows $21 as the pier at Olivine, $23 as plain water and
-- indoor tiling, $33 as a wave pattern — and **$24 as a spiral**. One block, one
-- swirl, in the two tilesets the sea routes use. A whirlpool looks like a
-- whirlpool, and nothing else here does.
--
-- The value is still *found* rather than written down, so Gold and Silver work
-- from the same code, and the locator refuses if more than one value qualifies.

local collision = require("src.rom.collision")
local tilesets = require("src.rom.tilesets")
local maps = require("src.rom.maps")

local whirlpool = {}

-- A whirlpool is needed in a few places. Well above the four Crystal uses, and
-- well below the 47 and 73 that ordinary water manages.
whirlpool.MAX_MAPS = 20

-- Every occurrence must stand alone: clusters must equal cells exactly. This is
-- the sharp one, and it is a ratio rather than a threshold.
whirlpool.MAX_CLUSTER = 1

-- And most of them must have water on opposite sides, because a whirlpool is
-- something you cross rather than something at the edge of the map. $24 scores
-- 89%; the only other single-cell value scores 0.
whirlpool.MIN_IN_CHANNEL = 0.5

--- Connected regions among cells the predicate accepts.
local function components(width, height, accept)
  local seen, count, stack = {}, 0, {}
  for cy = 0, height - 1 do
    for cx = 0, width - 1 do
      local key = cy * width + cx
      if not seen[key] and accept(cx, cy) then
        count = count + 1
        seen[key] = true
        stack[#stack + 1] = key
        while #stack > 0 do
          local at = table.remove(stack)
          local x, y = at % width, math.floor(at / width)
          local function push(nx, ny)
            if nx >= 0 and ny >= 0 and nx < width and ny < height then
              local next_key = ny * width + nx
              if not seen[next_key] and accept(nx, ny) then
                seen[next_key] = true
                stack[#stack + 1] = next_key
              end
            end
          end
          push(x - 1, y) push(x + 1, y) push(x, y - 1) push(x, y + 1)
        end
      end
    end
  end
  return count
end

--- Measure every water value across every map.
-- @return { [value] = { cells, maps, clusters, in_channel } }
function whirlpool.survey(rom, tileset_result, map_result)
  local sets = {}
  for index = 1, tileset_result.count do
    local header = tileset_result.headers[index]
    if header then
      sets[index] = tilesets.decode_collision(rom, header)
    end
  end

  local stat = {}
  local function record_for(value)
    stat[value] = stat[value] or
      { cells = 0, maps = 0, clusters = 0, in_channel = 0 }
    return stat[value]
  end

  for _, header in ipairs(map_result.headers) do
    if not header.unparsed and header.attributes then
      local set = sets[header.tileset]
      local blocks = maps.decode_block_data(rom, header)
      if set and blocks then
        local width = header.attributes.width * 2
        local height = header.attributes.height * 2

        local grid = {}
        for cy = 0, height - 1 do
          for cx = 0, width - 1 do
            local row = blocks[math.floor(cy / 2) + 1]
            local block = row and row[math.floor(cx / 2) + 1]
            local quadrant = (cy % 2) * 2 + (cx % 2)
            local entry = block and set[block + 1]
            grid[cy * width + cx] = entry and entry[quadrant + 1]
          end
        end

        local function at(cx, cy)
          if cx < 0 or cy < 0 or cx >= width or cy >= height then
            return nil
          end
          return grid[cy * width + cx]
        end

        local present = {}
        for cy = 0, height - 1 do
          for cx = 0, width - 1 do
            local value = at(cx, cy)
            if value and collision.is_water(value) then
              present[value] = (present[value] or 0) + 1
            end
          end
        end

        for value, count in pairs(present) do
          local record = record_for(value)
          record.cells = record.cells + count
          record.maps = record.maps + 1
          record.clusters = record.clusters + components(width, height,
            function(cx, cy) return at(cx, cy) == value end)

          for cy = 0, height - 1 do
            for cx = 0, width - 1 do
              if at(cx, cy) == value then
                local function wet(nx, ny)
                  local other = at(nx, ny)
                  return other ~= nil and other ~= value
                    and collision.is_water(other)
                end
                if (wet(cx - 1, cy) and wet(cx + 1, cy))
                  or (wet(cx, cy - 1) and wet(cx, cy + 1)) then
                  record.in_channel = record.in_channel + 1
                end
              end
            end
          end
        end
      end
    end
  end

  return stat
end

--- Which water value is the whirlpool.
-- @return { value = n, cells, maps, survey = {...} } or nil plus a reason
function whirlpool.locate(rom, tileset_result, map_result)
  local stat = whirlpool.survey(rom, tileset_result, map_result)

  local accepted = {}
  for value, record in pairs(stat) do
    if record.cells > 0
      and record.maps <= whirlpool.MAX_MAPS
      and record.clusters >= record.cells * whirlpool.MAX_CLUSTER
      and record.in_channel >= record.cells * whirlpool.MIN_IN_CHANNEL then
      accepted[#accepted + 1] = value
    end
  end

  if #accepted == 0 then
    return nil, "no water value is rare, isolated and surrounded by water"
  end
  if #accepted > 1 then
    local places = {}
    table.sort(accepted)
    for _, value in ipairs(accepted) do
      places[#places + 1] = ("$%02X"):format(value)
    end
    return nil, ("%d water values look like a whirlpool (%s); refusing to guess")
      :format(#accepted, table.concat(places, ", "))
  end

  local value = accepted[1]
  return {
    value = value,
    cells = stat[value].cells,
    maps = stat[value].maps,
    survey = stat,
  }
end

return whirlpool
