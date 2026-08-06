-- The import pipeline.
--
-- One pass over a player-supplied cartridge: verify it, work out which game it
-- is, find and decode the data tables, write the results to the cache, and drop
-- the image. The cartridge is never copied to disk and is not retained after
-- this returns.

local Rom = require("src.rom.rom")
local header = require("src.rom.header")
local versions = require("src.rom.versions")
local locate = require("src.rom.locate")
local pics = require("src.rom.pics")
local cache = require("src.import.cache")

local importer = {}

--- Hex SHA-1 of the whole image.
local function sha1_hex(data)
  local digest = love.data.hash("sha1", data)
  return (digest:gsub(".", function(c)
    return ("%02x"):format(c:byte())
  end))
end

--- Run an import.
--
-- @param path     filesystem path to the cartridge image
-- @param progress optional function(message) called as work proceeds
-- @return report table on success, or nil plus an error message
function importer.run(path, progress)
  local function step(message)
    if progress then
      progress(message)
    end
  end

  step("reading cartridge")
  local rom, err = Rom.load(path)
  if not rom then
    return nil, err
  end

  step("hashing")
  local sha1 = sha1_hex(rom.data)

  step("parsing header")
  local info = header.parse(rom)
  local problems = header.validate(info)

  local descriptor, why = versions.identify(info, sha1)
  if not descriptor then
    rom:release()
    return nil, why
  end

  step(("identified %s"):format(versions.describe(descriptor)))

  -- Structural problems are reported but not fatal. A ROM with a bad global
  -- checksum is usually a trimmed or lightly patched dump that still decodes
  -- correctly, and refusing it outright would be unhelpful. The tables have
  -- their own validation and will fail if the data really is wrong.
  for _, problem in ipairs(problems) do
    step(("warning: %s"):format(problem))
  end

  step("locating data tables")
  local found, failed = locate.all(rom, step)

  if not next(found) then
    rom:release()
    return nil, "no data tables could be located; this does not look like a " ..
      "Gen 2 cartridge despite its header"
  end

  step("writing cache")
  local ok, cache_err = cache.ensure(descriptor.game)
  if not ok then
    rom:release()
    return nil, cache_err
  end

  local written = {}
  local offsets = {}
  for key, result in pairs(found) do
    local written_path, size = cache.write(descriptor.game, key, result.records)
    if not written_path then
      rom:release()
      return nil, size -- second return is the error message on failure
    end
    written[key] = { path = written_path, bytes = size, count = #result.records }
    offsets[key] = result.offset
  end

  -- Sprites, if the base stats were decoded: their footprints are what makes
  -- the pic table findable and what says where each sprite ends and its
  -- animation frames begin.
  local sprites = { written = 0, failed = 0 }
  if found.base_stats then
    step("locating sprites")
    local stats = found.base_stats.records
    local table_info, pic_err = pics.locate(rom, stats)

    if not table_info then
      failed.sprites = pic_err
    else
      offsets.pic_table = table_info.offset
      cache.ensure(descriptor.game .. "/sprites")
      step("extracting sprites")

      for species = 1, #stats do
        -- Unown's entry is not a pointer; its forms are stored separately and
        -- are not extracted yet.
        if species ~= pics.UNOWN_SPECIES then
          local tiles = pics.decode_front(rom, table_info, species, stats)
          if tiles then
            local record = stats[species]
            local image = pics.to_image_data(tiles, record.sprite_width,
              record.sprite_height, nil, true)
            local path = cache.write_image(descriptor.game,
              ("sprites/%03d_front"):format(species), image)
            sprites.written = sprites.written + (path and 1 or 0)
          else
            sprites.failed = sprites.failed + 1
          end
        end
      end
      step(("wrote %d sprites"):format(sprites.written))
    end
  end

  cache.write(descriptor.game, "manifest", {
    format_version = cache.FORMAT_VERSION,
    game = descriptor.game,
    name = descriptor.name,
    region = descriptor.region or "unknown",
    revision = descriptor.revision or -1,
    revision_known = descriptor.revision_known,
    sha1 = sha1,
    rom_banks = info.banks,
    rom_size = info.actual_rom_size,
    header_checksum_ok = info.header_checksum_ok,
    global_checksum_ok = info.global_checksum_ok,
    -- Recording where each table was found turns the next import into a
    -- verification rather than a fresh search, and makes the offsets available
    -- for anyone comparing against a disassembly.
    offsets = offsets,
    imported_at = os.time(),
  })

  -- The cartridge has served its purpose.
  rom:release()

  return {
    descriptor = descriptor,
    header = info,
    problems = problems,
    written = written,
    offsets = offsets,
    failed = failed,
    sprites = sprites,
    sha1 = sha1,
  }
end

--- Format a report for display, one line per fact.
function importer.format_report(report)
  local lines = {}

  lines[#lines + 1] = versions.describe(report.descriptor)
  lines[#lines + 1] = ("SHA-1 %s"):format(report.sha1)
  lines[#lines + 1] = ("%d banks, %d KiB")
    :format(report.header.banks, report.header.actual_rom_size / 1024)
  lines[#lines + 1] = ""

  local keys = {}
  for key in pairs(report.written) do
    keys[#keys + 1] = key
  end
  table.sort(keys)

  for _, key in ipairs(keys) do
    local entry = report.written[key]
    lines[#lines + 1] = ("  %-16s %4d records  found at 0x%06X")
      :format(key, entry.count, report.offsets[key])
  end

  if report.sprites then
    lines[#lines + 1] = ("  %-16s %4d sprites written, %d failed")
      :format("sprites", report.sprites.written, report.sprites.failed)
  end

  if next(report.failed) then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "not extracted:"
    local failed_keys = {}
    for key in pairs(report.failed) do
      failed_keys[#failed_keys + 1] = key
    end
    table.sort(failed_keys)
    for _, key in ipairs(failed_keys) do
      lines[#lines + 1] = ("  %s: %s"):format(key, report.failed[key])
    end
  end

  return table.concat(lines, "\n")
end

return importer
