-- Diagnostic: what do the special commands do, and does it matter?
--
-- `special` calls into assembly, which cannot be run from bytecode, so the
-- interpreter steps over it. That is only safe if nothing downstream depends on
-- what it returned. This measures two things: which specials are actually used,
-- and how often one is followed straight away by a branch -- because a branch
-- reading a value we never produced is a branch taken on stale history.
--
--   love . --probe-specials <rom> <report>

local Rom = require("src.rom.rom")
local tilesets = require("src.rom.tilesets")
local maps = require("src.rom.maps")
local events = require("src.rom.events")
local script_ops = require("src.rom.script_ops")
local script_decode = require("src.rom.script_decode")
local std_scripts = require("src.rom.std_scripts")
local text = require("src.rom.text")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

local SPECIAL = 0x0F
local CONDITIONALS = {
  [0x06] = "ifequal", [0x07] = "ifnotequal", [0x08] = "iffalse",
  [0x09] = "iftrue", [0x0A] = "ifgreater", [0x0B] = "ifless",
}

function probe.run(rom_path, report_path)
  report = {}

  local rom, err = Rom.load(rom_path)
  if not rom then
    log("FATAL: %s", err)
    local fh = io.open(report_path, "w")
    if fh then fh:write(table.concat(report, "\n") .. "\n") fh:close() end
    return true
  end

  local tileset_result = tilesets.locate(rom)
  local map_result = maps.locate(rom, tileset_result.count)

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

  local std_result = std_scripts.locate(rom)
  if std_result then
    for _, entry in ipairs(std_result.entries) do
      entries[#entries + 1] = { bank = entry.bank, addr = entry.addr }
    end
  end

  local code = script_decode.reachable(rom, entries)

  -- Which specials, how often, and what follows them.
  local used, followed_by, total = {}, {}, 0
  local followed_soon = 0
  local context = {}

  for bank, block in pairs(code) do
    for addr, instruction in pairs(block) do
      if instruction.opcode == SPECIAL then
        local index = (instruction.args[1] or 0)
          + (instruction.args[2] or 0) * 256
        used[index] = (used[index] or 0) + 1
        total = total + 1

        -- Look at the next few instructions for a branch.
        local at, found = addr + instruction.size, nil
        for step = 1, 3 do
          local next_instruction = block[at]
          if not next_instruction then break end
          if CONDITIONALS[next_instruction.opcode] then
            found = CONDITIONALS[next_instruction.opcode]
            if step <= 2 then
              followed_soon = followed_soon + 1
            end
            break
          end
          at = at + next_instruction.size
        end
        followed_by[found or "nothing"] =
          (followed_by[found or "nothing"] or 0) + 1

        -- Context is gathered in a second pass below, walking each bank in
        -- address order. Stepping backwards one byte at a time does not work:
        -- instructions are keyed by where they start, so addr - 1 is almost
        -- never one.
      end
    end
  end

  -- A special cannot be run, so it is identified by what is said around it.
  -- Walking a bank in address order gives each one the last thing said before
  -- it, which for the nurse is the offer to heal.
  for _, block in pairs(code) do
    local addresses = {}
    for addr in pairs(block) do
      addresses[#addresses + 1] = addr
    end
    table.sort(addresses)

    local recent = nil
    for _, addr in ipairs(addresses) do
      local instruction = block[addr]
      if instruction.text then
        recent = text.flatten({ pages = instruction.text }):sub(1, 52)
      end
      if instruction.opcode == SPECIAL and recent then
        local index = (instruction.args[1] or 0)
          + (instruction.args[2] or 0) * 256
        context[index] = context[index] or recent
      end
    end
  end

  log("%d special commands, %d distinct", total, (function()
    local n = 0
    for _ in pairs(used) do n = n + 1 end
    return n
  end)())

  local ranked = {}
  for index, count in pairs(used) do
    ranked[#ranked + 1] = { index = index, count = count }
  end
  table.sort(ranked, function(a, b) return a.count > b.count end)

  log("\nthe commonest, with any text near them:")
  for i = 1, math.min(#ranked, 25) do
    log("  %3d x%-4d %s", ranked[i].index, ranked[i].count,
      context[ranked[i].index] or "")
  end

  -- Every context each index appears in, not just the first, so an index that
  -- always turns up beside the same words can be told from one that does not.
  local all_contexts = {}
  for _, block in pairs(code) do
    local addresses = {}
    for addr in pairs(block) do addresses[#addresses + 1] = addr end
    table.sort(addresses)
    local recent = nil
    for _, addr in ipairs(addresses) do
      local instruction = block[addr]
      if instruction.text then
        recent = text.flatten({ pages = instruction.text }):sub(1, 40)
      end
      if instruction.opcode == SPECIAL and recent then
        local index = (instruction.args[1] or 0)
          + (instruction.args[2] or 0) * 256
        all_contexts[index] = all_contexts[index] or {}
        all_contexts[index][recent] = (all_contexts[index][recent] or 0) + 1
      end
    end
  end

  log("\nindices whose surroundings mention healing or a POKe CENTER:")
  for index, seen in pairs(all_contexts) do
    local hits, distinct, sample = 0, 0, nil
    for line, count in pairs(seen) do
      distinct = distinct + 1
      if line:lower():find("heal") or line:lower():find("rest")
        or line:lower():find("comfy bed") then
        hits = hits + count
        sample = sample or line
      end
    end
    if hits > 0 then
      log("  %3d  %d of its %d distinct contexts mention it: %s", index, hits,
        distinct, sample)
    end
  end

  log("\nwhat follows a special:")
  local order = {}
  for what, count in pairs(followed_by) do
    order[#order + 1] = { what = what, count = count }
  end
  table.sort(order, function(a, b) return a.count > b.count end)
  for _, entry in ipairs(order) do
    log("  %-10s %4d  (%d%%)", entry.what, entry.count,
      math.floor(entry.count / math.max(total, 1) * 100))
  end
  log("\n%d of %d are followed by a branch within two instructions (%d%%)",
    followed_soon, total, math.floor(followed_soon / math.max(total, 1) * 100))

  rom:release()

  local fh = io.open(report_path, "w")
  if fh then
    fh:write(table.concat(report, "\n") .. "\n")
    fh:close()
  end
  return true
end

return probe
