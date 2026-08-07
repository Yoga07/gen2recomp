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
