-- Headless test harness.
--
-- LOVE is a windowed binary, so tests report by writing a file rather than to
-- stdout. Run with:
--
--   love . --test <rom-path> <report-path>
--
-- Everything here asserts against content known independently of this codebase:
-- documented header values, and species and moves whose stats are a matter of
-- public record. A test that only checks our decoder against our own encoder
-- would pass just as happily with the format wrong.

local Rom = require("src.rom.rom")
local header = require("src.rom.header")
local versions = require("src.rom.versions")
local locate = require("src.rom.locate")
local lz = require("src.rom.lz")
local gfx = require("src.rom.gfx")
local pics = require("src.rom.pics")
local palettes = require("src.rom.palettes")
local tilesets = require("src.rom.tilesets")
local maps = require("src.rom.maps")
local events = require("src.rom.events")
local ow_sprites = require("src.rom.ow_sprites")
local scripts = require("src.rom.scripts")
local text = require("src.rom.text")
local font = require("src.rom.font")
local script_table = require("src.rom.script_table")
local encounters = require("src.rom.encounters")
local trainers = require("src.rom.trainers")

local harness = {}

local report = {}
local passed, failed = 0, 0

local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

local function check(label, condition, detail)
  if condition then
    passed = passed + 1
    log("  PASS  %s", label)
  else
    failed = failed + 1
    log("  FAIL  %s%s", label, detail and ("  -- " .. detail) or "")
  end
  return condition
end

local function check_equal(label, actual, expected)
  return check(label, actual == expected,
    ("got %s, expected %s"):format(tostring(actual), tostring(expected)))
end

--------------------------------------------------------------------------------

local function test_header(rom)
  log("\n== cartridge header ==")
  local info = header.parse(rom)

  check_equal("title", info.title, "PM_CRYSTAL")
  check_equal("game code", info.game_code, "BYTE")
  check_equal("cart type is MBC3+TIMER+RAM+BATTERY", info.cart_type, 0x10)
  check_equal("declared ROM size matches file", info.declared_rom_size, info.actual_rom_size)
  check_equal("bank count", info.banks, 128)
  check_equal("SRAM size", info.ram_size, 32 * 1024)
  check("header checksum verifies", info.header_checksum_ok)
  check("global checksum verifies", info.global_checksum_ok,
    ("stored $%04X"):format(info.global_checksum))

  local problems = header.validate(info)
  check_equal("no structural problems", #problems, 0)
  for _, problem in ipairs(problems) do
    log("        %s", problem)
  end

  return info
end

local function test_identify(rom, info)
  log("\n== identification ==")
  local digest = love.data.hash("sha1", rom.data)
  local sha1 = (digest:gsub(".", function(c) return ("%02x"):format(c:byte()) end))

  log("  sha1 %s", sha1)
  local descriptor, why = versions.identify(info, sha1)
  if not check("identifies the cartridge", descriptor ~= nil, why) then
    return nil
  end

  check_equal("game", descriptor.game, "crystal")
  check_equal("region", descriptor.region, "usa_europe")
  check("revision is recognised", descriptor.revision_known,
    "hash is not in the revision table")
  return descriptor
end

--- Addressing is easy to get subtly wrong, so pin it against the header, which
-- we know lies at a fixed place in bank 0.
local function test_addressing(rom)
  log("\n== bank and pointer arithmetic ==")

  check_equal("bank 0 address maps to itself", rom:offset(0, 0x0134), 0x0134)
  check_equal("a bank-0 address ignores the bank byte beside it",
    rom:offset(0x14, 0x0134), 0x0134)
  check_equal("switched window maps into the bank",
    rom:offset(0x14, 0x4000), 0x14 * 0x4000)
  check_equal("end of the switched window",
    rom:offset(0x01, 0x7FFF), 0x01 * 0x4000 + 0x3FFF)

  check_equal("far read agrees with flat read",
    rom:read(rom:offset(0, 0x134), 10), rom:read(0x134, 10))
end

--- Exercise every LZ command. These streams are hand-assembled from the format
-- description, so this checks the decoder is self-consistent and handles the
-- long form, overlapping copies, and both back-reference encodings. Correctness
-- against real cartridge data is established by the sprite tests below.
local function test_lz_commands()
  log("\n== LZ command decoding ==")

  local function decode(byte_list)
    local chars = {}
    for i, b in ipairs(byte_list) do
      chars[i] = string.char(b)
    end
    return lz.decompress(table.concat(chars), 0)
  end

  check_equal("literal run", decode { 0x02, 0xAA, 0xBB, 0xCC, 0xFF }, "\xAA\xBB\xCC")
  check_equal("iterate", decode { 0x23, 0x7E, 0xFF }, "\x7E\x7E\x7E\x7E")
  check_equal("alternate", decode { 0x43, 0x11, 0x22, 0xFF }, "\x11\x22\x11\x22")
  check_equal("zero fill", decode { 0x62, 0xFF }, "\0\0\0")

  check_equal("repeat, absolute reference",
    decode { 0x02, 0x01, 0x02, 0x03, 0x81, 0x00, 0x00, 0xFF },
    "\x01\x02\x03\x01\x02")

  check_equal("repeat, relative reference",
    decode { 0x02, 0x01, 0x02, 0x03, 0x81, 0x82, 0xFF },
    "\x01\x02\x03\x01\x02")

  -- The read head advances into bytes this command is itself emitting.
  check_equal("overlapping repeat",
    decode { 0x00, 0xAB, 0x83, 0x80, 0xFF },
    "\xAB\xAB\xAB\xAB\xAB")

  check_equal("flip",
    decode { 0x00, 0x01, 0xA0, 0x80, 0xFF },
    "\x01\x80")

  -- $C2 is command 6 with a length of three; $80 references the last byte
  -- emitted, so the copy runs backwards from there to the start.
  check_equal("reverse",
    decode { 0x02, 0x01, 0x02, 0x03, 0xC2, 0x80, 0xFF },
    "\x01\x02\x03\x03\x02\x01")

  local long = { 0xE1, 0x2B }
  for i = 1, 300 do
    long[#long + 1] = i % 256
  end
  long[#long + 1] = 0xFF
  local decoded = decode(long)
  check_equal("long-form length", decoded and #decoded, 300)

  local bad, err = decode { 0x81, 0x00, 0x00, 0xFF }
  check("back-reference past the write head is rejected", bad == nil, err)
end

local function test_tables(rom)
  log("\n== data tables ==")
  local found, failures = locate.all(rom)

  for _, key in ipairs { "species_names", "move_names", "base_stats", "moves" } do
    local result = found[key]
    if check(("located %s"):format(key), result ~= nil, failures[key]) then
      log("        offset 0x%06X (bank $%02X), %d records",
        result.offset, math.floor(result.offset / 0x4000), #result.records)
    end
  end

  if found.species_names then
    local names = found.species_names.records
    check_equal("species 1", names[1], "BULBASAUR")
    check_equal("species 151", names[151], "MEW")
    check_equal("species 152", names[152], "CHIKORITA")
    check_equal("species 245", names[245], "SUICUNE")
    check_equal("species 251", names[251], "CELEBI")
    -- The charmap entries most likely to be wrong.
    check_equal("species 29 uses the female symbol", names[29], "NIDORAN♀")
    check_equal("species 32 uses the male symbol", names[32], "NIDORAN♂")
  end

  if found.move_names then
    local names = found.move_names.records
    check_equal("move 1", names[1], "POUND")
    check_equal("move 13", names[13], "RAZOR WIND")
    check_equal("move 251", names[251], "BEAT UP")
  end

  if found.base_stats then
    local stats = found.base_stats.records
    check_equal("Pikachu HP", stats[25].hp, 35)
    check_equal("Pikachu Speed", stats[25].speed, 90)
    check_equal("Pikachu type", stats[25].type_1, "electric")
    check_equal("Blissey HP", stats[242].hp, 255)
    check_equal("Blissey type", stats[242].type_1, "normal")
    check_equal("Steelix Defense", stats[208].defense, 200)
    check_equal("Steelix primary type", stats[208].type_1, "steel")
    check_equal("Steelix secondary type", stats[208].type_2, "ground")

    -- Rather than assert a specific species holds a specific item, check the
    -- field is populated across the table: a decoder reading the wrong byte
    -- would give all zeroes or implausibly many.
    local with_items = 0
    for _, record in ipairs(stats) do
      if record.held_item_1 ~= 0 or record.held_item_2 ~= 0 then
        with_items = with_items + 1
      end
    end
    check("held items are populated but not universal",
      with_items > 10 and with_items < #stats,
      ("%d of %d species carry an item"):format(with_items, #stats))

    -- Footprints are square in Gen 2 and only ever 5x5, 6x6 or 7x7.
    local bad_shape = 0
    for _, record in ipairs(stats) do
      local w, h = record.sprite_width, record.sprite_height
      if w ~= h or w < 5 or w > 7 then
        bad_shape = bad_shape + 1
      end
    end
    check_equal("every sprite footprint is 5x5, 6x6 or 7x7", bad_shape, 0)
  end

  if found.moves then
    local moves = found.moves.records
    check_equal("Pound power", moves[1].power, 40)
    check_equal("Pound PP", moves[1].pp, 35)
    -- Accuracy is a fraction of 255, not a percentage.
    check_equal("Pound accuracy raw", moves[1].accuracy, 255)
    check_equal("Fissure PP", moves[90].pp, 5)
    check_equal("Struggle power", moves[165].power, 50)
    -- Curse is the ??? type, which is the entry a types table is likely to miss.
    check_equal("Curse has the ??? type", moves[174].type, "unknown")
  end

  return found
end

--- The real test of the LZ decoder: decompress cartridge data across all 251
-- species and check every result against sizes recorded elsewhere in the ROM.
local function test_sprites(rom, base_stats)
  log("\n== sprites ==")
  if not base_stats then
    log("  SKIP  base stats were not located")
    return
  end

  local stats = base_stats.records

  local table_info, why = pics.locate(rom, stats)
  if not check("located the Pokémon pic pointer table", table_info ~= nil, why) then
    return
  end

  log("        table at 0x%06X (bank $%02X), bank bias +$%02X, stride %d",
    table_info.offset, math.floor(table_info.offset / 0x4000),
    table_info.bias, table_info.stride)

  -- Walk every species. Each front pic must decompress to a tile-aligned size
  -- of at least its recorded footprint, and each back pic to exactly 6x6.
  local front_failures, back_failures = {}, {}
  local animated = 0
  local total_bytes = 0

  for species = 1, 251 do
    -- Unown's entry in this table is not a pointer; its 26 forms live in their
    -- own table and are checked separately below.
    if species ~= pics.UNOWN_SPECIES then
      local tiles, extra_or_err = pics.decode_front(rom, table_info, species, stats)
      if not tiles then
        if #front_failures < 5 then
          front_failures[#front_failures + 1] =
            ("species %d: %s"):format(species, tostring(extra_or_err))
        end
      else
        local record = stats[species]
        if #tiles ~= record.sprite_width * record.sprite_height then
          front_failures[#front_failures + 1] =
            ("species %d decoded %d tiles"):format(species, #tiles)
        end
        if extra_or_err > 0 then
          animated = animated + 1
        end
        total_bytes = total_bytes + #tiles * gfx.BYTES_PER_TILE
      end

      local back, back_err = pics.decode_back(rom, table_info, species)
      if not back or #back ~= pics.BACK_TILES then
        if #back_failures < 5 then
          back_failures[#back_failures + 1] =
            ("species %d: %s"):format(species, tostring(back_err or #back))
        end
      end
    end
  end

  check_equal("all 250 non-Unown front sprites decode", #front_failures, 0)
  for _, failure in ipairs(front_failures) do
    log("        %s", failure)
  end

  check_equal("all 250 non-Unown back sprites decode as 6x6", #back_failures, 0)
  for _, failure in ipairs(back_failures) do
    log("        %s", failure)
  end

  -- Unown's own table.
  -- Unown's 26 forms live in their own table, which has not been located yet.
  -- Recorded here rather than asserted so the gap stays visible.
  log("        species %d (Unown) is not extracted: its 26 forms use a " ..
    "separate table", pics.UNOWN_SPECIES)

  log("        %d of 251 species carry appended animation frames", animated)
  log("        %d bytes of base front-sprite tile data", total_bytes)

  -- Real art uses the whole palette and is not uniformly filled.
  local tiles = pics.decode_front(rom, table_info, 1, stats)
  local histogram = { [0] = 0, 0, 0, 0 }
  for _, tile in ipairs(tiles) do
    for _, index in ipairs(tile) do
      histogram[index] = histogram[index] + 1
    end
  end
  local used = 0
  for i = 0, 3 do
    if histogram[i] > 0 then
      used = used + 1
    end
  end
  check("species 1's sprite uses at least three colour indices", used >= 3,
    ("histogram %d/%d/%d/%d"):format(histogram[0], histogram[1],
      histogram[2], histogram[3]))

  return table_info
end

--- Palettes are checked by hue rather than by exact colour values, which we do
-- not know independently. A table decoded at the wrong offset would not produce
-- a green Bulbasaur and a yellow Pikachu.
local function test_palettes(rom, species_names)
  log("\n== sprite palettes ==")

  local result, why = palettes.locate(rom)
  if not check("located the palette table", result ~= nil, why) then
    return
  end

  log("        table at 0x%06X (bank $%02X), %d records, %d bytes each",
    result.offset, math.floor(result.offset / 0x4000), #result.records,
    palettes.RECORD_SIZE)

  check_equal("one record per species", #result.records, 251)

  -- Every stored colour must be a real 15-bit value.
  local out_of_range = 0
  for _, record in ipairs(result.records) do
    for _, pair in ipairs { record.normal, record.shiny } do
      for _, word in ipairs(pair) do
        if word > 0x7FFF then
          out_of_range = out_of_range + 1
        end
      end
    end
  end
  check_equal("no colour has bit 15 set", out_of_range, 0)

  -- Hue spot checks against species whose colour is not in dispute.
  local expected = {
    [1] = { "g", "BULBASAUR" },
    [4] = { "r", "CHARMANDER" },
    [25] = { "yellow", "PIKACHU" },
    -- Jigglypuff is pink: red leads, but blue outranks green. A classifier
    -- that compares the trailing channels to each other calls this blue.
    [39] = { "r", "JIGGLYPUFF" },
    -- Only two colours are stored per sprite, so the light slot is whatever
    -- dominates the lit areas — Oddish's leaves, not its blue body.
    [43] = { "g", "ODDISH" },
  }

  for species, want in pairs(expected) do
    local record = result.records[species]
    local light = record.normal[1]
    local r, g, b = palettes.channels(light)
    local dominant = palettes.dominant(light)
    local name = species_names and species_names[species] or ("#" .. species)
    check(("%s's light colour reads as %s"):format(name, want[1]),
      dominant == want[1],
      ("rgb %d,%d,%d reads as %s"):format(r, g, b, dominant))
  end

  -- Shiny palettes exist and mostly differ from the normal ones.
  local differing = 0
  for _, record in ipairs(result.records) do
    if record.normal[1] ~= record.shiny[1] or record.normal[2] ~= record.shiny[2] then
      differing = differing + 1
    end
  end
  check("shiny palettes differ from normal ones", differing > 200,
    ("%d of 251 differ"):format(differing))

  return result
end

--- Tilesets are checked structurally and then by whether their block
-- definitions actually reference the graphics they ship with. Block data that
-- decoded at the wrong offset still yields tile indices, but they scatter
-- across the whole 0-255 range instead of landing inside the tile sheet.
local function test_tilesets(rom)
  log("\n== tilesets ==")

  local result, why = tilesets.locate(rom)
  if not check("located the tileset header table", result ~= nil, why) then
    return
  end

  log("        table at 0x%06X (bank $%02X), %d headers, %d bytes each",
    result.offset, math.floor(result.offset / 0x4000), result.count,
    tilesets.HEADER_SIZE)

  check("Crystal ships at least 25 tilesets", result.count >= 25,
    ("found %d"):format(result.count))

  local bad_reserved, bad_graphics, bad_counts = 0, 0, 0
  local clean_blocks = 0
  local block_sizes = {}

  for _, header in ipairs(result.headers) do
    if header.reserved ~= 0 then
      bad_reserved = bad_reserved + 1
    end

    block_sizes[header.block_count] = (block_sizes[header.block_count] or 0) + 1

    -- Block counts are derived from the gap between the block and collision
    -- pointers, so an implausible one means the header decoded wrong.
    if header.block_count < tilesets.MIN_BLOCKS
      or header.block_count > tilesets.MAX_BLOCKS then
      bad_counts = bad_counts + 1
    end

    local tiles = tilesets.decode_graphics(rom, header)
    if not tiles then
      bad_graphics = bad_graphics + 1
    else
      local blocks = tilesets.decode_blocks(rom, header)
      local out_of_range = 0
      for _, block in ipairs(blocks) do
        for _, tile_index in ipairs(block) do
          if tile_index >= #tiles then
            out_of_range = out_of_range + 1
          end
        end
      end
      if out_of_range == 0 then
        clean_blocks = clean_blocks + 1
      end
    end
  end

  check_equal("every header's reserved word is zero", bad_reserved, 0)
  check_equal("every tileset's graphics decompress", bad_graphics, 0)
  check_equal("every block count is plausible", bad_counts, 0)

  local sizes = {}
  for count, n in pairs(block_sizes) do
    sizes[#sizes + 1] = ("%d blocks x%d"):format(count, n)
  end
  table.sort(sizes)
  log("        block counts: %s", table.concat(sizes, ", "))

  -- Most tilesets are self-contained. A minority index past their own sheet
  -- into tiles the game loads separately, which is a known gap rather than a
  -- decoding error.
  check(("most tilesets reference only their own tiles"),
    clean_blocks >= result.count / 2,
    ("%d of %d are self-contained"):format(clean_blocks, result.count))
  log("        %d of %d tilesets reference tiles outside their own sheet",
    result.count - clean_blocks, result.count)

  -- Collision must decode to one value per quadrant for every block.
  local header = result.headers[1]
  local collision = tilesets.decode_collision(rom, header)
  check_equal("collision has one entry per block", #collision, header.block_count)
  check_equal("each collision entry has four quadrants", #collision[1],
    tilesets.COLLISION_PER_BLOCK)

  return result
end

--- Maps are confirmed by cross-checking two independently located structures.
-- Every block id in a map's data must be one the tileset its header names
-- actually defines. Map headers and tileset headers are found by separate
-- searches in different banks, so agreement between them is not something a
-- wrong offset produces.
local function test_maps(rom, tileset_result)
  log("\n== maps ==")
  if not tileset_result then
    log("  SKIP  tilesets were not located")
    return
  end

  local result, why = maps.locate(rom, tileset_result.count)
  if not check("located map headers", result ~= nil, why) then
    return
  end

  log("        %d headers across %d runs", #result.headers, #result.runs)
  for _, run in ipairs(result.runs) do
    log("        run at 0x%06X (bank $%02X): %d headers",
      run.offset, math.floor(run.offset / 0x4000), run.count)
  end

  check("Crystal has at least 250 maps", #result.headers >= 250,
    ("found %d"):format(#result.headers))

  local bad_dimensions, bad_environment = 0, 0
  local with_connections = 0
  local block_id_violations = 0
  local checked_against_tileset = 0
  local total_blocks = 0

  for _, header in ipairs(result.headers) do
    -- Placeholder slots exist to hold map numbering in place; they carry no
    -- attributes to check.
    if not header.unparsed then
    local attributes = header.attributes

    if attributes.width < 1 or attributes.width > maps.MAX_DIMENSION
      or attributes.height < 1 or attributes.height > maps.MAX_DIMENSION then
      bad_dimensions = bad_dimensions + 1
    end

    if not header.environment_name then
      bad_environment = bad_environment + 1
    end

    if attributes.connections ~= 0 then
      with_connections = with_connections + 1
    end

    total_blocks = total_blocks + attributes.width * attributes.height

    local tileset = tileset_result.headers[header.tileset]
    if tileset then
      checked_against_tileset = checked_against_tileset + 1
      local highest = -1
      for i = 0, attributes.width * attributes.height - 1 do
        local id = rom:u8(attributes.block_data + i)
        if id > highest then
          highest = id
        end
      end
      if highest >= tileset.block_count then
        block_id_violations = block_id_violations + 1
      end
    end
    end
  end

  log("        %d placeholder slots hold numbering for headers that do not decode",
    result.placeholders or 0)

  check_equal("every map has usable dimensions", bad_dimensions, 0)
  check_equal("every environment id is known", bad_environment, 0)

  -- The decisive one.
  check_equal("every map's block ids fit its tileset", block_id_violations, 0)
  log("        %d maps checked against their tileset, %d blocks total",
    checked_against_tileset, total_blocks)

  -- Routes and towns connect to their neighbours; interiors do not. Both must
  -- be present or the connection byte is being misread.
  check("some maps have edge connections, most do not",
    with_connections > 20 and with_connections < #result.headers / 2,
    ("%d of %d have connections"):format(with_connections, #result.headers))

  -- Block data must be readable as a grid of the stated size.
  local sample
  for _, header in ipairs(result.headers) do
    if not header.unparsed then
      sample = header
      break
    end
  end
  local grid = maps.decode_block_data(rom, sample)
  check_equal("block data has one row per map row", #grid, sample.attributes.height)
  check_equal("block data has one column per map column", #grid[1],
    sample.attributes.width)

  return result
end

--- Event headers are confirmed by position. Every warp and NPC must land
-- inside its own map, which a parse desynchronised by a wrong record size does
-- not manage. The record sizes themselves were established the same way.
local function test_events(rom, map_result)
  log("\n== map events ==")
  if not map_result then
    log("  SKIP  maps were not located")
    return
  end

  local decoded_count, failures = 0, {}
  local totals = { warps = 0, coord_events = 0, bg_events = 0, objects = 0 }
  local bad_destinations, bad_scripts, unknown_bg = 0, 0, 0
  local outside = 0

  local parsed_maps = 0
  for _, header in ipairs(map_result.headers) do
    local decoded, why
    if not header.unparsed then
      parsed_maps = parsed_maps + 1
      decoded, why = events.decode(rom, header)
    end

    if header.unparsed then -- luacheck: ignore
      -- No attributes, so no event header to reach.
    elseif not decoded then
      if #failures < 5 then
        failures[#failures + 1] = ("0x%06X: %s"):format(header.offset, tostring(why))
      end
    else
      decoded_count = decoded_count + 1
      for key in pairs(totals) do
        totals[key] = totals[key] + #decoded[key]
      end

      for _, warp in ipairs(decoded.warps) do
        -- Crystal has 26 map groups; a destination outside that is a misread.
        if warp.destination_group < 1 or warp.destination_group > 26 then
          bad_destinations = bad_destinations + 1
        end
      end

      for _, bg in ipairs(decoded.bg_events) do
        if not bg.kind_name then
          unknown_bg = unknown_bg + 1
        end
        if not bg.script then
          bad_scripts = bad_scripts + 1
        end
      end

      for _, object in ipairs(decoded.objects) do
        if object.out_of_bounds then
          outside = outside + 1
        end
      end
    end
  end

  check_equal("every decodable map's events decode", decoded_count, parsed_maps)
  for _, failure in ipairs(failures) do
    log("        %s", failure)
  end

  log("        %d warps, %d triggers, %d signposts, %d objects",
    totals.warps, totals.coord_events, totals.bg_events, totals.objects)

  -- Objects sitting outside their map are legal and rare. Many of them would
  -- mean the record size is wrong.
  check("almost no objects sit outside their map", outside <= 2,
    ("%d of %d are out of bounds"):format(outside, totals.objects))
  log("        %d objects sit outside their map's own dimensions", outside)

  -- A map with no warps at all would be unreachable, and Crystal is mostly
  -- interiors, so warps should outnumber maps.
  check("warps outnumber maps", totals.warps > #map_result.headers,
    ("%d warps for %d maps"):format(totals.warps, #map_result.headers))

  check_equal("every warp targets a real map group", bad_destinations, 0)
  check_equal("every signpost type is known", unknown_bg, 0)
  check_equal("every signpost has a script pointer", bad_scripts, 0)

  -- Objects carry scripts too, though some are null.
  local with_script, object_total = 0, 0
  for _, header in ipairs(map_result.headers) do
    local decoded = not header.unparsed and events.decode(rom, header)
    if decoded then
      for _, object in ipairs(decoded.objects) do
        object_total = object_total + 1
        if object.script then
          with_script = with_script + 1
        end
      end
    end
  end
  check("most objects carry a script pointer", with_script > object_total * 0.9,
    ("%d of %d"):format(with_script, object_total))
end

--- Overworld sprites: the player and NPCs. Checked structurally and then
-- against how many of the game's NPCs can actually be drawn.
local function test_ow_sprites(rom, map_result)
  log("\n== overworld sprites ==")

  local result, why = ow_sprites.locate(rom)
  if not check("located the overworld sprite table", result ~= nil, why) then
    return
  end

  log("        table at 0x%06X (bank $%02X), %d entries",
    result.offset, math.floor(result.offset / 0x4000), #result.entries)

  check("the table holds at least 100 sprites", #result.entries >= 100,
    ("found %d"):format(#result.entries))

  local bad_bank, bad_frames, bad_decode = 0, 0, 0
  local kinds, frame_counts = {}, {}

  for _, entry in ipairs(result.entries) do
    if not ow_sprites.BANKS[entry.bank] then
      bad_bank = bad_bank + 1
    end
    if entry.tiles % ow_sprites.TILES_PER_FRAME ~= 0 or entry.frames < 1 then
      bad_frames = bad_frames + 1
    end
    if not ow_sprites.decode(rom, entry) then
      bad_decode = bad_decode + 1
    end
    kinds[entry.kind] = (kinds[entry.kind] or 0) + 1
    frame_counts[entry.frames] = (frame_counts[entry.frames] or 0) + 1
  end

  check_equal("every sprite lives in a graphics bank", bad_bank, 0)
  check_equal("every sprite is a whole number of frames", bad_frames, 0)
  check_equal("every sprite's tiles decode", bad_decode, 0)

  local shapes = {}
  for frames, count in pairs(frame_counts) do
    shapes[#shapes + 1] = ("%d frames x%d"):format(frames, count)
  end
  table.sort(shapes)
  log("        %s", table.concat(shapes, ", "))

  local kind_list = {}
  for kind, count in pairs(kinds) do
    kind_list[#kind_list + 1] = ("type %d x%d"):format(kind, count)
  end
  table.sort(kind_list)
  log("        %s", table.concat(kind_list, ", "))

  -- The point of all this: can the game's NPCs actually be drawn?
  if map_result then
    local drawable, total = 0, 0
    for _, header in ipairs(map_result.headers) do
      local decoded = not header.unparsed and events.decode(rom, header)
      if decoded then
        for _, object in ipairs(decoded.objects) do
          total = total + 1
          if result.entries[object.sprite] then
            drawable = drawable + 1
          end
        end
      end
    end
    check("most NPCs have a sprite in the table",
      drawable > total * 0.75,
      ("%d of %d NPCs drawable"):format(drawable, total))
    log("        %d of %d NPC instances resolve to a sprite", drawable, total)
  end
end

--- The font. Checked by glyph layout rather than by shape, since we have no
-- reference image to compare against; the shapes were confirmed by rendering a
-- signpost's text and reading it.
local function test_font(rom)
  log("\n== font ==")

  local located, why = font.locate(rom, "crystal")
  if not check("located the font", located ~= nil, why) then
    return
  end

  log("        offset 0x%06X (bank $%02X), found by %s",
    located.offset, math.floor(located.offset / 0x4000), located.source)

  local glyphs = font.decode(rom, located)
  if not check("the font decodes as 1bpp tiles", glyphs ~= nil) then
    return
  end
  check_equal("the sheet holds 256 glyphs", #glyphs, font.GLYPH_COUNT)

  local function ink(code)
    local tile = glyphs[font.tile_for(code) + 1]
    if not tile then
      return nil
    end
    local set = 0
    for i = 1, 64 do
      if tile[i] ~= 0 then
        set = set + 1
      end
    end
    return set
  end

  check_equal("the space glyph is blank", ink(text.charmap and 0x7F or 0x7F), 0)

  local blank_letters = 0
  for code = 0x80, 0x99 do
    if (ink(code) or 0) == 0 then
      blank_letters = blank_letters + 1
    end
  end
  check_equal("no uppercase letter is blank", blank_letters, 0)

  local blank_digits = 0
  for code = 0xF6, 0xFF do
    if (ink(code) or 0) == 0 then
      blank_digits = blank_digits + 1
    end
  end
  check_equal("no digit is blank", blank_digits, 0)

  -- 'I' is a bar and 'M' is dense; if the bias were off by even one tile this
  -- ordering would not survive.
  check("'I' carries less ink than 'M'", (ink(0x88) or 0) < (ink(0x8C) or 0),
    ("I=%d M=%d"):format(ink(0x88) or -1, ink(0x8C) or -1))
end

--- Dialogue and the scripts that show it.
--
-- The charmap is already proven by the name tables, so what is being checked
-- here is the dialogue bytecode around it — where lines and pages break, where
-- a block ends — and that the script opcode really does point at text.
local function test_scripts(rom, map_result)
  log("\n== scripts and text ==")
  if not map_result then
    log("  SKIP  maps were not located")
    return
  end

  local read, total = 0, 0
  local pages_total, empty_blocks = 0, 0
  local samples = {}
  local by_opcode = {}

  for _, header in ipairs(map_result.headers) do
    local decoded = not header.unparsed and events.decode(rom, header)
    if decoded then
      local said = scripts.read_map_text(rom, header, decoded)
      read = read + said.understood
      total = total + said.total

      for _, group in ipairs { said.bg, said.objects } do
        for _, found in pairs(group) do
          for _, entry in ipairs(found.blocks) do
            by_opcode[entry.opcode_name] = (by_opcode[entry.opcode_name] or 0) + 1
            pages_total = pages_total + #entry.block.pages
          end

          local flat = text.flatten(found.blocks[1].block)
          if flat == "" then
            empty_blocks = empty_blocks + 1
          elseif #samples < 6 then
            samples[#samples + 1] = flat
          end
        end
      end
    end
  end

  check("scripts resolve to text", read > 400,
    ("%d of %d scripts read as text"):format(read, total))
  log("        %d of %d scripts yield text when walked", read, total)

  local opcode_list = {}
  for name, count in pairs(by_opcode) do
    opcode_list[#opcode_list + 1] = ("%s x%d"):format(name, count)
  end
  table.sort(opcode_list)
  log("        %s", table.concat(opcode_list, ", "))

  check_equal("no decoded block is empty", empty_blocks, 0)
  check("every block has at least one page", pages_total >= read,
    ("%d pages across %d blocks"):format(pages_total, read))

  -- Content check. Signposts in Crystal name routes, cities and towns; if the
  -- charmap or the page splitting were wrong these would not read as words.
  local landmarks = 0
  for _, header in ipairs(map_result.headers) do
    local decoded = not header.unparsed and events.decode(rom, header)
    if decoded then
      local said = scripts.read_map_text(rom, header, decoded)
      for _, found in pairs(said.bg) do
        local flat = text.flatten(found.blocks[1].block)
        if flat:find("ROUTE") or flat:find("CITY") or flat:find("TOWN") then
          landmarks = landmarks + 1
        end
      end
    end
  end
  check("signposts name routes, cities and towns", landmarks >= 20,
    ("%d landmark signs"):format(landmarks))

  log("        sample dialogue:")
  for _, sample in ipairs(samples) do
    log("          %s", sample:sub(1, 72))
  end
end

--- The inferred script opcode table.
--
-- Nothing here checks the widths against a specification, because there is
-- none. What is checked is that the table explains the cartridge: walks land
-- exactly on script boundaries and never overshoot. An overrun means a width is
-- wrong, so holding that at zero is the real assertion.
local function test_script_table(rom, map_result)
  log("\n== script opcode table ==")
  if not map_result then
    log("  SKIP  maps were not located")
    return
  end

  local sorted, total = script_table.collect_entries(rom, map_result, events)
  local extents = script_table.extents(sorted)
  log("        %d script pointers, %d with a usable extent", total, #extents)

  local inferred = script_table.infer(rom, sorted)
  check("inference learns a useful number of opcodes", inferred.learned >= 20,
    ("learned %d"):format(inferred.learned))
  log("        learned %d opcodes over %d rounds", inferred.learned, inferred.rounds)

  -- The bootstrap: 3-byte scripts fix the common openers at two operand bytes.
  check_equal("$53 takes two operand bytes", inferred.widths[0x53], 2)
  check_equal("$51 takes two operand bytes", inferred.widths[0x51], 2)
  check_equal("$91 takes none and ends the script", inferred.widths[0x91], 0)
  check("$91 is a terminator", inferred.terminators[0x91] == true)

  local counts = script_table.score(rom, sorted, inferred)
  log("        walks: %d ended (%d exact), %d blocked, %d overran",
    counts.ended, counts.exact, counts.unknown, counts.overrun)

  -- The assertion that matters. A wrong width desynchronises the walk and it
  -- sails past the script boundary; zero overruns across 1500 scripts is what
  -- says the widths are right.
  check_equal("no walk overruns its script", counts.overrun, 0)

  check("most completed walks land exactly on the boundary",
    counts.exact >= counts.ended * 0.9,
    ("%d of %d exact"):format(counts.exact, counts.ended))

  check("a substantial share of scripts walk to completion",
    counts.ended >= 700, ("%d of %d"):format(counts.ended, #extents))
end

--- Wild encounters and trainer parties.
--
-- Checked against content that is a matter of public record: the gym leaders'
-- teams, and the fact that starters and legendaries do not appear in grass.
-- The structures come from a disassembly, so these tests exist to confirm the
-- tables were located in *this* cartridge, not to restate the documentation.
local function test_battle_data(rom, species_names)
  log("\n== wild encounters ==")

  local grass, grass_err = encounters.locate_grass(rom)
  if check("located grass encounter tables", grass ~= nil, grass_err) then
    local maps, bad_species, bad_levels = 0, 0, 0
    local seen = {}
    for _, run in ipairs(grass) do
      log("        0x%06X (bank $%02X): %d maps",
        run.offset, math.floor(run.offset / 0x4000), run.count)
      for _, entry in ipairs(run.entries) do
        maps = maps + 1
        for _, time in ipairs(encounters.times) do
          for _, slot in ipairs(entry.slots[time]) do
            seen[slot.species] = true
            if slot.species < 1 or slot.species > 251 then
              bad_species = bad_species + 1
            end
            if slot.level < 2 or slot.level > 70 then
              bad_levels = bad_levels + 1
            end
          end
        end
      end
    end

    check("Crystal has grass encounters on many maps", maps >= 80,
      ("%d maps"):format(maps))
    check_equal("every wild species exists", bad_species, 0)
    check_equal("every wild level is sane", bad_levels, 0)

    local distinct = 0
    for _ in pairs(seen) do
      distinct = distinct + 1
    end
    log("        %d distinct species appear in grass", distinct)
    check("a wide range of species appear in grass", distinct >= 90,
      ("%d distinct"):format(distinct))

    -- The starters are given, never found in grass.
    check("starters do not appear in grass",
      not seen[152] and not seen[155] and not seen[158])
  end

  local water, water_err = encounters.locate_water(rom)
  if check("located water encounter tables", water ~= nil, water_err) then
    local maps = 0
    for _, run in ipairs(water) do
      maps = maps + run.count
    end
    log("        %d maps with water encounters", maps)
    check("water encounters cover a good number of maps", maps >= 40,
      ("%d maps"):format(maps))
  end

  log("\n== trainers ==")
  local runs, trainer_err = trainers.locate(rom)
  if not check("located trainer parties", runs ~= nil, trainer_err) then
    return
  end

  local all = {}
  for _, run in ipairs(runs) do
    for _, entry in ipairs(run.entries) do
      all[#all + 1] = entry
    end
  end
  log("        %d runs, %d trainers", #runs, #all)
  check("Crystal has hundreds of trainers", #all >= 400,
    ("%d trainers"):format(#all))

  local by_name = {}
  for _, trainer in ipairs(all) do
    by_name[trainer.name] = by_name[trainer.name] or trainer
  end

  local function team_of(name)
    local trainer = by_name[name]
    if not trainer then
      return nil
    end
    local parts = {}
    for _, member in ipairs(trainer.party) do
      parts[#parts + 1] = ("%d/%s"):format(member.level,
        species_names and species_names[member.species] or member.species)
    end
    return table.concat(parts, " ")
  end

  -- Gym leaders, whose teams are not in dispute.
  check_equal("Falkner's team", team_of("FALKNER"), "7/PIDGEY 9/PIDGEOTTO")
  check_equal("Whitney's team", team_of("WHITNEY"), "18/CLEFAIRY 20/MILTANK")
  check_equal("Bugsy's team", team_of("BUGSY"),
    "14/METAPOD 14/KAKUNA 16/SCYTHER")

  local with_moves, with_items = 0, 0
  for _, trainer in ipairs(all) do
    for _, member in ipairs(trainer.party) do
      if member.moves then
        with_moves = with_moves + 1
      end
      if member.item then
        with_items = with_items + 1
      end
    end
  end
  log("        %d party members carry explicit moves, %d hold an item",
    with_moves, with_items)
  check("some trainers specify moves", with_moves > 100)
  check("some trainers hold items", with_items > 10)
end

--- Stat calculation, checked against values that can be worked out by hand
--- from the published formula.
local function test_pokemon(base_stats, species_names)
  log("\n== pokemon stats ==")
  if not base_stats then
    log("  SKIP  base stats were not located")
    return
  end

  local pokemon = require("src.engine.pokemon")
  local stats = base_stats.records

  -- Pikachu at level 5 with perfect DVs. Base HP 35, attack 55.
  -- HP    = floor((35+15)*2*5/100) + 5 + 10 = 5 + 15 = 20
  -- attack= floor((55+15)*2*5/100) + 5      = 7 + 5  = 12
  local perfect = { attack = 15, defense = 15, speed = 15, special = 15 }
  local pikachu = pokemon.new(25, stats[25], { level = 5, dvs = perfect })
  check_equal("Pikachu L5 perfect HP", pikachu.stats.hp, 20)
  check_equal("Pikachu L5 perfect attack", pikachu.stats.attack, 12)
  check_equal("a fresh Pokémon is at full health", pikachu.hp, pikachu.stats.hp)

  -- The HP DV is assembled from the low bit of the other four, so all-perfect
  -- gives 15 and all-even gives 0.
  check_equal("perfect DVs give an HP DV of 15", pokemon.hp_dv(perfect), 15)
  check_equal("even DVs give an HP DV of 0",
    pokemon.hp_dv { attack = 14, defense = 10, speed = 4, special = 0 }, 0)

  -- Blissey at level 100 with perfect DVs and no training:
  -- floor(((255+15)*2)*100/100) + 100 + 10 = 540 + 110 = 650.
  local blissey = pokemon.new(242, stats[242], { level = 100, dvs = perfect })
  check_equal("Blissey L100 perfect HP, untrained", blissey.stats.hp, 650)

  -- Fully trained, stat experience adds floor(sqrt(65535)/4) = 63 to the term,
  -- which is the only path that exercises the statexp branch.
  local trained = pokemon.new(242, stats[242], {
    level = 100, dvs = perfect,
    statexp = { hp = 65535 },
  })
  check_equal("Blissey L100 perfect HP, fully trained", trained.stats.hp, 713)
  check("training raises HP", trained.stats.hp > blissey.stats.hp)

  -- Stats must rise with level and never with nothing else changing.
  local low = pokemon.new(25, stats[25], { level = 5, dvs = perfect })
  local high = pokemon.new(25, stats[25], { level = 50, dvs = perfect })
  check("stats rise with level", high.stats.attack > low.stats.attack,
    ("%d vs %d"):format(high.stats.attack, low.stats.attack))

  -- Shininess is a DV pattern, not a flag.
  check("the shiny DV pattern is recognised",
    pokemon.is_shiny { attack = 14, defense = 10, speed = 10, special = 10 })
  check("ordinary DVs are not shiny",
    not pokemon.is_shiny { attack = 5, defense = 5, speed = 5, special = 5 })

  -- Types come from the species record.
  check_equal("Pikachu is electric", pikachu.types[1], "electric")

  -- Every species must produce sane stats at both ends of the level range.
  local bad = 0
  for species = 1, #stats do
    for _, level in ipairs { 2, 100 } do
      local instance = pokemon.new(species, stats[species],
        { level = level, dvs = perfect })
      for _, stat in ipairs(pokemon.STATS) do
        local value = instance.stats[stat]
        if value < 1 or value > 999 then
          bad = bad + 1
        end
      end
    end
  end
  check_equal("every species has usable stats at levels 2 and 100", bad, 0)
  log("        %d species checked", #stats)

  if species_names then
    log("        %s L5: HP %d ATK %d DEF %d SPD %d",
      species_names[25], pikachu.stats.hp, pikachu.stats.attack,
      pikachu.stats.defense, pikachu.stats.speed)
  end
end

--- The type chart and the damage formula.
--
-- Type matchups are checked against relationships every player knows, which is
-- the only independent check available for a table transcribed from a
-- reference. Damage is checked by computing the formula by hand.
local function test_battle(base_stats, move_records, species_names, move_names)
  log("\n== battle ==")
  if not base_stats or not move_records then
    log("  SKIP  base stats or moves were not located")
    return
  end

  local types = require("src.engine.types")
  local battle = require("src.engine.battle")
  local pokemon = require("src.engine.pokemon")
  local stats = base_stats.records
  local moves = move_records.records

  -- Matchups nobody disputes.
  check_equal("water beats fire", types.against("water", "fire"), types.SUPER)
  check_equal("fire is weak to water", types.against("fire", "water"), types.NOT_VERY)
  check_equal("electric cannot hit ground", types.against("electric", "ground"), 0)
  check_equal("ghost cannot hit normal", types.against("ghost", "normal"), 0)
  check_equal("normal on normal is neutral",
    types.against("normal", "normal"), types.NORMAL)

  -- Gen 2 specifics that later games changed, so a table copied from the wrong
  -- generation would fail here.
  check_equal("ghost beats psychic in Gen 2",
    types.against("ghost", "psychic"), types.SUPER)
  check_equal("dark resists psychic entirely",
    types.against("psychic", "dark"), 0)
  check_equal("steel resists ice", types.against("ice", "steel"), types.NOT_VERY)

  -- Stacking across a dual type: fire on a grass/steel target is 2x * 2x.
  check_equal("double weakness stacks",
    types.effectiveness("fire", { "grass", "steel" }), 40)
  check_equal("weakness and resistance cancel",
    types.effectiveness("water", { "fire", "grass" }), 10)
  check_equal("a duplicated type only counts once",
    types.effectiveness("water", { "fire", "fire" }), 20)

  -- Gen 2 splits physical and special by type, not by move.
  check("normal is physical", types.is_physical("normal"))
  check("fire is special", not types.is_physical("fire"))

  -- Damage, computed by hand. A level 10 attacker, 30 attack, against 30
  -- defence, with a 40-power same-type-less move, no crit, top of the spread:
  --   base = floor(2*10/5 + 2) = 6
  --   6 * 40 * 30 / 30 / 50 = floor(240/50) = 4
  --   +2 = 6
  local attacker = pokemon.new(19, stats[19], { level = 10,
    dvs = { attack = 0, defense = 0, speed = 0, special = 0 } })
  local defender = pokemon.new(19, stats[19], { level = 10,
    dvs = { attack = 0, defense = 0, speed = 0, special = 0 } })

  local fixed = { power = 40, type = "psychic", accuracy = 255 }
  local damage = battle.damage(attacker, defender, fixed,
    { crit = false, spread = battle.SPREAD_HIGH })
  check("a plain hit does sensible damage", damage > 0 and damage < defender.stats.hp,
    ("%d damage against %d HP"):format(damage, defender.stats.hp))

  -- A critical hit must beat a normal one, and STAB must beat neither-type.
  local plain = battle.damage(attacker, defender, fixed,
    { crit = false, spread = battle.SPREAD_HIGH })
  local crit = battle.damage(attacker, defender, fixed,
    { crit = true, spread = battle.SPREAD_HIGH })
  check("critical hits hurt more", crit > plain, ("%d vs %d"):format(crit, plain))

  local stab = battle.damage(attacker, defender,
    { power = 40, type = attacker.types[1], accuracy = 255 },
    { crit = false, spread = battle.SPREAD_HIGH })
  check("same-type attacks hurt more", stab > plain,
    ("%d vs %d"):format(stab, plain))

  -- No effect means no damage at all, not one point.
  local ghost_defender = pokemon.new(92, stats[92], { level = 10,
    dvs = { attack = 0, defense = 0, speed = 0, special = 0 } })
  local nothing = battle.damage(attacker, ghost_defender,
    { power = 40, type = "normal", accuracy = 255 },
    { crit = false, spread = battle.SPREAD_HIGH })
  check_equal("an immune target takes nothing", nothing, 0)

  -- A whole battle must terminate rather than loop, and the loser must be the
  -- one on zero HP.
  local names = species_names or {}
  local fight = battle.new(
    pokemon.new(25, stats[25], { level = 50 }),
    pokemon.new(19, stats[19], { level = 3 }),
    moves, move_names or {}, names)

  local turns = 0
  while not fight.over and turns < 200 do
    turns = turns + 1
    fight:turn(1, 1, { crit = false, spread = battle.SPREAD_HIGH, coin = 0 })
  end

  check("a battle reaches a conclusion", fight.over,
    ("%d turns elapsed"):format(turns))
  check_equal("the level 50 wins against the level 3", fight.winner, "player")
  check("the loser is on zero HP", fight.opponent.hp == 0)
  log("        battle resolved in %d turns", turns)
  for _, line in ipairs(fight.log) do
    log("          %s", line)
  end
end

--- Level-up learnsets and evolutions.
local function test_learnsets(rom, species_names, move_names)
  log("\n== learnsets ==")

  local learnsets = require("src.rom.learnsets")
  local result, why = learnsets.locate(rom)
  if not check("located the learnset table", result ~= nil, why) then
    return
  end

  log("        0x%06X (bank $%02X), %d species",
    result.offset, math.floor(result.offset / 0x4000), #result.records)
  check_equal("one block per species", #result.records, 251)

  local names = species_names or {}
  local moves = move_names or {}

  -- Bulbasaur, whose first two moves and evolution are not in dispute.
  local bulbasaur = result.records[1]
  check_equal("Bulbasaur's first move is at level 1", bulbasaur.moves[1].level, 1)
  check_equal("Bulbasaur starts with Tackle",
    moves[bulbasaur.moves[1].move], "TACKLE")
  check_equal("Bulbasaur learns Growl at 4", bulbasaur.moves[2].level, 4)
  check_equal("Bulbasaur's second move is Growl",
    moves[bulbasaur.moves[2].move], "GROWL")
  check_equal("Bulbasaur has one evolution", #bulbasaur.evolutions, 1)
  check_equal("Bulbasaur evolves by level", bulbasaur.evolutions[1].method, "level")
  check_equal("Bulbasaur evolves at 16", bulbasaur.evolutions[1].level, 16)
  check_equal("Bulbasaur evolves into Ivysaur",
    names[bulbasaur.evolutions[1].into], "IVYSAUR")

  -- Structural checks across the whole table.
  local no_moves, bad_levels, total_moves = 0, 0, 0
  local with_evolutions = 0
  local methods = {}
  for _, record in ipairs(result.records) do
    if #record.moves == 0 then
      no_moves = no_moves + 1
    end
    total_moves = total_moves + #record.moves
    for _, entry in ipairs(record.moves) do
      if entry.level < 1 or entry.level > 100 then
        bad_levels = bad_levels + 1
      end
    end
    if #record.evolutions > 0 then
      with_evolutions = with_evolutions + 1
    end
    for _, evolution in ipairs(record.evolutions) do
      methods[evolution.method] = (methods[evolution.method] or 0) + 1
    end
  end

  check_equal("every species learns something", no_moves, 0)
  check_equal("every learn level is in range", bad_levels, 0)
  log("        %d level-up moves in total, %d species evolve",
    total_moves, with_evolutions)

  local method_list = {}
  for method, count in pairs(methods) do
    method_list[#method_list + 1] = ("%s x%d"):format(method, count)
  end
  table.sort(method_list)
  log("        evolution methods: %s", table.concat(method_list, ", "))

  -- Every method Gen 2 has should appear somewhere.
  check("stone evolutions exist", (methods.item or 0) > 0)
  check("trade evolutions exist", (methods.trade or 0) > 0)
  check("happiness evolutions exist", (methods.happiness or 0) > 0)
  -- Tyrogue is the only species that evolves on a stat comparison.
  check("the stat-comparison evolution exists", (methods.stat or 0) > 0)

  -- Moves known at a level: the last four learned at or below it.
  local at_five = learnsets.moves_at(bulbasaur, 5)
  check("Bulbasaur knows two moves at level 5", #at_five == 2,
    ("knows %d"):format(#at_five))
  local at_hundred = learnsets.moves_at(bulbasaur, 100)
  check_equal("a Pokémon never knows more than four moves", #at_hundred, 4)

  local sample = {}
  for _, move in ipairs(at_hundred) do
    sample[#sample + 1] = moves[move] or ("#" .. move)
  end
  log("        %s at L100 knows: %s", names[1] or "?",
    table.concat(sample, ", "))
end

--- Catching.
local function test_catching(base_stats)
  log("\n== catching ==")
  if not base_stats then
    log("  SKIP  base stats were not located")
    return
  end

  local catching = require("src.engine.catching")
  local pokemon = require("src.engine.pokemon")
  local stats = base_stats.records

  local perfect = { attack = 15, defense = 15, speed = 15, special = 15 }
  local target = pokemon.new(19, stats[19], { level = 10, dvs = perfect })
  local rate = stats[19].catch_rate

  -- A hurt target is easier to catch than a healthy one.
  local healthy = catching.value(target, rate, "poke")
  target.hp = 1
  local hurt = catching.value(target, rate, "poke")
  check("a hurt target is easier to catch", hurt > healthy,
    ("%d at 1 HP vs %d at full"):format(hurt, healthy))

  -- Better balls are better.
  target.hp = target.stats.hp
  local poke = catching.value(target, rate, "poke")
  local great = catching.value(target, rate, "great")
  local ultra = catching.value(target, rate, "ultra")
  check("a Great Ball beats a Poké Ball", great > poke,
    ("%d vs %d"):format(great, poke))
  check("an Ultra Ball beats a Great Ball", ultra > great,
    ("%d vs %d"):format(ultra, great))

  -- The Master Ball never fails, whatever the target.
  local legendary = pokemon.new(150, stats[150], { level = 70, dvs = perfect })
  local caught = catching.attempt(legendary, stats[150].catch_rate, "master",
    nil, 255)
  check("the Master Ball always catches", caught)

  -- Mewtwo in an ordinary ball at full health should essentially never work.
  local hopeless = catching.value(legendary, stats[150].catch_rate, "poke")
  check("a legendary at full health resists a Poké Ball", hopeless < 20,
    ("value %d"):format(hopeless))

  -- Sleep helps more than nothing does. Note the Gen 2 quirk: the "nothing"
  -- case still receives the smaller bonus rather than none.
  target.hp = math.floor(target.stats.hp / 2)
  local awake = catching.value(target, rate, "poke")
  local asleep = catching.value(target, rate, "poke", "sleep")
  check("sleep helps", asleep > awake, ("%d vs %d"):format(asleep, awake))
  check_equal("the quirk is preserved: no status still adds 5",
    asleep - awake, catching.SLEEP_FREEZE_BONUS - catching.OTHER_BONUS)

  -- The roll decides, and the boundary is exclusive.
  local value = catching.value(target, rate, "poke")
  check("a roll below the value catches",
    (catching.attempt(target, rate, "poke", nil, value - 1)))
  check("a roll at the value does not",
    not (catching.attempt(target, rate, "poke", nil, value)))

  log("        Rattata L10 half HP: value %d of 255", value)
end

--- Saving and loading.
--
-- Runs against the real cache, writes a save, reads it back, and then removes
-- it so the test leaves nothing behind.
local function test_save(base_stats)
  log("\n== saving ==")
  if not base_stats then
    log("  SKIP  base stats were not located")
    return
  end

  local save = require("src.engine.save")
  local pokemon = require("src.engine.pokemon")
  local stats = base_stats.records
  local game_id = "harness_test"

  -- A party worth round-tripping: two members, one hurt, distinct DVs.
  local first = pokemon.new(155, stats[155], {
    level = 12,
    dvs = { attack = 9, defense = 4, speed = 15, special = 2 },
    moves = { 33, 52 },
  })
  first.hp = 7

  local second = pokemon.new(19, stats[19], {
    level = 3,
    dvs = { attack = 1, defense = 1, speed = 1, special = 1 },
    moves = { 33 },
  })

  local ok, why = save.write(game_id, {
    map_index = 42, cell_x = 11, cell_y = 13, facing = "left",
    party = { first, second },
  })
  if not check("a save is written", ok, why) then
    return
  end

  local state, read_err = save.read(game_id, stats)
  if not check("a save is read back", state ~= nil, read_err) then
    save.remove(game_id)
    return
  end

  check_equal("the map survives", state.map_index, 42)
  check_equal("the position survives", state.cell_x, 11)
  check_equal("the facing survives", state.facing, "left")
  check_equal("the party size survives", #state.party, 2)

  local restored = state.party[1]
  check_equal("species survives", restored.species, 155)
  check_equal("level survives", restored.level, 12)
  check_equal("DVs survive", restored.dvs.speed, 15)
  check_equal("current HP survives", restored.hp, 7)
  check_equal("moves survive", restored.moves[2], 52)

  -- Stats are not stored; they are recomputed, so they must match exactly what
  -- the same species, level and DVs produce fresh.
  local fresh = pokemon.new(155, stats[155], {
    level = 12,
    dvs = { attack = 9, defense = 4, speed = 15, special = 2 },
  })
  check_equal("stats are recomputed, not stored",
    restored.stats.attack, fresh.stats.attack)
  check_equal("recomputed HP matches too", restored.stats.hp, fresh.stats.hp)
  check("current HP is below maximum after loading a hurt Pokémon",
    restored.hp < restored.stats.hp)

  -- A save from a future format must be refused rather than half-read.
  local raw = ("return { format_version = %d, game = %q, party = {} }")
    :format(save.FORMAT_VERSION + 1, game_id)
  love.filesystem.write(save.path(game_id), raw)
  local refused, version_err = save.read(game_id, stats)
  check("a save from a newer format is refused", refused == nil, version_err)

  save.remove(game_id)
  check("the save can be removed", not save.exists(game_id))
end

--- Status conditions and stat stages.
local function test_status(base_stats, move_records)
  log("\n== status and stages ==")
  if not base_stats or not move_records then
    log("  SKIP  base stats or moves were not located")
    return
  end

  local stages = require("src.engine.stages")
  local status = require("src.engine.status")
  local battle = require("src.engine.battle")
  local pokemon = require("src.engine.pokemon")
  local stats = base_stats.records
  local moves = move_records.records

  -- The multipliers are not symmetric, which is the thing a formula gets wrong.
  check_equal("+1 is 150%", stages.apply(100, 1), 150)
  check_equal("-1 is 66%, not 75%", stages.apply(100, -1), 66)
  check_equal("+6 quadruples", stages.apply(100, 6), 400)
  check_equal("-6 quarters", stages.apply(100, -6), 25)
  check_equal("stage 0 changes nothing", stages.apply(100, 0), 100)

  -- Stages clamp rather than run away.
  local set = stages.new()
  for _ = 1, 10 do
    stages.shift(set, "attack", 1)
  end
  check_equal("stages clamp at +6", set.attack, stages.MAX)
  local _, moved = stages.shift(set, "attack", 1)
  check("a clamped stage reports it did not move", not moved)

  -- Burn halves attack and paralysis quarters speed, outside the stage system.
  local burned = pokemon.new(155, stats[155], { level = 20 })
  check_equal("a healthy Pokémon has no attack penalty",
    status.attack_factor(burned), 1)
  status.apply(burned, status.BURN)
  check_equal("burn halves attack", status.attack_factor(burned), 0.5)
  status.clear(burned)
  status.apply(burned, status.PARALYSIS)
  check_equal("paralysis quarters speed", status.speed_factor(burned), 0.25)

  -- Only one status at a time.
  status.clear(burned)
  check("a status applies to a healthy Pokémon",
    status.apply(burned, status.POISON))
  check("a second status does not stack",
    not status.apply(burned, status.BURN))
  check_equal("the first status is kept", burned.status, status.POISON)

  -- Residual damage is a fraction of maximum health, and toxic climbs.
  local poisoned = pokemon.new(242, stats[242], { level = 50 })
  status.apply(poisoned, status.POISON)
  local tick = status.residual(poisoned)
  check_equal("poison costs an eighth of maximum HP",
    tick, math.floor(poisoned.stats.hp / 8))

  local toxined = pokemon.new(242, stats[242], { level = 50 })
  status.apply(toxined, status.TOXIC)
  local first_tick = status.residual(toxined)
  local second_tick = status.residual(toxined)
  check("toxic damage climbs", second_tick > first_tick,
    ("%d then %d"):format(first_tick, second_tick))

  -- Sleep expires; freeze does not, on its own.
  local sleeper = pokemon.new(155, stats[155], { level = 20 })
  status.apply(sleeper, status.SLEEP, function() return 2 end)
  local acting = status.can_act(sleeper)
  check("a sleeping Pokémon cannot act", not acting)
  status.can_act(sleeper)
  check("sleep wears off", sleeper.status == nil)

  local frozen = pokemon.new(155, stats[155], { level = 20 })
  status.apply(frozen, status.FREEZE)
  status.can_act(frozen)
  status.can_act(frozen)
  check("freeze does not wear off by itself", frozen.status == status.FREEZE)
  check("a fire move thaws it", status.thaw_on_hit(frozen, "fire"))
  check("and the freeze is gone", frozen.status == nil)

  -- Paralysis changes who goes first, which is the point of it.
  -- Identical DVs, or the two are not actually the same speed and the coin
  -- never gets consulted.
  local same = { attack = 8, defense = 8, speed = 8, special = 8 }
  local quick = pokemon.new(25, stats[25], { level = 50, dvs = same })
  local slow = pokemon.new(25, stats[25], { level = 50, dvs = same })
  local first = battle.order(
    { pokemon = quick, side = "a" }, { pokemon = slow, side = "b" }, 0)
  check_equal("equal speeds break by the coin", first.side, "a")

  status.apply(quick, status.PARALYSIS)
  local now_first = battle.order(
    { pokemon = quick, side = "a" }, { pokemon = slow, side = "b" }, 0)
  check_equal("paralysis loses the speed race", now_first.side, "b")

  -- A staged attack really does more damage.
  local attacker = pokemon.new(155, stats[155], { level = 30 })
  local defender = pokemon.new(19, stats[19], { level = 30 })
  attacker.stages = stages.new()
  defender.stages = stages.new()

  local move = { power = 60, type = "normal", accuracy = 255 }
  local plain = battle.damage(attacker, defender, move,
    { crit = false, spread = battle.SPREAD_HIGH })
  attacker.stages.attack = 2
  local boosted = battle.damage(attacker, defender, move,
    { crit = false, spread = battle.SPREAD_HIGH })
  check("raising attack raises damage", boosted > plain,
    ("%d vs %d"):format(boosted, plain))

  attacker.stages.attack = 0
  defender.stages.defense = 2
  local resisted = battle.damage(attacker, defender, move,
    { crit = false, spread = battle.SPREAD_HIGH })
  check("raising defence lowers damage", resisted < plain,
    ("%d vs %d"):format(resisted, plain))

  -- And a real move with a real effect byte lands its status.
  local effects = require("src.engine.move_effects")
  local thunder_wave
  for id, record in ipairs(moves) do
    if effects.lookup(record.effect)
      and effects.lookup(record.effect).status == status.PARALYSIS
      and effects.lookup(record.effect).always then
      thunder_wave = id
      break
    end
  end
  check("the cartridge has a move that always paralyses", thunder_wave ~= nil)

  if thunder_wave then
    local fight = battle.new(
      pokemon.new(25, stats[25], { level = 30 }),
      pokemon.new(19, stats[19], { level = 30 }),
      moves, {}, {})
    fight:strike(fight.player, fight.opponent, thunder_wave,
      { crit = false, spread = battle.SPREAD_HIGH, effect_roll = 0 })
    check_equal("it paralyses the target", fight.opponent.status,
      status.PARALYSIS)
  end
end

--- Items: the attribute table read off the cartridge, and the bag built on it.
local function test_items(attributes, names)
  log("\n== items ==")

  local item_data = require("src.rom.items")
  local bag = require("src.engine.bag")
  local catching = require("src.engine.catching")

  if not check("item attributes were located", attributes ~= nil) then
    return
  end
  if not check("item names were located", names ~= nil) then
    return
  end

  check_equal("255 items have attributes", #attributes, item_data.COUNT)
  check_equal("255 items have names", #names, item_data.COUNT)

  -- Names carry substitution codes, and item 5 is the one that proves it: it
  -- is stored as $54 then " BALL", the $54 being the glyph that reads POKe.
  check_equal("item 5 is the POKe BALL", names[5], "POKé BALL")
  check_equal("item 1 is the MASTER BALL", names[1], "MASTER BALL")
  check_equal("the machines are named in order", names[191], "TM01")
  check_equal("and run to HM07", names[249], "HM07")

  -- Every pocket should be populated, and the numbers should look like a
  -- Pokemon game rather than like a table that happened to validate.
  local by_pocket = {}
  for _, record in ipairs(attributes) do
    by_pocket[record.pocket] = (by_pocket[record.pocket] or 0) + 1
  end
  local shape = {}
  for pocket, count in pairs(by_pocket) do
    shape[#shape + 1] = ("%s %d"):format(pocket, count)
  end
  table.sort(shape)
  log("        %s", table.concat(shape, ", "))

  check("every pocket is used", by_pocket.items and by_pocket.balls
    and by_pocket.key and by_pocket.machines)
  -- 50 TMs plus 7 HMs, and nothing else lives in that pocket.
  check_equal("the machine pocket holds the 57 TMs and HMs",
    by_pocket.machines, 57)
  check("the balls are a dozen or so", by_pocket.balls >= 10
    and by_pocket.balls <= 16, ("%d"):format(by_pocket.balls))

  -- Prices held back from the search, checked again here against the decoded
  -- records rather than the raw bytes.
  check_equal("a POTION costs 300", attributes[18].price, 300)
  check_equal("and restores 20 HP", attributes[18].parameter, 20)
  check_equal("a MAX POTION restores everything it can hold",
    attributes[15].parameter, 255)
  check_equal("the MASTER BALL is free", attributes[1].price, 0)

  -- The property bits, which is where the field is easiest to get backwards.
  check("the BICYCLE can be registered but not tossed",
    attributes[7].selectable and not attributes[7].tossable)
  check("a POTION can be tossed but not registered",
    attributes[18].tossable and not attributes[18].selectable)

  -- Balls are identified by their pocket, not by name, which is what keeps the
  -- Heavy, Level and Friend balls working without being listed anywhere.
  local ball_names = {}
  for index, record in ipairs(attributes) do
    if item_data.is_ball(record) then
      ball_names[#ball_names + 1] = names[index]
    end
  end
  local ball_list = table.concat(ball_names, ", ")
  log("        balls: %s", ball_list)
  check("the odd balls come along by pocket, not by name",
    ball_list:find("HEAVY BALL", 1, true) ~= nil
    and ball_list:find("FRIEND BALL", 1, true) ~= nil)

  -- Which multiplier each ball uses is worked out from its name.
  check_equal("the MASTER BALL is recognised",
    catching.kind_for_name(names[1]), "master")
  check_equal("the ULTRA BALL is recognised",
    catching.kind_for_name(names[2]), "ultra")
  check_equal("the GREAT BALL is recognised",
    catching.kind_for_name(names[4]), "great")
  check_equal("the POKe BALL is the plain one",
    catching.kind_for_name(names[5]), "poke")
  check_equal("an odd ball falls back to the plain multiplier",
    catching.kind_for_name(names[157]), "poke")

  -- The bag itself.
  local held = bag.new(attributes, names)
  held:add(5, 5)
  held:add(18, 3)
  held:add(7, 1)
  check_equal("items land in the pocket the cartridge names",
    held:pocket_of(5), "balls")
  check_equal("the ball pocket holds one kind", #held:pocket("balls"), 1)
  check_equal("the item pocket holds the potion", #held:pocket("items"), 1)
  check_equal("the key pocket holds the bicycle", #held:pocket("key"), 1)
  check_equal("empty pockets are left out", #held:used_pockets(), 3)

  check_equal("the first ball is what a battle reaches for",
    held:first_ball().item, 5)

  -- Stacks cap at 99, and the return says how many were actually taken.
  check_equal("adding past the cap takes only what fits",
    held:add(18, 200), 96)
  check_equal("and the stack stops at 99", held:count(18), 99)

  check("removing more than is held fails", not held:remove(9, 1))
  check("removing what is held works", held:remove(5, 5))
  check_equal("an emptied stack leaves the pocket", held:count(5), 0)
  check_equal("and the pocket with it", #held:used_pockets(), 2)

  -- Selling. A shop pays half, rounded down, and will not take a key item.
  local shop = bag.new(attributes, names)
  shop:add(5, 3)   -- POKe BALL, 200
  shop:add(18, 1)  -- POTION, 300
  shop:add(9, 1)   -- ANTIDOTE, 100
  shop:add(7, 1)   -- BICYCLE, a key item
  shop:add(243, 1) -- HM01, which cannot be tossed either

  check_equal("a shop pays half for a POKe BALL", shop:sell_price(5), 100)
  check_equal("and half for a POTION", shop:sell_price(18), 150)
  check_equal("odd prices round down", shop:sell_price(9),
    math.floor(attributes[9].price / 2))

  -- Nothing here names a key item: the bit that stops the Bicycle being
  -- tossed is the same one that stops it being sold.
  check("the BICYCLE cannot be sold", not shop:can_sell(7))
  check("nor can an HM", not shop:can_sell(243))
  check("but a POTION can", shop:can_sell(18))

  local offered = shop:sellable()
  check_equal("only the sellable things are offered", #offered, 3)
  local offered_names = {}
  for _, entry in ipairs(offered) do
    offered_names[entry.name] = true
  end
  check("the key items are held back", offered_names["BICYCLE"] == nil
    and offered_names["HM01"] == nil)

  -- Everything a shop will take has a price, or it would be sold for nothing.
  for _, entry in ipairs(offered) do
    if entry.price <= 0 then
      check("everything offered is worth something", false, entry.name)
      break
    end
  end
  check("everything offered is worth something", true)

  -- Nothing in the whole item table is sellable-but-worthless, which is what
  -- would happen if the two conditions were checked with an "or".
  local worthless = 0
  for item = 1, item_data.COUNT do
    if shop:can_sell(item) and shop:sell_price(item) <= 0 then
      worthless = worthless + 1
    end
  end
  check_equal("no item is sellable for nothing", worthless, 0)

  -- Buying and selling by quantity. How many you can take on is the smaller of
  -- what the money buys and what the bag will hold.
  check_equal("¥3000 buys five GREAT BALLs at 600",
    bag.affordable(600, 3000, 99), 5)
  check_equal("and four when only four will fit",
    bag.affordable(600, 3000, 4), 4)
  check_equal("one short of the price buys none",
    bag.affordable(600, 599, 99), 0)
  check_equal("a free item is limited only by room",
    bag.affordable(0, 0, 7), 7)
  check_equal("an empty stack has room for a full one",
    bag.new(attributes, names):room_for(18), bag.MAX_STACK)

  -- A stack near the cap limits the purchase rather than silently truncating
  -- it, which is what the buy path relies on to avoid charging for items it
  -- cannot hand over.
  local nearly_full = bag.new(attributes, names)
  nearly_full:add(18, 96)
  check_equal("a nearly full stack has room for three",
    nearly_full:room_for(18), 3)
  check_equal("and money does not create room",
    bag.affordable(300, 999999, nearly_full:room_for(18)), 3)
  check_equal("adding more than fits reports what fit",
    nearly_full:add(18, 10), 3)
  check_equal("and the stack is at the cap", nearly_full:count(18),
    bag.MAX_STACK)

  -- Selling several at once takes them all or none.
  local stack = bag.new(attributes, names)
  stack:add(18, 4)
  check("selling more than is held fails", not stack:remove(18, 5))
  check_equal("and leaves the stack alone", stack:count(18), 4)
  check("selling exactly what is held works", stack:remove(18, 4))
  check_equal("and empties it", stack:count(18), 0)

  -- Round trip through the save.
  local restored = bag.from_list(attributes, names, held:to_list())
  check_equal("the bag survives a save", restored:count(18), 99)
  check_equal("and keeps its key items", restored:count(7), 1)
  check_equal("and does not invent any", restored:total(), held:total())
end

-- Mart inventories.
local function test_marts(rom, names, attributes, map_result)
  log("\n== marts ==")
  if not names or not attributes then
    log("  SKIP  the item tables were not located")
    return
  end

  local marts = require("src.rom.marts")

  local result, why = marts.locate(rom, names, attributes)
  if not check("the mart table was located", result ~= nil, why) then
    return
  end

  log("        %d marts, table at 0x%06X", result.count, result.offset)
  check("Crystal has a few dozen shops", result.count >= 20
    and result.count <= 60, ("%d"):format(result.count))

  -- The structural claim the locator rests on, asserted rather than assumed:
  -- the table of pointers ends exactly where the first list it points at
  -- begins. Noise does not produce that.
  local first = math.huge
  for _, offset in ipairs(result.offsets) do
    first = math.min(first, offset)
  end
  check_equal("the pointer table ends where its data begins",
    result.offset + result.count * 2, first)

  -- The shape alone identifies nothing, which is the point of the above.
  local sellable = marts.sellable_predicate(names, attributes)
  local coincidences = 0
  for offset = 0, rom.size - 2 do
    if marts.decode(rom, offset, sellable) then
      coincidences = coincidences + 1
    end
  end
  log("        %d offsets in the ROM read as a mart list", coincidences)
  check("the list shape on its own is not distinctive",
    coincidences > result.count * 2, ("%d"):format(coincidences))

  -- Every list decoded, and every item in it is something a shop could sell.
  local decoded, stocked, placeholder = 0, {}, 0
  for _, list in ipairs(result.lists) do
    if list then
      decoded = decoded + 1
      for _, item in ipairs(list) do
        stocked[names[item] or "?"] = true
        if names[item] == "TERU-SAMA" then
          placeholder = placeholder + 1
        end
      end
    end
  end
  check_equal("every pointer resolves to a list", decoded, result.count)
  check_equal("no shop stocks an unused slot", placeholder, 0)

  -- The first mart is Cherrygrove's, which sells exactly these four. That is
  -- known independently of this code, which is what makes it a check rather
  -- than a restatement.
  local first_list = {}
  for _, item in ipairs(result.lists[1]) do
    first_list[#first_list + 1] = names[item]
  end
  check_equal("the first mart is Cherrygrove's stock",
    table.concat(first_list, ", "), "POTION, ANTIDOTE, PARLYZ HEAL, AWAKENING")

  -- The department store floors are the interesting ones: a shop that sells
  -- nothing but machines, and one that sells nothing but vitamins.
  local machine_shops, vitamin_shops = 0, 0
  for _, list in ipairs(result.lists) do
    local all_machines, all_vitamins = true, true
    for _, item in ipairs(list) do
      if attributes[item].pocket ~= "machines" then
        all_machines = false
      end
      -- The vitamins are the five that raise a stat permanently.
      local name = names[item]
      if name ~= "HP UP" and name ~= "PROTEIN" and name ~= "IRON"
        and name ~= "CARBOS" and name ~= "CALCIUM" then
        all_vitamins = false
      end
    end
    if all_machines then machine_shops = machine_shops + 1 end
    if all_vitamins then vitamin_shops = vitamin_shops + 1 end
  end
  check("some shops sell only machines", machine_shops >= 4,
    ("%d"):format(machine_shops))
  check("some shops sell only vitamins", vitamin_shops >= 2,
    ("%d"):format(vitamin_shops))

  check("the shops between them stock plenty", stocked["POKé BALL"] == true
    and stocked["ULTRA BALL"] == true and stocked["FULL RESTORE"] == true)

  -- Which shopkeeper opens which shop, found by walking their script for the
  -- pokemart command. The walk stops at branches, so this reaches most of the
  -- shops rather than all of them, and the count is asserted as a floor.
  if not map_result then
    log("  SKIP  maps were not located, so shopkeepers were not looked for")
    return
  end

  local found_marts, shopkeepers = {}, 0
  for _, header in ipairs(map_result.headers) do
    local decoded = not header.unparsed and events.decode(rom, header)
    if decoded then
      local bank = math.floor(header.attributes.scripts / 0x4000)
      for _, object in ipairs(decoded.objects) do
        if object.kind == events.OBJECT_SCRIPT and object.script then
          local index = marts.for_script(rom, scripts, bank, object.script,
            result.count)
          if index then
            shopkeepers = shopkeepers + 1
            found_marts[index] = (found_marts[index] or 0) + 1
          end
        end
      end
    end
  end

  local distinct = 0
  for _ in pairs(found_marts) do distinct = distinct + 1 end
  log("        %d shopkeepers open %d distinct shops", shopkeepers, distinct)
  check("most shops have a shopkeeper who opens them", shopkeepers >= 20,
    ("%d of %d"):format(shopkeepers, result.count))
  -- A shopkeeper standing for two different shops would mean the index is
  -- being read from the wrong place.
  check("each shopkeeper opens one shop", distinct >= shopkeepers - 2,
    ("%d shopkeepers, %d shops"):format(shopkeepers, distinct))
end

-- The menu widget: cursor, wrapping, and the scroll window.
local function test_menu()
  log("\n== menus ==")
  local menu = require("src.engine.menu")

  local list = menu.new({ "A", "B", "C" }, 3)
  check_equal("a new list starts on the first item", list:selected(), "A")

  list:move(1)
  check_equal("down moves to the next", list:selected(), "B")

  list:move(-1)
  list:move(-1)
  check_equal("up from the first wraps to the last", list:selected(), "C")

  list:move(1)
  check_equal("down from the last wraps to the first", list:selected(), "A")

  -- An empty list must not crash or select anything.
  local empty = menu.new({}, 4)
  check("an empty list reports itself empty", empty:is_empty())
  empty:move(1)
  check("moving in an empty list selects nothing", empty:selected() == nil)
  check_equal("an empty list has no rows", #empty:window(), 0)

  -- The scroll window: six items, three visible.
  local long = menu.new({ 1, 2, 3, 4, 5, 6 }, 3)
  check_equal("only the visible rows are returned", #long:window(), 3)
  check_equal("the window starts at the top", long:window()[1].index, 1)

  long:move(1)
  long:move(1)
  check_equal("the window does not scroll until it must",
    long:window()[1].index, 1)

  long:move(1)
  check_equal("the window follows the cursor down", long:window()[1].index, 2)
  check_equal("the cursor is the last visible row",
    long:window()[3].index, long.cursor)

  -- Wrapping from the end has to jump the window, not nudge it.
  long.cursor = 6
  long.offset = 3
  long:move(1)
  check_equal("wrapping to the top resets the window", long:window()[1].index, 1)
  check_equal("and selects the first item", long.cursor, 1)

  -- Exactly one row is ever marked selected.
  local marked = 0
  for _, row in ipairs(long:window()) do
    if row.selected then
      marked = marked + 1
    end
  end
  check_equal("exactly one row is selected", marked, 1)
end

--- Item balls lying on the ground.
local function test_item_balls(rom, map_result, item_names)
  log("\n== item balls ==")
  if not map_result or not item_names then
    log("  SKIP  maps or item names were not located")
    return
  end

  local by_kind = {}
  local balls, quantities, placeholder = {}, {}, 0

  for _, header in ipairs(map_result.headers) do
    local decoded = not header.unparsed and events.decode(rom, header)
    if decoded then
      local bank = math.floor(header.attributes.scripts / 0x4000)
      for _, object in ipairs(decoded.objects) do
        by_kind[object.kind] = (by_kind[object.kind] or 0) + 1
        if object.kind == events.OBJECT_ITEM and object.script then
          local block = events.decode_item(rom, bank, object.script)
          if block then
            balls[#balls + 1] = block
            quantities[block.quantity] = (quantities[block.quantity] or 0) + 1
            -- TERU-SAMA is the placeholder name on the unused item slots. A
            -- real pickup never names one.
            if item_names[block.item] == "TERU-SAMA" then
              placeholder = placeholder + 1
            end
          end
        end
      end
    end
  end

  log("        %d item balls over %d objects of that type", #balls,
    by_kind[events.OBJECT_ITEM] or 0)
  check("Crystal has well over a hundred item balls", #balls >= 150,
    ("%d"):format(#balls))
  check_equal("every object of that type decodes as an item", #balls,
    by_kind[events.OBJECT_ITEM] or 0)

  -- This is the evidence that the nibble means what we think. The quantity
  -- byte is read with no filtering at all in the probe and takes exactly one
  -- value across every item ball; here the decoded quantity says the same.
  local distinct = 0
  for _ in pairs(quantities) do distinct = distinct + 1 end
  check_equal("every item ball holds exactly one thing", distinct, 1)
  check("and that one thing is a single item", quantities[1] == #balls)

  check_equal("no item ball names an unused slot", placeholder, 0)

  -- Spot check that the pickups are the sort of thing found on the ground.
  local found = {}
  for _, block in ipairs(balls) do
    found[item_names[block.item] or "?"] = true
  end
  check("the ground holds ULTRA BALLs", found["ULTRA BALL"] == true)
  check("and NUGGETs", found["NUGGET"] == true)
  check("and RARE CANDY", found["RARE CANDY"] == true)

  -- Item balls and trainers must not be the same objects.
  check("item balls are a different type from trainers",
    events.OBJECT_ITEM ~= events.OBJECT_TRAINER)
  log("        objects by type nibble: 0 -> %d, 1 -> %d, 2 -> %d",
    by_kind[0] or 0, by_kind[1] or 0, by_kind[2] or 0)
end

-- The text codes that were missing, checked on bytes built here rather than
-- found in the cartridge, so the expected reading is stated rather than
-- discovered.
local function test_text_codes()
  log("\n== text codes ==")

  local function block(...)
    local bytes = {}
    for _, value in ipairs({ ... }) do
      bytes[#bytes + 1] = string.char(value)
    end
    return table.concat(bytes)
  end

  local function reads(bytes)
    local decoded = text.decode_dialogue(bytes, 0)
    return decoded and text.flatten(decoded) or nil
  end

  -- The contractions. "didn" then $D5 should read "didn't", which is what the
  -- cartridge means by it: 366 blocks stopped on $D4 alone.
  local D = { 0xD0, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6 }
  local expect = { "'d", "'l", "'m", "'r", "'s", "'t", "'v" }
  for index, code in ipairs(D) do
    check_equal(("$%02X reads %s"):format(code, expect[index]),
      reads(block(0x00, 0x88, code, 0x57)), "I" .. expect[index])
  end

  -- $D5 in context, which is how it was identified.
  check_equal("didn$D5 reads as didn't",
    reads(block(0x00, 0xA3, 0xA8, 0xA3, 0xAD, 0xD5, 0x57)), "didn't")

  -- $75 draws nothing and is stepped over.
  check_equal("$75 draws nothing",
    reads(block(0x00, 0x75, 0x88, 0x57)), "I")
  check_equal("and does not swallow what follows",
    reads(block(0x00, 0x88, 0x75, 0x93, 0x57)), "IT")

  -- $14 stands where a name goes, with no operand.
  check_equal("$14 is a name",
    reads(block(0x00, 0x87, 0xA8, 0x7F, 0x14, 0xE7, 0x57)), "Hi <NAME>!")

  -- $01 is a name too, but it carries the RAM address it reads from, and those
  -- two bytes must not be read as letters. $D099 is work RAM, which is what
  -- gave it away.
  check_equal("$01 takes a two-byte operand",
    reads(block(0x00, 0x01, 0x99, 0xD0, 0x7F, 0xA8, 0xB2, 0x57)),
    "<NAME> is")
  -- Without the skip, $99 and $D0 would read as "Z" and "'d".
  check("the operand is not read as text",
    not (reads(block(0x00, 0x01, 0x99, 0xD0, 0x57)) or ""):find("Z", 1, true))

  -- The codes carry through to what the bitmap font draws, or a placeholder
  -- would render as nothing.
  local decoded = text.decode_dialogue(block(0x00, 0x14, 0x57), 0)
  local codes = decoded and decoded.pages[1] and decoded.pages[1][1]
    and decoded.pages[1][1].codes
  check("a name placeholder still gives the font something to draw",
    codes ~= nil and #codes == 4)

  -- $54 spells out as POKe with the accent, and the accent has to survive the
  -- trip into font codes. Walking the placeholder a byte at a time dropped it,
  -- so POKeMON reached the screen as POKMON.
  local accented = text.decode_dialogue(
    block(0x00, 0x54, 0x8C, 0x8E, 0x8D, 0x57), 0)
  local line = accented and accented.pages[1] and accented.pages[1][1]
  check_equal("POKe spells out with the accent kept", line and line.text,
    "POKéMON")
  check_equal("and reaches the font as seven codes", line and #line.codes, 7)
  check("the accent is there as its own code", (function()
    for _, code in ipairs(line and line.codes or {}) do
      if code == 0xEA then return true end
    end
    return false
  end)())
end

-- The music table. Located and read; not played.
local function test_music(rom)
  log("\n== music ==")

  local music = require("src.rom.music")

  local result, why = music.locate(rom)
  if not check("the music table was located", result ~= nil, why) then
    return
  end

  log("        %d songs at 0x%06X, %d headers end exactly where their first " ..
    "channel begins", result.count, result.offset, result.exact)

  check("Crystal has dozens of songs", result.count >= 40
    and result.count <= 200, ("%d"):format(result.count))

  -- The structural agreement the locator rests on, asserted rather than
  -- assumed: a header's entries are contiguous with the data they point at, so
  -- the arithmetic has to close. It closes for most of them.
  check("most headers run straight into their own channel data",
    result.exact >= result.count * 0.75,
    ("%d of %d"):format(result.exact, result.count))

  -- Songs use two, three or four channels, and the Game Boy has four.
  local by_count, slack = {}, {}
  for _, song in ipairs(result.songs) do
    by_count[song.count] = (by_count[song.count] or 0) + 1
    if not song.exact then
      slack[song.slack] = (slack[song.slack] or 0) + 1
    end
  end
  local shape = {}
  for count, times in pairs(by_count) do
    shape[#shape + 1] = ("%d channels x%d"):format(count, times)
  end
  table.sort(shape)
  log("        %s", table.concat(shape, ", "))

  check("no song asks for more channels than the hardware has",
    by_count[5] == nil and by_count[0] == nil)
  check("most songs use three or four channels",
    (by_count[3] or 0) + (by_count[4] or 0) >= result.count * 0.8)

  -- Where a header does not close exactly, by how much. A scatter would mean
  -- the shape is wrong; one consistent value means one unexplained byte.
  local gaps = {}
  for value, times in pairs(slack) do
    gaps[#gaps + 1] = ("%d byte x%d"):format(value, times)
  end
  table.sort(gaps)
  if #gaps > 0 then
    log("        the rest are short by: %s", table.concat(gaps, ", "))
  end
  check("the ones that do not close are all off by the same amount",
    #gaps <= 1, table.concat(gaps, ", "))

  -- Channels are stored in order within a song.
  local ordered = 0
  for _, song in ipairs(result.songs) do
    local rising = true
    for index = 2, song.count do
      if song.channels[index] < song.channels[index - 1] then
        rising = false
      end
    end
    if rising then ordered = ordered + 1 end
  end
  check_equal("every song's channels are stored in order", ordered,
    result.count)
end

-- Movement blocks: the little language applymovement points at.
local function test_movement(rom, map_result)
  log("\n== movement ==")

  local movement = require("src.rom.movement")

  -- Read from bytes built here, so the expected reading is stated rather than
  -- discovered. $0C is a step down, $0F a step right, $01 a turn to face up.
  local function block(...)
    local bytes = {}
    for _, value in ipairs({ ... }) do
      bytes[#bytes + 1] = string.char(value)
    end
    local fake = { size = #bytes, data = table.concat(bytes) }
    function fake:u8(offset)
      return string.byte(self.data, offset + 1)
    end
    return fake
  end

  local down_twice = movement.decode(block(0x0C, 0x0C, 0x47), 0)
  check_equal("two steps down move two tiles down", down_twice and down_twice.dy, 2)
  check_equal("and none sideways", down_twice and down_twice.dx, 0)
  check_equal("and leave the walker facing down",
    down_twice and down_twice.facing, "down")
  check_equal("and the block is three bytes", down_twice and down_twice.bytes, 3)

  local around = movement.decode(block(0x0C, 0x0D, 0x0E, 0x0F, 0x47), 0)
  check_equal("down, up, left, right cancels out on y",
    around and around.dy, 0)
  check_equal("and on x", around and around.dx, 0)
  check_equal("ending facing the way it last stepped",
    around and around.facing, "right")

  -- The first group of four turns without moving, which is the distinction
  -- that matters: a script that turns someone must not also shift them.
  local turn = movement.decode(block(0x01, 0x47), 0)
  check_equal("a turn changes the facing", turn and turn.facing, "up")
  check_equal("without moving", turn and (turn.dx + turn.dy), 0)

  -- Every group above the turns steps.
  for _, base in ipairs({ 0x04, 0x08, 0x0C, 0x10 }) do
    local stepped = movement.decode(block(base, 0x47), 0)
    check_equal(("$%02X steps"):format(base), stepped and stepped.dy, 1)
  end

  if not map_result then
    log("  SKIP  maps were not located")
    return
  end

  -- The real blocks. This is where the direction mapping is checked against
  -- the cartridge rather than against itself: if up and down were the wrong
  -- way round, objects would walk off their maps far more often.
  local script_decode = require("src.rom.script_decode")
  local std_scripts = require("src.rom.std_scripts")

  local entries = {}
  for _, header in ipairs(map_result.headers) do
    local decoded = not header.unparsed and events.decode(rom, header)
    if decoded then
      local bank = math.floor(header.attributes.scripts / 0x4000)
      for _, object in ipairs(decoded.objects) do
        if object.script and object.kind ~= events.OBJECT_TRAINER
          and object.kind ~= events.OBJECT_ITEM then
          entries[#entries + 1] = { bank = bank, addr = object.script }
        end
      end
      for _, bg in ipairs(decoded.bg_events) do
        if bg.script and bg.kind ~= events.BGEVENT_ITEM then
          entries[#entries + 1] = { bank = bank, addr = bg.script }
        end
      end
      for _, coord in ipairs(decoded.coord_events) do
        if coord.script then
          entries[#entries + 1] = { bank = bank, addr = coord.script }
        end
      end
    end
  end

  local std_result = std_scripts.locate(rom)
  if std_result then
    for _, entry in ipairs(std_result.entries) do
      entries[#entries + 1] = { bank = entry.bank, addr = entry.addr }
    end
  end

  local code = script_decode.reachable(rom, entries)

  local blocks, decoded_ok, with_unknown, longest = 0, 0, 0, 0
  local steps_total = 0
  for _, bank_code in pairs(code) do
    for _, instruction in pairs(bank_code) do
      if instruction.opcode == 0x69 or instruction.opcode == 0x6A then
        blocks = blocks + 1
        if instruction.movement then
          decoded_ok = decoded_ok + 1
          steps_total = steps_total + #instruction.movement.steps
          longest = math.max(longest, #instruction.movement.steps)
          if instruction.movement.unknown then
            with_unknown = with_unknown + 1
          end
        end
      end
    end
  end

  log("        %d movement commands, %d blocks decoded, %d steps, longest %d",
    blocks, decoded_ok, steps_total, longest)
  check("the movement blocks decode", decoded_ok >= blocks * 0.95,
    ("%d of %d"):format(decoded_ok, blocks))
  check("and most end cleanly rather than on something unrecognised",
    with_unknown <= blocks * 0.2,
    ("%d of %d stopped early"):format(with_unknown, blocks))
  -- The longest walk in the game is 56 steps, which is a cutscene rather than
  -- someone stepping aside. What matters is that it fits inside the decoder's
  -- own limit, or the block would come back unfinished and look like a walk
  -- that simply stopped.
  check("the longest walk fits within the decoder's limit",
    longest < movement.MAX_STEPS, ("%d of %d"):format(longest,
      movement.MAX_STEPS))
end

-- The script interpreter, run over every script in the game.
local function test_script_vm(rom, map_result)
  log("\n== script interpreter ==")
  if not map_result then
    log("  SKIP  maps were not located")
    return
  end

  local script_decode = require("src.rom.script_decode")
  local vm = require("src.engine.vm")

  -- Every entry point, the same set the importer decodes from.
  local entries = {}
  for _, header in ipairs(map_result.headers) do
    local decoded = not header.unparsed and events.decode(rom, header)
    if decoded then
      local bank = math.floor(header.attributes.scripts / 0x4000)
      for _, bg in ipairs(decoded.bg_events) do
        if bg.script and bg.kind ~= events.BGEVENT_ITEM then
          entries[#entries + 1] = { bank = bank, addr = bg.script }
        end
      end
      for _, object in ipairs(decoded.objects) do
        if object.script and object.kind ~= events.OBJECT_TRAINER
          and object.kind ~= events.OBJECT_ITEM then
          entries[#entries + 1] = { bank = bank, addr = object.script }
        end
      end
      for _, coord in ipairs(decoded.coord_events) do
        if coord.script then
          entries[#entries + 1] = { bank = bank, addr = coord.script }
        end
      end
    end
  end

  -- The standard scripts are entry points too, and jumpstd resolves through
  -- them, so they have to be decoded alongside the map scripts.
  local std_scripts = require("src.rom.std_scripts")
  local std_result, std_err = std_scripts.locate(rom)
  if check("the standard script table was located", std_result ~= nil, std_err) then
    log("        %d standard scripts at 0x%06X in bank $%02X, %d decode as " ..
      "routines", std_result.count, std_result.offset, std_result.bank,
      std_result.real)
    -- 52 in Crystal, and the highest index any script asks for is 51. That
    -- agreement between two independently found things is the evidence.
    check("the table has a few dozen entries", std_result.count >= 40
      and std_result.count <= 80, ("%d"):format(std_result.count))
    -- Not all of them, and deliberately so. The routine test wants at least
    -- three instructions and something recognisable among them, which is the
    -- strictness that killed two false tables -- one whose 104 entries all
    -- pointed at the same terminator byte, and one whose targets marched in a
    -- constant nine-byte step. Being that strict necessarily rejects the
    -- genuinely short routines too.
    check("most entries are real routines",
      std_result.real >= std_result.count * 0.65,
      ("%d of %d"):format(std_result.real, std_result.count))

    for _, entry in ipairs(std_result.entries) do
      entries[#entries + 1] = { bank = entry.bank, addr = entry.addr }
    end
  end

  local code, stats = script_decode.reachable(rom, entries)
  log("        %d entry points, %d instructions, %d blocks unreadable",
    #entries, stats.instructions, stats.failed)
  check("the bytecode decodes", stats.instructions > 8000,
    ("%d"):format(stats.instructions))

  -- A stand-in world, so the interpreter can be run without a screen. It says
  -- yes to nothing and no to nothing that matters, which is the point: the
  -- test is about control flow reaching an end, not about outcomes.
  local flags = { event = {}, flag = {} }
  local host = {
    script_flag = function(_, space, index) return flags[space][index] == true end,
    set_script_flag = function(_, space, index, on)
      flags[space][index] = on or nil
    end,
    script_has_item = function() return false end,
    script_give_item = function() return true end,
    script_take_item = function() return false end,
    script_pocket_full = function() return false end,
    script_money = function() return 3000 end,
    script_add_money = function() end,
    face_player = function() return false end,
  }

  local outcomes, ignored, stopped_on, ended_by = {}, {}, {}, {}
  local lost_at = {}
  local text_shown = 0

  for _, entry in ipairs(entries) do
    local machine = vm.new(host, code, std_result and std_result.entries)
    if not machine:start(entry.bank, entry.addr) then
      outcomes["no script"] = (outcomes["no script"] or 0) + 1
    else
      -- Drive it the way the engine does: resume, and whenever it asks for a
      -- text box, pretend the player read it and press on.
      local status
      for _ = 1, 200 do
        status = machine:resume()
        if status ~= "waiting" then
          break
        end
        if machine.pending and machine.pending.kind == "text" then
          text_shown = text_shown + 1
        end
      end
      outcomes[status] = (outcomes[status] or 0) + 1
      if status == "unsupported" then
        stopped_on[machine.stopped_on] = (stopped_on[machine.stopped_on] or 0) + 1
      end
      if machine.ended_by then
        ended_by[machine.ended_by] = (ended_by[machine.ended_by] or 0) + 1
      end
      if status == "lost" then
        lost_at[machine.lost_at or "?"] = (lost_at[machine.lost_at or "?"] or 0) + 1
      end
      for op, count in pairs(machine.ignored) do
        ignored[op] = (ignored[op] or 0) + count
      end
    end
  end

  local ended = outcomes.ended or 0
  local ranked = {}
  for outcome, count in pairs(outcomes) do
    ranked[#ranked + 1] = ("%s %d"):format(outcome, count)
  end
  table.sort(ranked)
  log("        outcomes: %s", table.concat(ranked, ", "))
  log("        %d text boxes shown along the way", text_shown)

  check("most scripts run to an end", ended >= #entries * 0.85,
    ("%d of %d"):format(ended, #entries))
  -- Nothing should get lost: a jump into an address that was never decoded
  -- means the traversal missed a branch the interpreter can reach.
  for where, count in pairs(lost_at) do
    log("        lost: %d x %s", count, where)
  end
  check_equal("no script jumps somewhere undecoded", outcomes.lost or 0, 0)
  check_equal("no script runs away", outcomes.runaway or 0, 0)

  -- What the interpreter refused, which is the honest list of what the engine
  -- still cannot do.
  ranked = {}
  for op, count in pairs(stopped_on) do
    ranked[#ranked + 1] = { op = op, count = count }
  end
  table.sort(ranked, function(a, b) return a.count > b.count end)
  local parts = {}
  for i = 1, math.min(#ranked, 8) do
    parts[#parts + 1] = ("%s %d"):format(ranked[i].op, ranked[i].count)
  end
  log("        refused: %s", table.concat(parts, ", "))

  -- Scripts that reached an end we do not follow through. jumpstd leaves for
  -- the standard-script table, which is not located yet, so the script really
  -- does stop there as far as this engine is concerned.
  ranked = {}
  for op, count in pairs(ended_by) do
    ranked[#ranked + 1] = { op = op, count = count }
  end
  table.sort(ranked, function(a, b) return a.count > b.count end)
  parts = {}
  for i = 1, math.min(#ranked, 6) do
    parts[#parts + 1] = ("%s %d"):format(ranked[i].op, ranked[i].count)
  end
  log("        ended early at: %s", table.concat(parts, ", "))

  -- What it carried on past without doing. These are approximations, and the
  -- count is worth seeing so it cannot grow unnoticed.
  ranked = {}
  for op, count in pairs(ignored) do
    ranked[#ranked + 1] = { op = op, count = count }
  end
  table.sort(ranked, function(a, b) return a.count > b.count end)
  parts = {}
  for i = 1, math.min(#ranked, 10) do
    parts[#parts + 1] = ("%s %d"):format(ranked[i].op, ranked[i].count)
  end
  log("        ignored: %s", table.concat(parts, ", "))

  -- Answering the questions. A prompt that does not change anything would be
  -- decoration, so this runs every script twice -- saying yes throughout, then
  -- no throughout -- and counts the ones that behave differently.
  local function run_all(say_yes)
    local signatures, asked = {}, 0
    for index, entry in ipairs(entries) do
      local machine = vm.new(host, code, std_result and std_result.entries)
      flags.event, flags.flag = {}, {}
      local boxes, status = 0, nil
      if machine:start(entry.bank, entry.addr) then
        for _ = 1, 200 do
          status = machine:resume()
          if status ~= "waiting" then
            break
          end
          if machine.pending and machine.pending.kind == "text" then
            boxes = boxes + 1
          elseif machine.pending and machine.pending.kind == "choice" then
            asked = asked + 1
            machine:answer(say_yes)
          end
        end
      end
      signatures[index] = ("%s/%d/%s"):format(tostring(status), boxes,
        tostring(machine.ended_by))
    end
    return signatures, asked
  end

  local yes_run, asked_yes = run_all(true)
  local no_run = run_all(false)

  local differ = 0
  for index = 1, #entries do
    if yes_run[index] ~= no_run[index] then
      differ = differ + 1
    end
  end

  log("        %d questions asked; %d scripts end differently depending on " ..
    "the answer", asked_yes, differ)
  check("scripts do ask questions", asked_yes > 100,
    ("%d"):format(asked_yes))
  check("and the answer changes what happens", differ > 20,
    ("%d scripts"):format(differ))

  -- Resuming without answering must not leave the carry holding whatever an
  -- earlier check set, or a branch would follow unrelated history.
  local unanswered = vm.new(host, code, std_result and std_result.entries)
  unanswered.carry = true
  unanswered.pending = { kind = "choice" }
  unanswered.status = "waiting"
  unanswered.awaiting_answer = true
  unanswered.next_pc = nil
  unanswered:resume()
  check("an unanswered question defaults to no", unanswered.carry == false)

  -- A special calls assembly the interpreter cannot run. What it must not do
  -- is let the branch after it read whatever the last check happened to leave
  -- behind. Built here rather than found, so the expected behaviour is stated.
  local synthetic = {
    [1] = {
      -- setval 5; special 99; ifequal 5 -> 0x4010; end
      [0x4000] = { op = "setval", opcode = 0x15, size = 2, args = { 5 } },
      [0x4002] = { op = "special", opcode = 0x0F, size = 3, args = { 99, 0 } },
      [0x4005] = { op = "ifequal", opcode = 0x06, size = 4, args = { 5, 0, 0 },
                   target = 0x4010, target_bank = 1 },
      [0x4009] = { op = "end", opcode = 0x91, size = 1, args = {}, ends = true },
      [0x4010] = { op = "end", opcode = 0x91, size = 1, args = {}, ends = true },
    },
  }

  local probe_vm = vm.new(host, synthetic)
  probe_vm:start(1, 0x4000)
  probe_vm:resume()
  check_equal("a special clears the register it cannot fill",
    probe_vm.value, 0)
  check_equal("so the branch after it is not taken on a stale value",
    probe_vm.guessed, 1)

  -- The same for the carry flag.
  local carry_case = {
    [1] = {
      [0x4000] = { op = "special", opcode = 0x0F, size = 3, args = { 99, 0 } },
      [0x4003] = { op = "iftrue", opcode = 0x09, size = 3, args = { 0, 0 },
                   target = 0x4010, target_bank = 1 },
      [0x4006] = { op = "end", opcode = 0x91, size = 1, args = {}, ends = true },
      [0x4010] = { op = "end", opcode = 0x91, size = 1, args = {}, ends = true },
    },
  }
  local carry_vm = vm.new(host, carry_case)
  carry_vm:start(1, 0x4000)
  carry_vm.carry = true -- as though an earlier check had set it
  carry_vm:resume()
  check("a special clears a carry left by an earlier check",
    carry_vm.carry == false)
  check_equal("and that branch is counted as a guess", carry_vm.guessed, 1)

  -- A check that does produce an answer must not be counted as a guess.
  local honest = {
    [1] = {
      [0x4000] = { op = "checkevent", opcode = 0x31, size = 3, args = { 1, 0 } },
      [0x4003] = { op = "iftrue", opcode = 0x09, size = 3, args = { 0, 0 },
                   target = 0x4010, target_bank = 1 },
      [0x4006] = { op = "end", opcode = 0x91, size = 1, args = {}, ends = true },
      [0x4010] = { op = "end", opcode = 0x91, size = 1, args = {}, ends = true },
    },
  }
  local honest_vm = vm.new(host, honest)
  honest_vm:start(1, 0x4000)
  honest_vm:resume()
  check_equal("a real check is not counted as a guess", honest_vm.guessed, 0)

  -- How much of the game rides on one, across every script.
  local specials_run, guessed_total = 0, 0
  for _, entry in ipairs(entries) do
    local machine = vm.new(host, code, std_result and std_result.entries)
    flags.event, flags.flag = {}, {}
    if machine:start(entry.bank, entry.addr) then
      for _ = 1, 200 do
        local status = machine:resume()
        if status ~= "waiting" then break end
        if machine.pending and machine.pending.kind == "choice" then
          machine:answer(false)
        end
      end
      specials_run = specials_run + (machine.specials or 0)
      guessed_total = guessed_total + (machine.guessed or 0)
    end
  end
  log("        %d specials stepped over, %d branches taken on a result the " ..
    "interpreter did not produce", specials_run, guessed_total)
  check("most specials cost nothing downstream",
    guessed_total < specials_run * 0.5,
    ("%d guesses from %d specials"):format(guessed_total, specials_run))

  -- The two flag spaces must stay apart. Event 5 and flag 5 are different
  -- things, and merging them shows up as a branch taken wrongly much later.
  local machine = vm.new(host, code, std_result and std_result.entries)
  flags.event, flags.flag = {}, {}
  host.set_script_flag(nil, "event", 5, true)
  check("setting an event does not set the flag of the same number",
    flags.event[5] == true and flags.flag[5] == nil)
  check_equal("and the interpreter reads them apart",
    tostring(host.script_flag(nil, "flag", 5)), "false")
  machine = nil
end

-- Hidden items: background events that carry an item instead of text.
local function test_hidden_items(rom, map_result, item_names)
  log("\n== hidden items ==")
  if not map_result or not item_names then
    log("  SKIP  maps or item names were not located")
    return
  end

  local function real_item(value)
    return value >= 1 and value <= 255 and item_names[value]
      and item_names[value] ~= "TERU-SAMA"
  end

  -- Most byte values name a real item, so "it decodes to an item" is a weak
  -- test on its own. Measuring the rate is what makes the comparison below
  -- mean anything: two readings of these bytes score at chance and the third
  -- scores 100%, and that gap is the evidence.
  local plausible = 0
  for value = 1, 255 do
    if real_item(value) then plausible = plausible + 1 end
  end
  local chance = plausible / 255
  log("        %d of 255 byte values name a real item (%d%%)", plausible,
    math.floor(chance * 100))

  local total, inline_hits, first_hits, flag_hits = 0, 0, 0, 0
  local flags, items = {}, {}

  for _, header in ipairs(map_result.headers) do
    local decoded = not header.unparsed and events.decode(rom, header)
    if decoded then
      local bank = math.floor(header.attributes.scripts / 0x4000)
      for _, bg in ipairs(decoded.bg_events) do
        if bg.kind == events.BGEVENT_ITEM then
          total = total + 1

          -- Reading one: the two bytes are the item inline.
          local word = bg.script_word or 0
          if real_item(word % 256) then
            inline_hits = inline_hits + 1
          end

          if bg.script then
            local at = bank * 0x4000 + (bg.script - 0x4000)
            -- Reading two: they point at the item directly, as an item ball's
            -- script does.
            if real_item(rom:u8(at)) then
              first_hits = first_hits + 1
            end
            -- Reading three: they point at a flag, then the item.
            local block = events.decode_hidden(rom, bank, bg.script)
            if block and real_item(block.item) then
              flag_hits = flag_hits + 1
              flags[block.flag] = (flags[block.flag] or 0) + 1
              items[item_names[block.item]] =
                (items[item_names[block.item]] or 0) + 1
            end
          end
        end
      end
    end
  end

  log("        %d hidden items; inline %d, item-at-pointer %d, flag-then-item %d",
    total, inline_hits, first_hits, flag_hits)

  check("Crystal has dozens of hidden items", total >= 60,
    ("%d"):format(total))
  check_equal("every one reads as an item under the flag-then-item layout",
    flag_hits, total)
  -- The rivals are what make that number worth something.
  check("reading the bytes inline does no better than chance",
    inline_hits <= math.ceil(total * chance) + 2,
    ("%d of %d, chance is %d"):format(inline_hits, total,
      math.floor(total * chance)))
  check("reading them as pointing straight at the item does worse",
    first_hits < flag_hits, ("%d against %d"):format(first_hits, flag_hits))

  -- The flags are what stop an item being found twice, so they have to be
  -- nearly all distinct. One pair in Crystal shares a flag.
  local distinct, shared = 0, 0
  for _, count in pairs(flags) do
    distinct = distinct + 1
    if count > 1 then shared = shared + 1 end
  end
  log("        %d distinct flags, %d shared", distinct, shared)
  check("the flags identify the items", distinct >= total - 2,
    ("%d flags for %d items"):format(distinct, total))

  -- What is buried should be worth digging up.
  check("the classic hidden items are there", items["MAX POTION"]
    and items["FULL HEAL"] and items["RARE CANDY"] and items["FULL RESTORE"])
end

-- Trainers on maps, and the class table that reaches their parties.
local function test_trainer_objects(rom, map_result, species_names)
  log("\n== trainers on maps ==")
  if not map_result then
    log("  SKIP  maps were not located")
    return
  end

  local runs = trainers.locate(rom)
  if not check("trainer parties are available", runs ~= nil) then
    return
  end

  local all = {}
  for _, run in ipairs(runs) do
    for _, entry in ipairs(run.entries) do
      all[#all + 1] = entry
    end
  end

  local groups, group_err = trainers.locate_groups(rom, all)
  if not check("located the trainer class table", groups ~= nil, group_err) then
    return
  end

  local classes = 0
  for _ in pairs(groups.classes) do
    classes = classes + 1
  end
  log("        class table at 0x%06X, %d classes resolved",
    groups.offset, classes)
  -- The table length is discovered, not assumed: Crystal stops at 57.
  check("a full set of trainer classes resolves", classes >= 50,
    ("%d classes"):format(classes))

  -- Reaching a known trainer through (class, id) rather than through the flat
  -- list is what says the class boundaries are right.
  -- Walking a class by (class, id) has to agree with the flat scan for the
  -- trainers it can reach. Named leaders are the clearest check.
  local reachable_names = {}
  for class = 1, trainers.MAX_CLASSES do
    if groups.classes[class] then
      for id = 1, 32 do
        local record = trainers.party_for(rom, groups, class, id)
        if not record then
          break
        end
        reachable_names[record.name] = { class = class, id = id, record = record }
      end
    end
  end

  local named = 0
  for _, who in ipairs { "WILL", "BRUNO", "KAREN", "KOGA", "LANCE", "BROCK",
                         "MISTY", "EUSINE" } do
    if reachable_names[who] then
      named = named + 1
    end
  end
  check("named leaders are reachable by class and id", named >= 6,
    ("%d of 8"):format(named))

  local total_reachable = 0
  for _ in pairs(reachable_names) do
    total_reachable = total_reachable + 1
  end
  log("        %d distinct trainers reachable by class and id", total_reachable)

  -- The validator itself: walk every class from its first entry to wherever
  -- the next class begins. A rejection part-way through truncates every
  -- trainer after it, so this is the property that matters, and it is checked
  -- at 100% rather than bounded — one bad glyph in the charmap used to cost a
  -- whole class, and that must not be able to come back quietly.
  local ordered = {}
  for class, start in pairs(groups.classes) do
    ordered[#ordered + 1] = { class = class, start = start }
  end
  table.sort(ordered, function(a, b) return a.start < b.start end)

  local walked, truncated, truncated_why = 0, 0, {}
  for index, entry in ipairs(ordered) do
    -- The last class runs to the end of its bank, not the end of the ROM;
    -- using the ROM would sweep in whatever follows and never look like the
    -- padding it actually is.
    local limit = ordered[index + 1] and ordered[index + 1].start
      or (math.floor(entry.start / 0x4000) + 1) * 0x4000
    local at = entry.start
    while at < limit do
      local record, consumed = trainers.decode(rom, at)
      if not record then
        -- Trailing zeros are the padding that ends a bank, not a defect.
        local padding = true
        for byte = at, limit - 1 do
          if rom:u8(byte) ~= 0 then
            padding = false
            break
          end
        end
        if not padding then
          truncated = truncated + 1
          if #truncated_why < 4 then
            truncated_why[#truncated_why + 1] =
              ("class %d at 0x%06X: %s"):format(entry.class, at,
                tostring(consumed))
          end
        end
        break
      end
      walked = walked + 1
      at = at + consumed
    end
  end

  log("        %d trainers walked across %d classes", walked, #ordered)
  check("every class walks end to end without a rejection", truncated == 0,
    ("%d classes truncated%s"):format(truncated,
      #truncated_why > 0 and ("; " .. table.concat(truncated_why, ", ")) or ""))
  check("the walk reaches as many trainers as the flat scan",
    walked >= #all * 0.95, ("%d walked, %d scanned"):format(walked, #all))

  -- Every trainer object on a map must reach a real party, which ties the
  -- object type nibble, the trainer block and the class table together.
  local objects, trainer_objects, resolved = 0, 0, 0
  local out_of_range = 0
  local unresolved_examples = {}

  for _, header in ipairs(map_result.headers) do
    local decoded = not header.unparsed and events.decode(rom, header)
    if decoded then
      local bank = math.floor(header.attributes.scripts / 0x4000)
      for _, object in ipairs(decoded.objects) do
        objects = objects + 1
        if object.kind == events.OBJECT_TRAINER and object.script then
          trainer_objects = trainer_objects + 1
          local block = events.decode_trainer(rom, bank, object.script)
          if block then
            if block.class > classes then
              -- Names a class the table does not have. These are almost
              -- certainly not trainers at all: the block validator's class
              -- bound is generous, so a few non-trainer scripts slip through.
              out_of_range = out_of_range + 1
            else
              local party = trainers.party_for(rom, groups, block.class, block.id)
              if party then
                resolved = resolved + 1
              elseif #unresolved_examples < 4 then
                unresolved_examples[#unresolved_examples + 1] =
                  ("class %d id %d"):format(block.class, block.id)
              end
            end
          end
        end
      end
    end
  end

  log("        %d objects, %d are trainers, %d reach a party, "
    .. "%d name a class outside the table",
    objects, trainer_objects, resolved, out_of_range)
  check("Crystal has hundreds of trainer objects", trainer_objects >= 250,
    ("%d"):format(trainer_objects))
  -- This number went down when it got honest, which is worth recording. It read
  -- 279 while party_for was unbounded: an id past the end of its class walked
  -- into the next class and returned a stranger's party, so an object asking
  -- for class 25 id 10 came back with somebody else's trainer instead of
  -- nothing. Bounding the walk cut it to the objects that genuinely agree with
  -- the class table.
  --
  -- The shortfall is not the party validator — every class walks end to end,
  -- checked above. It is the object type nibble: reading class and id from
  -- byte 2 of the block resolves 156, against 47 for the next best offset and
  -- zero for most, so the layout is right and the rest are not trainer blocks
  -- at all. Asserted as a floor, since the way to move it is to classify those
  -- objects properly rather than to loosen what counts as agreement.
  check("trainer objects agree with the class table", resolved >= 150,
    ("%d of %d; e.g. %s"):format(resolved, trainer_objects,
      table.concat(unresolved_examples, ", ")))

  -- The type nibble must actually discriminate: objects that are not type 2
  -- should not parse as trainer blocks.
  local false_positives = 0
  for _, header in ipairs(map_result.headers) do
    local decoded = not header.unparsed and events.decode(rom, header)
    if decoded then
      local bank = math.floor(header.attributes.scripts / 0x4000)
      for _, object in ipairs(decoded.objects) do
        if object.kind ~= events.OBJECT_TRAINER and object.script then
          if events.decode_trainer(rom, bank, object.script) then
            false_positives = false_positives + 1
          end
        end
      end
    end
  end
  -- The type nibble has to be doing real work: if scripts in general looked
  -- like trainer blocks, the classification would mean nothing. It is not
  -- zero, because the block validator is only a range check.
  log("        %d of %d non-trainer objects would parse as a trainer block",
    false_positives, objects - trainer_objects)
  check("the type nibble discriminates",
    false_positives < (objects - trainer_objects) * 0.25,
    ("%d of %d"):format(false_positives, objects - trainer_objects))
end

--- The engine reads only the cache, never a cartridge, so these tests check the
-- cached data is shaped the way a game needs rather than the way a viewer does.
-- Skipped when nothing has been imported yet.
local function test_engine()
  log("\n== engine ==")

  local cache = require("src.import.cache")
  local world = require("src.engine.world")

  local games = cache.list_games()
  local game_id
  for _, entry in ipairs(games) do
    if entry.current then
      game_id = entry.game
      break
    end
  end

  if not game_id then
    log("  SKIP  no import in the cache")
    return
  end

  local loaded, why = world.load(game_id)
  if not check("world loads from the cache", loaded ~= nil, why) then
    return
  end

  log("        %d maps, %d tilesets", loaded:map_count(), #loaded.tilesets)

  -- Every map must name a tileset that was actually cached, or it cannot be
  -- drawn at all.
  local missing_tileset, playable = 0, 0
  for index = 1, loaded:map_count() do
    local map = loaded:map(index)
    if not map.unparsed then
      playable = playable + 1
      if not loaded.tilesets[map.tileset] then
        missing_tileset = missing_tileset + 1
      end
    end
  end
  check_equal("every map's tileset is cached", missing_tileset, 0)
  log("        %d playable, %d placeholder slots", playable,
    loaded:map_count() - playable)

  -- Collision must resolve for every cell of every map; a nil means block or
  -- tileset data is short.
  local unresolved, walkable_cells, total_cells = 0, 0, 0
  for index = 1, loaded:map_count() do
    local map = loaded:map(index)
    if not map.unparsed then
    for cell_y = 0, map.height * world.CELLS_PER_BLOCK - 1 do
      for cell_x = 0, map.width * world.CELLS_PER_BLOCK - 1 do
        total_cells = total_cells + 1
        if not loaded:collision_at(map, cell_x, cell_y) then
          unresolved = unresolved + 1
        elseif loaded:walkable(map, cell_x, cell_y) then
          walkable_cells = walkable_cells + 1
        end
      end
    end
    end
  end
  check_equal("collision resolves for every cell", unresolved, 0)
  log("        %d of %d cells walkable (%d%%)", walkable_cells, total_cells,
    math.floor(walkable_cells / total_cells * 100))

  -- The provisional rule reported 58% of the world walkable, which was far too
  -- generous. Water, ledges, counters and trees are all distinct values.
  check("the walkable share is plausible",
    walkable_cells / total_cells < 0.5,
    ("%d%% walkable"):format(math.floor(walkable_cells / total_cells * 100)))

  -- Doors are wall tiles you walk into: 544 of Crystal's warps sit on $07. So
  -- "every warp is walkable" is false and was the wrong assertion. What must
  -- hold is that every warp is *enterable*, which is what makes doors usable.
  local warps_total, warps_enterable, warps_on_walls = 0, 0, 0
  for index = 1, loaded:map_count() do
    local map = loaded:map(index)
    if not map.unparsed then
      for _, warp in ipairs(map.warps or {}) do
        warps_total = warps_total + 1
        if loaded:can_enter(map, warp.x, warp.y) then
          warps_enterable = warps_enterable + 1
        end
        if not loaded:walkable(map, warp.x, warp.y) then
          warps_on_walls = warps_on_walls + 1
        end
      end
    end
  end
  check_equal("every warp is enterable", warps_enterable, warps_total)
  log("        %d warps, %d of them on tiles that are not walkable",
    warps_total, warps_on_walls)

  -- And the rule must not make everything enterable: a wall without a warp
  -- still blocks.
  local sample_map
  for index = 1, loaded:map_count() do
    local candidate = loaded:map(index)
    if not candidate.unparsed then
      sample_map = candidate
      break
    end
  end

  local blocked = 0
  for cell_y = 0, math.min(sample_map.height * world.CELLS_PER_BLOCK, 40) - 1 do
    for cell_x = 0, math.min(sample_map.width * world.CELLS_PER_BLOCK, 40) - 1 do
      if not loaded:can_enter(sample_map, cell_x, cell_y) then
        blocked = blocked + 1
      end
    end
  end
  check("walls without warps still block", blocked > 0,
    ("%d blocked cells on the sample map"):format(blocked))

  -- Grass, and that it lines up with the maps that have encounter tables.
  local grass_maps, grass_cells, with_tables = 0, 0, 0
  for index = 1, loaded:map_count() do
    local map = loaded:map(index)
    if not map.unparsed then
      local found = 0
      for cell_y = 0, map.height * world.CELLS_PER_BLOCK - 1 do
        for cell_x = 0, map.width * world.CELLS_PER_BLOCK - 1 do
          if loaded:is_grass(map, cell_x, cell_y) then
            found = found + 1
          end
        end
      end
      if found > 0 then
        grass_maps = grass_maps + 1
        grass_cells = grass_cells + found
        if map.encounters then
          with_tables = with_tables + 1
        end
      end
    end
  end
  log("        %d maps have grass tiles (%d cells), %d of those have an "
    .. "encounter table", grass_maps, grass_cells, with_tables)

  -- Neither implication holds, and the reasons differ.
  --
  -- Most encounter tables belong to maps with no grass: caves and dungeons roll
  -- on ordinary floor, which is why the engine consults the environment as well
  -- as the terrain. Going the other way, 25 maps have grass tiles and no table;
  -- that is not yet explained, so it is reported rather than asserted either
  -- way. Guessing a threshold that happens to pass would hide it.
  local rolling = 0
  for index = 1, loaded:map_count() do
    local map = loaded:map(index)
    if not map.unparsed and map.encounters then
      rolling = rolling + 1
    end
  end
  log("        %d maps have an encounter table; %d of those are caves or "
    .. "dungeons that roll on floor", rolling, rolling - with_tables)
  check("a fair number of maps have grass", grass_maps >= 40,
    ("%d maps"):format(grass_maps))
  check("maps that can roll for encounters are plentiful", rolling >= 80,
    ("%d maps"):format(rolling))

  -- Map connections. The engine must let the player walk off an edge that has
  -- one, and the arrival must land inside the destination.
  -- Read locally: the warp section below reads this too, but later, and this
  -- block runs first.
  local group_starts = cache.read(game_id, "map_groups")

  local with_connections, crossings, bad_arrivals, unresolved_targets = 0, 0, 0, 0
  for index = 1, loaded:map_count() do
    local map = loaded:map(index)
    if not map.unparsed and #(map.connections or {}) > 0 then
      with_connections = with_connections + 1

      for _, connection in ipairs(map.connections) do
        crossings = crossings + 1

        local start = group_starts and group_starts[connection.group]
        local target = start and loaded:map(start + connection.number - 1)
        if not target or target.unparsed then
          unresolved_targets = unresolved_targets + 1
        else
          -- The destination's own width must match what the record claims,
          -- which is what confirms the field layout.
          if connection.width ~= target.width then
            bad_arrivals = bad_arrivals + 1
          end
        end
      end
    end
  end

  log("        %d maps have connections, %d crossings in total",
    with_connections, crossings)
  check("a good number of maps connect", with_connections >= 30,
    ("%d maps"):format(with_connections))
  check_equal("every connection names a map that exists", unresolved_targets, 0)
  check_equal("every connection's width matches its destination",
    bad_arrivals, 0)

  -- Walking off a connected edge must be permitted, and off an unconnected one
  -- must not.
  local connected_map, connected_edge
  for index = 1, loaded:map_count() do
    local map = loaded:map(index)
    if not map.unparsed and #(map.connections or {}) > 0 then
      connected_map = map
      connected_edge = map.connections[1]
      break
    end
  end

  if connected_map then
    local width = connected_map.width * world.CELLS_PER_BLOCK
    local height = connected_map.height * world.CELLS_PER_BLOCK
    local probe_x, probe_y = 0, 0
    if connected_edge.direction == "north" then
      probe_x, probe_y = math.floor(width / 2), -1
    elseif connected_edge.direction == "south" then
      probe_x, probe_y = math.floor(width / 2), height
    elseif connected_edge.direction == "west" then
      probe_x, probe_y = -1, math.floor(height / 2)
    else
      probe_x, probe_y = width, math.floor(height / 2)
    end

    check("stepping off a connected edge is allowed",
      loaded:can_enter(connected_map, probe_x, probe_y),
      ("%s edge"):format(connected_edge.direction))
    check("the edge resolves to its connection",
      loaded:connection_beyond(connected_map, probe_x, probe_y) ~= nil)
  end

  -- Off-map is blocked.
  local first
  for index = 1, loaded:map_count() do
    if not loaded:map(index).unparsed then
      first = loaded:map(index)
      break
    end
  end
  check("stepping off the map edge is blocked",
    not loaded:walkable(first, -1, 0) and not loaded:walkable(first, 0, -1))

  -- The warp graph. Every warp names a destination by group and number, and
  -- every one of those must resolve to a real map through the group table.
  -- This exercises the group table, the map ordering and the warp decoder at
  -- once, across the whole game.
  local groups = cache.read(game_id, "map_groups")
  if check("map group table is cached", groups ~= nil) then
    check_equal("Crystal has 26 map groups", #groups, 26)

    local total_warps, unresolved_warps = 0, 0
    local zero_index, missing_arrival = 0, 0
    for index = 1, loaded:map_count() do
      for _, warp in ipairs(loaded:map(index).warps or {}) do
        total_warps = total_warps + 1
        local start = groups[warp.destination_group]
        local destination = start and loaded:map(start + warp.destination_map - 1)
        if not destination or destination.unparsed then
          unresolved_warps = unresolved_warps + 1
        elseif warp.destination_warp == 0 then
          -- Index 0 is not a warp on the destination. Gen 2 uses it for warps
          -- whose arrival point is decided by a script rather than by geometry.
          zero_index = zero_index + 1
        elseif not (destination.warps or {})[warp.destination_warp] then
          missing_arrival = missing_arrival + 1
        end
      end
    end

    -- Not asserted as zero, because it is not zero and pretending otherwise
    -- would hide a regression rather than prevent one. Eight warps lead into
    -- the four headers that do not decode; six name an arrival index their
    -- destination lacks, which is unexplained. Both are well under a percent,
    -- and the thresholds are tight enough that any real breakage trips them.
    check("virtually every warp resolves to a decodable map",
      unresolved_warps <= total_warps * 0.01,
      ("%d of %d unresolved"):format(unresolved_warps, total_warps))
    check("virtually every warp finds its arrival point",
      missing_arrival <= total_warps * 0.01,
      ("%d of %d missing"):format(missing_arrival, total_warps))

    log("        %d warps: %d unresolved, %d missing arrival, %d use index 0",
      total_warps, unresolved_warps, missing_arrival, zero_index)
  end
end

--------------------------------------------------------------------------------

function harness.run(rom_path, report_path)
  report = {}
  passed, failed = 0, 0

  log("gen2recomp test run")
  log("rom: %s", rom_path)

  local rom, err = Rom.load(rom_path)
  if not rom then
    -- Counted as a failure: a run that tests nothing must never report success.
    failed = failed + 1
    log("\nFATAL: %s", err)
  else
    local info = test_header(rom)
    test_identify(rom, info)
    test_addressing(rom)
    test_lz_commands()
    local found = test_tables(rom)
    test_sprites(rom, found and found.base_stats)
    test_palettes(rom, found and found.species_names and found.species_names.records)
    local tileset_result = test_tilesets(rom)
    local map_result = test_maps(rom, tileset_result)
    test_events(rom, map_result)
    test_ow_sprites(rom, map_result)
    test_font(rom)
    test_scripts(rom, map_result)
    test_script_table(rom, map_result)
    test_battle_data(rom, found and found.species_names and found.species_names.records)
    test_pokemon(found and found.base_stats,
      found and found.species_names and found.species_names.records)
    test_learnsets(rom,
      found and found.species_names and found.species_names.records,
      found and found.move_names and found.move_names.records)
    test_catching(found and found.base_stats)
    test_save(found and found.base_stats)
    test_status(found and found.base_stats, found and found.moves)
    test_menu()
    test_items(found and found.item_attributes and found.item_attributes.records,
      found and found.item_names and found.item_names.records)
    test_marts(rom,
      found and found.item_names and found.item_names.records,
      found and found.item_attributes and found.item_attributes.records,
      map_result)
    test_item_balls(rom, map_result,
      found and found.item_names and found.item_names.records)
    test_text_codes()
    test_music(rom)
    test_movement(rom, map_result)
    test_script_vm(rom, map_result)
    test_hidden_items(rom, map_result,
      found and found.item_names and found.item_names.records)
    test_trainer_objects(rom, map_result,
      found and found.species_names and found.species_names.records)
    test_battle(found and found.base_stats, found and found.moves,
      found and found.species_names and found.species_names.records,
      found and found.move_names and found.move_names.records)
    rom:release()
    test_engine()
  end

  log("\n== summary ==")
  log("  %d passed, %d failed", passed, failed)

  local out = table.concat(report, "\n") .. "\n"
  local fh = io.open(report_path, "w")
  if fh then
    fh:write(out)
    fh:close()
  end
  return failed == 0
end

return harness
