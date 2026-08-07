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
local palettes = require("src.rom.palettes")
local tilesets = require("src.rom.tilesets")
local maps = require("src.rom.maps")
local events = require("src.rom.events")
local ow_sprites = require("src.rom.ow_sprites")
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

      -- Palettes are optional: without them sprites still export, in the
      -- monochrome shades the original DMG hardware produced.
      step("locating palettes")
      local palette_result, palette_err = palettes.locate(rom)
      if palette_result then
        offsets.palettes = palette_result.offset
        cache.write(descriptor.game, "palettes", palette_result.records)
      else
        failed.palettes = palette_err
      end

      cache.ensure(descriptor.game .. "/sprites")
      step("extracting sprites")

      for species = 1, #stats do
        -- Unown's entry is not a pointer; its forms are stored separately and
        -- are not extracted yet.
        if species ~= pics.UNOWN_SPECIES then
          local tiles = pics.decode_front(rom, table_info, species, stats)
          if tiles then
            local record = stats[species]
            local palette
            if palette_result then
              palette = palettes.to_rgb(palette_result.records[species].normal)
            end
            local image = pics.to_image_data(tiles, record.sprite_width,
              record.sprite_height, palette, true)
            local path = cache.write_image(descriptor.game,
              ("sprites/%03d_front"):format(species), image)
            sprites.written = sprites.written + (path and 1 or 0)
          else
            sprites.failed = sprites.failed + 1
          end
        end
      end
      sprites.colored = palette_result ~= nil
      step(("wrote %d sprites (%s)"):format(sprites.written,
        palette_result and "colour" or "monochrome"))
    end
  end

  -- Tilesets. Block and collision tables go into the cache as data; the tile
  -- graphics are written as one blockset image per tileset, which is both what
  -- the renderer will want and what makes a decoding error obvious on sight.
  step("locating tilesets")
  local tileset_summary = { count = 0, images = 0 }
  local tileset_result, tileset_err = tilesets.locate(rom)

  if not tileset_result then
    failed.tilesets = tileset_err
  else
    offsets.tileset_headers = tileset_result.offset
    tileset_summary.count = tileset_result.count
    cache.ensure(descriptor.game .. "/tilesets")
    step(("extracting %d tilesets"):format(tileset_result.count))

    local records = {}
    for index, header in ipairs(tileset_result.headers) do
      local tiles = tilesets.decode_graphics(rom, header)
      if tiles then
        local blocks = tilesets.decode_blocks(rom, header)
        records[index] = {
          graphics = header.graphics,
          blocks_offset = header.blocks,
          collision_offset = header.collision,
          block_count = header.block_count,
          tile_count = #tiles,
          blocks = blocks,
          collision = tilesets.decode_collision(rom, header),
        }
        -- The tilesheet is what the engine actually draws from; the blockset
        -- is for humans checking the import by eye.
        if cache.write_image(descriptor.game, ("tilesets/%02d_tiles"):format(index),
          tilesets.tilesheet_image(tiles, 16)) then
          tileset_summary.images = tileset_summary.images + 1
        end
        cache.write_image(descriptor.game, ("tilesets/%02d_blocks"):format(index),
          tilesets.blockset_image(tiles, blocks, 8))
        records[index].tilesheet_columns = 16
      end
    end
    cache.write(descriptor.game, "tilesets", records)
  end

  -- Overworld sprites: the player and the NPCs.
  step("locating overworld sprites")
  local ow_summary = { count = 0, images = 0 }
  local ow_result, ow_err = ow_sprites.locate(rom)

  if not ow_result then
    failed.ow_sprites = ow_err
  else
    offsets.ow_sprites = ow_result.offset
    ow_summary.count = #ow_result.entries
    cache.ensure(descriptor.game .. "/ow")

    local records = {}
    for index, entry in ipairs(ow_result.entries) do
      records[index] = {
        graphics = entry.graphics,
        tiles = entry.tiles,
        frames = entry.frames,
        kind = entry.kind,
        palette = entry.palette,
      }
      local tiles = ow_sprites.decode(rom, entry)
      if tiles then
        local image = ow_sprites.to_image_data(tiles, entry.frames)
        if cache.write_image(descriptor.game, ("ow/%03d"):format(index), image) then
          ow_summary.images = ow_summary.images + 1
        end
      end
    end
    cache.write(descriptor.game, "ow_sprites", records)
    step(("wrote %d overworld sprites"):format(ow_summary.images))
  end

  -- Maps. Block data is cached rather than rendered: the engine draws from the
  -- grid at runtime, and rendering 384 maps up front would cost minutes and
  -- produce images nothing reads. `--dump-maps` renders them when a human needs
  -- to look.
  local map_summary = { count = 0, blocks = 0, warps = 0, objects = 0,
                        event_failures = 0 }
  if tileset_result then
    step("locating maps")
    local map_result, map_err = maps.locate(rom, tileset_result.count)

    if not map_result then
      failed.maps = map_err
    else
      map_summary.count = #map_result.headers
      step(("extracting %d maps"):format(map_summary.count))

      local records = {}
      for index, header in ipairs(map_result.headers) do
        -- Placeholder slots keep the numbering aligned so warps, which address
        -- maps by position within a group, still land where they should.
        if header.unparsed then
          records[index] = { unparsed = true, header_offset = header.offset }
          goto continue
        end

        local attributes = header.attributes
        map_summary.blocks = map_summary.blocks + attributes.width * attributes.height

        -- Block data is stored flat; the engine indexes it as
        -- row * width + column rather than paying for a table per row.
        local flat = {}
        for i = 0, attributes.width * attributes.height - 1 do
          flat[i + 1] = rom:u8(attributes.block_data + i)
        end

        local record = {
          header_offset = header.offset,
          tileset = header.tileset,
          environment = header.environment_name,
          width = attributes.width,
          height = attributes.height,
          border_block = attributes.border_block,
          connections = maps.connection_list(attributes),
          -- Kept so the script decoder has somewhere to start.
          script_offset = attributes.scripts,
          event_offset = attributes.events,
          blocks = flat,
        }

        local decoded = events.decode(rom, header)
        if decoded then
          record.warps = decoded.warps
          record.coord_events = decoded.coord_events
          record.bg_events = decoded.bg_events
          record.objects = decoded.objects
          map_summary.warps = map_summary.warps + #decoded.warps
          map_summary.objects = map_summary.objects + #decoded.objects
        else
          map_summary.event_failures = map_summary.event_failures + 1
        end

        records[index] = record
        ::continue::
      end

      -- Warps name their destination by (group, number), so the group table is
      -- what makes them followable.
      local groups, group_err = maps.locate_groups(rom, map_result.headers)
      if groups then
        offsets.map_groups = groups.offset
        cache.write(descriptor.game, "map_groups",
          maps.group_index(map_result.headers, groups.groups))
        map_summary.groups = #groups.groups
      else
        failed.map_groups = group_err
      end

      cache.write(descriptor.game, "maps", records)
      offsets.map_headers = map_result.runs[1] and map_result.runs[1].offset
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
    tilesets = tileset_summary,
    maps = map_summary,
    ow_sprites = ow_summary,
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

  if report.ow_sprites then
    lines[#lines + 1] = ("  %-16s %4d sprites, %d images")
      :format("overworld", report.ow_sprites.count, report.ow_sprites.images)
  end

  if report.tilesets then
    lines[#lines + 1] = ("  %-16s %4d tilesets, %d blockset images")
      :format("tilesets", report.tilesets.count, report.tilesets.images)
  end

  if report.maps then
    lines[#lines + 1] = ("  %-16s %4d maps, %d blocks total")
      :format("maps", report.maps.count, report.maps.blocks)
    lines[#lines + 1] = ("  %-16s %4d warps, %d objects, %d maps whose events failed")
      :format("events", report.maps.warps, report.maps.objects,
        report.maps.event_failures)
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
