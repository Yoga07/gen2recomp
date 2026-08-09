-- Which move each TM and HM teaches.
--
-- The items are named TM01 to TM50 and HM01 to HM07, which says nothing about
-- what is on them. The list is 57 move ids in that order.
--
-- A run of 57 distinct valid move ids is not convincing on its own -- 626
-- offsets in Crystal satisfy that. What settles it is the tail: the last seven
-- have to decode, through the move-name table this project validates
-- separately, to the seven field moves in HM order. Exactly one of the 626 does,
-- and the rest of that list then reads as the real thing: TM01 DynamicPunch,
-- TM06 Toxic, TM26 Earthquake, TM44 Rest.

local machines = {}

machines.TM_COUNT = 50
machines.HM_COUNT = 7
machines.COUNT = machines.TM_COUNT + machines.HM_COUNT
machines.MOVE_COUNT = 251

-- The field moves, in the order the HMs carry them. Used to confirm a
-- candidate table rather than to define one: the names are compared against
-- what the cartridge's own move-name table says.
machines.FIELD_MOVES = {
  "CUT", "FLY", "SURF", "STRENGTH", "FLASH", "WHIRLPOOL", "WATERFALL",
}

--- Locate the table.
-- @param move_names the decoded move-name table, for the confirming check
-- @return { offset, moves = { [1..57] = move id }, hm = { name -> move id } }
function machines.locate(rom, move_names)
  if not move_names then
    return nil, "the move names are needed to confirm the machine list"
  end

  local function run_at(offset)
    local seen = {}
    for index = 0, machines.COUNT - 1 do
      local value = rom:u8(offset + index)
      if value < 1 or value > machines.MOVE_COUNT then
        return false
      end
      -- Two machines teaching the same move would be pointless.
      if seen[value] then
        return false
      end
      seen[value] = true
    end
    return true
  end

  local accepted = {}
  for offset = 0, rom.size - machines.COUNT do
    if run_at(offset) then
      -- The confirming check: the last seven are the field moves, in order.
      local same = true
      for index, wanted in ipairs(machines.FIELD_MOVES) do
        local move = rom:u8(offset + machines.TM_COUNT + index - 1)
        if move_names[move] ~= wanted then
          same = false
          break
        end
      end
      if same then
        accepted[#accepted + 1] = offset
      end
    end
  end

  if #accepted == 0 then
    return nil, "no run of 57 move ids ends with the field moves"
  end
  if #accepted > 1 then
    local places = {}
    for _, offset in ipairs(accepted) do
      places[#places + 1] = ("0x%06X"):format(offset)
    end
    return nil, ("the machine list validated at %d offsets (%s); refusing " ..
      "to guess"):format(#accepted, table.concat(places, ", "))
  end

  local offset = accepted[1]
  local moves, hm = {}, {}
  for index = 1, machines.COUNT do
    moves[index] = rom:u8(offset + index - 1)
  end
  for index, name in ipairs(machines.FIELD_MOVES) do
    hm[name] = moves[machines.TM_COUNT + index]
  end

  return { offset = offset, moves = moves, hm = hm }
end

--- The item id of a machine, given its number. TMs and HMs sit together in the
-- item table, the HMs immediately after the fiftieth TM.
function machines.item_for(index, first_tm_item)
  return first_tm_item + index - 1
end

return machines
