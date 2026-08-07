-- Diagnostic: work out the layout of Crystal's map event headers.
--
-- Each map's attributes record already gives us a pointer to its event header.
-- The header is four counted arrays in a fixed order — warps, coordinate
-- triggers, background events (signposts), then object events (NPCs) — each
-- preceded by a one-byte count, with some filler at the front.
--
-- The order is not in doubt. The record sizes are. Rather than guess, try every
-- plausible combination and score it: a correct layout puts every warp and
-- every NPC at coordinates that fall inside the map's own dimensions, and a
-- wrong one desynchronises the parse so later arrays land on garbage. With 384
-- maps to test against, only one combination should survive.
--
-- Coordinates are in tiles and a block is 2x2 tiles, so a map's walkable extent
-- is twice its block dimensions. Object coordinates are stored with 4 added.
--
--   love . --probe-events <rom> <report>

local Rom = require("src.rom.rom")
local tilesets = require("src.rom.tilesets")
local maps = require("src.rom.maps")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

local MAX_COUNT = 64      -- no Gen 2 map has anywhere near this many of anything
local OBJECT_COORD_BIAS = 4

--- Try to parse one map's event header under a candidate layout.
-- @return table of counts, or nil plus the reason it failed
local function parse(rom, header, layout)
  local attributes = header.attributes
  local tile_height = attributes.height * 2
  local tile_width = attributes.width * 2

  local at = attributes.events + layout.filler

  local function take_count()
    if at + 1 > rom.size then
      return nil
    end
    local n = rom:u8(at)
    at = at + 1
    if n > MAX_COUNT then
      return nil
    end
    return n
  end

  local function in_bounds(y, x, bias)
    bias = bias or 0
    return y >= bias and y < tile_height + bias
       and x >= bias and x < tile_width + bias
  end

  -- Warps: y, x, destination warp id, destination map group and number.
  local warps = take_count()
  if not warps then
    return nil, "warp count"
  end
  for i = 1, warps do
    if at + 5 > rom.size then
      return nil, "warp overruns ROM"
    end
    if not in_bounds(rom:u8(at), rom:u8(at + 1)) then
      return nil, ("warp %d out of bounds"):format(i)
    end
    at = at + 5
  end

  -- Coordinate triggers and background events are counted but their internal
  -- layout is not checked here; only their size matters for staying in sync.
  local coords = take_count()
  if not coords then
    return nil, "coord count"
  end
  at = at + coords * layout.coord

  local bg = take_count()
  if not bg then
    return nil, "bg count"
  end
  at = at + bg * layout.bg

  -- Object events. If any earlier size was wrong the parse is desynchronised by
  -- now and these coordinates will be nonsense, which is what makes this the
  -- discriminating check.
  local objects = take_count()
  if not objects then
    return nil, "object count"
  end
  for i = 1, objects do
    if at + layout.object > rom.size then
      return nil, "object overruns ROM"
    end
    if not in_bounds(rom:u8(at + 1), rom:u8(at + 2), OBJECT_COORD_BIAS) then
      return nil, ("object %d out of bounds"):format(i)
    end
    at = at + layout.object
  end

  return {
    warps = warps, coords = coords, bg = bg, objects = objects,
    size = at - attributes.events,
  }
end

function probe.run(rom_path, report_path)
  report = {}

  local rom, err = Rom.load(rom_path)
  if not rom then
    log("FATAL: %s", err)
    local fh = io.open(report_path, "w")
    if fh then fh:write(table.concat(report, "\n") .. "\n") fh:close() end
    return true
  end

  local tileset_result = tilesets.locate(rom)
  local map_result = maps.locate(rom, tileset_result.count)
  log("testing against %d maps", #map_result.headers)

  local results = {}
  for _, filler in ipairs { 0, 2 } do
    for _, coord in ipairs { 6, 7, 8 } do
      for _, bg in ipairs { 4, 5 } do
        for _, object in ipairs { 12, 13, 14 } do
          local layout = { filler = filler, coord = coord, bg = bg, object = object }
          local ok, total_objects, total_warps = 0, 0, 0
          for _, header in ipairs(map_result.headers) do
            local counts = parse(rom, header, layout)
            if counts then
              ok = ok + 1
              total_objects = total_objects + counts.objects
              total_warps = total_warps + counts.warps
            end
          end
          results[#results + 1] = {
            layout = layout, ok = ok,
            objects = total_objects, warps = total_warps,
          }
        end
      end
    end
  end

  table.sort(results, function(a, b) return a.ok > b.ok end)

  log("\n== layouts ranked by maps parsed cleanly ==")
  log("  %-6s %-6s %-4s %-7s %6s  %7s %7s",
    "filler", "coord", "bg", "object", "maps", "warps", "objects")
  for i = 1, math.min(#results, 10) do
    local r = results[i]
    log("  %-6d %-6d %-4d %-7d %6d  %7d %7d",
      r.layout.filler, r.layout.coord, r.layout.bg, r.layout.object,
      r.ok, r.warps, r.objects)
  end

  -- Detail for the winner.
  local best = results[1]
  if best and best.ok > 0 then
    log("\n== sample maps under the best layout ==")
    local shown = 0
    for _, header in ipairs(map_result.headers) do
      local counts = parse(rom, header, best.layout)
      if counts and counts.objects > 0 and shown < 10 then
        shown = shown + 1
        log("  %2dx%-2d blocks  events 0x%06X  %d warps, %d triggers, " ..
          "%d signposts, %d objects  (%d bytes)",
          header.attributes.width, header.attributes.height,
          header.attributes.events, counts.warps, counts.coords,
          counts.bg, counts.objects, counts.size)
      end
    end

    local failures = 0
    for _, header in ipairs(map_result.headers) do
      if not parse(rom, header, best.layout) then
        failures = failures + 1
      end
    end
    log("\n  %d of %d maps fail under the best layout",
      failures, #map_result.headers)

    -- Where inside each record does the script pointer live? Read every byte
    -- offset as a 16-bit little-endian word and count how often it lands in the
    -- switchable bank window. A real pointer field is valid essentially always;
    -- coordinate and flag bytes are not.
    log("\n== locating script pointers within each record ==")

    local function pointer_profile(kind, record_size)
      local totals, counts = {}, 0
      for i = 0, record_size - 2 do
        totals[i] = 0
      end

      for _, header in ipairs(map_result.headers) do
        local parsed = parse(rom, header, best.layout)
        if parsed then
          -- Re-walk to the array we care about.
          local at = header.attributes.events + best.layout.filler
          at = at + 1 + parsed.warps * 5
          local coord_at = at + 1
          at = coord_at + parsed.coords * best.layout.coord
          local bg_at = at + 1
          at = bg_at + parsed.bg * best.layout.bg
          local object_at = at + 1

          local base, n
          if kind == "warp" then
            base, n = header.attributes.events + best.layout.filler + 1, parsed.warps
          elseif kind == "coord" then
            base, n = coord_at, parsed.coords
          elseif kind == "bg" then
            base, n = bg_at, parsed.bg
          else
            base, n = object_at, parsed.objects
          end

          for record = 0, n - 1 do
            counts = counts + 1
            for i = 0, record_size - 2 do
              local word = rom:u16le(base + record * record_size + i)
              if word >= 0x4000 and word <= 0x7FFF then
                totals[i] = totals[i] + 1
              end
            end
          end
        end
      end

      local parts = {}
      for i = 0, record_size - 2 do
        parts[#parts + 1] = ("%d:%d%%"):format(i,
          counts > 0 and math.floor(totals[i] / counts * 100) or 0)
      end
      log("  %-7s (%2d bytes, %4d records): %s",
        kind, record_size, counts, table.concat(parts, " "))
    end

    pointer_profile("warp", 5)
    pointer_profile("coord", best.layout.coord)
    pointer_profile("bg", best.layout.bg)
    pointer_profile("object", best.layout.object)
  end

  rom:release()

  local fh = io.open(report_path, "w")
  if fh then
    fh:write(table.concat(report, "\n") .. "\n")
    fh:close()
  end
  return true
end

return probe
