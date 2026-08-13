-- Diagnostic: does the channel command table hold up against the cartridge?
--
-- The widths in `src/rom/music_ops.lua` are read from the pokecrystal audio
-- macros, the same way the script opcode widths were. Borrowing a number is
-- only allowed here if the number is then checked, and there is a sharp check
-- available: channel data is contiguous, so a walk through a channel must land
-- **exactly** on where the next channel begins, and there are 256 boundaries to
-- agree at once.
--
-- The measure is worthless when a search is choosing the widths — width zero is
-- admissible, so a table of all zeros lands on every boundary — and it is
-- decisive when the widths come from somewhere else, because a fixed table
-- cannot bend itself to fit. That is the entire argument for this route.
--
-- Two commands take a drum-kit byte or nothing depending on how they are
-- written. Those are left as unknowns and settled here, one at a time, the way
-- the script widths were: try each width, and see which one the boundaries
-- agree with.
--
--   love . --probe-musicops <rom> <report>

local Rom = require("src.rom.rom")
local music = require("src.rom.music")
local music_ops = require("src.rom.music_ops")

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

--- Every channel with a known end, and which channel number it is.
local function extents_of(rom, located)
  local extents = {}
  for _, song in ipairs(located.songs) do
    if not song.unparsed then
      for index = 1, song.count - 1 do
        local from = song.bank * 0x4000 + (song.channels[index] - 0x4000)
        local to = song.bank * 0x4000 + (song.channels[index + 1] - 0x4000)
        if to > from and to - from < 4096 then
          extents[#extents + 1] = { from = from, to = to, channel = index }
        end
      end
    end
  end
  return extents
end

--- Score a width table against every boundary.
local function score(rom, extents, unknowns)
  local landed, overran, short, blocked = 0, 0, 0, 0
  local blockers = {}
  for _, extent in ipairs(extents) do
    local walk = music_ops.walk(rom, extent.from, extent.to, extent.channel,
      unknowns)
    if walk.unknown then
      blocked = blocked + 1
      blockers[walk.unknown] = (blockers[walk.unknown] or 0) + 1
    elseif walk.landed then
      landed = landed + 1
    elseif walk.overran then
      overran = overran + 1
    else
      short = short + 1
    end
  end
  return landed, overran, short, blocked, blockers
end

function probe.run(rom_path, report_path)
  report = {}

  local rom, err = Rom.load(rom_path)
  if not rom then
    log("FATAL: %s", err)
    write(report_path)
    return true
  end

  local located, why = music.locate(rom)
  if not located then
    log("FATAL: %s", tostring(why))
    rom:release()
    write(report_path)
    return true
  end

  local extents = extents_of(rom, located)
  log("== %d channel boundaries to agree with ==", #extents)

  -- Which commands the corpus actually contains. Everything below turns on
  -- this: a width can only be tested against the cartridge if the cartridge
  -- uses it.
  local settled = { [music_ops.TOGGLE_NOISE] = 0,
                    [music_ops.SFX_TOGGLE_NOISE] = 0 }
  local counts = {}
  for _, extent in ipairs(extents) do
    local walk = music_ops.walk(rom, extent.from, extent.to, extent.channel,
      settled)
    for opcode, times in pairs(walk.counts or {}) do
      counts[opcode] = (counts[opcode] or 0) + times
    end
  end

  log("\n== the two commands the macros leave open ==")
  for _, opcode in ipairs({ music_ops.TOGGLE_NOISE,
                            music_ops.SFX_TOGGLE_NOISE }) do
    if counts[opcode] then
      log("  $%02X (%s) occurs %d times, so the boundaries can settle it",
        opcode, music_ops.name(opcode), counts[opcode])
      for width = 0, 1 do
        local trial = { [opcode] = width }
        for key, value in pairs(settled) do
          if key ~= opcode then trial[key] = value end
        end
        local landed = score(rom, extents, trial)
        log("    width %d: %d of %d land", width, landed, #extents)
      end
    else
      -- Not settled, and saying so matters. Both widths score identically
      -- because neither is ever exercised, and reading that as "the answer is
      -- zero" would be inventing a fact out of an absence of evidence.
      log("  $%02X (%s) never occurs in any channel, so the boundaries cannot",
        opcode, music_ops.name(opcode))
      log("    settle it either way. It stays unknown.")
    end
  end

  log("\n== the table as it now stands ==")
  local landed, overran, short, blocked, blockers = score(rom, extents, settled)
  log("  land exactly on the boundary : %d of %d (%.1f%%)", landed, #extents,
    landed / #extents * 100)
  log("  overrun                      : %d", overran)
  log("  fall short                   : %d", short)
  log("  stop on an unknown opcode    : %d", blocked)
  for opcode, times in pairs(blockers) do
    log("    $%02X x%d", opcode, times)
  end

  -- What would a wrong answer have scored?
  --
  -- 256 of 256 is worth nothing on its own, and the degenerate table proves it:
  -- with every command zero bytes wide the walk steps one byte at a time and
  -- therefore lands on *any* endpoint it is given. It scores 256 too. Landing
  -- is only evidence for a table that could have missed.
  log("\n== what a table that says nothing scores ==")
  local zeros = {}
  for opcode = 0xD0, 0xFF do
    zeros[opcode] = 0
  end
  local zero_landed = score(rom, extents, zeros)
  log("  every command zero bytes wide: %d of %d land exactly", zero_landed,
    #extents)

  -- The measure that is not degenerate: do the addresses inside the stream
  -- resolve?
  --
  -- `sound_call`, `sound_loop` and `sound_jump` each carry a two-byte address.
  -- Read at the right offset it is a pointer into the switchable bank window,
  -- $4000 to $7FFF, and it lands on a byte that the walk also reached as the
  -- start of an instruction. Read one byte out it is arbitrary data, and
  -- arbitrary data is in the window a quarter of the time and on a boundary
  -- less often than that.
  --
  -- This is the lever the rest of the project runs on -- a pointer that has to
  -- resolve -- and it is what the extent measure never was: a wrong answer
  -- cannot quietly re-synchronise its way out of it.
  local function resolve(overrides)
    local in_window, on_boundary, total, ended_on_terminator, walked = 0, 0, 0, 0, 0
    -- Instruction starts across every channel of every song, as flat offsets.
    local starts = {}
    local pending = {}
    for _, extent in ipairs(extents) do
      local walk = music_ops.walk(rom, extent.from, extent.to, extent.channel,
        overrides)
      walked = walked + 1
      if walk.last and music_ops.terminators[walk.last] then
        ended_on_terminator = ended_on_terminator + 1
      end
      for offset in pairs(walk.starts or {}) do
        starts[offset] = true
      end
      local bank = math.floor(extent.from / 0x4000)
      for _, address in ipairs(walk.targets or {}) do
        pending[#pending + 1] = { address = address, bank = bank }
      end
    end
    for _, target in ipairs(pending) do
      total = total + 1
      if target.address >= 0x4000 and target.address <= 0x7FFF then
        in_window = in_window + 1
        local flat = target.bank * 0x4000 + (target.address - 0x4000)
        if starts[flat] then
          on_boundary = on_boundary + 1
        end
      end
    end
    return in_window, on_boundary, total, ended_on_terminator, walked
  end

  log("\n== do the addresses inside the stream resolve? ==")
  local in_window, on_boundary, total, terminated, walked = resolve(settled)
  log("  control-transfer commands decoded : %d", total)
  log("  address in the $4000-$7FFF window : %d (%.1f%%)", in_window,
    in_window / math.max(total, 1) * 100)
  log("  address on an instruction boundary: %d (%.1f%%)", on_boundary,
    on_boundary / math.max(total, 1) * 100)
  log("  channels ending on a terminator   : %d of %d", terminated, walked)

  -- So the real question is whether the cartridge *pins* each number. Change
  -- one width by one and see what breaks -- and score it on the measure that
  -- can actually break, not on the one that cannot.
  -- Scored as a *rate*, not a count. A desynchronised walk decodes more
  -- transfer commands than a correct one, because it reads operand bytes as
  -- opcodes, so the absolute number that happen to resolve can go *up* while
  -- the parse gets worse. Comparing counts made every width look unfalsifiable;
  -- the fraction is the honest measure.
  log("\n== is each borrowed width pinned by the cartridge? ==")
  log("  addresses resolving when the width is changed by one, each way:")
  log("  command             uses | one narrower  | one wider      | wider caught")
  local occurring, pinned = 0, 0
  local order = {}
  for opcode in pairs(counts) do
    if opcode >= music_ops.FIRST_COMMAND then
      order[#order + 1] = opcode
    end
  end
  table.sort(order, function(a, b) return counts[a] > counts[b] end)

  for _, opcode in ipairs(order) do
    local base = music_ops.width(opcode, 1, settled)
    if base ~= nil then
      occurring = occurring + 1
      -- The two directions are reported apart, because they turn out to say
      -- completely different things and averaging or maximising over them hides
      -- the whole result.
      local shown = {}
      local rates = {}
      for _, delta in ipairs({ -1, 1 }) do
        local width = base + delta
        if width < 0 then
          shown[delta] = "n/a"
        else
          local trial = { [opcode] = width }
          for key, value in pairs(settled) do
            if key ~= opcode then trial[key] = value end
          end
          local _, resolved, count = resolve(trial)
          rates[delta] = count > 0 and resolved / count or 0
          shown[delta] = ("%d/%d"):format(resolved, count)
        end
      end

      -- Too large is detectable; too small is the open question.
      local caught_bigger = (rates[1] or 0) < 0.999
      if caught_bigger then
        pinned = pinned + 1
      end
      log("  %-18s%5d | %14s | %14s | %s", music_ops.name(opcode),
        counts[opcode], shown[-1], shown[1],
        caught_bigger and "yes" or "no")
    end
  end
  log("  a width one too large is caught for %d of %d commands that occur",
    pinned, occurring)
  log("")
  log("  A width one too *small* is caught for almost none, and the reason is")
  log("  structural rather than a shortage of evidence. Drop a width by one and")
  log("  the operand byte is read as an opcode instead of being stepped over --")
  log("  and operand bytes are nearly always below $D0, which is a note, which")
  log("  is one byte wide. Skipping the byte and executing it as a note cost")
  log("  the walk exactly the same distance, so every position-based measure")
  log("  sees an identical parse. The cartridge bounds each width from above")
  log("  and says nothing at all from below.")

  -- Where it goes wrong, if it does.
  if overran + short + blocked > 0 then
    log("\n== the first few that do not land ==")
    local shown = 0
    for _, extent in ipairs(extents) do
      if shown < 8 then
        local walk = music_ops.walk(rom, extent.from, extent.to,
          extent.channel, settled)
        if not walk.landed then
          shown = shown + 1
          log("  0x%06X..0x%06X (channel %d): %s", extent.from, extent.to,
            extent.channel,
            walk.unknown and ("stopped on $%02X"):format(walk.unknown)
              or ("ended at 0x%06X, %d bytes %s"):format(walk.at,
                math.abs(walk.at - extent.to),
                walk.at > extent.to and "over" or "short"))
          local bytes = {}
          for offset = extent.from, math.min(extent.from + 23, extent.to - 1) do
            bytes[#bytes + 1] = ("%02X"):format(rom:u8(offset))
          end
          log("    opens: %s", table.concat(bytes, " "))
        end
      end
    end
  end

  -- And what is left untested, which is the honest other half of the result.
  local unused = {}
  for opcode = 0xD0, 0xFF do
    if not counts[opcode] then
      unused[#unused + 1] = music_ops.name(opcode)
    end
  end
  log("\n== what the cartridge never exercises ==")
  log("  %d of the 48 commands never appear in any channel, so their widths",
    #unused)
  log("  are borrowed and untested here:")
  local line = {}
  for _, name in ipairs(unused) do
    line[#line + 1] = name
    if #line == 5 then
      log("    %s", table.concat(line, ", "))
      line = {}
    end
  end
  if #line > 0 then
    log("    %s", table.concat(line, ", "))
  end

  rom:release()
  write(report_path)
  return true
end

return probe
