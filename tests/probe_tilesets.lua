-- Diagnostic: find Crystal's tileset header table and work out its shape.
--
-- A tileset header holds far pointers to LZ-compressed tile graphics, to the
-- 4x4-tile block definitions, and to collision data. Nothing about its stride
-- or location is assumed here.
--
-- The method that worked for sprites works again: find the data first, then
-- find what points at it. Tileset graphics are LZ blocks that decompress to a
-- whole number of tiles, so index those, then look for ROM positions holding a
-- far pointer to one. Real pointers cluster into an arithmetic progression —
-- one hit per header, spaced by the header stride — which reveals both the
-- table and its layout at once.
--
--   love . --probe-tilesets <rom> <report> [<cache>]

local Rom = require("src.rom.rom")
local lz = require("src.rom.lz")
local gfx = require("src.rom.gfx")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

-- A Gen 2 tileset is at most 128 tiles; allow a generous window either side.
local MIN_GFX_BYTES = 0x200
local MAX_GFX_BYTES = 0x1800

--- Offsets whose LZ stream decompresses to a whole number of tiles in range.
-- Cached: the scan is the slow part and every iteration needs the same list.
local function scan_gfx_blocks(rom, cache_path)
  if cache_path then
    local fh = io.open(cache_path, "r")
    if fh then
      local body = fh:read("*a")
      fh:close()
      local chunk = loadstring("return " .. body)
      if chunk then
        local ok, value = pcall(chunk)
        if ok and type(value) == "table" and value.min == MIN_GFX_BYTES then
          log("loaded %d cached graphics blocks", #value.offsets)
          local set = {}
          for _, entry in ipairs(value.offsets) do
            set[entry[1]] = entry[2]
          end
          return set, #value.offsets
        end
      end
    end
  end

  local set = {}
  local list = {}
  local start = os.clock()
  for offset = 0, rom.size - 4 do
    local data = lz.decompress(rom.data, offset)
    if data then
      local size = #data
      if size >= MIN_GFX_BYTES and size <= MAX_GFX_BYTES
        and size % gfx.BYTES_PER_TILE == 0 then
        set[offset] = size
        list[#list + 1] = { offset, size }
      end
    end
  end
  log("scanned for graphics blocks in %.1fs: %d found", os.clock() - start, #list)

  if cache_path then
    local fh = io.open(cache_path, "w")
    if fh then
      local parts = {}
      for i, entry in ipairs(list) do
        parts[i] = ("{%d,%d}"):format(entry[1], entry[2])
      end
      fh:write(("{ min = %d, offsets = { %s } }")
        :format(MIN_GFX_BYTES, table.concat(parts, ",")))
      fh:close()
    end
  end

  return set, #list
end

function probe.run(rom_path, report_path, cache_path)
  report = {}

  local rom, err = Rom.load(rom_path)
  if not rom then
    log("FATAL: %s", err)
    local fh = io.open(report_path, "w")
    if fh then fh:write(table.concat(report, "\n") .. "\n") fh:close() end
    return true
  end

  local gfx_blocks, count = scan_gfx_blocks(rom, cache_path)
  log("graphics-block candidates: %d", count)

  -- Positions in the ROM holding a far pointer to one of those blocks, for
  -- each plausible bank bias.
  for _, bias in ipairs { 0x00, 0x36 } do
    log("\n== pointer hits with bank bias +$%02X ==", bias)

    local hits = {}
    for offset = 0, rom.size - 4 do
      local bank = rom:u8(offset)
      local addr = rom:u16le(offset + 1)
      if addr >= 0x4000 and addr <= 0x7FFF then
        local flat = (bank + bias) * 0x4000 + (addr - 0x4000)
        if gfx_blocks[flat] then
          hits[#hits + 1] = offset
        end
      end
    end
    log("  %d positions point at a graphics block", #hits)

    if #hits >= 8 then
      -- Which spacing recurs? The header stride shows up as the dominant gap
      -- between consecutive hits inside the table.
      local gaps = {}
      for i = 2, #hits do
        local gap = hits[i] - hits[i - 1]
        if gap > 0 and gap <= 64 then
          gaps[gap] = (gaps[gap] or 0) + 1
        end
      end

      local ranked = {}
      for gap, n in pairs(gaps) do
        ranked[#ranked + 1] = { gap = gap, n = n }
      end
      table.sort(ranked, function(a, b) return a.n > b.n end)

      local summary = {}
      for i = 1, math.min(#ranked, 6) do
        summary[#summary + 1] = ("%d bytes x%d"):format(ranked[i].gap, ranked[i].n)
      end
      log("  most common spacings: %s", table.concat(summary, ", "))

      -- Longest run at the dominant spacing.
      if ranked[1] then
        local stride = ranked[1].gap
        local best = { length = 0 }
        local i = 1
        while i <= #hits do
          local length = 1
          while i + length <= #hits and hits[i + length] - hits[i + length - 1] == stride do
            length = length + 1
          end
          if length > best.length then
            best = { length = length, start = hits[i] }
          end
          i = i + length
        end

        log("  longest run at %d-byte stride: %d entries starting 0x%06X (bank $%02X)",
          stride, best.length, best.start, math.floor(best.start / 0x4000))

        if best.length >= 4 then
          log("\n  first headers:")
          for e = 0, math.min(best.length - 1, 7) do
            local at = best.start + e * stride
            local bank = rom:u8(at)
            local addr = rom:u16le(at + 1)
            local flat = (bank + bias) * 0x4000 + (addr - 0x4000)
            local size = gfx_blocks[flat]

            -- Dump the whole header so the other fields are visible.
            local raw = {}
            for i2 = 0, stride - 1 do
              raw[#raw + 1] = ("%02X"):format(rom:u8(at + i2))
            end
            log("    %2d @ 0x%06X  gfx 0x%06X %4d bytes (%3d tiles)  | %s",
              e, at, flat, size, size / gfx.BYTES_PER_TILE,
              table.concat(raw, " "))
          end
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
