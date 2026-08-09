-- Diagnostic: how much of the script graph can actually be decoded?
--
-- The text walk stops at the first branch, deliberately, because following one
-- arm would report dialogue the player may never see. An interpreter has no
-- such excuse: it has to know every instruction it might reach. This traverses
-- the whole reachable graph from every entry point and reports what stops it.
--
--   love . --probe-vm <rom> <report>

local Rom = require("src.rom.rom")
local tilesets = require("src.rom.tilesets")
local maps = require("src.rom.maps")
local events = require("src.rom.events")
local script_ops = require("src.rom.script_ops")

local probe = {}

local report = {}
local function log(fmt, ...)
  report[#report + 1] = select("#", ...) > 0 and fmt:format(...) or fmt
end

-- Where a branch target sits inside each command's operands, for the commands
-- that transfer control within the same bank. The far variants carry their own
-- bank byte and are left for later.
local NEAR_TARGET = {
  [0x00] = 0, -- scall
  [0x03] = 0, -- sjump
  [0x06] = 1, -- ifequal
  [0x07] = 1, -- ifnotequal
  [0x08] = 0, -- iffalse
  [0x09] = 0, -- iftrue
  [0x0A] = 1, -- ifgreater
  [0x0B] = 1, -- ifless
  [0x8D] = 0, -- sdefer
  [0x8F] = 0, -- stopandsjump
}

probe.MAX_BLOCKS = 400

function probe.run(rom_path, report_path)
  report = {}

  local rom, err = Rom.load(rom_path)
  if not rom then
    log("FATAL: %s", err)
    local fh = io.open(report_path, "w")
    if fh then fh:write(table.concat(report, "\n") .. "\n") fh:close() end
    return true
  end

  local widths, terminators, names = script_ops.widths()

  --- Walk the whole reachable graph from one entry point.
  -- @return ok, reason, instruction count, opcodes seen
  local function traverse(bank, addr, seen_ops)
    local queue = { addr }
    local visited = {}
    local count = 0

    while #queue > 0 do
      local at_addr = table.remove(queue)
      if not visited[at_addr] and at_addr >= 0x4000 and at_addr <= 0x7FFF then
        visited[at_addr] = true

        local at = bank * 0x4000 + (at_addr - 0x4000)
        local cursor = at
        local guard = 0

        while true do
          guard = guard + 1
          if guard > 2000 then
            return false, "block ran too long", count
          end
          if cursor + 1 > rom.size then
            return false, "ran past the ROM", count
          end

          local opcode = rom:u8(cursor)
          local width = widths[opcode]
          if width == nil then
            return false, ("unknown opcode $%02X"):format(opcode), count
          end

          count = count + 1
          seen_ops[opcode] = (seen_ops[opcode] or 0) + 1

          local offset = NEAR_TARGET[opcode]
          if offset then
            local target = rom:u16le(cursor + 1 + offset)
            if target >= 0x4000 and target <= 0x7FFF then
              queue[#queue + 1] = target
            end
          end

          cursor = cursor + 1 + width

          if terminators[opcode] then
            break
          end
        end
      end
    end

    return true, nil, count
  end

  local tileset_result = tilesets.locate(rom)
  local map_result = maps.locate(rom, tileset_result.count)

  local total, complete = 0, 0
  local reasons = {}
  local seen_ops = {}
  local instructions = 0

  local function try(bank, addr)
    if not addr then
      return
    end
    total = total + 1
    local ok, why, count = traverse(bank, addr, seen_ops)
    instructions = instructions + count
    if ok then
      complete = complete + 1
    else
      reasons[why] = (reasons[why] or 0) + 1
    end
  end

  for _, header in ipairs(map_result.headers) do
    local decoded = not header.unparsed and events.decode(rom, header)
    if decoded then
      local bank = math.floor(header.attributes.scripts / 0x4000)
      for _, bg in ipairs(decoded.bg_events) do
        if bg.kind ~= events.BGEVENT_ITEM then
          try(bank, bg.script)
        end
      end
      for _, object in ipairs(decoded.objects) do
        if object.kind ~= events.OBJECT_TRAINER
          and object.kind ~= events.OBJECT_ITEM then
          try(bank, object.script)
        end
      end
      for _, coord in ipairs(decoded.coord_events) do
        try(bank, coord.script)
      end
    end
  end

  log("%d entry points, %d traverse the whole graph (%d%%)", total, complete,
    math.floor(complete / math.max(total, 1) * 100))
  log("%d instructions decoded along the way", instructions)

  log("\nwhat stops the rest:")
  local ranked = {}
  for reason, count in pairs(reasons) do
    ranked[#ranked + 1] = { reason = reason, count = count }
  end
  table.sort(ranked, function(a, b) return a.count > b.count end)
  for i = 1, math.min(#ranked, 14) do
    log("  %4d x %s", ranked[i].count, ranked[i].reason)
  end

  log("\nthe commands that actually occur, commonest first:")
  ranked = {}
  for opcode, count in pairs(seen_ops) do
    ranked[#ranked + 1] = { opcode = opcode, count = count }
  end
  table.sort(ranked, function(a, b) return a.count > b.count end)
  local cumulative, all = 0, 0
  for _, entry in ipairs(ranked) do all = all + entry.count end
  for i = 1, math.min(#ranked, 40) do
    cumulative = cumulative + ranked[i].count
    log("  %-24s %5d  %3d%% cumulative", names[ranked[i].opcode],
      ranked[i].count, math.floor(cumulative / all * 100))
  end
  log("  ... %d distinct commands in total", #ranked)

  rom:release()

  local fh = io.open(report_path, "w")
  if fh then
    fh:write(table.concat(report, "\n") .. "\n")
    fh:close()
  end
  return true
end

return probe
