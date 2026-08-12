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
local scripts = require("src.rom.scripts")
local font = require("src.rom.font")
local encounters = require("src.rom.encounters")
local trainers = require("src.rom.trainers")
local marts = require("src.rom.marts")
local script_decode = require("src.rom.script_decode")
local std_scripts = require("src.rom.std_scripts")
local music = require("src.rom.music")
local machines = require("src.rom.machines")
local obstacles = require("src.rom.obstacles")
local learnsets = require("src.rom.learnsets")
local dex = require("src.rom.dex")
local cures = require("src.rom.cures")
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

  -- Wild encounters and trainer parties: what the battle system will need.
  step("locating wild encounters")
  local battle_summary = { grass = 0, water = 0, trainers = 0, learnsets = 0 }

  local grass, grass_err = encounters.locate_grass(rom)
  if not grass then
    failed.grass_encounters = grass_err
  else
    local records = {}
    for _, run in ipairs(grass) do
      for _, entry in ipairs(run.entries) do
        records[#records + 1] = entry
      end
    end
    battle_summary.grass = #records
    offsets.grass_encounters = grass[1].offset
    cache.write(descriptor.game, "grass_encounters", records)
  end

  local water, water_err = encounters.locate_water(rom)
  if not water then
    failed.water_encounters = water_err
  else
    local records = {}
    for _, run in ipairs(water) do
      for _, entry in ipairs(run.entries) do
        records[#records + 1] = entry
      end
    end
    battle_summary.water = #records
    offsets.water_encounters = water[1].offset
    cache.write(descriptor.game, "water_encounters", records)
  end

  step("locating learnsets")
  local learnset_result, learnset_err = learnsets.locate(rom)
  if not learnset_result then
    failed.learnsets = learnset_err
  else
    offsets.learnsets = learnset_result.offset
    battle_summary.learnsets = #learnset_result.records
    cache.write(descriptor.game, "learnsets", learnset_result.records)
  end

  step("locating trainer parties")
  local trainer_runs, trainer_err = trainers.locate(rom)
  if not trainer_runs then
    failed.trainers = trainer_err
  else
    local records = {}
    for _, run in ipairs(trainer_runs) do
      for _, entry in ipairs(run.entries) do
        records[#records + 1] = entry
      end
    end
    battle_summary.trainers = #records
    offsets.trainers = trainer_runs[1].offset

    -- Class boundaries, so a trainer's (class, id) can reach its party.
    local groups, group_err = trainers.locate_groups(rom, records)
    if not groups then
      failed.trainer_classes = group_err
    else
      offsets.trainer_classes = groups.offset
      local by_class = {}
      for class, start in pairs(groups.classes) do
        local list = {}
        local at = start
        -- Walk the class until an entry stops decoding or the next class
        -- begins, whichever comes first.
        local limit = groups.classes[class + 1]
        while at < (limit or rom.size) do
          local record, consumed = trainers.decode(rom, at)
          if not record then
            break
          end
          list[#list + 1] = record
          at = at + consumed
        end
        by_class[class] = list
        battle_summary.classes = (battle_summary.classes or 0) + 1
      end
      cache.write(descriptor.game, "trainer_classes", by_class)
    end

    cache.write(descriptor.game, "trainers", records)
  end

  -- Mart inventories, which need the item tables to know what can be stocked.
  local mart_summary = { count = 0 }
  if found.item_names and found.item_attributes then
    step("locating marts")
    local mart_result, mart_err = marts.locate(rom,
      found.item_names.records, found.item_attributes.records)
    if not mart_result then
      failed.marts = mart_err
    else
      offsets.marts = mart_result.offset
      mart_summary.count = mart_result.count
      cache.write(descriptor.game, "marts", mart_result.lists)
    end
  end

  -- Which move each TM and HM teaches. Needs the move names, because the
  -- names are what confirm the list is the list.
  local machine_summary = { count = 0 }
  if found.move_names then
    step("locating the machine list")
    local machine_result, machine_err = machines.locate(rom,
      found.move_names.records)
    if not machine_result then
      failed.machines = machine_err
    else
      offsets.machines = machine_result.offset
      machine_summary.count = machines.COUNT
      cache.write(descriptor.game, "machines", machine_result.moves)
      cache.write(descriptor.game, "hm_moves", machine_result.hm)
    end
  end

  -- Which status each curing item undoes. Needs the item names, because that is
  -- what turns "an Antidote cures poison" into an item id without any id being
  -- written down here.
  local cure_summary = { count = 0 }
  if found.item_names then
    step("locating the status cures")
    local cure_result, cure_err = cures.locate(rom, found.item_names.records)
    if not cure_result then
      failed.cures = cure_err
    else
      offsets.cures = cure_result.offset
      cure_summary.count = cure_result.count
      cache.write(descriptor.game, "cures", cure_result.by_item)
    end
  end

  -- The Pokédex entries: classification, height, weight and the description.
  -- Independent of everything above -- the search is on shape alone, so this
  -- does not wait on the species names or anything else having been found.
  local dex_summary = { count = 0 }
  step("locating the Pokédex entries")
  local dex_result, dex_err = dex.locate(rom)
  if not dex_result then
    failed.dex = dex_err
  else
    offsets.dex = dex_result.offset
    dex_summary.count = #dex_result.entries
    dex_summary.found = dex_result.found
    dex_summary.runner_up = dex_result.runner_up
    dex_summary.banks = dex_result.bank_order
    local records = {}
    for index, entry in ipairs(dex_result.entries) do
      records[index] = dex.to_record(entry)
    end
    cache.write(descriptor.game, "dex_entries", records)
  end

  -- The music table. Read, not played: sound would need the channel command
  -- language and a Game Boy sound chip to feed it to.
  local music_summary = { count = 0, exact = 0 }
  step("locating music")
  local music_result, music_err = music.locate(rom)
  if not music_result then
    failed.music = music_err
  else
    offsets.music = music_result.offset
    music_summary.count = music_result.count
    music_summary.exact = music_result.exact
    cache.write(descriptor.game, "music", music_result.songs)
  end

  -- The font, so the engine can draw text in the cartridge's own letters.
  step("locating the font")
  local font_result, font_err = font.locate(rom, descriptor.game)
  if not font_result then
    failed.font = font_err
  else
    offsets.font = font_result.offset
    local glyphs = font.decode(rom, font_result)
    if glyphs then
      cache.write_image(descriptor.game, "font", font.to_image_data(glyphs))
    end
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
                        event_failures = 0, scripts = 0, scripts_read = 0,
                        with_encounters = 0, trainers = 0, items = 0,
                        shopkeepers = 0, hidden = 0 }
  local script_entries = {}
  local script_summary = { instructions = 0, entries = 0, failed = 0, std = 0 }
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
          connections = maps.decode_connections(rom, attributes),
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

          -- Attach whatever text each script displays. Scripts doing anything
          -- more than showing a message are left without text rather than
          -- guessed at.
          local said = scripts.read_map_text(rom, header, decoded)
          map_summary.scripts = map_summary.scripts + said.total
          map_summary.scripts_read = map_summary.scripts_read + said.understood

          -- A script may show several messages in sequence; they are
          -- concatenated into one run of pages so the text box pages through
          -- the whole conversation.
          local function pages_of(found)
            local pages = {}
            for _, entry in ipairs(found.blocks) do
              for _, page in ipairs(entry.block.pages) do
                pages[#pages + 1] = page
              end
            end
            return pages
          end

          -- Trainers: an object of type 2 points at a trainer block rather
          -- than at bytecode.
          local script_bank = math.floor(attributes.scripts / 0x4000)
          for index, object in ipairs(record.objects or {}) do
            if object.kind == events.OBJECT_TRAINER and object.script then
              local trainer = events.decode_trainer(rom, script_bank, object.script)
              if trainer then
                record.objects[index].trainer = trainer
                map_summary.trainers = map_summary.trainers + 1
              end
            elseif object.kind == events.OBJECT_SCRIPT and object.script
              and mart_summary.count > 0 then
              -- A shopkeeper is an ordinary script object; what marks them out
              -- is a pokemart command in the script they run.
              local mart = marts.for_script(rom, scripts, script_bank,
                object.script, mart_summary.count)
              if mart then
                record.objects[index].mart = mart
                map_summary.shopkeepers = map_summary.shopkeepers + 1
              end
            elseif object.kind == events.OBJECT_ITEM and object.script then
              -- An item ball points at two bytes, not at bytecode.
              local item = events.decode_item(rom, script_bank, object.script)
              if item then
                record.objects[index].item = item
                map_summary.items = map_summary.items + 1
              end
            end
          end

          -- Hidden items: a background event that points at a flag and an item
          -- rather than at text.
          for index, bg in ipairs(record.bg_events or {}) do
            if bg.kind == events.BGEVENT_ITEM and bg.script then
              local block = events.decode_hidden(rom, script_bank, bg.script)
              if block then
                record.bg_events[index].hidden = block
                map_summary.hidden = map_summary.hidden + 1
              end
            end
          end

          -- The interpreter needs to know which bank a map's near pointers are
          -- relative to, and it only ever sees the cache.
          record.script_bank = script_bank

          -- Every entry point into the bytecode, for the interpreter to decode
          -- from. Item balls and hidden items are excluded: their pointers lead
          -- to data rather than to instructions.
          for _, bg in ipairs(record.bg_events or {}) do
            if bg.script and bg.kind ~= events.BGEVENT_ITEM then
              script_entries[#script_entries + 1] =
                { bank = script_bank, addr = bg.script }
            end
          end
          for _, object in ipairs(record.objects or {}) do
            if object.script and object.kind ~= events.OBJECT_TRAINER
              and object.kind ~= events.OBJECT_ITEM then
              script_entries[#script_entries + 1] =
                { bank = script_bank, addr = object.script }
            end
          end
          for _, coord in ipairs(record.coord_events or {}) do
            if coord.script then
              script_entries[#script_entries + 1] =
                { bank = script_bank, addr = coord.script }
            end
          end

          for index, found in pairs(said.bg) do
            record.bg_events[index].text = pages_of(found)
          end
          for index, found in pairs(said.objects) do
            record.objects[index].text = pages_of(found)
          end
        else
          map_summary.event_failures = map_summary.event_failures + 1
        end

        records[index] = record
        ::continue::
      end

      -- What the field moves clear away. Found rather than listed: the sprite
      -- ids are not written down anywhere in this project.
      local obstacle_result, obstacle_err = obstacles.locate(rom, map_result)
      if not obstacle_result then
        failed.obstacles = obstacle_err
      else
        map_summary.tree_sprite = obstacle_result.tree
        map_summary.boulder_sprite = obstacle_result.boulder
        cache.write(descriptor.game, "obstacles", obstacle_result)
      end

      -- The bytecode, decoded once for the whole game. Scripts jump into each
      -- other across maps, so this is keyed by bank and address rather than
      -- gathered per map, which dedupes the shared tails as well.
      -- The standard scripts are entry points too, and they have to be decoded
      -- or every jumpstd lands in nothing.
      step("locating standard scripts")
      local std_result, std_err = std_scripts.locate(rom)
      if not std_result then
        failed.std_scripts = std_err
      else
        offsets.std_scripts = std_result.offset
        script_summary.std = std_result.count
        for _, entry in ipairs(std_result.entries) do
          script_entries[#script_entries + 1] =
            { bank = entry.bank, addr = entry.addr }
        end
        cache.write(descriptor.game, "std_scripts", std_result.entries)
      end

      if #script_entries > 0 then
        step("decoding scripts")
        local code, script_stats = script_decode.reachable(rom, script_entries)
        script_summary.entries = #script_entries
        script_summary.instructions = script_stats.instructions
        script_summary.failed = script_stats.failed
        cache.write(descriptor.game, "script_code", code)
      end

      -- Wild encounters are keyed by (group, number), so they can only be
      -- attached to maps once the group table is known.
      local encounter_by_map = {}
      local function key_of(group, number)
        return group * 256 + number
      end
      if grass then
        for _, run in ipairs(grass) do
          for _, entry in ipairs(run.entries) do
            encounter_by_map[key_of(entry.group, entry.map)] = entry
          end
        end
      end

      -- Warps name their destination by (group, number), so the group table is
      -- what makes them followable.
      local groups, group_err = maps.locate_groups(rom, map_result.headers)
      local group_index, group_of = nil, {}
      if groups then
        offsets.map_groups = groups.offset
        group_index = maps.group_index(map_result.headers, groups.groups)
        cache.write(descriptor.game, "map_groups", group_index)
        map_summary.groups = #groups.groups

        -- Invert the group starts into per-map (group, number), which is how
        -- everything outside the map tables addresses a map.
        local starts = {}
        for group, start in pairs(group_index) do
          starts[#starts + 1] = { group = group, start = start }
        end
        table.sort(starts, function(a, b) return a.start < b.start end)

        for i, entry in ipairs(starts) do
          local last = starts[i + 1] and starts[i + 1].start - 1
            or #map_result.headers
          for index = entry.start, last do
            group_of[index] = { group = entry.group, number = index - entry.start + 1 }
          end
        end
      else
        failed.map_groups = group_err
      end

      -- Second pass: now that maps can be addressed by (group, number), give
      -- each its own id and attach whatever wild encounters it has.
      for index, record in ipairs(records) do
        local where = group_of[index]
        if where then
          record.group = where.group
          record.number = where.number

          local entry = encounter_by_map[key_of(where.group, where.number)]
          if entry and not record.unparsed then
            record.encounters = { rates = entry.rates, slots = entry.slots }
            map_summary.with_encounters = map_summary.with_encounters + 1
          end
        end
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
    battle_data = battle_summary,
    marts = mart_summary,
    music = music_summary,
    machines = machine_summary,
    dex = dex_summary,
    cures = cure_summary,
    script_code = script_summary,
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

  if report.battle_data then
    lines[#lines + 1] = ("  %-16s %4d grass maps, %d water maps, %d trainers, " ..
      "%d learnsets"):format("battle data", report.battle_data.grass,
      report.battle_data.water, report.battle_data.trainers,
      report.battle_data.learnsets)
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
    lines[#lines + 1] = ("  %-16s %4d of %d scripts read as text")
      :format("scripts", report.maps.scripts_read, report.maps.scripts)
    lines[#lines + 1] = ("  %-16s %4d maps carry wild encounters")
      :format("encounters", report.maps.with_encounters)
    lines[#lines + 1] = ("  %-16s %4d trainer objects on maps")
      :format("trainers", report.maps.trainers)
    lines[#lines + 1] = ("  %-16s %4d item balls, %d hidden items")
      :format("items", report.maps.items, report.maps.hidden)
    if report.maps.tree_sprite then
      lines[#lines + 1] = ("  %-16s cut tree is sprite %d, boulder is %d")
        :format("obstacles", report.maps.tree_sprite,
          report.maps.boulder_sprite)
    end
  end

  if report.script_code and report.script_code.entries > 0 then
    lines[#lines + 1] = ("  %-16s %4d instructions from %d entry points, " ..
      "%d blocks unreadable"):format("bytecode",
      report.script_code.instructions, report.script_code.entries,
      report.script_code.failed)
    lines[#lines + 1] = ("  %-16s %4d standard scripts")
      :format("std scripts", report.script_code.std)
  end

  if report.machines and report.machines.count > 0 then
    lines[#lines + 1] = ("  %-16s %4d TMs and HMs")
      :format("machines", report.machines.count)
  end

  if report.cures and report.cures.count > 0 then
    lines[#lines + 1] = ("  %-16s %4d items undo a status")
      :format("cures", report.cures.count)
  end

  if report.dex and report.dex.count > 0 then
    lines[#lines + 1] = ("  %-16s %4d entries across banks %s")
      :format("pokedex", report.dex.count,
        (function()
          local names = {}
          for _, bank in ipairs(report.dex.banks or {}) do
            names[#names + 1] = ("$%02X"):format(bank)
          end
          return table.concat(names, ", ")
        end)())
  end

  if report.music and report.music.count > 0 then
    lines[#lines + 1] = ("  %-16s %4d songs, %d headers closing exactly")
      :format("music", report.music.count, report.music.exact)
  end

  if report.marts and report.marts.count > 0 then
    lines[#lines + 1] = ("  %-16s %4d shop inventories, %d shopkeepers found")
      :format("marts", report.marts.count, report.maps.shopkeepers or 0)
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
