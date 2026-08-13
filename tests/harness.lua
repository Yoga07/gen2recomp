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
local bytes = require("src.util.bytes")
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

  -- How much room the search has to be wrong.
  --
  -- The structural test is "251 consecutive records of four 15-bit words, not
  -- all zero", and this file used to describe that as a signature nothing else
  -- satisfies. It is satisfied tens of thousands of times. What that means is
  -- that hue is carrying the entire decision, so the number of offsets hue
  -- leaves standing is the only measure that matters -- and with the three
  -- checks this started with, that number was 461.
  do
    local data = rom.data
    local stride = palettes.RECORD_SIZE
    local run = {}
    for offset = rom.size - stride, 0, -1 do
      local plausible = true
      local any = false
      for i = 0, palettes.COLORS_PER_RECORD - 1 do
        local word = bytes.u16le(data, offset + i * 2)
        if bytes.band(word, 0x8000) ~= 0 then
          plausible = false
          break
        end
        if word ~= 0 then any = true end
      end
      run[offset] = (plausible and any) and ((run[offset + stride] or 0) + 1) or 0
    end

    local structural = {}
    for offset = 0, rom.size - stride do
      if run[offset] >= 251 then
        structural[#structural + 1] = offset
      end
    end

    local function surviving(checks)
      local count = 0
      for _, offset in ipairs(structural) do
        local ok = true
        for species, want in pairs(checks) do
          local word = bytes.u16le(data, offset + (species - 1) * stride)
          if palettes.dominant(word) ~= want then
            ok = false
            break
          end
        end
        if ok then count = count + 1 end
      end
      return count
    end

    local three = surviving { [1] = "g", [4] = "r", [25] = "yellow" }
    local all = surviving(palettes.SPOT_CHECKS)

    log("        %d offsets pass the structural test alone", #structural)
    log("        %d of those survive the original three hues", three)
    log("        %d survive all %d", all, (function()
      local n = 0
      for _ in pairs(palettes.SPOT_CHECKS) do n = n + 1 end
      return n
    end)())

    -- The structural test on its own decides nothing, and saying so here is the
    -- point: the claim it once carried was that it decided everything.
    check("the structural test alone is not remotely sufficient",
      #structural > 1000)
    check("three hues were not sufficient either", three > 100)
    check_equal("the full set leaves exactly one offset", all, 1)
  end

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

-- Fainting: sending out the next, and running out of them.
local function test_fainting(base_stats)
  log("\n== fainting ==")
  if not base_stats then
    log("  SKIP  the base stats were not located")
    return
  end

  local game = require("src.engine.game")
  local pokemon = require("src.engine.pokemon")
  local battle = require("src.engine.battle")

  -- The game's methods are tested against a stand-in rather than a running
  -- game: everything here is about party bookkeeping, and building a real one
  -- would drag in a window and a cartridge cache to prove nothing extra.
  local function fake(party, money)
    local instance = setmetatable({
      party = party,
      money = money or 3000,
      species_names = {},
      base_stats = base_stats,
      entered = nil,
      said = nil,
    }, game)
    instance.enter = function(self, index) self.entered = index or true end
    instance.say = function(self, lines) self.said = lines end
    instance.default_map = function() return 7 end
    return instance
  end

  local function mon(species, level, hp)
    local instance = pokemon.new(species, base_stats[species], { level = level })
    instance.hp = hp == nil and instance.stats.hp or hp
    return instance
  end

  -- Finding a replacement.
  local down, up = mon(155, 10, 0), mon(25, 12)
  local instance = fake({ down, up })
  check_equal("the next healthy member is the one still standing",
    instance:next_healthy_member(down), up)
  check("a fainted one is never chosen",
    instance:next_healthy_member(up) == nil)

  -- Sending it out clears the finished flag, or the battle would be dismissed
  -- the moment the replacement arrived.
  instance.battle = { player = down, opponent = mon(19, 8), over = true,
                      winner = "opponent" }
  check("a replacement is sent out", instance:send_next_party_member())
  check_equal("and it is the healthy one", instance.battle.player, up)
  check("the battle is no longer finished", instance.battle.over == false)
  check("nor does it have a winner", instance.battle.winner == nil)

  -- With nothing left there is no replacement.
  local all_down = fake({ mon(155, 10, 0), mon(25, 12, 0) })
  all_down.battle = { player = all_down.party[1], over = true }
  check("with nothing standing there is no replacement",
    all_down:send_next_party_member() == false)

  -- Blacking out heals, charges half the money, and moves the player.
  local beaten = fake({ mon(155, 10, 0), mon(25, 12, 0) }, 3000)
  beaten.battle = { player = beaten.party[1], over = true }
  beaten:blackout()
  check_equal("blacking out costs half the money", beaten.money, 1500)
  check_equal("the party is healed", beaten.party[1].hp,
    beaten.party[1].stats.hp)
  check_equal("all of it", beaten.party[2].hp, beaten.party[2].stats.hp)
  check("the battle is gone", beaten.battle == nil)
  check("and the player has been moved", beaten.entered ~= nil)
  check("with something said about it", beaten.said ~= nil)

  -- Odd amounts round in the player's favour by a coin at most.
  local odd = fake({ mon(155, 10, 0) }, 999)
  odd.battle = { player = odd.party[1] }
  odd:blackout()
  check_equal("half of an odd amount rounds down", odd.money, 500)

  -- Status is cleared along with the damage.
  local poisoned = fake({ mon(155, 10, 0) })
  poisoned.party[1].status = "poison"
  poisoned.battle = { player = poisoned.party[1] }
  poisoned:blackout()
  check("blacking out clears status too", poisoned.party[1].status == nil)

  -- The bug this found: a knockout sets `over`, so a trainer whose first
  -- Pokémon fell had the battle dismissed before the second was sent out.
  -- Sending the next one has to clear the flag.
  local against = fake({ mon(155, 20) })
  against.trainer = {
    name = "FALKNER", sent = 1, flag = 1,
    party = { mon(16, 7, 0), mon(17, 9) },
  }
  against.battle = battle.new(against.party[1], against.trainer.party[1],
    {}, {}, {})
  against.battle.over = true
  against.battle.winner = "player"
  against.beaten = {}
  check("the trainer sends out another", against:send_next_trainer_pokemon())
  check_equal("and it is their second", against.battle.opponent,
    against.trainer.party[2])
  check("the battle is not over after a knockout mid-team",
    against.battle.over == false)
end

-- The time of day.
local function test_clock()
  log("\n== clock ==")

  local clock = require("src.engine.clock")
  local encounters_module = require("src.rom.encounters")
  local vm = require("src.engine.vm")

  -- One source for the ordering: the encounter tables' own three slots.
  check_equal("the periods are the encounter tables' periods",
    table.concat(clock.TIMES, ","),
    table.concat(encounters_module.times, ","))
  check_equal("and there are three", #clock.TIMES, 3)

  -- Gen 2's boundaries, checked on both sides of each.
  local expected = {
    [0] = "nite", [3] = "nite", [4] = "morn", [9] = "morn",
    [10] = "day", [17] = "day", [18] = "nite", [23] = "nite",
  }
  for hour, wanted in pairs(expected) do
    check_equal(("%02d:00 is %s"):format(hour, wanted),
      clock.time_of_day(hour), wanted)
  end

  -- Night is the one that wraps midnight, so it has to be the same period on
  -- both sides of it.
  check_equal("night runs across midnight", clock.time_of_day(23),
    clock.time_of_day(0))

  -- The mask. Crystal only ever uses 1, 2 and 4, which is what says the bits
  -- are one per period rather than an index.
  check_equal("morning is bit zero", clock.mask_for("morn"), 1)
  check_equal("day is bit one", clock.mask_for("day"), 2)
  check_equal("night is bit two", clock.mask_for("nite"), 4)
  check_equal("something that is not a period has no bit",
    clock.mask_for("teatime"), 0)

  check("a mask of one matches the morning", clock.matches(1, "morn"))
  check("and not the day", not clock.matches(1, "day"))
  check("a combined mask matches both its periods",
    clock.matches(5, "morn") and clock.matches(5, "nite"))
  check("and not the one it leaves out", not clock.matches(5, "day"))

  -- checktime in the interpreter, asked of a host that is always at night.
  local host = {
    script_time_matches = function(_, mask)
      return clock.matches(mask, "nite")
    end,
  }
  local function ran(mask)
    local machine = vm.new(host, {
      [1] = {
        [0x4000] = { op = "checktime", opcode = 0x2B, size = 2,
                     args = { mask } },
        [0x4002] = { op = "end", opcode = 0x91, size = 1, args = {},
                     ends = true },
      },
    })
    machine:start(1, 0x4000)
    machine:resume()
    return machine.carry
  end

  check("checktime for night is true at night", ran(4) == true)
  check("and false for the morning", ran(1) == false)
  check("a mask covering everything is always true", ran(7) == true)
end

-- The storage boxes.
local function test_storage(base_stats)
  log("\n== storage ==")
  if not base_stats then
    log("  SKIP  the base stats were not located")
    return
  end

  local storage = require("src.engine.storage")
  local pokemon = require("src.engine.pokemon")

  local function mon(species, level)
    return pokemon.new(species, base_stats[species], { level = level or 5 })
  end

  local boxes = storage.new()
  check_equal("there are fourteen boxes", #boxes.boxes, storage.BOX_COUNT)
  check_equal("all empty to begin with", boxes:total(), 0)
  check_equal("and no box is in use", #boxes:used_boxes(), 0)

  check_equal("the first deposit goes in the current box",
    boxes:deposit(mon(155)), 1)
  check_equal("which now holds one", boxes:count(1), 1)
  check_equal("and shows up as used", #boxes:used_boxes(), 1)

  -- Filling the current box rolls on to the next rather than refusing, which
  -- the games do not do but loses nothing and saves a trip to a menu.
  for _ = 2, storage.BOX_SIZE do
    boxes:deposit(mon(25))
  end
  check("the first box is full", boxes:is_full(1))
  check_equal("the next one goes into box two", boxes:deposit(mon(19)), 2)
  check_equal("box one is untouched", boxes:count(1), storage.BOX_SIZE)

  -- Taking one out.
  local taken = boxes:withdraw(2, 1)
  check("something came out", taken ~= nil)
  check_equal("and box two is empty again", boxes:count(2), 0)
  check("taking from an empty slot gives nothing",
    boxes:withdraw(2, 1) == nil)
  check("as does taking from a box that does not exist",
    boxes:withdraw(99, 1) == nil)

  -- Completely full.
  local packed = storage.new()
  for _ = 1, storage.BOX_COUNT * storage.BOX_SIZE do
    packed:deposit(mon(19))
  end
  check_equal("every box holds twenty", packed:total(),
    storage.BOX_COUNT * storage.BOX_SIZE)
  check("and one more has nowhere to go", packed:deposit(mon(19)) == nil)

  -- Round trip through a save. The members are packed the same way the party
  -- is, so what survives is what survives for a carried Pokémon.
  local saved = storage.new()
  saved:deposit(mon(155, 30))
  saved:deposit(mon(25, 12))
  saved.boxes[5][1] = mon(251, 70)

  local list = saved:to_list(function(instance)
    return { species = instance.species, level = instance.level }
  end)
  local restored = storage.from_list(list, function(member)
    return pokemon.new(member.species, base_stats[member.species],
      { level = member.level })
  end)

  check_equal("the boxes survive a save", restored:total(), saved:total())
  check_equal("in the boxes they were in", restored:count(5), 1)
  check_equal("and the right thing is in box five",
    restored:box(5)[1].species, 251)
  check_equal("at the right level", restored:box(5)[1].level, 70)
end

-- The sound chip.
--
-- A sound chip has a failure mode nothing else here has: **it makes a noise
-- either way**. "I can hear something" is the audio version of the metrics this
-- suite keeps as cautionary tales, so nothing below is judged by ear. Ask for
-- 440 Hz and the output is measured for 440 Hz; ask for a 12.5% duty and the
-- output is measured for how long it stays high; the shift register's period is
-- counted exactly.
--
-- Needs no cartridge: the hardware is documented, so this is the one part of
-- the audio problem that can be written from the specification and checked
-- against arithmetic.
local function test_apu()
  log("\n== sound chip ==")

  local apu = require("src.audio.apu")
  local RATE = 44100

  local function tone(chip, hz, duty, volume, channel_two)
    local register = math.floor(2048 - 131072 / hz + 0.5)
    chip:write(0xFF26, 0x80)
    chip:write(0xFF24, 0x77)
    chip:write(0xFF25, 0xFF)
    local base = channel_two and 0xFF15 or 0xFF10
    chip:write(base + 1, duty * 64)
    chip:write(base + 2, volume * 16)
    chip:write(base + 3, register % 256)
    chip:write(base + 4, 0x80 + math.floor(register / 256))
    return register
  end

  local function hertz(samples)
    local crossings, previous = 0, nil
    for index = 1, #samples, 2 do
      local value = samples[index]
      if previous and ((previous < 0) ~= (value < 0)) then
        crossings = crossings + 1
      end
      previous = value
    end
    return crossings / 2 / ((#samples / 2) / RATE)
  end

  local function swing(samples, from, to)
    local low, high = math.huge, -math.huge
    for index = from or 1, math.min(to or #samples, #samples), 2 do
      low = math.min(low, samples[index])
      high = math.max(high, samples[index])
    end
    return low > high and 0 or (high - low)
  end

  --- When the output goes quiet and stays quiet, in seconds.
  --
  -- Asked as a measurement rather than as "is the tail quiet", because the two
  -- are not the same question. Switching a channel off steps the mix, and the
  -- output capacitor answers a step with a decaying transient — so a window
  -- starting at the moment of the cut is never silent, however correct the
  -- chip is. Finding where the sound *ends* tests the length counter's timing;
  -- checking a window only tests where the window was put.
  local function silence_time(samples)
    local block = 256
    local frames = #samples / 2
    local loudest = 0
    local blocks = {}
    for start = 0, frames - block, block do
      local level = swing(samples, start * 2 + 1, (start + block) * 2)
      blocks[#blocks + 1] = { at = start, level = level }
      loudest = math.max(loudest, level)
    end
    local threshold = loudest * 0.1
    local quiet_from = frames
    for index = #blocks, 1, -1 do
      if blocks[index].level > threshold then
        break
      end
      quiet_from = blocks[index].at
    end
    return quiet_from / RATE
  end

  -- Frequency. The hardware's own formula is 131072/(2048-n), and the point is
  -- that the chip reproduces it, not that it lands on a musical note.
  log("        wanted | measured | hardware formula")
  local worst = 0
  for _, wanted in ipairs({ 110, 220, 440, 880 }) do
    local chip = apu.new(RATE)
    local register = tone(chip, wanted, 2, 15, true)
    local samples = chip:generate(math.floor(RATE / 2))
    local measured = hertz(samples)
    local expected = 131072 / (2048 - register)
    local error_pct = math.abs(measured - expected) / expected * 100
    worst = math.max(worst, error_pct)
    log("        %6d | %8.2f | %8.2f", wanted, measured, expected)
  end
  check("every tone comes out at the frequency the hardware would give",
    worst < 0.5, ("worst error %.3f%%"):format(worst))

  -- Duty. Measured low, where a period is 400 samples, so the one sample per
  -- transition that lands between levels is a quarter of a percent rather
  -- than a whole one.
  local nominal = { [0] = 0.125, 0.25, 0.5, 0.75 }
  local duty_error = 0
  for duty = 0, 3 do
    local chip = apu.new(RATE)
    tone(chip, 110, duty, 15, true)
    local samples = chip:generate(math.floor(RATE / 2))
    local high, total = 0, 0
    for index = 1, #samples, 2 do
      if samples[index] > 0 then high = high + 1 end
      total = total + 1
    end
    duty_error = math.max(duty_error, math.abs(high / total - nominal[duty]))
  end
  check("each duty cycle is high for the fraction of the time it should be",
    duty_error < 0.01, ("worst %.4f off"):format(duty_error))

  -- The envelope, which is also the test that caught the missing output
  -- capacitor: without one a falling envelope slides the waveform downwards
  -- instead of shrinking it, and the loudness never changes.
  do
    local chip = apu.new(RATE)
    chip:write(0xFF26, 0x80)
    chip:write(0xFF24, 0x77)
    chip:write(0xFF25, 0xFF)
    chip:write(0xFF16, 2 * 64)
    chip:write(0xFF17, 0xF1)     -- full, falling, one step every 1/64 s
    local register = math.floor(2048 - 131072 / 440 + 0.5)
    chip:write(0xFF18, register % 256)
    chip:write(0xFF19, 0x80 + math.floor(register / 256))

    local samples = chip:generate(math.floor(RATE / 2))
    local window = math.floor(RATE / 16)
    local first = swing(samples, window * 2 + 1, window * 4)
    local later = swing(samples, window * 6 + 1, window * 8)
    local silent = swing(samples, window * 10 + 1, #samples)
    log("        envelope swing: %.4f then %.4f then %.4f",
      first, later, silent)
    check("a falling envelope actually gets quieter", later < first * 0.8)
    check("and reaches silence", silent < 0.001)
  end

  -- A rising envelope, so the direction bit is not being ignored.
  do
    local chip = apu.new(RATE)
    chip:write(0xFF26, 0x80)
    chip:write(0xFF24, 0x77)
    chip:write(0xFF25, 0xFF)
    chip:write(0xFF16, 2 * 64)
    chip:write(0xFF17, 0x0B)     -- from nothing, rising, period 3
    local register = math.floor(2048 - 131072 / 440 + 0.5)
    chip:write(0xFF18, register % 256)
    chip:write(0xFF19, 0x80 + math.floor(register / 256))
    local samples = chip:generate(math.floor(RATE / 2))
    local window = math.floor(RATE / 8)
    check("a rising envelope gets louder",
      swing(samples, window * 6 + 1, #samples)
        > swing(samples, 1, window * 2))
  end

  -- The noise channel's shift register. Its periods are exact numbers, which
  -- makes this the sharpest check available anywhere in the chip.
  --
  -- What repeats is the audible sequence rather than the whole register: in
  -- seven-bit mode bits 0 to 6 are a closed register and the upper bits become
  -- a delay line with no feedback, so the full fifteen bits never return to the
  -- value a trigger loads. Measuring those would report no period at all, which
  -- would be a fact about the measure.
  for _, width_7 in ipairs({ false, true }) do
    local chip = apu.new(RATE)
    chip:write(0xFF26, 0x80)
    chip:write(0xFF21, 0xF0)
    chip:write(0xFF22, width_7 and 0x08 or 0x00)
    chip:write(0xFF23, 0x80)

    local mask = width_7 and 0x80 or 0x8000
    local start = chip.noise.lfsr % mask
    local steps = 0
    repeat
      chip:advance(chip.noise.timer)
      steps = steps + 1
    until chip.noise.lfsr % mask == start or steps > 40000
    check_equal(("the %d-bit shift register repeats after the right number of "
      .. "shifts"):format(width_7 and 7 or 15), steps,
      width_7 and 127 or 32767)
  end

  -- The wave channel reads wave RAM, and the volume code shifts it.
  do
    local chip = apu.new(RATE)
    chip:write(0xFF26, 0x80)
    for index = 0, 15 do
      chip:write(0xFF30 + index, index * 16 + index)
    end
    chip:write(0xFF1A, 0x80)
    chip:write(0xFF1C, 0x20)
    local register = math.floor(2048 - 131072 / 440 + 0.5)
    chip:write(0xFF1D, register % 256)
    chip:write(0xFF1E, 0x80 + math.floor(register / 256))

    local seen = {}
    for _ = 1, 2048 do
      chip:advance(chip.wave.timer)
      seen[chip.wave.sample] = true
    end
    local distinct = 0
    for _ in pairs(seen) do distinct = distinct + 1 end
    check_equal("a ramp in wave RAM comes back out as sixteen levels",
      distinct, 16)

    -- Volume code 0 is silence, not full volume: the shift is four places.
    chip:write(0xFF1C, 0x00)
    local quiet = chip:generate(math.floor(RATE / 8))
    check("volume code zero is silence", silence_time(quiet) < 0.02,
      ("still sounding at %.3fs"):format(silence_time(quiet)))
  end

  -- The length counter, which is what stops a note.
  do
    local chip = apu.new(RATE)
    chip:write(0xFF26, 0x80)
    chip:write(0xFF24, 0x77)
    chip:write(0xFF25, 0xFF)
    chip:write(0xFF16, 2 * 64 + 32)   -- length 32, so 32 ticks at 256 Hz
    chip:write(0xFF17, 0xF0)
    local register = math.floor(2048 - 131072 / 440 + 0.5)
    chip:write(0xFF18, register % 256)
    chip:write(0xFF19, 0xC0 + math.floor(register / 256))  -- trigger + enable

    -- The length counter is clocked at 256 Hz, so 32 of them is exactly an
    -- eighth of a second. That is a number to measure against, not a bound.
    local samples = chip:generate(math.floor(RATE / 4))
    local stopped = silence_time(samples)
    log("        a length of 32 stops the note at %.4fs (256Hz gives %.4fs)",
      stopped, 32 / 256)
    check("a note with a length still sounds at the start",
      swing(samples, 1, math.floor(RATE / 16)) > 0.1)
    check("and stops when its length runs out",
      math.abs(stopped - 32 / 256) < 0.01,
      ("%.4fs against %.4fs"):format(stopped, 32 / 256))
  end

  -- Panning, which is the one thing a mono measurement would miss entirely.
  do
    local chip = apu.new(RATE)
    chip:write(0xFF26, 0x80)
    chip:write(0xFF24, 0x77)
    chip:write(0xFF25, 0x20)   -- channel 2 to the left only
    chip:write(0xFF16, 2 * 64)
    chip:write(0xFF17, 0xF0)
    local register = math.floor(2048 - 131072 / 440 + 0.5)
    chip:write(0xFF18, register % 256)
    chip:write(0xFF19, 0x80 + math.floor(register / 256))
    local samples = chip:generate(math.floor(RATE / 8))

    local left, right = 0, 0
    for index = 1, #samples, 2 do
      left = math.max(left, math.abs(samples[index]))
      right = math.max(right, math.abs(samples[index + 1]))
    end
    check("a channel panned left comes out on the left", left > 0.1)
    check("and not on the right", right < 0.001)
  end

  -- Powering the chip down silences it, which the sound engine relies on
  -- between tracks.
  do
    local chip = apu.new(RATE)
    tone(chip, 440, 2, 15, true)
    chip:generate(64)
    chip:write(0xFF26, 0x00)
    local samples = chip:generate(math.floor(RATE / 8))
    check("powering the chip down silences it", swing(samples) < 0.001)
  end

  -- And the capacitor itself: a steady tone must average to nothing, or every
  -- channel starting and stopping would step the whole mix and click.
  do
    local chip = apu.new(RATE)
    tone(chip, 440, 0, 15, true)   -- 12.5% duty, the least symmetric one
    local samples = chip:generate(math.floor(RATE / 2))
    local sum, count = 0, 0
    -- Skip the first tenth, which is the capacitor charging.
    for index = math.floor(RATE / 10) * 2 + 1, #samples, 2 do
      sum = sum + samples[index]
      count = count + 1
    end
    local mean = sum / count
    log("        mean level of a 12.5%% duty tone: %.5f", mean)
    check("the output carries no DC offset", math.abs(mean) < 0.005)
  end
end

-- Which collision value is a whirlpool.
--
-- This was open for a long time because the question was being asked the wrong
-- way round: two dozen values are water and a value's number says nothing. What
-- settles it is what a whirlpool has to *do* — be rare, stand alone, and sit in
-- open water — and then looking at the art, which is what actually decided it.
local function test_whirlpool(rom, tileset_result, map_result)
  log("\n== whirlpool ==")
  if not tileset_result or not map_result then
    log("  SKIP  the tilesets or maps were not located")
    return
  end

  local whirlpool = require("src.rom.whirlpool")
  local collision = require("src.rom.collision")

  local result, why = whirlpool.locate(rom, tileset_result, map_result)
  if not check("the whirlpool value was found", result ~= nil, why) then
    return
  end

  log("        collision $%02X, %d cells on %d maps", result.value,
    result.cells, result.maps)
  check("it is water", collision.is_water(result.value))

  -- The whole survey, because the answer only means something beside the
  -- values it was chosen over.
  local values = {}
  for value in pairs(result.survey) do
    values[#values + 1] = value
  end
  table.sort(values)

  log("        value | cells | maps | clusters | mean size | in a channel")
  for _, value in ipairs(values) do
    local record = result.survey[value]
    if record.cells > 0 then
      log("         $%02X  | %5d | %4d | %8d | %9.1f | %3d%%%s", value,
        record.cells, record.maps, record.clusters,
        record.cells / math.max(record.clusters, 1),
        math.floor(record.in_channel / record.cells * 100),
        value == result.value and "   <-- chosen" or "")
    end
  end

  local chosen = result.survey[result.value]
  check_equal("every occurrence stands alone", chosen.clusters, chosen.cells)
  check("most of them have water on both sides",
    chosen.in_channel >= chosen.cells * 0.5)
  check("it is rare", chosen.maps <= whirlpool.MAX_MAPS)

  -- The three tests together are what pick it out, and no other water value
  -- passes all three. That is the claim the locator rests on, so it is asserted
  -- rather than described: the ordinary sea is far too common, the coastlines
  -- clump, and the one other value whose cells stand alone is never in water.
  local rivals = {}
  for _, value in ipairs(values) do
    local record = result.survey[value]
    if value ~= result.value and record.cells > 0
      and record.maps <= whirlpool.MAX_MAPS
      and record.clusters >= record.cells
      and record.in_channel >= record.cells * 0.5 then
      rivals[#rivals + 1] = ("$%02X"):format(value)
    end
  end
  check_equal("no other water value is rare, isolated and in the water",
    #rivals, 0, table.concat(rivals, ", "))

  -- Where it sits. A whirlpool guards sea routes; a waterfall would be mostly
  -- caves, so the split is worth recording as a second, independent check on
  -- which of the two field moves this value belongs to.
  local by_environment = {}
  for index, header in ipairs(map_result.headers) do
    if not header.unparsed and header.attributes then
      local set = tilesets.decode_collision(rom,
        tileset_result.headers[header.tileset])
      local blocks = maps.decode_block_data(rom, header)
      if set and blocks then
        local found = false
        for _, row in ipairs(blocks) do
          for _, block in ipairs(row) do
            local entry = set[block + 1]
            for _, quadrant in ipairs(entry or {}) do
              found = found or quadrant == result.value
            end
          end
        end
        if found then
          -- The header stores the environment as a byte; the names live in the
          -- map decoder rather than being repeated here.
          local name = maps.environments[header.environment] or "?"
          by_environment[name] = (by_environment[name] or 0) + 1
          log("        map %3d is a %s", index, tostring(name))
        end
      end
    end
  end
  check("it is mostly on routes rather than in caves",
    (by_environment["route"] or 0) > (by_environment["cave"] or 0))

  -- And in the engine's hands: water you cannot cross until somebody can.
  local cache_module = require("src.import.cache")
  local world = require("src.engine.world")
  local game_id
  for _, entry in ipairs(cache_module.list_games()) do
    if entry.current then
      game_id = entry.game
    end
  end
  if not game_id then
    log("  SKIP  no import in the cache for the engine half")
    return
  end

  local loaded = world.load(game_id)
  if not loaded then
    return
  end
  check_equal("the engine reads the same value from the cache",
    loaded.whirlpool, result.value)

  -- Find one and stand next to it.
  local found_map, wx, wy
  for index = 1, loaded:map_count() do
    local map = loaded:map(index)
    if not map.unparsed then
      for cell_y = 0, map.height * world.CELLS_PER_BLOCK - 1 do
        for cell_x = 0, map.width * world.CELLS_PER_BLOCK - 1 do
          if loaded:is_whirlpool(map, cell_x, cell_y) then
            found_map, wx, wy = map, cell_x, cell_y
            break
          end
        end
        if found_map then break end
      end
    end
    if found_map then break end
  end

  if not check("the engine can find one on a map", found_map ~= nil) then
    return
  end

  check("it reads as water", loaded:is_water(found_map, wx, wy))
  check("surfing does not get you across it",
    loaded:can_enter(found_map, wx, wy, true, false) == false)
  check("but knowing WHIRLPOOL does",
    loaded:can_enter(found_map, wx, wy, true, true))
  check("and on foot it is still water either way",
    loaded:can_enter(found_map, wx, wy, false, true) == false)
end

-- Which status each curing item undoes.
local function test_cures(rom, item_names, item_records, base_stats)
  log("\n== status cures ==")
  if not item_names then
    log("  SKIP  the item names were not located")
    return
  end

  local cures = require("src.rom.cures")

  local result, why = cures.locate(rom, item_names)
  if not check("the cure table was located", result ~= nil, why) then
    return
  end

  log("        %d records at 0x%06X (bank $%02X)", result.count, result.offset,
    math.floor(result.offset / 0x4000))
  check("more than the handful used to find it", result.count > 8)

  local id_of = {}
  for index, name in ipairs(item_names) do
    id_of[name] = index
  end

  -- The five that found it. Restated here because they are the whole basis of
  -- the search: what each undoes is not in dispute in any game in the series.
  local known = {
    { "ANTIDOTE", "poison" }, { "BURN HEAL", "burn" },
    { "ICE HEAL", "freeze" }, { "AWAKENING", "sleep" },
    { "PARLYZ HEAL", "paralysis" },
  }
  for _, entry in ipairs(known) do
    local record = result.by_item[id_of[entry[1]]]
    check_equal(("%s undoes %s"):format(entry[1], entry[2]),
      record and record.status, entry[2])
  end

  -- The eight that did not, which is where the evidence actually is. The two
  -- crossed berries are the best of them: an ICE BERRY soothing a burn and a
  -- BURNT BERRY thawing a freeze is exactly the pairing somebody guessing from
  -- the names would invert.
  local unsearched = {
    { "PSNCUREBERRY", "poison" }, { "PRZCUREBERRY", "paralysis" },
    { "MINT BERRY", "sleep" }, { "ICE BERRY", "burn" },
    { "BURNT BERRY", "freeze" }, { "MIRACLEBERRY", "all" },
    { "FULL RESTORE", "all" }, { "HEAL POWDER", "all" },
  }
  for _, entry in ipairs(unsearched) do
    local id = id_of[entry[1]]
    local record = id and result.by_item[id]
    check_equal(("%s undoes %s, and took no part in the search")
      :format(entry[1], entry[2]), record and record.status, entry[2])
  end

  -- Every mask is a real status, and the middle byte agrees with it everywhere.
  local unknown_mask, disagreements = 0, 0
  local action_of = {}
  for _, record in ipairs(result.records) do
    if not record.status then
      unknown_mask = unknown_mask + 1
    end
    if action_of[record.mask] and action_of[record.mask] ~= record.action then
      disagreements = disagreements + 1
    end
    action_of[record.mask] = record.action
  end
  check_equal("every mask names a status", unknown_mask, 0)
  check_equal("the middle byte agrees with the mask in every record",
    disagreements, 0)

  -- Why the obvious search does not work, asserted as the exact fact rather
  -- than as a statistic. "Where do the curing items' ids appear together" is
  -- close to worthless here because **the five single-status cures are
  -- consecutive ids**: every ascending run of bytes in the cartridge contains
  -- all five, and so does every shop stocking a Pokémon Centre's worth of
  -- medicine. Measured in --probe-cures, they sit together at 330 places and 4
  -- of 32 sampled five-runs do at least as well; what is sharp is not where the
  -- ids are but what sits beside them.
  local ordered = { "ANTIDOTE", "BURN HEAL", "ICE HEAL", "AWAKENING",
                    "PARLYZ HEAL" }
  local consecutive = true
  for index = 2, #ordered do
    if id_of[ordered[index]] ~= id_of[ordered[index - 1]] + 1 then
      consecutive = false
    end
  end
  log("        the five single-status cures are items %d to %d",
    id_of[ordered[1]], id_of[ordered[#ordered]])
  check("they are consecutive, which is what makes proximity useless",
    consecutive)

  -- Is the known-content check load-bearing, or is the structure enough on its
  -- own? Claim an Antidote cures a burn and the locator must refuse: if it
  -- still found a table, the pairing would not be what accepted this one.
  do
    local was = cures.KNOWN["ANTIDOTE"]
    cures.KNOWN["ANTIDOTE"] = cures.KNOWN["BURN HEAL"]
    local wrong = cures.locate(rom, item_names)
    cures.KNOWN["ANTIDOTE"] = was
    check("a wrong claim about what an Antidote does is refused", wrong == nil)
  end

  if not item_records or not base_stats then
    return
  end

  -- And in the engine's hands. Nothing below names an item: the Antidote is
  -- reached by asking the cure table which item undoes poison.
  local game = require("src.engine.game")
  local pokemon = require("src.engine.pokemon")
  local status = require("src.engine.status")
  local bag = require("src.engine.bag")

  local poison_cure, cure_all
  for item, record in pairs(result.by_item) do
    if record.status == "poison" and not poison_cure then poison_cure = item end
    if record.status == "all" and not cure_all then cure_all = item end
  end

  local instance = setmetatable({
    cures = result.by_item,
    item_records = item_records,
    item_names = item_names,
    base_stats = base_stats,
    species_names = setmetatable({}, { __index = function() return "MON" end }),
    party = { pokemon.new(155, base_stats[155], { level = 20 }) },
  }, game)
  instance.bag = bag.new(item_records, item_names)
  instance.bag:add(poison_cure, 2)
  instance.bag:add(cure_all, 1)

  local subject = instance.party[1]
  status.apply(subject, status.POISON)
  check("the subject is poisoned", subject.status == status.POISON)

  local entry = instance.bag:pocket("items")[1]
  for _, candidate in ipairs(instance.bag:pocket("items")) do
    if candidate.item == poison_cure then entry = candidate end
  end
  instance.ui = { kind = "pocket", pocket = "items" }
  instance:use_item_in_field(entry)
  check("using the poison cure clears it", subject.status == nil)
  check_equal("and it leaves the bag",
    instance.bag:count(poison_cure), 1)

  -- Toxic is poison that climbs rather than a status of its own, and the
  -- cartridge has one poison bit for both. An Antidote that failed on the worse
  -- poison would be a silent hole.
  status.apply(subject, status.TOXIC)
  instance.ui = { kind = "pocket", pocket = "items" }
  local again
  for _, candidate in ipairs(instance.bag:pocket("items")) do
    if candidate.item == poison_cure then again = candidate end
  end
  instance:use_item_in_field(again)
  check("the same cure undoes the worse poison too", subject.status == nil)

  -- A cure aimed at the wrong status does nothing and is not spent.
  status.apply(subject, status.BURN)
  instance.bag:add(poison_cure, 1)
  local wrong
  for _, candidate in ipairs(instance.bag:pocket("items")) do
    if candidate.item == poison_cure then wrong = candidate end
  end
  instance.ui = { kind = "pocket", pocket = "items" }
  instance:use_item_in_field(wrong)
  check("a poison cure does nothing to a burn", subject.status == status.BURN)
  check_equal("and stays in the bag", instance.bag:count(poison_cure), 1)

  local everything
  for _, candidate in ipairs(instance.bag:pocket("items")) do
    if candidate.item == cure_all then everything = candidate end
  end
  instance.ui = { kind = "pocket", pocket = "items" }
  instance:use_item_in_field(everything)
  check("but the one that undoes everything does", subject.status == nil)
end

-- The Pokédex entries: classification, height, weight and description.
--
-- The table is found by shape alone -- there is no first record to encode as a
-- signature, because a classification is just a word -- so most of what follows
-- is about how much the shape is really doing and what a wrong answer would
-- have scored.
local function test_dex(rom, species_names)
  log("\n== pokedex entries ==")

  local dex_rom = require("src.rom.dex")

  local result, why = dex_rom.locate(rom)
  if not check("the Pokédex entries were located", result ~= nil, why) then
    return
  end

  log("        %d entries, pointer table at 0x%06X", #result.entries,
    result.offset)
  check_equal("one entry per species", #result.entries, dex_rom.SPECIES_COUNT)

  -- The shape finds exactly as many records as there are species, and it was
  -- never told how many to look for. Anything else in the cartridge that
  -- happened to match would push this number up.
  check_equal("the shape finds no more records than there are species",
    result.found, dex_rom.SPECIES_COUNT)

  -- What would a wrong answer have scored? The one constraint on the four
  -- bytes that is arithmetic rather than "looks like text" is that a height in
  -- feet and inches cannot carry a twelfth inch. Dropping it and rescanning
  -- says how much work it does.
  local loose = 0
  do
    local data = rom.data
    local offset = 0
    while offset < #data - 16 do
      local first = string.byte(data, offset + 1)
      local hit = nil
      if first and first >= 0x80 and first <= 0x99 then
        local class, terminator = dex_rom.read_class(data, offset)
        if class then
          local cursor, ok = terminator + 5, true
          for index = 1, dex_rom.PAGES do
            local lines, consumed = dex_rom.read_page(data, cursor,
              index == 1 and 12 or 1)
            if not lines then
              ok = false
              break
            end
            cursor = cursor + consumed
          end
          if ok then
            hit = cursor
          end
        end
      end
      if hit then
        loose = loose + 1
        offset = hit
      else
        offset = offset + 1
      end
    end
  end
  log("        the same shape without the feet-and-inches check: %d records",
    loose)
  check("the feet-and-inches check is doing real work",
    loose > dex_rom.SPECIES_COUNT)

  -- One long run of pointers is only evidence beside how long the others get.
  log("        longest pointer run %d, next longest %d",
    dex_rom.SPECIES_COUNT, result.runner_up)
  check("no other run of pointers comes close", result.runner_up < 20)

  -- The bank split fell out of the search rather than being asked for: the
  -- cartridge stores its dex text in runs by species range, and a shape search
  -- that knew nothing about banks reproduced them.
  local counts = {}
  for _, bank in ipairs(result.bank_order) do
    counts[#counts + 1] = ("$%02X x%d"):format(bank, result.banks[bank])
  end
  log("        banks: %s", table.concat(counts, ", "))
  check_equal("the entries fall into four bank runs", #result.bank_order, 4)

  -- Every record decodes, and every height reads as feet and inches.
  local bad_inches, classless, short_pages, letters = 0, 0, 0, 0
  for _, entry in ipairs(result.entries) do
    if entry.height % 100 >= 12 then
      bad_inches = bad_inches + 1
    end
    if not entry.class or entry.class == "" then
      classless = classless + 1
    end
    if #entry.pages ~= dex_rom.PAGES then
      short_pages = short_pages + 1
    end
    for _, page in ipairs(entry.pages) do
      for _, line in ipairs(page) do
        letters = letters + #line.codes
      end
    end
  end
  check_equal("no height carries a twelfth inch", bad_inches, 0)
  check_equal("every species is classified", classless, 0)
  check_equal("every description has two pages", short_pages, 0)
  log("        %d characters of description across the dex", letters)
  -- A per-species floor rather than a total, which a handful of long entries
  -- could carry on their own. Two pages of three lines is around ninety
  -- characters; thirty is well below anything real and well above a stray
  -- match.
  local thin, thinnest = 0, math.huge
  for _, entry in ipairs(result.entries) do
    local count = 0
    for _, page in ipairs(entry.pages) do
      for _, line in ipairs(page) do
        count = count + #line.codes
      end
    end
    if count < 30 then
      thin = thin + 1
    end
    thinnest = math.min(thinnest, count)
  end
  log("        the shortest description is %d characters", thinnest)
  check_equal("every species has a real description", thin, 0)

  -- Spot checks. None of these took any part in finding the table, and the
  -- measurements are the same in Gold and Silver, so they are the same kind of
  -- external fact as "species 1 is BULBASAUR".
  local first = result.entries[1]
  check_equal("species 1 is the SEED POKéMON", first.class, "SEED")
  check_equal("and stands 2'04\"", dex_rom.height_text(first.height), "2'04")
  check_equal("and weighs 15.0lb", dex_rom.weight_text(first.weight), "15.0lb")

  check_equal("species 25 is the MOUSE POKéMON", result.entries[25].class,
    "MOUSE")
  check_equal("species 143 is the heaviest thing in the dex",
    dex_rom.weight_text(result.entries[143].weight), "1014.0lb")
  check_equal("species 251 is the TIMETRAVEL POKéMON",
    result.entries[251].class, "TIMETRAVEL")

  -- Steelix is the tallest, and its height is the one that most nearly breaks
  -- the two-digit inch rule the search leans on.
  local tallest, tallest_at = 0, nil
  for index, entry in ipairs(result.entries) do
    if entry.height > tallest then
      tallest, tallest_at = entry.height, index
    end
  end
  log("        tallest is species %d at %s", tallest_at,
    dex_rom.height_text(tallest))
  check("the tallest is still inside the ceiling the search allows",
    tallest < dex_rom.HEIGHT_MAX)

  -- No line may overrun the screen. The canvas is 160 wide, the text starts at
  -- x=4 and a glyph is 8 across, so 19 characters is the ceiling: the widest
  -- line, "LITTLE BIRD POKéMON", lands on 156 against the border at 157.
  -- Text running off the right edge is a bug this project has shipped before
  -- and only caught by looking at it; this catches it without looking.
  local longest, longest_text = 0, ""
  for _, entry in ipairs(result.entries) do
    for _, page in ipairs(entry.pages) do
      for _, line in ipairs(page) do
        if #line.codes > longest then
          longest, longest_text = #line.codes, line.text
        end
      end
    end
  end
  log("        the longest line is %d glyphs: %q", longest, longest_text)
  check("every description line fits the screen", longest <= 19)

  -- And the classification, which is drawn with " POKéMON" after it.
  local longest_class, class_text = 0, ""
  for _, entry in ipairs(result.entries) do
    if #entry.class > longest_class then
      longest_class, class_text = #entry.class, entry.class
    end
  end
  log("        the longest classification is %q", class_text)
  check("the longest classification still fits beside POKéMON",
    longest_class + 8 <= 19)

  -- The second page is where a one-page reading would have silently stopped,
  -- so it gets a content check of its own rather than only a count. This is
  -- Bulbasaur's, read off the cartridge before any of this code existed.
  local second = first.pages[2]
  check_equal("the second page has three lines", #second, 3)
  check_equal("and reads on from the first", second[1].text, "stored in the")
  check_equal("through its second line", second[2].text, "seeds on its back")
  check_equal("to its last", second[3].text, "in order to grow.")

  -- The line codes are what the font actually draws, and they have to agree
  -- with the text rather than being a parallel decoding that could drift.
  check_equal("the codes match the text they were read from",
    #second[1].codes, #second[1].text)

  if species_names then
    local entry = result.entries[1]
    log("        %s, the %s POKéMON: %s", species_names[1], entry.class,
      entry.pages[1][1].text)
    log("        page 2: %s / %s / %s", second[1].text, second[2].text,
      second[3].text)
  end
end

--- Which species have been seen and which have been caught.
local function test_dex_tracking(base_stats)
  log("\n== pokedex tracking ==")

  local dex = require("src.engine.dex")

  local book = dex.new(251)
  check_equal("a new dex has seen nothing", book:seen_count(), 0)
  check_equal("and caught nothing", book:caught_count(), 0)

  check("seeing one is news the first time", book:see(19))
  check("but not the second", book:see(19) == false)
  check("it is seen", book:is_seen(19))
  check("and not caught", book:is_caught(19) == false)
  check_equal("one sighting", book:seen_count(), 1)

  -- The implication that stops eight call sites having to remember it.
  check("catching one that was never seen is news", book:catch(25))
  check("and it counts as seen too", book:is_seen(25))
  check_equal("two sightings now", book:seen_count(), 2)
  check_equal("and one catch", book:caught_count(), 1)

  -- Out of range is refused rather than quietly stored, which would put a
  -- species 0 or a species 999 in the counts.
  check("species 0 is refused", book:see(0) == false)
  check("as is one past the end", book:see(252) == false)
  check("and something that is not a number", book:see("25") == false)
  check_equal("none of which changed the count", book:seen_count(), 2)

  check_equal("the first one seen is the lowest numbered", book:first_seen(1), 19)
  check_equal("looking from past it finds the next", book:first_seen(20), 25)
  check("looking past everything finds nothing",
    book:first_seen(200) == nil)

  -- Round trip through the two lists a save holds. The two states have to stay
  -- apart across it: one species seen, the other seen and caught.
  local seen, caught = book:to_lists()
  check_equal("two species go into the save", #seen, 2)
  check_equal("one of them caught", #caught, 1)
  local restored = dex.from_lists(251, seen, caught)
  check_equal("the sightings come back", restored:seen_count(), 2)
  check_equal("and the catches", restored:caught_count(), 1)
  check("the right one is caught", restored:is_caught(25))
  check("and the other only seen", restored:is_caught(19) == false)

  -- Catching one already seen is news, but not a second sighting.
  check("catching one already seen is still news", book:catch(19))
  check_equal("without adding a sighting", book:seen_count(), 2)
  check_equal("and now both are owned", book:caught_count(), 2)

  -- And through a real save file, not just the two lists. The dex goes in as
  -- an object and comes back as data, so the two halves have to agree about
  -- the shape between them.
  local save = require("src.engine.save")
  local game_id = "harness_dex_test"
  local written, why = save.write(game_id, { party = {}, dex = book })
  if check("a save carrying a dex is written", written, why) then
    local state = save.read(game_id, base_stats)
    if check("and read back", state ~= nil) then
      local back = dex.from_lists(251, state.dex.seen, state.dex.caught)
      check_equal("the sightings survive the file", back:seen_count(), 2)
      check_equal("and the catches", back:caught_count(), 2)
      check("naming the same species", back:is_caught(19) and back:is_caught(25))
    end
    save.remove(game_id)
  end

  if not base_stats then
    return
  end

  -- The engine's own hooks. Anything reaching the party is owned, and an
  -- evolution is a species nothing else would register: it never passes back
  -- through add_to_party.
  local game = require("src.engine.game")
  local pokemon = require("src.engine.pokemon")

  local instance = setmetatable({
    dex = dex.new(251),
    party = {},
    base_stats = base_stats,
  }, game)

  instance:add_to_party(pokemon.new(25, base_stats[25], { level = 5 }))
  check("joining the party registers a catch", instance.dex:is_caught(25))

  -- The description turns over rather than scrolling, because that is the shape
  -- the cartridge stores it in. Two pages, and it wraps at both ends.
  instance.dex_entries = { [25] = { pages = { {}, {} } } }
  instance.ui = { kind = "dex_entry", species = 25, page = 1 }
  instance:dex_entry_page(1)
  check_equal("right turns to the second page", instance.ui.page, 2)
  instance:dex_entry_page(1)
  check_equal("and wraps back to the first", instance.ui.page, 1)
  instance:dex_entry_page(-1)
  check_equal("left from the first wraps to the last", instance.ui.page, 2)

  local subject = pokemon.new(1, base_stats[1], { level = 15 })
  pokemon.evolve(subject, 2, base_stats[2])
  instance.dex:catch(subject.species)
  check("and what it evolves into is a catch of its own",
    instance.dex:is_caught(2))
  check_equal("which is two species owned from one caught",
    instance.dex:caught_count(), 2)
end

-- What the field moves clear away.
local function test_obstacles(rom, map_result)
  log("\n== obstacles ==")
  if not map_result then
    log("  SKIP  maps were not located")
    return
  end

  local obstacles = require("src.rom.obstacles")

  local result, why = obstacles.locate(rom, map_result)
  if not check("the cut tree and the boulder were found", result ~= nil, why) then
    return
  end

  log("        tree is sprite %d (%s), boulder is sprite %d (%s)",
    result.tree, result.evidence.tree, result.boulder,
    result.evidence.boulder)

  check("they are two different things", result.tree ~= result.boulder)
  check("and two different routines", result.tree_std ~= result.boulder_std)

  -- The Pokémon Centre nurse matched everything the first version of this
  -- looked for: twenty-two of her, all indoors, all jumping straight to one
  -- routine, so she ranked as the most enclosed thing in the game. What
  -- separates her is that her routine greets you and an obstacle's says
  -- nothing, so the routines are checked for text.
  local events_module = require("src.rom.events")
  local by_sprite = {}
  for _, header in ipairs(map_result.headers) do
    local decoded = not header.unparsed and events_module.decode(rom, header)
    if decoded then
      for _, object in ipairs(decoded.objects) do
        by_sprite[object.sprite] = (by_sprite[object.sprite] or 0) + 1
      end
    end
  end

  check("there are a couple of dozen trees",
    (by_sprite[result.tree] or 0) >= 8 and (by_sprite[result.tree] or 0) <= 60,
    ("%d"):format(by_sprite[result.tree] or 0))
  check("and a couple of dozen boulders",
    (by_sprite[result.boulder] or 0) >= 8
    and (by_sprite[result.boulder] or 0) <= 60,
    ("%d"):format(by_sprite[result.boulder] or 0))

  -- The split that tells them apart: boulders are underground, trees are not.
  local function enclosed_share(sprite)
    local enclosed, total = 0, 0
    for _, header in ipairs(map_result.headers) do
      local decoded = not header.unparsed and events_module.decode(rom, header)
      if decoded then
        for _, object in ipairs(decoded.objects) do
          if object.sprite == sprite then
            total = total + 1
            if obstacles.ENCLOSED[header.environment_name] then
              enclosed = enclosed + 1
            end
          end
        end
      end
    end
    return enclosed / math.max(total, 1)
  end

  local boulder_share = enclosed_share(result.boulder)
  local tree_share = enclosed_share(result.tree)
  log("        boulders are %d%% enclosed, trees %d%%",
    math.floor(boulder_share * 100), math.floor(tree_share * 100))
  check("boulders are the enclosed ones", boulder_share > tree_share,
    ("%.2f against %.2f"):format(boulder_share, tree_share))
  check("and it is not a close call", boulder_share - tree_share > 0.3)
end

-- The machine list, and the field moves it names.
local function test_machines(rom, move_names, base_stats)
  log("\n== machines ==")
  if not move_names then
    log("  SKIP  the move names were not located")
    return
  end

  local machines = require("src.rom.machines")

  local result, why = machines.locate(rom, move_names)
  if not check("the machine list was located", result ~= nil, why) then
    return
  end

  log("        57 machines at 0x%06X", result.offset)
  check_equal("fifty TMs and seven HMs", #result.moves, machines.COUNT)

  -- The HMs are what the check rests on, and they are worth restating: these
  -- names come from the cartridge's move table, not from here.
  local expected = { CUT = "CUT", FLY = "FLY", SURF = "SURF",
                     STRENGTH = "STRENGTH", FLASH = "FLASH",
                     WHIRLPOOL = "WHIRLPOOL", WATERFALL = "WATERFALL" }
  for name, wanted in pairs(expected) do
    check_equal(("HM %s teaches %s"):format(name, wanted),
      move_names[result.hm[name]], wanted)
  end

  -- Every machine teaches a different move, which is the shape half of the
  -- test. On its own it is satisfied by 626 offsets in this cartridge.
  local seen, distinct = {}, 0
  for _, move in ipairs(result.moves) do
    if not seen[move] then
      seen[move] = true
      distinct = distinct + 1
    end
  end
  check_equal("no move is on two machines", distinct, machines.COUNT)

  -- Spot checks on the TM half, from outside this code.
  check_equal("TM01 is DYNAMICPUNCH", move_names[result.moves[1]],
    "DYNAMICPUNCH")
  check_equal("TM26 is EARTHQUAKE", move_names[result.moves[26]], "EARTHQUAKE")
  check_equal("TM44 is REST", move_names[result.moves[44]], "REST")

  if not base_stats then
    return
  end

  -- The field moves in the engine's hands.
  local game = require("src.engine.game")
  local pokemon = require("src.engine.pokemon")

  local instance = setmetatable({
    hm_moves = result.hm,
    badges = {},
    party = { pokemon.new(155, base_stats[155], { level = 20 }) },
    species_names = setmetatable({}, { __index = function() return "MON" end }),
  }, game)
  instance.party[1].moves = { 33 }

  check("nobody can surf to begin with",
    instance:knows_field_move("SURF") == nil)
  instance.party[1].moves[#instance.party[1].moves + 1] = result.hm.SURF
  check("teaching it changes that",
    instance:knows_field_move("SURF") == instance.party[1])

  -- The badge half is written but not enforced, and the test says which is
  -- which rather than letting the distinction blur.
  local member, licensed = instance:can_use_field_move("SURF",
    game.SURF_BADGE)
  check("the move is known", member ~= nil)
  check("but the badge is not held", licensed == false)
  instance:award_badge(game.SURF_BADGE)
  local _, now = instance:can_use_field_move("SURF", game.SURF_BADGE)
  check("awarding it says so", now == true)
end

-- Switching, and reaching into the bag mid-fight.
local function test_battle_menu(base_stats, item_attributes, item_names)
  log("\n== battle menu ==")
  if not base_stats or not item_attributes then
    log("  SKIP  the base stats or item tables were not located")
    return
  end

  local game = require("src.engine.game")
  local pokemon = require("src.engine.pokemon")
  local bag = require("src.engine.bag")

  local function mon(species, level, hp)
    local instance = pokemon.new(species, base_stats[species], { level = level })
    instance.hp = hp == nil and instance.stats.hp or hp
    return instance
  end

  local function fake(party)
    local instance = setmetatable({
      party = party,
      money = 3000,
      species_names = setmetatable({}, { __index = function() return "MON" end }),
      base_stats = base_stats,
      item_records = item_attributes,
      item_names = item_names,
      bag = bag.new(item_attributes, item_names),
      replies = 0,
    }, game)
    instance.notify = function(self, message) self.notified = message end
    -- The opponent's answer is counted rather than played out: what is being
    -- checked is that acting costs the turn, not what the reply was.
    instance.opponent_replies = function(self) self.replies = self.replies + 1 end
    return instance
  end

  -- Switching.
  local out, spare = mon(155, 10), mon(25, 12)
  local instance = fake({ out, spare })
  instance.battle = { player = out, opponent = mon(19, 8), over = false }

  check("switching to the one already out is refused",
    instance:switch_to(out) == false)
  check_equal("and nothing is spent on it", instance.replies, 0)

  local fainted = mon(16, 9, 0)
  instance.party[3] = fainted
  check("switching to a fainted one is refused",
    instance:switch_to(fainted) == false)

  check("switching to a healthy one works", instance:switch_to(spare))
  check_equal("it is the one on the field now", instance.battle.player, spare)
  check("it starts with fresh stat stages", spare.stages ~= nil)
  check_equal("and the opponent gets a free move", instance.replies, 1)

  -- Items. A Potion restores its parameter and costs the turn.
  local hurt = fake({ mon(155, 20, 5) })
  hurt.battle = { player = hurt.party[1], opponent = mon(19, 8), over = false }
  hurt.bag:add(18, 2)   -- POTION
  hurt.bag:add(9, 1)    -- ANTIDOTE
  hurt.bag:add(5, 3)    -- POKe BALL

  local potion = hurt.bag:pocket("items")
  local entry
  for _, candidate in ipairs(potion) do
    if candidate.item == 18 then entry = candidate end
  end
  hurt:use_item_in_battle(entry)
  check_equal("a potion restores its parameter", hurt.battle.player.hp,
    5 + item_attributes[18].parameter)
  check_equal("it leaves the bag", hurt.bag:count(18), 1)
  check_equal("and using it costs the turn", hurt.replies, 1)

  -- An Antidote reads as a heal in the menu nibble but carries no amount,
  -- because what it undoes is poison. Treating it as a heal spent the turn to
  -- recover nothing, which is the bug this guards.
  local antidote
  for _, candidate in ipairs(hurt.bag:pocket("items")) do
    if candidate.item == 9 then antidote = candidate end
  end
  check_equal("an antidote's menu nibble does say heal",
    item_attributes[9].battle_use, "heal")
  check_equal("but it carries no amount", item_attributes[9].parameter, 0)

  local before_hp, before_turns = hurt.battle.player.hp, hurt.replies
  hurt:use_item_in_battle(antidote)
  check_equal("using it changes no HP", hurt.battle.player.hp, before_hp)
  check_equal("costs no turn", hurt.replies, before_turns)
  check_equal("stays in the bag", hurt.bag:count(9), 1)
  check("and says so", hurt.notified ~= nil)

  -- A ball is not for someone else's Pokémon.
  local ball
  for _, candidate in ipairs(hurt.bag:pocket("balls")) do
    ball = ball or candidate
  end
  hurt.trainer = { name = "FALKNER" }
  hurt.close_menu = function() end
  hurt:use_item_in_battle(ball)
  check_equal("a ball thrown at a trainer's Pokémon is refused",
    hurt.bag:count(5), 3)
end

-- Experience, levelling, and what follows from it.
local function test_experience(rom, base_stats)
  log("\n== experience ==")

  local experience = require("src.engine.experience")
  local pokemon = require("src.engine.pokemon")
  local learnsets = require("src.rom.learnsets")

  local located = rom and learnsets.locate(rom)
  local learnset_records = located and located.records

  -- The totals at level 100 are round, well-known numbers that come from
  -- outside this code, which is what makes them worth asserting: a mistyped
  -- coefficient shows up here rather than as a Pokémon that levels slightly
  -- wrong for fifty hours.
  check_equal("medium fast tops out at a million",
    experience.total_for("medium_fast", 100), 1000000)
  check_equal("fast at 800,000", experience.total_for("fast", 100), 800000)
  check_equal("slow at 1,250,000", experience.total_for("slow", 100), 1250000)
  check_equal("medium slow at 1,059,860",
    experience.total_for("medium_slow", 100), 1059860)

  -- Every curve starts at nothing, including the one whose polynomial goes
  -- negative down there.
  for _, name in ipairs(experience.CURVE_NAMES) do
    check_equal(("%s starts at zero"):format(name),
      experience.total_for(name, 1), 0)
  end
  check("the medium slow curve is not negative at low levels",
    experience.total_for("medium_slow", 2) >= 0)

  -- Curves have to be climbing, or level_for would go backwards.
  local rising = 0
  for _, name in ipairs(experience.CURVE_NAMES) do
    local ok = true
    for level = 2, 100 do
      if experience.total_for(name, level)
        < experience.total_for(name, level - 1) then
        ok = false
      end
    end
    if ok then rising = rising + 1 end
  end
  check_equal("every curve climbs", rising, #experience.CURVE_NAMES)

  -- Reading a level back out of an amount has to agree with what put it in.
  local agree = 0
  for _, name in ipairs(experience.CURVE_NAMES) do
    local ok = true
    for level = 1, 100 do
      if experience.level_for(name, experience.total_for(name, level)) ~= level then
        ok = false
      end
    end
    if ok then agree = agree + 1 end
  end
  check_equal("a level round-trips through its own total", agree,
    #experience.CURVE_NAMES)
  check_equal("one short of the next level is still the old level",
    experience.level_for("medium_fast",
      experience.total_for("medium_fast", 30) - 1), 29)

  -- What a defeat is worth. A trainer's Pokémon pays half as much again, and
  -- splitting it between participants divides it.
  local plain = experience.gain(100, 20)
  check_equal("a level 20 with 100 base exp is worth 285", plain, 285)
  check_equal("a trainer's is worth half as much again",
    experience.gain(100, 20, { trainer = true }), 427)
  check_equal("two participants split it",
    experience.gain(100, 20, { participants = 2 }), 142)
  check("nothing is ever worth nothing", experience.gain(0, 1) >= 1)

  if not base_stats then
    log("  SKIP  the base stats were not located")
    return
  end

  -- A new Pokémon starts with the experience its level is worth, or it would
  -- level up on the first point it earned.
  local cyndaquil = pokemon.new(155, base_stats[155], { level = 20 })
  check_equal("a new Pokémon starts at its level's total", cyndaquil.exp,
    experience.total_for(base_stats[155].growth_rate, 20))

  -- Levelling recomputes the stats.
  local before = cyndaquil.stats.attack
  cyndaquil.hp = cyndaquil.stats.hp
  experience.award(cyndaquil, base_stats[155].growth_rate,
    experience.total_for(base_stats[155].growth_rate, 25) - cyndaquil.exp)
  check_equal("it reaches the level the experience buys", cyndaquil.level, 25)
  pokemon.recompute(cyndaquil, base_stats[155])
  check("and its stats went up", cyndaquil.stats.attack > before)
  check_equal("a healthy Pokémon stays healthy through a level up",
    cyndaquil.hp, cyndaquil.stats.hp)

  -- Damage carries across a level up rather than being healed away.
  local hurt = pokemon.new(155, base_stats[155], { level = 20 })
  hurt.hp = hurt.stats.hp - 7
  hurt.level = 21
  pokemon.recompute(hurt, base_stats[155])
  check_equal("and a hurt one stays hurt by the same amount",
    hurt.stats.hp - hurt.hp, 7)

  -- Crossing several levels at once must not skip the moves in between.
  if learnset_records then
    local jumped = 0
    for species = 1, 251 do
      local record = learnset_records[species]
      if record then
        for _, entry in ipairs(record.moves) do
          local at = learnsets.moves_learned_at(record, entry.level)
          local present = false
          for _, move in ipairs(at) do
            present = present or move == entry.move
          end
          if present then jumped = jumped + 1 end
        end
      end
    end
    check("every learnset entry is returned at its own level", jumped > 2000,
      ("%d"):format(jumped))

    -- Evolution by level is read from the same records.
    local evolving = 0
    for species = 1, 251 do
      if learnsets.evolution_at(learnset_records[species], 100) then
        evolving = evolving + 1
      end
    end
    log("        %d species evolve by level somewhere below 100", evolving)
    check("plenty of species evolve by level", evolving > 50,
      ("%d"):format(evolving))

    -- Evolving keeps what is personal and changes what is not.
    local bulbasaur = pokemon.new(1, base_stats[1], { level = 16 })
    local dvs_before, exp_before = bulbasaur.dvs, bulbasaur.exp
    pokemon.evolve(bulbasaur, 2, base_stats[2])
    check_equal("evolving changes the species", bulbasaur.species, 2)
    check_equal("keeps the DVs", bulbasaur.dvs, dvs_before)
    check_equal("keeps the experience", bulbasaur.exp, exp_before)
    check_equal("keeps the level", bulbasaur.level, 16)
    check("and takes the new species' typing",
      bulbasaur.types[1] == base_stats[2].type_1)
  end
end

-- Reading a real cartridge save.
local function test_sav(base_stats)
  log("\n== save files ==")
  if not base_stats then
    log("  SKIP  the base stats were not located")
    return
  end

  local sav = require("src.engine.sav")
  local pokemon = require("src.engine.pokemon")

  local function byte(value)
    return string.char(value % 256)
  end
  local function word(value)
    return byte(math.floor(value / 256)) .. byte(value)
  end

  -- Build a party member the way the cartridge stores one, with the stats
  -- worked out by the same formula the reader checks them against.
  local function member(species, level, dvs, statexp)
    statexp = statexp or {}
    local base = base_stats[species]
    local out = {}
    out[#out + 1] = byte(species)          -- species
    out[#out + 1] = byte(0)                -- held item
    out[#out + 1] = byte(33) .. byte(0) .. byte(0) .. byte(0) -- moves
    out[#out + 1] = word(0)                -- OT id
    out[#out + 1] = byte(0) .. byte(0) .. byte(0) -- experience
    for _, name in ipairs({ "hp", "attack", "defense", "speed", "special" }) do
      out[#out + 1] = word(statexp[name] or 0)
    end
    out[#out + 1] = byte(dvs.attack * 16 + dvs.defense)
    out[#out + 1] = byte(dvs.speed * 16 + dvs.special)
    out[#out + 1] = byte(0) .. byte(0) .. byte(0) .. byte(0) -- pp
    out[#out + 1] = byte(70)               -- friendship
    out[#out + 1] = byte(0)                -- pokerus
    out[#out + 1] = word(0)                -- caught data
    out[#out + 1] = byte(level)            -- level
    out[#out + 1] = byte(0)                -- status
    out[#out + 1] = byte(0)                -- unused

    local hp = pokemon.stat(base.hp, pokemon.dv_for(dvs, "hp"), level, "hp",
      statexp.hp)
    out[#out + 1] = word(hp)               -- current HP
    out[#out + 1] = word(hp)               -- max HP
    for _, name in ipairs(sav.STAT_ORDER) do
      local pool = name:find("special") and statexp.special or statexp[name]
      out[#out + 1] = word(pokemon.stat(base[sav.BASE_FIELD[name]],
        pokemon.dv_for(dvs, name), level, name, pool))
    end

    local packed = table.concat(out)
    assert(#packed == sav.MEMBER_SIZE,
      ("member is %d bytes, expected %d"):format(#packed, sav.MEMBER_SIZE))
    return packed
  end

  local dvs = { attack = 13, defense = 9, speed = 15, special = 4 }
  local party = {
    { 155, 24 },  -- CYNDAQUIL
    { 25, 31 },   -- PIKACHU
    { 251, 70 },  -- CELEBI
  }

  local function build_party(damage, level_shift)
    local list, members = {}, {}
    for index, entry in ipairs(party) do
      list[index] = byte(entry[1])
      members[index] = member(entry[1], entry[2] + (level_shift or 0), dvs,
        index == 2 and { hp = 5000, attack = 12000 } or nil)
    end
    -- Count, six species slots however many are filled, then the terminator.
    local packed = byte(#party) .. table.concat(list)
      .. string.rep(byte(0), sav.PARTY_LIMIT - #party)
      .. byte(sav.SPECIES_TERMINATOR)
      .. table.concat(members)

    if damage then
      -- Nudge one stat by one. The shape stays perfect; only the arithmetic
      -- stops agreeing.
      local at = 2 + sav.PARTY_LIMIT + sav.OFFSETS.attack + 1
      packed = packed:sub(1, at) ..
        byte((packed:byte(at + 1) + 1) % 256) .. packed:sub(at + 2)
    end
    return packed
  end

  -- Hide the party in a save full of noise, at an offset the reader is not
  -- told. Deterministic noise, so a failure is reproducible.
  local function save_with(block, at)
    math.randomseed(20260809)
    local noise = {}
    for _ = 1, sav.SIZE do
      noise[#noise + 1] = byte(math.random(0, 255))
    end
    local data = table.concat(noise)
    return data:sub(1, at) .. block .. data:sub(at + #block + 1)
  end

  local block = build_party(false)
  local hidden_at = 0x2A3C
  local data = save_with(block, hidden_at)

  local members, where = sav.find_party(data, base_stats)
  if check("the party is found without being told where", members ~= nil,
    tostring(where)) then
    check_equal("at the offset it was hidden at", where, hidden_at)
    check_equal("with the right number of members", #members, #party)
    check_equal("the first is a CYNDAQUIL", members[1].species, 155)
    check_equal("at the level it was given", members[1].level, 24)
    check_equal("the last is CELEBI", members[3].species, 251)
    check_equal("its speed DV survives", members[1].dvs.speed, 15)
    -- Stat experience feeds the formula, so a member carrying some proves the
    -- reader is using it rather than ignoring it.
    check("the trained member has more HP than the untrained formula gives",
      members[2].stats.hp > pokemon.stat(base_stats[25].hp,
        pokemon.dv_for(dvs, "hp"), 31, "hp", 0))
  end

  -- A real Crystal save holds the party twice: the cartridge keeps a backup of
  -- everything it writes. Two copies saying the same thing is one party, not an
  -- ambiguity, and the reader has to see it that way or it refuses every real
  -- save there is.
  local twice = save_with(block, hidden_at)
  local backup_at = hidden_at + 0xE00
  twice = twice:sub(1, backup_at) .. block
    .. twice:sub(backup_at + #block + 1)
  local both, from, copies = sav.find_party(twice, base_stats)
  check("a party stored twice is still one party", both ~= nil, tostring(from))
  check_equal("and both copies are counted", copies, 2)
  check_equal("reading from the first", from, hidden_at)

  -- Copies that disagree are a save caught mid-write, and choosing between
  -- them is not this code's decision. Both have to be valid parties for this
  -- to test anything: a corrupt backup fails the stat check outright and is
  -- not a competing answer at all, which is why the first attempt at this test
  -- passed for the wrong reason.
  local other = build_party(false, 1)
  local disagreeing = twice:sub(1, backup_at) .. other
    .. twice:sub(backup_at + #other + 1)
  check_equal("both copies are valid parties",
    #sav.find_parties(disagreeing, base_stats), 2)
  check("but disagreeing copies are refused",
    sav.find_party(disagreeing, base_stats) == nil)

  -- And a backup that is merely corrupt does not stop the good copy being
  -- read, since it is not a party at all.
  local corrupt = twice:sub(1, backup_at) .. build_party(true)
    .. twice:sub(backup_at + #block + 1)
  check("a corrupt backup does not block the good copy",
    sav.find_party(corrupt, base_stats) ~= nil)

  -- The check that matters. One stat byte off by one, everything else perfect.
  local damaged = save_with(build_party(true), hidden_at)
  local found_damaged, why = sav.find_party(damaged, base_stats)
  check("a party with one stat wrong is refused", found_damaged == nil,
    tostring(why))

  -- Noise alone holds no party.
  local empty = save_with("", 0)
  check("a save of noise holds no party", sav.find_party(empty, base_stats) == nil)

  -- Wrong size is not a save.
  check("something that is not 32K is refused",
    sav.find_party(("\0"):rep(1024), base_stats) == nil)

  -- Without a cartridge there is nothing to check against, and guessing is
  -- worse than refusing.
  check("without base stats it refuses rather than guessing",
    sav.find_party(data, nil) == nil)
end

-- The music table. Located and read; not played.
local function test_music(rom)
  log("\n== music ==")

  local music = require("src.rom.music")

  local result, why = music.locate(rom)
  if not check("the music table was located", result ~= nil, why) then
    return
  end

  log("        %d slots at 0x%06X, %d decode, %d end exactly where their " ..
    "first channel begins", result.count, result.offset, result.decoded,
    result.exact)

  check("Crystal has dozens of songs", result.count >= 40
    and result.count <= 200, ("%d"):format(result.count))

  -- The table used to stop at the first slot that did not decode, and reported
  -- 59. The scripts said otherwise: `playmusic` asks for music 78, 93, 96 and
  -- 97. Enumerating the region rather than stopping at the first awkward slot
  -- takes it to 103, which covers every id the game asks for.
  check("the table reaches the highest music id the scripts ask for",
    result.count > 97, ("%d slots"):format(result.count))

  -- The awkward slots are kept rather than dropped, because a song is named by
  -- its index: omitting one would shift every song after it.
  local placeholders = result.count - result.decoded
  log("        %d slots do not decode and are kept as placeholders",
    placeholders)
  check("almost every slot decodes", result.decoded >= result.count * 0.95,
    ("%d of %d"):format(result.decoded, result.count))

  -- The structural agreement the locator rests on, asserted rather than
  -- assumed: a header's entries are contiguous with the data they point at, so
  -- the arithmetic has to close. It closes for most of them.
  check("most headers run straight into their own channel data",
    result.exact >= result.decoded * 0.75,
    ("%d of %d"):format(result.exact, result.decoded))

  -- Songs use two, three or four channels, and the Game Boy has four.
  local by_count, slack = {}, {}
  for _, song in ipairs(result.songs) do
    if not song.unparsed then
      by_count[song.count] = (by_count[song.count] or 0) + 1
      if not song.exact then
        slack[song.slack] = (slack[song.slack] or 0) + 1
      end
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
    (by_count[3] or 0) + (by_count[4] or 0) >= result.decoded * 0.8)

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
    if not song.unparsed then
      local rising = true
      for index = 2, song.count do
        if song.channels[index] < song.channels[index - 1] then
          rising = false
        end
      end
      if rising then ordered = ordered + 1 end
    end
  end
  check_equal("every song's channels are stored in order", ordered,
    result.decoded)

  -- The channel command language is not decoded, and this records why rather
  -- than leaving the question open for someone to answer the same wrong way.
  --
  -- Channel data is contiguous: channel 1 runs up to where channel 2 starts.
  -- That is the lever that validated the script opcode widths, so it is the
  -- obvious one to reach for here. It is useless. A walk with every command
  -- one byte wide consumes a byte at a time and lands on the boundary every
  -- time, so a table of zeros scores perfectly and the measure distinguishes
  -- nothing. Asserting the degeneracy keeps it from being adopted again.
  local extents = {}
  for _, song in ipairs(result.songs) do
    for index = 1, (song.unparsed and 0 or song.count) - 1 do
      local from = song.bank * 0x4000 + (song.channels[index] - 0x4000)
      local to = song.bank * 0x4000 + (song.channels[index + 1] - 0x4000)
      if to > from and to - from < 4096 then
        extents[#extents + 1] = { from = from, to = to }
      end
    end
  end

  local function lands_exactly(widths)
    local exact = 0
    for _, extent in ipairs(extents) do
      local at = extent.from
      local ok = true
      while at < extent.to do
        local value = rom:u8(at)
        local width = value < 0xD0 and 0 or widths[value]
        if width == nil then
          ok = false
          break
        end
        at = at + 1 + width
      end
      if ok and at == extent.to then
        exact = exact + 1
      end
    end
    return exact
  end

  local zeros = {}
  for value = 0xD0, 0xFF do
    zeros[value] = 0
  end

  log("        %d channel extents; a width table of all zeros lands exactly " ..
    "%d times", #extents, lands_exactly(zeros))
  check("there are channel extents to measure against", #extents > 100,
    ("%d"):format(#extents))
  check_equal("a table of zeros satisfies the extents completely",
    lands_exactly(zeros), #extents)

  -- The facts that do stand, and are worth keeping true.
  local starts, ends = {}, {}
  for _, extent in ipairs(extents) do
    starts[rom:u8(extent.from)] = (starts[rom:u8(extent.from)] or 0) + 1
    ends[rom:u8(extent.to - 1)] = (ends[rom:u8(extent.to - 1)] or 0) + 1
  end
  local distinct_starts = 0
  for _ in pairs(starts) do distinct_starts = distinct_starts + 1 end
  check("a channel opens with one of only a few commands", distinct_starts <= 10,
    ("%d distinct"):format(distinct_starts))
  check("and most channels end on $FF", (ends[0xFF] or 0) >= #extents * 0.5,
    ("%d of %d"):format(ends[0xFF] or 0, #extents))
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
    -- A battle always starts and is always won, so the scripts that fight can
    -- be walked past rather than stopping there.
    script_start_battle = function() return true end,
    script_just_battled = function() return true end,
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
        -- A battle resolves and the script carries on.
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

  -- Battles started by a script. Built here so the sequence is stated: load a
  -- combatant, start the fight, and do not move on until it is over.
  local asked_for = nil
  local battle_host = {}
  for key, value in pairs(host) do battle_host[key] = value end
  battle_host.script_start_battle = function(_, spec)
    asked_for = spec
    return true
  end

  local function battle_code(loader, args)
    return {
      [1] = {
        [0x4000] = { op = loader, opcode = loader == "loadwildmon" and 0x5D
          or 0x5E, size = 3, args = args },
        [0x4003] = { op = "startbattle", opcode = 0x5F, size = 1, args = {} },
        [0x4004] = { op = "checkjustbattled", opcode = 0x67, size = 1,
                     args = {} },
        [0x4005] = { op = "end", opcode = 0x91, size = 1, args = {},
                     ends = true },
      },
    }
  end

  local wild = vm.new(battle_host, battle_code("loadwildmon", { 155, 20 }))
  wild:start(1, 0x4000)
  local status = wild:resume()
  check_equal("a script that fights stops to do it", status, "waiting")
  check_equal("and says so", wild.pending and wild.pending.kind, "battle")
  check_equal("the wild Pokémon it loaded is what is asked for",
    asked_for and asked_for.species, 155)
  check_equal("at the level it said", asked_for and asked_for.level, 20)
  -- Resuming is what the engine does when the fight ends.
  check_equal("and the script carries on afterwards", wild:resume(), "ended")

  asked_for = nil
  local versus = vm.new(battle_host, battle_code("loadtrainer", { 12, 3 }))
  versus:start(1, 0x4000)
  versus:resume()
  check_equal("a trainer is loaded by class", asked_for and asked_for.class, 12)
  check_equal("and by id", asked_for and asked_for.id, 3)

  -- Loading and then not fighting must not leave the combatant lying around.
  local nothing = vm.new(battle_host, {
    [1] = {
      [0x4000] = { op = "startbattle", opcode = 0x5F, size = 1, args = {} },
      [0x4001] = { op = "end", opcode = 0x91, size = 1, args = {}, ends = true },
    },
  })
  nothing:start(1, 0x4000)
  check_equal("starting a battle with nothing loaded stops the script",
    nothing:resume(), "unsupported")

  -- A host that cannot fight is told so rather than the script pretending.
  local unable = vm.new({}, battle_code("loadwildmon", { 155, 20 }))
  unable:start(1, 0x4000)
  check_equal("and so does a host that cannot start one", unable:resume(),
    "unsupported")

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

--- Every locator, against a cartridge that is not Gold, Silver or Crystal.
--
-- The README claims a dump that would decode into nonsense fails loudly. The
-- importer does refuse a Gen 1 cartridge, but on the title string, which is the
-- weakest check here and says nothing about the searches. This runs the
-- searches themselves, with the version gate out of the way.
--
-- A Gen 1 cartridge is the right adversary rather than random noise: it carries
-- species names in nearly the same encoding, padded to the same ten bytes, and
-- tables of its own for moves, items and base stats. It is exactly what would
-- decode into plausible garbage if validation were only as strong as signature.
-- Three of the six named tables do have their signature occur in it.
local function test_foreign(path)
  log("\n== a cartridge that is not Gen 2 ==")
  if not path then
    log("  SKIP  no second cartridge given; pass one as the third argument")
    return
  end

  local other, why = Rom.load(path)
  if not check("the other cartridge loads", other ~= nil, why) then
    return
  end

  local info = header.parse(other)
  log("        %q, %d banks", info and info.title or "?", other.banks)

  local names = {}
  for key in pairs(locate.descriptors) do
    names[#names + 1] = key
  end
  table.sort(names)

  local matched_signature = 0
  for _, key in ipairs(names) do
    local result, reason = locate.table(locate.descriptors[key], other)
    check(("%s is refused"):format(key), result == nil,
      result and ("accepted at 0x%06X"):format(result.offset))
    if reason and not tostring(reason):match("no candidate offset") then
      matched_signature = matched_signature + 1
    end
  end

  -- The interesting half. A signature that never occurs proves nothing about
  -- the validation; a signature that *does* occur and is then thrown out is the
  -- whole claim being tested.
  log("        %d of %d signatures occur in it and were caught by validation",
    matched_signature, #names)
  check("some signatures do occur, so validation is doing the work",
    matched_signature > 0)

  -- The searches with shapes of their own. Two are not reachable at all,
  -- because the tables they depend on did not locate, and that is part of the
  -- answer rather than something to route around.
  local standalone = {
    { "pokedex", function() return require("src.rom.dex").locate(other) end },
    { "music", function() return require("src.rom.music").locate(other) end },
    { "tilesets", function() return tilesets.locate(other) end },
    { "ow sprites",
      function() return require("src.rom.ow_sprites").locate(other) end },
    { "grass", function() return encounters.locate_grass(other) end },
    { "water", function() return encounters.locate_water(other) end },
    { "trainers", function() return trainers.locate(other) end },
    { "std scripts",
      function() return require("src.rom.std_scripts").locate(other) end },
    { "palettes", function() return palettes.locate(other) end },
    -- Refuses because the item names it needs do not locate here, which is the
    -- pipeline stopping early rather than a search of its own failing.
    { "cures", function()
        local other_names = locate.table(locate.descriptors.item_names, other)
        return require("src.rom.cures").locate(other,
          other_names and other_names.records)
      end },
  }

  for _, entry in ipairs(standalone) do
    local ok, result = pcall(entry[2])
    check(("%s is refused"):format(entry[1]), ok and result == nil,
      ok and "it accepted something" or "it crashed instead of refusing")
  end

  other:release()
end

-- @param other_rom optional second cartridge, used to check that the searches
--        refuse a dump they were never meant to read
function harness.run(rom_path, report_path, other_rom)
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
    test_experience(rom, found and found.base_stats and found.base_stats.records)
    test_fainting(found and found.base_stats and found.base_stats.records)
    test_clock()
    test_storage(found and found.base_stats and found.base_stats.records)
    test_cures(rom,
      found and found.item_names and found.item_names.records,
      found and found.item_attributes and found.item_attributes.records,
      found and found.base_stats and found.base_stats.records)
    test_dex(rom, found and found.species_names and found.species_names.records)
    test_dex_tracking(found and found.base_stats and found.base_stats.records)
    test_obstacles(rom, map_result)
    test_whirlpool(rom, tileset_result, map_result)
    test_machines(rom,
      found and found.move_names and found.move_names.records,
      found and found.base_stats and found.base_stats.records)
    test_battle_menu(found and found.base_stats and found.base_stats.records,
      found and found.item_attributes and found.item_attributes.records,
      found and found.item_names and found.item_names.records)
    test_sav(found and found.base_stats and found.base_stats.records)
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

  -- Needs no cartridge, so it runs whether or not one loaded.
  test_apu()

  test_foreign(other_rom)

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
