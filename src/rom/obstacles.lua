-- The things a field move clears out of the way.
--
-- Cut trees and Strength boulders are not terrain. They are ordinary map
-- objects, which is why no collision value corresponds to either -- a search
-- for one found $B2 sitting in 62% "gates", and rendering the map showed long
-- horizontal runs of wall across open floor. A wall line has walkable ground
-- above and below every cell of it, so the gate measure counted a fence as a
-- doorway.
--
-- What they are is objects whose script goes straight to a standard routine and
-- says nothing. That is a sharp signature: an ordinary NPC has dialogue.
--
-- Which of the two groups is which is settled by where they stand. A boulder is
-- a cave and gym-puzzle obstacle; a cut tree is an outdoor one. In Crystal that
-- comes out as 14 caves and 10 interiors against 6 towns, 5 caves, 4 routes and
-- a dungeon, and the split is not close.
--
-- Nothing here is a sprite id written down. The ids are found.

local events = require("src.rom.events")
local script_decode = require("src.rom.script_decode")
local std_scripts = require("src.rom.std_scripts")

local obstacles = {}

-- Enough of them to be a class of scenery rather than a coincidence.
obstacles.MINIMUM = 8
-- Nearly all of a group must share one routine.
obstacles.AGREEMENT = 0.9

-- Environments that put an obstacle underground or indoors.
obstacles.ENCLOSED = { cave = true, indoor = true, dungeon = true }

--- Find the cut tree and the boulder.
-- @return { tree, boulder } as sprite ids, plus the evidence
function obstacles.locate(rom, map_result)
  local groups = {}

  for _, header in ipairs(map_result.headers) do
    local decoded = not header.unparsed and events.decode(rom, header)
    if decoded then
      local bank = math.floor(header.attributes.scripts / 0x4000)
      for _, object in ipairs(decoded.objects) do
        if object.script and object.kind ~= events.OBJECT_TRAINER
          and object.kind ~= events.OBJECT_ITEM then
          local group = groups[object.sprite]
          if not group then
            group = { count = 0, std = {}, enclosed = 0, open = 0 }
            groups[object.sprite] = group
          end
          group.count = group.count + 1

          if obstacles.ENCLOSED[header.environment_name] then
            group.enclosed = group.enclosed + 1
          else
            group.open = group.open + 1
          end

          local code = script_decode.reachable(rom,
            { { bank = bank, addr = object.script } })
          local block = code[bank]
          local instruction = block and block[object.script]
          if instruction and (instruction.op == "jumpstd"
            or instruction.op == "callstd") then
            local index = (instruction.args[1] or 0)
              + (instruction.args[2] or 0) * 256
            group.std[index] = (group.std[index] or 0) + 1
            -- Something that only jumps to a routine says nothing itself.
            group.silent = (group.silent or 0) + 1
          end
        end
      end
    end
  end

  -- Candidates: a sprite whose objects nearly all leave through one routine.
  local candidates = {}
  for sprite, group in pairs(groups) do
    local total, best, best_index = 0, 0, nil
    for index, count in pairs(group.std) do
      total = total + count
      if count > best then
        best, best_index = count, index
      end
    end
    if total >= obstacles.MINIMUM and best >= total * obstacles.AGREEMENT then
      candidates[#candidates + 1] = {
        sprite = sprite, std = best_index, count = group.count,
        enclosed = group.enclosed, open = group.open,
      }
    end
  end

  -- "Runs one routine and says nothing itself" is not enough on its own, and
  -- the first attempt proved it: the Pokémon Centre nurse matched. Twenty-two
  -- of her, every one indoors, every one jumping straight to the same routine,
  -- and she ranked as the most enclosed thing in the game.
  --
  -- What separates her is the routine. Hers greets you; the ones that clear an
  -- obstacle have no text at all, because what they do is done in assembly.
  local std = std_scripts.locate(rom)
  if not std then
    return nil, "the standard scripts are needed to tell an obstacle from an NPC"
  end

  local function routine_is_silent(index)
    local entry = std.entries[index + 1]
    if not entry then
      return false
    end
    local code = script_decode.reachable(rom,
      { { bank = entry.bank, addr = entry.addr } })
    for _, instruction in pairs(code[entry.bank] or {}) do
      if instruction.text then
        return false
      end
    end
    return true
  end

  local silent = {}
  for _, candidate in ipairs(candidates) do
    if routine_is_silent(candidate.std) then
      silent[#silent + 1] = candidate
    end
  end
  candidates = silent

  if #candidates < 2 then
    return nil, ("only %d sprite groups run a routine that says nothing")
      :format(#candidates)
  end

  -- The most enclosed is the boulder; the most open is the tree. Ranking
  -- rather than thresholding, so the answer does not depend on a cutoff.
  table.sort(candidates, function(a, b)
    local a_share = a.enclosed / math.max(a.count, 1)
    local b_share = b.enclosed / math.max(b.count, 1)
    return a_share > b_share
  end)

  local boulder = candidates[1]
  local tree = candidates[#candidates]
  if boulder.sprite == tree.sprite then
    return nil, "the same sprite came out most enclosed and most open"
  end

  return {
    boulder = boulder.sprite,
    tree = tree.sprite,
    boulder_std = boulder.std,
    tree_std = tree.std,
    evidence = {
      boulder = ("%d objects, %d enclosed"):format(boulder.count,
        boulder.enclosed),
      tree = ("%d objects, %d in the open"):format(tree.count, tree.open),
    },
  }
end

return obstacles
