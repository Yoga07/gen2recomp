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
    rom:release()
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
