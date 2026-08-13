-- Diagnostic: what is the channel command language?
--
-- The music table gives channel boundaries: within a song, channel 1's data
-- runs up to where channel 2 starts. That is the same lever the script opcode
-- table was validated with -- a walk must land exactly on the boundary, never
-- over it and never short -- and it is strong enough to infer operand widths
-- rather than assume them.
--
-- The earlier attempt at inferring script widths failed because it marked every
-- command it learned as terminating, so a walk that stopped at the first
-- instruction could never overrun and the score was meaningless. Here nothing
-- is assumed to terminate, so overrunning is possible and the number means
-- something.
--
--   love . --probe-channels <rom> <report>

local Rom = require("src.rom.rom")
local music = require("src.rom.music")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

-- Bytes below this are taken to be notes: pitch in the high nibble, length in
-- the low one. Whether that is right is measured below, not assumed.
probe.FIRST_COMMAND = 0xD0

function probe.run(rom_path, report_path)
  report = {}

  local rom, err = Rom.load(rom_path)
  if not rom then
    log("FATAL: %s", err)
    local fh = io.open(report_path, "w")
    if fh then fh:write(table.concat(report, "\n") .. "\n") fh:close() end
    return true
  end

  local located, why = music.locate(rom)
  if not located then
    log("FATAL: %s", tostring(why))
    local fh = io.open(report_path, "w")
    if fh then fh:write(table.concat(report, "\n") .. "\n") fh:close() end
    return true
  end

  -- Extents: a channel's data runs to where the next channel of the same song
  -- begins. The last channel of each song has no known end, so it is left out.
  local extents = {}
  for _, song in ipairs(located.songs) do
    -- Slots that do not decode are kept in the table so the indices after them
    -- stay put; they carry no channels to measure.
    for index = 1, (song.unparsed and 0 or song.count) - 1 do
      local from = song.bank * 0x4000 + (song.channels[index] - 0x4000)
      local to = song.bank * 0x4000 + (song.channels[index + 1] - 0x4000)
      if to > from and to - from < 4096 then
        extents[#extents + 1] = { from = from, to = to }
      end
    end
  end
  log("%d channel extents with a known end", #extents)

  -- What the bytes look like.
  local notes, commands, total = 0, {}, 0
  for _, extent in ipairs(extents) do
    for at = extent.from, extent.to - 1 do
      local value = rom:u8(at)
      total = total + 1
      if value < probe.FIRST_COMMAND then
        notes = notes + 1
      else
        commands[value] = (commands[value] or 0) + 1
      end
    end
  end
  log("%d bytes in all; %d below $D0 (%d%%)", total, notes,
    math.floor(notes / math.max(total, 1) * 100))

  local ranked = {}
  for value, count in pairs(commands) do
    ranked[#ranked + 1] = { value = value, count = count }
  end
  table.sort(ranked, function(a, b) return a.count > b.count end)
  log("\n%d distinct bytes at $D0 or above, commonest first:", #ranked)
  local line = {}
  for i = 1, #ranked do
    line[#line + 1] = ("$%02X x%d"):format(ranked[i].value, ranked[i].count)
    if #line == 6 then
      log("  %s", table.concat(line, "  "))
      line = {}
    end
  end
  if #line > 0 then
    log("  %s", table.concat(line, "  "))
  end

  --- Walk one extent with a candidate width table.
  -- @return "exact", "over", "short", or "unknown"
  local function walk(extent, widths)
    local at = extent.from
    while at < extent.to do
      local value = rom:u8(at)
      local width = value < probe.FIRST_COMMAND and 0 or widths[value]
      if width == nil then
        return "unknown", at
      end
      at = at + 1 + width
    end
    return at == extent.to and "exact" or "over"
  end

  -- Anchors: what a channel starts and ends with. A terminator that repeats is
  -- a command of no operands, and it is the one thing that can be read off
  -- without solving anything.
  local first_byte, last_byte = {}, {}
  for _, extent in ipairs(extents) do
    local head = rom:u8(extent.from)
    local tail = rom:u8(extent.to - 1)
    first_byte[head] = (first_byte[head] or 0) + 1
    last_byte[tail] = (last_byte[tail] or 0) + 1
  end
  local function top(counts, label)
    local order = {}
    for value, count in pairs(counts) do
      order[#order + 1] = { value = value, count = count }
    end
    table.sort(order, function(a, b) return a.count > b.count end)
    local parts = {}
    for i = 1, math.min(#order, 6) do
      parts[#parts + 1] = ("$%02X x%d"):format(order[i].value, order[i].count)
    end
    log("%s: %d distinct -- %s", label, #order, table.concat(parts, ", "))
  end
  log("")
  top(first_byte, "channels start with")
  top(last_byte, "channels end with")

  -- Nothing is known here, so there is nothing to propagate from: an extent
  -- with two different unknown commands constrains neither. Instead, search.
  -- Every command starts at width 0 and widths are changed one at a time,
  -- keeping whatever raises the number of extents that land exactly on their
  -- boundary. Landing exactly is a strong measure -- a walk can overrun or stop
  -- short, and 148 of them have to agree at once.
  -- Landing exactly is not enough on its own, and that is the whole lesson
  -- here: with every width at zero a walk consumes one byte at a time and
  -- always lands on the boundary, so all 148 agree and the measure says
  -- nothing. It is the same vacuous metric that got the script widths wrong
  -- once already.
  --
  -- $FF is what 89 of the 148 channels end on, so under a correct parse it
  -- should be reached as a command only at the very end. Every $FF met earlier
  -- is a byte that ought to have been swallowed as somebody's operand, and
  -- counting those gives the search something it cannot satisfy by doing
  -- nothing.
  local function walk_scored(extent, widths)
    local at = extent.from
    local stray = 0
    while at < extent.to do
      local value = rom:u8(at)
      if value == 0xFF and at + 1 < extent.to then
        stray = stray + 1
      end
      local width = value < probe.FIRST_COMMAND and 0 or widths[value]
      if width == nil then
        return false, stray
      end
      at = at + 1 + width
    end
    return at == extent.to, stray
  end

  local function score_of(widths)
    local points = 0
    for _, extent in ipairs(extents) do
      local exact, stray = walk_scored(extent, widths)
      if exact then
        points = points + 10
      end
      points = points - stray
    end
    return points
  end

  local function climb(seed)
    local widths = {}
    for _, entry in ipairs(ranked) do
      widths[entry.value] = seed and math.random(0, 3) or 0
    end

    local best = score_of(widths)
    local improved = true
    local passes = 0
    while improved and passes < 30 do
      improved = false
      passes = passes + 1
      for _, entry in ipairs(ranked) do
        local was = widths[entry.value]
        for candidate = 0, 3 do
          if candidate ~= was then
            widths[entry.value] = candidate
            local now = score_of(widths)
            if now > best then
              best, was, improved = now, candidate, true
            else
              widths[entry.value] = was
            end
          end
        end
      end
    end
    return widths, best
  end

  -- One run from all-zero, then several from random starts. If they are all
  -- finding the same language they will agree; if the search is fitting noise
  -- they will not. That check is the point of doing it more than once.
  local widths, best = climb(false)
  local function summarise(table_of_widths)
    local exact, stray = 0, 0
    for _, extent in ipairs(extents) do
      local landed, strays = walk_scored(extent, table_of_widths)
      if landed then exact = exact + 1 end
      stray = stray + strays
    end
    return exact, stray
  end
  local exact_zero, stray_zero = summarise(widths)
  log("\nsearch from zero: score %d, %d of %d land exactly, %d stray $FF",
    best, exact_zero, #extents, stray_zero)

  local agreements = 0
  for attempt = 1, 4 do
    math.randomseed(attempt * 7919)
    local other, other_best = climb(true)
    local same = true
    for _, entry in ipairs(ranked) do
      if other[entry.value] ~= widths[entry.value] then
        same = false
        break
      end
    end
    if same then
      agreements = agreements + 1
    end
    local other_exact, other_stray = summarise(other)
    log("  restart %d: score %d, %d land exactly, %d stray $FF, %s", attempt,
      other_best, other_exact, other_stray,
      same and "same widths" or "DIFFERENT widths")
  end
  log("  %d of 4 restarts agree with the run from zero", agreements)

  local score = { exact = 0, over = 0, unknown = 0 }
  for _, extent in ipairs(extents) do
    local result = walk(extent, widths)
    score[result] = score[result] + 1
  end
  log("\n  %d extents land exactly, %d overrun, %d hit an unknown command",
    score.exact, score.over, score.unknown)

  local listed = {}
  for value, width in pairs(widths) do
    listed[#listed + 1] = { value = value, width = width }
  end
  table.sort(listed, function(a, b) return a.value < b.value end)
  line = {}
  for _, entry in ipairs(listed) do
    line[#line + 1] = ("$%02X:%d"):format(entry.value, entry.width)
    if #line == 10 then
      log("  %s", table.concat(line, " "))
      line = {}
    end
  end
  if #line > 0 then
    log("  %s", table.concat(line, " "))
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
