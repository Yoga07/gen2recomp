-- Diagnostic: what do the locators do when handed a cartridge that is not
-- Gold, Silver or Crystal?
--
-- The README claims that "a dump that would have decoded into nonsense fails
-- loudly". The importer does refuse a Gen 1 cartridge, but it refuses on the
-- title string, which is the weakest check in the whole project and proves
-- nothing about the searches. This runs every locator directly against whatever
-- ROM it is given, with the version gate out of the way, and reports what each
-- one does and which layer of the defence stopped it.
--
-- A Gen 1 cartridge is the interesting adversary rather than random noise. It
-- carries species names in nearly the same character encoding, padded to the
-- same ten bytes, and base stats and item names in tables of its own. It is
-- exactly the kind of dump that would decode into plausible garbage if the
-- validation were only as strong as the signature.
--
--   love . --probe-foreign <rom> <report>

local Rom = require("src.rom.rom")
local header = require("src.rom.header")
local locate = require("src.rom.locate")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

local function write(path)
  local fh = io.open(path, "w")
  if fh then
    fh:write(table.concat(report, "\n") .. "\n")
    fh:close()
  end
end

--- Which layer of the defence turned a candidate away.
--
-- The point of the report is not that a locator failed but *where*. A signature
-- that never occurs says the table is simply not there; a signature that occurs
-- and then fails validation says the search found something that looked right
-- and the checking caught it, which is the case worth knowing about.
local function classify(why)
  if not why then
    return "accepted"
  end
  if why:match("no candidate offset") then
    return "signature absent"
  end
  if why:match("spot check") then
    return "spot check refused it"
  end
  if why:match("malformed") or why:match("decoded as") then
    return "table did not decode"
  end
  if why:match("refusing to guess") then
    return "ambiguous, refused"
  end
  return "other"
end

function probe.run(rom_path, report_path)
  report = {}

  local rom, err = Rom.load(rom_path)
  if not rom then
    log("FATAL: %s", err)
    write(report_path)
    return true
  end

  log("rom: %s", tostring(rom_path))
  log("%d bytes, %d banks", rom.size, rom.banks)

  local info = header.parse(rom)
  if info then
    log("title %q, cart type $%02X", tostring(info.title),
      info.cartridge_type or 0)
  end

  -- The named tables, which are the ones with signatures and spot checks.
  log("\n== the signature-and-spot-check tables ==")
  local names = {}
  for key in pairs(locate.descriptors) do
    names[#names + 1] = key
  end
  table.sort(names)

  local accepted = 0
  for _, key in ipairs(names) do
    local result, why = locate.table(locate.descriptors[key], rom)
    if result then
      accepted = accepted + 1
      log("  %-16s ACCEPTED at 0x%06X  <-- this should not happen",
        key, result.offset)
    else
      log("  %-16s refused: %s", key, classify(why))
      -- The first line of the reason, which names the offsets tried.
      local first = tostring(why):match("^[^\n]*")
      log("  %-16s   %s", "", first)
    end
  end

  -- The locators that do not go through the descriptor mechanism. Each has its
  -- own shape and its own refusal.
  log("\n== the tables with searches of their own ==")

  -- Two of these take an input from an earlier stage. On a foreign cartridge
  -- that input does not locate, so they are never reached at all -- which is
  -- part of the answer rather than something to work around. Calling them with
  -- a nil they never see in practice produces a crash that says nothing.
  local tileset_result = require("src.rom.tilesets").locate(rom)
  local stats_result = locate.table(locate.descriptors.base_stats, rom)

  local others = {
    { "pokedex", function() return require("src.rom.dex").locate(rom) end },
    { "music", function() return require("src.rom.music").locate(rom) end },
    { "tilesets", function() return tileset_result, "see above" end },
    { "maps", function()
        if not tileset_result then
          return nil, "not reached: the tilesets it needs did not locate"
        end
        return require("src.rom.maps").locate(rom, #tileset_result.headers)
      end },
    { "ow sprites",
      function() return require("src.rom.ow_sprites").locate(rom) end },
    { "grass",
      function() return require("src.rom.encounters").locate_grass(rom) end },
    { "water",
      function() return require("src.rom.encounters").locate_water(rom) end },
    { "trainers", function() return require("src.rom.trainers").locate(rom) end },
    { "std scripts",
      function() return require("src.rom.std_scripts").locate(rom) end },
    { "sprite pics", function()
        if not stats_result then
          return nil, "not reached: the base stats it needs did not locate"
        end
        return require("src.rom.pics").locate(rom, stats_result.records)
      end },
    { "palettes", function() return require("src.rom.palettes").locate(rom) end },
  }

  for _, entry in ipairs(others) do
    local key, run = entry[1], entry[2]
    local ok, result, why = pcall(run)
    if not ok then
      log("  %-16s crashed: %s", key, tostring(result):match("^[^\n]*"))
    elseif result then
      accepted = accepted + 1
      log("  %-16s ACCEPTED  <-- this should not happen", key)
    else
      log("  %-16s refused: %s", key,
        tostring(why):match("^[^\n]*") or "no reason given")
    end
  end

  -- The palette locator gets its own section, because it is the one that
  -- accepted something. Its shape test is "four 15-bit words, not all zero",
  -- which is weak on its own, and its hue spot checks are applied to *every*
  -- offset in a long enough run. A run of length L offers L-250 separate
  -- chances to pass those checks by luck, which is the part worth measuring.
  log("\n== how much room the palette search has to be wrong ==")
  do
    local palettes = require("src.rom.palettes")
    local bytes = require("src.util.bytes")
    local stride = palettes.RECORD_SIZE
    local wanted = palettes.SPECIES_COUNT
    local data = rom.data

    local function plausible(offset)
      if offset + stride > #data then
        return false
      end
      local any = false
      for i = 0, palettes.COLORS_PER_RECORD - 1 do
        local word = bytes.u16le(data, offset + i * 2)
        if bytes.band(word, 0x8000) ~= 0 then
          return false
        end
        if word ~= 0 then
          any = true
        end
      end
      return any
    end

    local run = {}
    for offset = rom.size - stride, 0, -1 do
      run[offset] = plausible(offset) and ((run[offset + stride] or 0) + 1) or 0
    end

    local candidates, passing, first_pass = 0, 0, nil
    for offset = 0, rom.size - stride do
      if run[offset] >= wanted then
        candidates = candidates + 1
        local ok = true
        for species, want in pairs({ [1] = "g", [4] = "r", [25] = "yellow" }) do
          local word = bytes.u16le(data, offset + (species - 1) * stride)
          if palettes.dominant(word) ~= want then
            ok = false
            break
          end
        end
        if ok then
          passing = passing + 1
          first_pass = first_pass or offset
        end
      end
    end

    log("  %d offsets hold %d consecutive colour-shaped records", candidates,
      wanted)
    log("  %d of those also match the three known hues", passing)
    if first_pass then
      log("  the first is 0x%06X, in a run of %d records", first_pass,
        run[first_pass])
    end
  end

  log("\n== summary ==")
  log("  %d locators accepted something from this cartridge", accepted)

  rom:release()
  write(report_path)
  return true
end

return probe
