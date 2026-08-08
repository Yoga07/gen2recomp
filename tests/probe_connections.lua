-- Diagnostic: check the connection record layout against the maps it names.
--
-- The connection macro is not in the files reachable from the reference, so the
-- field order is reasoned rather than read. It does not have to be taken on
-- trust: byte 7 is the destination map's width in blocks, and the destination
-- map's own header says what its width is. If the layout is right those agree
-- everywhere; if a field is off by one they disagree almost everywhere.
--
-- Byte 7 is tested against every other plausible position so the answer is
-- chosen by evidence rather than assumed.
--
--   love . --probe-connections <rom> <report>

local Rom = require("src.rom.rom")
local tilesets = require("src.rom.tilesets")
local maps = require("src.rom.maps")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
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
  local groups = maps.locate_groups(rom, map_result.headers)

  -- (group, number) -> header, so a connection's destination can be looked up.
  local by_id = {}
  if groups then
    local index_map = maps.group_index(map_result.headers, groups.groups)
    local starts = {}
    for group, start in pairs(index_map) do
      starts[#starts + 1] = { group = group, start = start }
    end
    table.sort(starts, function(a, b) return a.start < b.start end)
    for i, entry in ipairs(starts) do
      local last = starts[i + 1] and starts[i + 1].start - 1 or #map_result.headers
      for index = entry.start, last do
        by_id[entry.group * 256 + (index - entry.start + 1)] =
          map_result.headers[index]
      end
    end
  end

  -- Every connection record in the game, as raw bytes.
  local records = {}
  for _, header in ipairs(map_result.headers) do
    if not header.unparsed then
      local attributes = header.attributes
      local at = attributes.offset + maps.ATTRIBUTES_SIZE
      for _, direction in ipairs(maps.CONNECTION_ORDER) do
        local bit = maps.connection_bits[direction]
        if attributes.connections % (bit * 2) >= bit then
          if at + maps.CONNECTION_SIZE <= rom.size then
            records[#records + 1] = { offset = at, direction = direction }
            at = at + maps.CONNECTION_SIZE
          end
        end
      end
    end
  end

  log("%d connection records across the game", #records)

  -- Which byte position holds the destination map's width? Score each.
  log("\nagreement between each byte and the destination map's real width:")
  for position = 0, maps.CONNECTION_SIZE - 1 do
    local checked, agreed = 0, 0
    for _, record in ipairs(records) do
      local group = rom:u8(record.offset)
      local number = rom:u8(record.offset + 1)
      local destination = by_id[group * 256 + number]
      if destination and not destination.unparsed then
        checked = checked + 1
        if rom:u8(record.offset + position) == destination.attributes.width then
          agreed = agreed + 1
        end
      end
    end
    log("  byte %2d: %d of %d (%d%%)", position, agreed, checked,
      checked > 0 and math.floor(agreed / checked * 100) or 0)
  end

  -- How often the first two bytes name a real map at all, which is what says
  -- the record starts where we think it does.
  local resolvable = 0
  for _, record in ipairs(records) do
    local group = rom:u8(record.offset)
    local number = rom:u8(record.offset + 1)
    if by_id[group * 256 + number] then
      resolvable = resolvable + 1
    end
  end
  log("\n%d of %d records name a map that exists", resolvable, #records)

  -- A sample, decoded.
  log("\nsample connections:")
  local shown = 0
  for _, header in ipairs(map_result.headers) do
    if not header.unparsed and header.attributes.connections ~= 0 and shown < 10 then
      for _, connection in ipairs(maps.decode_connections(rom, header.attributes)) do
        local destination = by_id[connection.group * 256 + connection.number]
        if destination and shown < 10 then
          shown = shown + 1
          log("  %2dx%-2d %-5s -> group %2d map %2d (%dx%d), width field %d, "
            .. "offsets y %d x %d",
            header.attributes.width, header.attributes.height,
            connection.direction, connection.group, connection.number,
            destination.attributes.width, destination.attributes.height,
            connection.width, connection.y_offset, connection.x_offset)
        end
      end
    end
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
