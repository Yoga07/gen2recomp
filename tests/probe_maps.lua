-- Diagnostic: find Crystal's map headers.
--
-- Gen 2 splits a map's description in two. A nine-byte header names the tileset
-- and environment and points at a twelve-byte attributes record, which carries
-- the dimensions, the block data, the scripts and the connections. Headers are
-- stored contiguously per map group, so they form long runs.
--
-- No offsets are assumed. The two records validate each other: a header is only
-- credible if the attributes record it points at has sane dimensions and a
-- block-data pointer that resolves, and an attributes record is only credible
-- if its block data fits in the ROM. Chaining those two checks and demanding a
-- long run of them is enough to find the table.
--
--   love . --probe-maps <rom> <report>

local Rom = require("src.rom.rom")
local tilesets = require("src.rom.tilesets")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

local HEADER_SIZE = 9
local ATTRIBUTES_SIZE = 12

-- Crystal's largest maps are well under this; the ceiling only needs to reject
-- nonsense, not be tight.
local MAX_DIMENSION = 64

local function far(rom, bank, addr)
  if addr < 0x4000 or addr > 0x7FFF then
    return nil
  end
  local flat = bank * 0x4000 + (addr - 0x4000)
  if flat < 0 or flat >= rom.size then
    return nil
  end
  return flat
end

local function attributes_valid(rom, offset)
  if offset + ATTRIBUTES_SIZE > rom.size then
    return nil
  end

  local height = rom:u8(offset + 1)
  local width = rom:u8(offset + 2)
  if height < 1 or height > MAX_DIMENSION then
    return nil
  end
  if width < 1 or width > MAX_DIMENSION then
    return nil
  end

  local block_data = far(rom, rom:u8(offset + 3), rom:u16le(offset + 4))
  if not block_data or block_data + width * height > rom.size then
    return nil
  end

  local scripts = far(rom, rom:u8(offset + 6), rom:u16le(offset + 7))
  if not scripts then
    return nil
  end

  -- The event pointer shares the script bank.
  local events = far(rom, rom:u8(offset + 6), rom:u16le(offset + 9))
  if not events then
    return nil
  end

  -- Connections is a four-bit mask: north, south, west, east.
  local connections = rom:u8(offset + 11)
  if connections > 0x0F then
    return nil
  end

  return {
    border_block = rom:u8(offset),
    height = height,
    width = width,
    block_data = block_data,
    scripts = scripts,
    events = events,
    connections = connections,
  }
end

local function header_valid(rom, offset, tileset_count)
  if offset + HEADER_SIZE > rom.size then
    return nil
  end

  local tileset = rom:u8(offset + 1)
  if tileset < 1 or tileset > tileset_count then
    return nil
  end

  -- Environment: town, route, indoor, cave, gate, dungeon and a couple more.
  local environment = rom:u8(offset + 2)
  if environment > 8 then
    return nil
  end

  local attributes_at = far(rom, rom:u8(offset), rom:u16le(offset + 3))
  if not attributes_at then
    return nil
  end

  local attributes = attributes_valid(rom, attributes_at)
  if not attributes then
    return nil
  end

  return {
    offset = offset,
    tileset = tileset,
    environment = environment,
    attributes_at = attributes_at,
    attributes = attributes,
    location = rom:u8(offset + 5),
    music = rom:u8(offset + 6),
    palette_flag = rom:u8(offset + 7),
    fishing_group = rom:u8(offset + 8),
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
  local tileset_count = tileset_result and tileset_result.count or 40
  log("using %d tilesets as the upper bound on tileset ids", tileset_count)

  -- Longest runs of consecutive valid headers.
  local runs = {}
  local offset = 0
  while offset <= rom.size - HEADER_SIZE do
    if header_valid(rom, offset, tileset_count) then
      local start = offset
      local count = 0
      while offset <= rom.size - HEADER_SIZE
        and header_valid(rom, offset, tileset_count) do
        count = count + 1
        offset = offset + HEADER_SIZE
      end
      if count >= 4 then
        runs[#runs + 1] = { offset = start, count = count }
      end
    else
      offset = offset + 1
    end
  end

  table.sort(runs, function(a, b) return a.count > b.count end)

  log("\n%d runs of at least 4 consecutive headers", #runs)

  local total = 0
  for _, run in ipairs(runs) do
    total = total + run.count
  end
  log("covering %d headers in total", total)

  for i = 1, math.min(#runs, 12) do
    local run = runs[i]
    log("\n  run %d: 0x%06X (bank $%02X), %d headers",
      i, run.offset, math.floor(run.offset / 0x4000), run.count)

    for e = 0, math.min(run.count - 1, 4) do
      local header = header_valid(rom, run.offset + e * HEADER_SIZE, tileset_count)
      local a = header.attributes
      log("    tileset %2d env %d  %2dx%-2d blocks  data 0x%06X  conn $%X",
        header.tileset, header.environment, a.width, a.height,
        a.block_data, a.connections)
    end
  end

  -- Do the block ids in the block data actually fit the tileset they name?
  -- This is the check that says the two structures were read consistently.
  if runs[1] and tileset_result then
    log("\n== block ids against tileset block counts ==")
    local checked, clean = 0, 0
    for i = 1, math.min(#runs, 40) do
      local run = runs[i]
      for e = 0, run.count - 1 do
        local header = header_valid(rom, run.offset + e * HEADER_SIZE, tileset_count)
        local tileset = tileset_result.headers[header.tileset]
        if tileset then
          checked = checked + 1
          local a = header.attributes
          local highest = -1
          for b = 0, a.width * a.height - 1 do
            local id = rom:u8(a.block_data + b)
            if id > highest then
              highest = id
            end
          end
          if highest < tileset.block_count then
            clean = clean + 1
          end
        end
      end
    end
    log("  %d of %d maps use only block ids their tileset defines", clean, checked)
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
