-- Finding the Gen 2 data tables inside a cartridge image.
--
-- Most tools in this space hardcode a table of offsets per game and per
-- revision. That works right up until someone hands you a dump you did not
-- anticipate, at which point it decodes plausible-looking nonsense rather than
-- failing. We search for each table instead.
--
-- The search works because the first record of every table is known content:
-- species 1 is always Bulbasaur, move 1 is always Pound. Encoding that first
-- record gives a signature long enough to be unique in two megabytes, and once
-- a candidate matches we validate it by decoding the whole table and checking
-- records we did not search for. A table is only accepted if every one of its
-- records is well formed and the spot checks land.

local structs = require("src.rom.structs")
local text = require("src.rom.text")
local items = require("src.rom.items")

local locate = {}

--- Encode an uppercase ASCII name into the Gen 2 character set, padded with the
-- terminator to `width` bytes. Mirrors how the name tables are stored.
local function encode_name(name, width)
  local out = {}
  for i = 1, #name do
    local c = name:sub(i, i)
    if c == " " then
      out[#out + 1] = string.char(0x7F)
    else
      local byte_value = c:byte() - ("A"):byte() + 0x80
      out[#out + 1] = string.char(byte_value)
    end
  end
  while #out < width do
    out[#out + 1] = string.char(text.TERMINATOR)
  end
  return table.concat(out)
end

--- Every offset at which `needle` occurs in `haystack`, as 0-based positions.
-- Uses a plain (non-pattern) find so arbitrary bytes are safe.
local function find_all(haystack, needle)
  local hits = {}
  local from = 1
  while true do
    local start = haystack:find(needle, from, true)
    if not start then
      break
    end
    hits[#hits + 1] = start - 1
    from = start + 1
  end
  return hits
end

--------------------------------------------------------------------------------
-- Table descriptors
--------------------------------------------------------------------------------
--
-- Each descriptor supplies a signature for the first record, a per-record
-- validator, and spot checks that must hold once the table is decoded. The spot
-- checks are the important part: a signature can collide, a fully decoded table
-- that also names Mew at index 151 cannot.

local function name_table_descriptor(opts)
  return {
    name = opts.name,
    count = opts.count,
    record_size = opts.width,
    signature = encode_name(opts.first, opts.width),
    validate_record = function(data, offset)
      return text.is_plausible_name(data, offset, opts.width)
    end,
    decode_record = function(data, offset)
      return text.decode(data, offset, opts.width)
    end,
    spot_checks = opts.spot_checks,
  }
end

locate.descriptors = {
  species_names = name_table_descriptor {
    name = "species_names",
    count = structs.SPECIES_COUNT,
    width = structs.SPECIES_NAME_LENGTH,
    first = "BULBASAUR",
    -- One from each generation's block plus both endpoints of Johto's range.
    spot_checks = {
      [2] = "IVYSAUR",
      [25] = "PIKACHU",
      [151] = "MEW",
      [152] = "CHIKORITA",
      [251] = "CELEBI",
    },
  },

  -- Move names are packed rather than padded: each is only as long as it needs
  -- to be, separated by the terminator. Species names are the exception, not
  -- the rule, so the locator supports both shapes.
  move_names = {
    name = "move_names",
    count = structs.MOVE_COUNT,
    variable_length = true,
    max_record_size = structs.MOVE_NAME_MAX,
    signature = encode_name("POUND", 5) .. string.char(text.TERMINATOR),
    validate_record = function(data, offset)
      return text.is_plausible_terminated(data, offset, structs.MOVE_NAME_MAX)
    end,
    decode_record = function(data, offset)
      return text.decode_terminated(data, offset, structs.MOVE_NAME_MAX)
    end,
    spot_checks = {
      [2] = "KARATE CHOP",
      [165] = "STRUGGLE",
      [251] = "BEAT UP",
    },
  },

  -- Item names carry substitution codes: item 5 is stored as $54 then " BALL",
  -- the $54 being the one glyph that reads POKe. A validator that only accepts
  -- charmap bytes rejects the table at its fifth record.
  item_names = {
    name = "item_names",
    count = items.COUNT,
    variable_length = true,
    max_record_size = items.NAME_MAX,
    signature = encode_name("MASTER BALL", 11) .. string.char(text.TERMINATOR),
    validate_record = function(data, offset)
      return text.is_plausible_terminated(data, offset, items.NAME_MAX, true)
    end,
    decode_record = function(data, offset)
      return text.decode_terminated(data, offset, items.NAME_MAX, true)
    end,
    spot_checks = {
      [5] = "POKé BALL",
      [18] = "POTION",
      [191] = "TM01",
      [249] = "HM07",
    },
  },

  -- The attributes have no text to anchor to, so the signature is the Master
  -- Ball's own record: free, no held effect, no parameter, cannot be
  -- registered, ball pocket, usable only in battle. The prices are what
  -- confirm it, and they are held back from the signature so they are evidence
  -- rather than part of the fit -- a stride-7 search on four known prices
  -- matched this offset and nothing else, at any stride from 5 to 10.
  item_attributes = {
    name = "item_attributes",
    count = items.COUNT,
    record_size = items.RECORD_SIZE,
    signature = string.char(0x00, 0x00, 0x00, 0x00, 0x40, 0x03, 0x06),
    validate_record = items.plausible,
    decode_record = items.decode,
    spot_checks = {
      [5] = function(record)
        -- POKe BALL: 200, ball pocket, thrown in battle and useless outside.
        return record.price == 200 and record.pocket == "balls"
          and record.battle_use == "ball" and record.field_use == "none"
      end,
      [18] = function(record)
        -- POTION: 300, restores 20 HP, usable in the field and in battle.
        return record.price == 300 and record.parameter == 20
          and record.field_use == "heal" and record.battle_use == "heal"
      end,
      [32] = function(record)
        -- RARE CANDY: 4800 and not a ball.
        return record.price == 4800 and record.pocket == "items"
      end,
      [7] = function(record)
        -- BICYCLE: the registerable key item. It is the one that shows the
        -- property bits are not all the same value.
        return record.pocket == "key" and record.selectable
          and not record.tossable
      end,
      [243] = function(record)
        -- HM01 cannot be tossed or registered, and lives with the machines.
        return record.pocket == "machines" and not record.tossable
          and not record.selectable
      end,
    },
  },

  base_stats = {
    name = "base_stats",
    count = structs.SPECIES_COUNT,
    record_size = structs.BASE_STATS_SIZE,
    -- Bulbasaur: dex 1, 45/49/49/45/65/65, Grass/Poison, catch rate 45,
    -- base experience 64. Eleven bytes of known content.
    signature = string.char(
      0x01, 45, 49, 49, 45, 65, 65, 0x16, 0x03, 45, 64
    ),
    validate_record = structs.base_stats_plausible,
    decode_record = structs.decode_base_stats,
    spot_checks = {
      -- Checked against the decoded record rather than a string.
      [151] = function(record)
        -- Mew: 100 across the board, pure Psychic.
        return record.hp == 100 and record.attack == 100
          and record.type_1 == "psychic" and record.type_2 == "psychic"
      end,
      [251] = function(record)
        -- Celebi: 100 across the board, Psychic/Grass.
        return record.hp == 100 and record.type_1 == "psychic"
          and record.type_2 == "grass"
      end,
    },
  },

  moves = {
    name = "moves",
    count = structs.MOVE_COUNT,
    record_size = structs.MOVE_SIZE,
    -- Pound: animation 1, no effect, 40 power, Normal, 255/255 accuracy,
    -- 35 PP, no secondary effect chance.
    signature = string.char(0x01, 0x00, 40, 0x00, 255, 35, 0x00),
    validate_record = structs.move_plausible,
    decode_record = structs.decode_move,
    spot_checks = {
      [165] = function(record)
        -- Struggle: 50 power, Normal, 1 PP.
        return record.power == 50 and record.type == "normal" and record.pp == 1
      end,
    },
  },
}

--------------------------------------------------------------------------------

--- Decode a whole table at `offset`, rejecting it if any record fails.
-- @return array of decoded records, or nil plus the reason it was rejected.
local function try_table(descriptor, data, offset)
  if not descriptor.variable_length then
    local size = descriptor.count * descriptor.record_size
    if offset + size > #data then
      return nil, "table would run past the end of the ROM"
    end
  end

  local records = {}
  local cursor = offset

  for i = 1, descriptor.count do
    if cursor >= #data then
      return nil, ("record %d starts past the end of the ROM"):format(i)
    end

    local ok, consumed = descriptor.validate_record(data, cursor)
    if not ok then
      return nil, ("record %d is malformed"):format(i)
    end

    records[i] = descriptor.decode_record(data, cursor)

    -- Fixed-width tables advance by a constant stride; packed tables advance by
    -- however much the record just consumed.
    if descriptor.variable_length then
      cursor = cursor + consumed
    else
      cursor = cursor + descriptor.record_size
    end
  end

  for index, expected in pairs(descriptor.spot_checks or {}) do
    local actual = records[index]
    if type(expected) == "function" then
      if not expected(actual) then
        return nil, ("spot check on record %d failed"):format(index)
      end
    elseif actual ~= expected then
      return nil, ("record %d decoded as %q, expected %q")
        :format(index, tostring(actual), expected)
    end
  end

  return records
end

--- Locate a single table.
-- @return { offset = n, records = {...} } or nil plus a diagnostic
function locate.table(descriptor, rom)
  local candidates = find_all(rom.data, descriptor.signature)

  if #candidates == 0 then
    return nil, ("no candidate offset found for %s; the signature for its " ..
      "first record does not occur in this ROM"):format(descriptor.name)
  end

  local rejections = {}
  local accepted = {}

  for _, offset in ipairs(candidates) do
    local records, why = try_table(descriptor, rom.data, offset)
    if records then
      accepted[#accepted + 1] = { offset = offset, records = records }
    else
      rejections[#rejections + 1] = ("  0x%06X: %s"):format(offset, why)
    end
  end

  if #accepted == 0 then
    return nil, ("found %d candidate offset(s) for %s but none validated:\n%s")
      :format(#candidates, descriptor.name, table.concat(rejections, "\n"))
  end

  if #accepted > 1 then
    -- Ambiguity means the validation is too weak to trust, not that we should
    -- guess. Surface it rather than picking the first.
    local offsets = {}
    for _, hit in ipairs(accepted) do
      offsets[#offsets + 1] = ("0x%06X"):format(hit.offset)
    end
    return nil, ("%s validated at %d different offsets (%s); refusing to guess")
      :format(descriptor.name, #accepted, table.concat(offsets, ", "))
  end

  return accepted[1]
end

--- Locate every known table. Returns a results map plus a list of failures, so
-- a partial import can still report what it did find.
function locate.all(rom, progress)
  local found, failed = {}, {}

  for key, descriptor in pairs(locate.descriptors) do
    if progress then
      progress(("locating %s"):format(key))
    end
    local result, why = locate.table(descriptor, rom)
    if result then
      found[key] = result
    else
      failed[key] = why
    end
  end

  return found, failed
end

return locate
