-- The game loop: an overworld you can walk around.
--
-- Renders at the Game Boy's 160x144 to a canvas and scales that up by whole
-- numbers, so every source pixel covers the same number of screen pixels. Any
-- other scaling produces uneven tile edges, which on this art is very visible.

local world = require("src.engine.world")
local player = require("src.engine.player")
local cache = require("src.import.cache")
local wild = require("src.engine.wild")
local pokemon = require("src.engine.pokemon")
local battle = require("src.engine.battle")
local catching = require("src.engine.catching")
local save = require("src.engine.save")
local menu = require("src.engine.menu")
local stages = require("src.engine.stages")
local bag = require("src.engine.bag")
local vm = require("src.engine.vm")
local events_module = require("src.rom.events")

local game = {}
game.__index = game

game.SCREEN_WIDTH = 160
game.SCREEN_HEIGHT = 144

local KEYS = {
  up = "up", down = "down", left = "left", right = "right",
  w = "up", s = "down", a = "left", d = "right",
}

local FACING_DELTA = {
  up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 },
}

-- Text box geometry, in the 160x144 the hardware rendered.
local BOX_HEIGHT = 48
local BOX_MARGIN = 6

--- Start a game on a cached import.
-- @param start_index which map to spawn on; defaults to the largest town
function game.new(game_id, start_index)
  local loaded, why = world.load(game_id)
  if not loaded then
    return nil, why
  end

  local instance = setmetatable({
    game_id = game_id,
    world = loaded,
    groups = cache.read(game_id, "map_groups") or {},
    canvas = love.graphics.newCanvas(game.SCREEN_WIDTH, game.SCREEN_HEIGHT),
    message = nil,
    message_timer = 0,
  }, game)
  instance.canvas:setFilter("nearest", "nearest")
  -- The canvas is only 160 wide, so the box needs a font sized for it. The
  -- cartridge's own font lives in bank $3E and is not wired up yet.
  instance.font = love.graphics.newFont(8)
  -- The cartridge's own font, when the import produced one. Falls back to
  -- LOVE's font rather than refusing to show text.
  instance.bitmap_font = require("src.engine.bitmap_font").load(game_id)
  instance.species_names = cache.read(game_id, "species_names")
  instance.base_stats = cache.read(game_id, "base_stats")
  instance.move_records = cache.read(game_id, "moves")
  instance.move_name_records = cache.read(game_id, "move_names")
  instance.learnset_records = cache.read(game_id, "learnsets")
  instance.trainer_classes = cache.read(game_id, "trainer_classes")
  instance.item_records = cache.read(game_id, "item_attributes")
  instance.item_names = cache.read(game_id, "item_names")
  instance.marts = cache.read(game_id, "marts") or {}
  instance.script_code = cache.read(game_id, "script_code")
  -- Two separate spaces, because the cartridge treats them as two.
  instance.script_flags = { event = {}, flag = {} }
  instance.bag = bag.new(instance.item_records, instance.item_names)
  -- What the games start you with. Like the starting bag, this is ours rather
  -- than the cartridge's: the script that sets it is not interpreted.
  instance.money = 3000
  -- Trainers already beaten, keyed by their event flag. Saved with the game.
  instance.beaten = {}
  -- Item balls already picked up, keyed by map and object index.
  instance.taken = {}
  -- Hidden items already turned up, keyed by their own event flag.
  instance.found = {}

  -- A stand-in for what the game's own scripts would hand out. Mum's potion,
  -- the balls from the mart and a key item are enough to exercise every pocket;
  -- the scripts that actually award items are not interpreted yet.
  instance.bag:add(5, 5)   -- POKe BALL
  instance.bag:add(18, 3)  -- POTION
  instance.bag:add(9, 1)   -- ANTIDOTE
  instance.bag:add(7, 1)   -- BICYCLE

  -- A save takes precedence over the default starting map.
  local restored = instance:restore()
  if not restored then
    instance:enter(start_index or instance:default_map())
  elseif start_index then
    -- An explicit map wins over the save, so the screenshot modes still work.
    instance:enter(start_index)
  end

  return instance
end

--- Write the current state to disk.
-- @return true, or false plus a reason
function game:save()
  local ok, why = save.write(self.game_id, {
    map_index = self.map_index,
    cell_x = self.player.cell_x,
    cell_y = self.player.cell_y,
    facing = self.player.facing,
    party = self.party,
    beaten = self.beaten,
    taken = self.taken,
    found = self.found,
    bag = self.bag:to_list(),
    money = self.money,
    script_flags = self.script_flags,
  })

  if ok then
    self:notify(("Saved. Party: %d"):format(#(self.party or {})))
    return true
  end

  self:notify(tostring(why))
  return false
end

--- Load a save, if there is one for this game.
-- @return true when state was restored
function game:restore()
  local state, why = save.read(self.game_id, self.base_stats)
  if not state then
    -- "no save" is the ordinary case and not worth reporting.
    if why ~= "no save" then
      self:notify(why)
    end
    return false
  end

  local map = state.map_index and self.world:map(state.map_index)
  if not map or map.unparsed then
    self:notify("the save points at a map this cache does not have")
    return false
  end

  self.party = state.party
  self.beaten = state.beaten or {}
  self.taken = state.taken or {}
  self.found = state.found or {}
  self.money = state.money or self.money
  if state.script_flags then
    self.script_flags = {
      event = state.script_flags.event or {},
      flag = state.script_flags.flag or {},
    }
  end
  -- A save written before the bag existed has no list, and the starting items
  -- set up in game.new stand rather than the bag coming back empty.
  if state.bag then
    self.bag = bag.from_list(self.item_records, self.item_names, state.bag)
  end
  self:enter(state.map_index, state.cell_x, state.cell_y, state.facing)
  self:notify(("Loaded. Party: %d"):format(#state.party))
  return true
end

--- Somewhere interesting to start: the biggest town, falling back to the
-- biggest map of any kind.
function game:default_map()
  local best, best_area, fallback, fallback_area = nil, -1, nil, -1
  for index = 1, self.world:map_count() do
    local map = self.world:map(index)
    if not map.unparsed then
    local area = map.width * map.height
    if area > fallback_area then
      fallback, fallback_area = index, area
    end
    if map.environment == "town" and area > best_area then
      best, best_area = index, area
    end
    end
  end
  return best or fallback
end

--- Put the player on a map, on a walkable cell near the middle if no spawn is
-- given. Real spawn points come from warps once you arrive through one.
function game:enter(map_index, cell_x, cell_y, facing)
  self.map_index = map_index
  self.map = self.world:map(map_index)

  if not cell_x then
    cell_x, cell_y = self:find_spawn()
  end

  if self.player then
    self.player:place(cell_x, cell_y, facing)
  else
    self.player = player.new(cell_x, cell_y)
  end
end

--- Nearest walkable cell to the map's centre, searched outwards.
function game:find_spawn()
  local centre_x = math.floor(self.map.width * world.CELLS_PER_BLOCK / 2)
  local centre_y = math.floor(self.map.height * world.CELLS_PER_BLOCK / 2)

  for radius = 0, math.max(self.map.width, self.map.height) * 2 do
    for dy = -radius, radius do
      for dx = -radius, radius do
        -- Only test the ring at this radius, not the filled square.
        if math.abs(dx) == radius or math.abs(dy) == radius then
          local x, y = centre_x + dx, centre_y + dy
          if self.world:walkable(self.map, x, y) then
            return x, y
          end
        end
      end
    end
  end
  return centre_x, centre_y
end

--- Jump to the first signpost in the game that has text and read it.
-- Used by the screenshot mode to check the whole path from cartridge to
-- text box without a human at the keyboard.
-- @return true when it found one
-- @param kind "sign" for a background event, "npc" for a person
function game:show_first_sign(kind)
  local want_pages = kind == "npc" and 2 or 1

  for index = 1, self.world:map_count() do
    local map = self.world:map(index)
    if not map.unparsed then
      local group = kind == "npc" and (map.objects or {}) or (map.bg_events or {})
      for _, item in ipairs(group) do
        -- For an NPC, prefer someone with a real conversation rather than a
        -- one-line remark.
        if item.text and #item.text >= want_pages then
          self:enter(index, item.x, item.y + 1, "up")
          -- Standing below it, facing up, is how you read a sign or speak to
          -- someone.
          self.dialogue = { pages = item.text, page = 1 }
          return true
        end
      end
    end
  end
  return false
end

--- Stand on the first grass tile in the game and force an encounter.
-- Used by the screenshot mode to exercise the whole path from collision
-- classification through the encounter tables to the text box.
-- @param demo "catch" to throw a ball immediately, otherwise open the menu
--- Stand in front of the first trainer in the game and start the fight.
function game:show_trainer_demo()
  for index = 1, self.world:map_count() do
    local map = self.world:map(index)
    if not map.unparsed then
      for _, object in ipairs(map.objects or {}) do
        if object.trainer and self.trainer_classes
          and self.trainer_classes[object.trainer.class] then
          self:enter(index, object.x, object.y + 1, "up")
          if self:start_trainer_battle(object.trainer) then
            return true
          end
        end
      end
    end
  end
  return false
end

--- Stand in front of the first shopkeeper found and open their counter.
-- @param mode nil for the counter itself, "buy" or "sell" to go through with
--        one transaction on whatever the cursor lands on first
function game:show_mart_demo(mode)
  for index = 1, self.world:map_count() do
    local map = self.world:map(index)
    if not map.unparsed then
      for _, object in ipairs(map.objects or {}) do
        if object.mart then
          self:enter(index, object.x, object.y + 1, "up")
          if not self:open_mart(object.mart) then
            return false
          end
          if mode == "buy" then
            self:open_mart_buy(object.mart)
            self:menu_confirm()
          elseif mode == "sell" then
            self:open_mart_sell(object.mart)
            self:menu_confirm()
          elseif mode == "quantity" then
            -- Open the dial and wind it up, without going through with it.
            self:open_mart_buy(object.mart)
            self:menu_confirm()
            self:quantity_move(10, false)
            self:quantity_move(2, false)
          elseif mode == "bulk" then
            self:open_mart_buy(object.mart)
            self:menu_confirm()
            self:quantity_move(4, false)
            self:menu_confirm()
          end
          return true
        end
      end
    end
  end
  return false
end

--- Talk to the first NPC whose script the interpreter can actually run.
-- Goes through `interact`, so this exercises the real path rather than putting
-- text on screen directly the way the older demos do.
function game:show_script_demo()
  for index = 1, self.world:map_count() do
    local map = self.world:map(index)
    if not map.unparsed then
      for _, object in ipairs(map.objects or {}) do
        if object.script and not object.trainer and not object.item then
          self:enter(index, object.x, object.y + 1, "up")
          self:interact()
          if self.dialogue then
            -- Prefer a line with a contraction in it, since those are what the
            -- text decoder used to choke on.
            for _, line in ipairs(self.dialogue.pages[1] or {}) do
              if (line.text or ""):find("'", 1, true) then
                return true
              end
            end
            self.dialogue = nil
            self.script = nil
          end
        end
      end
    end
  end
  return false
end

--- Stand in front of the first hidden item found and turn it up.
-- @param again when true, try a second time and show the item pocket, which
--        would show two of it if the flag were not stopping the repeat
function game:show_hidden_demo(again)
  for index = 1, self.world:map_count() do
    local map = self.world:map(index)
    if not map.unparsed then
      for _, bg in ipairs(map.bg_events or {}) do
        if bg.hidden then
          self:enter(index, bg.x, bg.y + 1, "up")
          self:interact()
          if again then
            self.dialogue = nil
            self:interact()
            self.dialogue = nil
            self:open_pocket(self.bag:pocket_of(bg.hidden.item))
          end
          return true
        end
      end
    end
  end
  return false
end

--- Stand in front of the first item ball on any map and pick it up.
-- @param again when true, take it, then try to take it a second time and show
--        the ball pocket. Taking twice would show a count of two.
function game:show_item_demo(again)
  for index = 1, self.world:map_count() do
    local map = self.world:map(index)
    if not map.unparsed then
      for _, object in ipairs(map.objects or {}) do
        if object.item then
          self:enter(index, object.x, object.y + 1, "up")
          self:interact()
          if again then
            self.dialogue = nil
            self:interact()
            self.dialogue = nil
            self:open_pocket("balls")
          end
          return true
        end
      end
    end
  end
  return false
end

--- Walk off a connected edge and end up on the neighbouring map.
-- Used by the screenshot mode to show a crossing rather than describe one.
function game:show_connection_demo()
  for index = 1, self.world:map_count() do
    local map = self.world:map(index)
    if not map.unparsed then
      for _, connection in ipairs(map.connections or {}) do
        local start = self.groups[connection.group]
        local target = start and self.world:map(start + connection.number - 1)
        if target and not target.unparsed then
          local width = map.width * world.CELLS_PER_BLOCK
          local height = map.height * world.CELLS_PER_BLOCK
          local x, y

          if connection.direction == "north" then
            x, y = math.floor(width / 2), -1
          elseif connection.direction == "south" then
            x, y = math.floor(width / 2), height
          elseif connection.direction == "west" then
            x, y = -1, math.floor(height / 2)
          else
            x, y = width, math.floor(height / 2)
          end

          self:enter(index)
          self:take_connection(connection, x, y)
          self:notify(("crossed %s into map %d")
            :format(connection.direction, start + connection.number - 1))
          return true
        end
      end
    end
  end
  return false
end

--- Catch something, then open the party summary on it.
-- Used by the screenshot mode to show the menus with real contents.
function game:show_party_demo()
  self:show_first_encounter("catch")
  self.battle = nil
  self.battle_lines = nil
  self:party_leader()
  self:open_party()
  self.ui.list:move(1)
  self:menu_confirm()
  return true
end

-- @param demo "catch" to throw a ball immediately, otherwise open the menu
function game:show_first_encounter(demo)
  for index = 1, self.world:map_count() do
    local map = self.world:map(index)
    if not map.unparsed and map.encounters then
      for cell_y = 0, map.height * world.CELLS_PER_BLOCK - 1 do
        for cell_x = 0, map.width * world.CELLS_PER_BLOCK - 1 do
          if self.world:is_grass(map, cell_x, cell_y) then
            self:enter(index, cell_x, cell_y, "down")
            -- A fixed roll, so the screenshot is reproducible.
            local met = wild.roll(map.encounters, "day", function(low, high)
              return low
            end)
            if met then
              self:wild_encounter(met)
              if (demo == "catch" or demo == "catchsave") and self.battle then
                -- Weaken it and throw, so the screenshot shows a catch
                -- resolving through the party rather than a menu.
                self.battle.opponent.hp = 1
                self:throw_ball()
                if demo == "catchsave" then
                  -- Dismiss the battle so the save records the overworld
                  -- position rather than a state mid-encounter.
                  self.battle = nil
                  self:save()
                end
                return true
              end
              -- Run one turn so the screenshot shows a battle in progress
              -- rather than only the opening line.
              if self.battle then
                -- Advance to the action menu so the screenshot shows the
                -- choice rather than only the opening line.
                self:battle_advance()
              end
              return true
            end
          end
        end
      end
    end
  end
  return false
end

function game:held_direction()
  for key, direction in pairs(KEYS) do
    if love.keyboard.isDown(key) then
      return direction
    end
  end
  return nil
end

function game:notify(text)
  self.message = text
  self.message_timer = 2.5
end

--------------------------------------------------------------------------------
-- Menus
--------------------------------------------------------------------------------

game.START_ENTRIES = { "POKEMON", "BAG", "SAVE", "CLOSE" }

-- What each pocket is called on screen. The cartridge names the pocket an item
-- belongs to but not the pocket itself, so these labels are ours.
game.POCKET_LABELS = {
  items = "ITEMS",
  balls = "BALLS",
  machines = "TM/HM",
  key = "KEY ITEMS",
}

--- Open the start menu, unless something else already owns the screen.
function game:open_menu()
  if self.battle or self.dialogue or self.player.moving then
    return
  end
  self.ui = { kind = "start", list = menu.new(game.START_ENTRIES, #game.START_ENTRIES) }
end

function game:close_menu()
  self.ui = nil
end

--- Short label for a party member, as the party list shows it.
function game:party_label(member)
  local name = self.species_names[member.species] or "?"
  local mark = ""
  if member.status then
    -- Three letters is all that fits beside the numbers.
    mark = " " .. member.status:upper():sub(1, 3)
  end
  return ("%s L%d %d/%d%s"):format(name:sub(1, 9), member.level,
    member.hp, member.stats.hp, mark)
end

--- Handle a key while a menu is open.
-- @return true when the key was consumed
function game:menu_key(key)
  if not self.ui then
    return false
  end

  -- The quantity dial takes the arrows before any list does, and it is the one
  -- screen where left and right mean something.
  if self.ui.kind == "quantity" then
    if key == "up" or key == "w" then
      self:quantity_move(1, true)
      return true
    end
    if key == "down" or key == "s" then
      self:quantity_move(-1, true)
      return true
    end
    if key == "right" or key == "d" then
      self:quantity_move(10, false)
      return true
    end
    if key == "left" or key == "a" then
      self:quantity_move(-10, false)
      return true
    end
  end

  if key == "up" or key == "w" then
    self.ui.list:move(-1)
    return true
  end

  if key == "down" or key == "s" then
    self.ui.list:move(1)
    return true
  end

  if key == "x" or key == "escape" or key == "backspace" then
    -- Step back one screen rather than closing everything at once.
    if self.ui.kind == "summary" then
      self:open_party()
    elseif self.ui.kind == "pocket" then
      self:open_bag()
    elseif self.ui.kind == "quantity" then
      -- Back to the list it was asked from, not out of the shop.
      if self.ui.mode == "buy" then
        self:open_mart_buy(self.ui.mart)
      else
        self:open_mart_sell(self.ui.mart)
      end
    elseif self.ui.kind == "mart" or self.ui.kind == "sell" then
      -- Back to the counter, not out of the shop entirely.
      self:open_mart(self.ui.mart)
    elseif self.ui.kind == "party" or self.ui.kind == "bag" then
      self.ui = { kind = "start", list = menu.new(game.START_ENTRIES, #game.START_ENTRIES) }
    else
      self:close_menu()
    end
    return true
  end

  if key == "z" or key == "space" or key == "return" then
    self:menu_confirm()
    return true
  end

  return false
end

function game:open_party()
  local party = self.party or {}
  local labels = {}
  for index, member in ipairs(party) do
    labels[index] = self:party_label(member)
  end
  self.ui = { kind = "party", list = menu.new(labels, 6) }
end

--- The pockets that currently hold something, as a menu.
-- Empty pockets are left out rather than shown empty, which is what the games
-- do once you have been given the bag.
function game:open_bag()
  local used = self.bag:used_pockets()
  local labels = {}
  for index, which in ipairs(used) do
    labels[index] = ("%s %d"):format(game.POCKET_LABELS[which] or which,
      #self.bag:pocket(which))
  end
  self.ui = { kind = "bag", pockets = used, list = menu.new(labels, 4) }
end

function game:open_pocket(which)
  local contents = self.bag:pocket(which)
  local labels = {}
  for index, entry in ipairs(contents) do
    -- Key items are singular, so a count beside them reads oddly.
    if which == "key" then
      labels[index] = entry.name
    else
      labels[index] = ("%s x%d"):format(entry.name, entry.count)
    end
  end
  self.ui = { kind = "pocket", pocket = which, contents = contents,
              list = menu.new(labels, 6) }
end

--- Use an item from the bag while walking around.
--
-- What an item does comes from its own record: the high nibble of the menu byte
-- says whether it is usable in the field at all, and the parameter says how
-- much. Nothing here is keyed on an item id, so a Super Potion heals more than
-- a Potion because the cartridge says 60 against 20, not because the engine
-- knows which is which.
function game:use_item_in_field(entry)
  local record = entry.record
  local leader = self:party_leader()

  if not record or record.field_use ~= "heal" then
    self:notify(("%s has no use here."):format(entry.name))
    return
  end

  if not leader then
    self:notify("No POKéMON to use it on.")
    return
  end

  if leader.hp >= leader.stats.hp then
    self:notify(("%s is already healthy."):format(
      self.species_names[leader.species] or "?"))
    return
  end

  local healed = math.min(record.parameter, leader.stats.hp - leader.hp)
  leader.hp = leader.hp + healed
  self.bag:remove(entry.item, 1)
  self:notify(("%s restored %d HP."):format(entry.name, healed))

  -- The pocket has changed underneath the cursor, so rebuild it. An emptied
  -- pocket drops back to the bag rather than showing an empty list.
  if #self.bag:pocket(entry.pocket or self.ui.pocket) > 0 then
    self:open_pocket(self.ui.pocket)
  else
    self:open_bag()
  end
end

function game:menu_confirm()
  local kind = self.ui.kind

  if kind == "bag" then
    local which = self.ui.pockets[self.ui.list.cursor]
    if which then
      self:open_pocket(which)
    end
    return
  end

  if kind == "pocket" then
    local entry = self.ui.contents[self.ui.list.cursor]
    if entry then
      self:use_item_in_field(entry)
    end
    return
  end

  if kind == "mart_menu" then
    local choice = self.ui.list:selected()
    if choice == "BUY" then
      self:open_mart_buy(self.ui.mart)
    elseif choice == "SELL" then
      if #self.bag:sellable() > 0 then
        self:open_mart_sell(self.ui.mart)
      else
        self:notify("You have nothing to sell.")
      end
    else
      self:close_menu()
    end
    return
  end

  if kind == "mart" then
    local entry = self.ui.stock[self.ui.list.cursor]
    if entry then
      self:open_quantity("buy", entry)
    end
    return
  end

  if kind == "sell" then
    local entry = self.ui.contents[self.ui.list.cursor]
    if entry then
      self:open_quantity("sell", entry)
    end
    return
  end

  if kind == "quantity" then
    self:quantity_confirm()
    return
  end

  if kind == "start" then
    local choice = self.ui.list:selected()
    if choice == "POKEMON" then
      self:party_leader() -- makes sure the starter exists before listing
      self:open_party()
    elseif choice == "BAG" then
      self:open_bag()
    elseif choice == "SAVE" then
      self:save()
      self:close_menu()
    else
      self:close_menu()
    end
    return
  end

  if kind == "party" then
    local index = self.ui.list.cursor
    local member = (self.party or {})[index]
    if member then
      self.ui = { kind = "summary", index = index,
                  list = menu.new({ "" }, 1) }
    end
    return
  end

  -- The summary has nothing to confirm; treat it as a step back.
  self:open_party()
end

--- Draw whichever menu is open, inside the hardware-sized canvas.
function game:draw_menu()
  local font = self.bitmap_font
  if not font then
    return
  end

  local kind = self.ui.kind

  if kind == "summary" then
    local member = (self.party or {})[self.ui.index]
    if not member then
      return
    end

    love.graphics.setColor(1, 1, 1)
    love.graphics.rectangle("fill", 0, 0, game.SCREEN_WIDTH, game.SCREEN_HEIGHT)
    love.graphics.setColor(0.1, 0.1, 0.1)
    love.graphics.rectangle("line", 2.5, 2.5,
      game.SCREEN_WIDTH - 5, game.SCREEN_HEIGHT - 5)

    local sprite = self.world:species_sprite(member.species)
    if sprite then
      love.graphics.setColor(1, 1, 1)
      love.graphics.draw(sprite, game.SCREEN_WIDTH - sprite:getWidth() - 6, 6)
    end

    love.graphics.setColor(0.1, 0.1, 0.1)
    local name = self.species_names[member.species] or "?"
    local lines = {
      name,
      ("L%d  %s"):format(member.level, member.gender or ""),
      ("HP %d/%d"):format(member.hp, member.stats.hp),
      -- SATK and SDEF rather than SPA/SPD, so neither can be mistaken for
      -- speed, which gets SPD to itself.
      ("ATK %d  DEF %d"):format(member.stats.attack, member.stats.defense),
      ("SATK %d  SDEF %d"):format(member.stats.special_attack,
        member.stats.special_defense),
      ("SPD %d"):format(member.stats.speed),
      member.types[1] == member.types[2] and member.types[1]
        or ("%s/%s"):format(member.types[1] or "?", member.types[2] or "?"),
      member.status and ("STATUS " .. member.status:upper()) or "",
      member.shiny and "SHINY" or "",
    }

    for i, line in ipairs(lines) do
      if line ~= "" then
        font:draw_codes(self:encode(line:upper()), 8, 8 + (i - 1) * 10)
      end
    end

    -- Moves along the bottom.
    local y = 8 + #lines * 10
    for _, move_id in ipairs(member.moves or {}) do
      local move_name = (self.move_name_records or {})[move_id]
        or ("MOVE " .. move_id)
      font:draw_codes(self:encode(move_name), 8, y)
      y = y + 10
    end

    love.graphics.setColor(1, 1, 1)
    return
  end

  -- The quantity dial has no list behind it, just a number being turned.
  if kind == "quantity" then
    local ui = self.ui
    -- The sell list already carries the halved price, so one field serves
    -- both directions.
    local total = ui.entry.price * ui.amount

    local box_width, box_height = 104, 34
    local x = game.SCREEN_WIDTH - box_width
    local y = 84

    love.graphics.setColor(1, 1, 1)
    love.graphics.rectangle("fill", x, y, box_width, box_height)
    love.graphics.setColor(0.1, 0.1, 0.1)
    love.graphics.rectangle("line", x + 2.5, y + 2.5,
      box_width - 5, box_height - 5)

    font:draw_codes(self:encode(self:truncate(ui.entry.name, 12)), x + 8, y + 6)
    font:draw_codes(self:encode(("x%02d   ¥%d"):format(ui.amount, total)),
      x + 8, y + 18)

    -- The money box below still applies, so fall through to it.
    love.graphics.setColor(1, 1, 1)
    local label = ("MONEY ¥%d"):format(self.money)
    local money_height = 22
    local money_y = game.SCREEN_HEIGHT - money_height
    love.graphics.rectangle("fill", 0, money_y, 104, money_height)
    love.graphics.setColor(0.1, 0.1, 0.1)
    love.graphics.rectangle("line", 2.5, money_y + 2.5, 99, money_height - 5)
    font:draw_codes(self:encode(label), 8, money_y + 7)
    love.graphics.setColor(1, 1, 1)
    return
  end

  -- Start menu and party list share a box on the right.
  local rows = self.ui.list:window()
  -- Party rows and item rows both carry a name and a number, so they need the
  -- full width; the short menus sit in the corner the way the games put them.
  local wide = kind == "party" or kind == "pocket" or kind == "mart"
    or kind == "sell"
  -- "KEY ITEMS" plus its count does not fit the 76 the short menus use, and a
  -- clipped label is worse than a wider box.
  local width = wide and game.SCREEN_WIDTH or (kind == "bag" and 112 or 76)
  local height = math.max(#rows, 1) * 12 + 12
  local x = wide and 0 or (game.SCREEN_WIDTH - width)

  love.graphics.setColor(1, 1, 1)
  love.graphics.rectangle("fill", x, 0, width, height)
  love.graphics.setColor(0.1, 0.1, 0.1)
  love.graphics.rectangle("line", x + 2.5, 2.5, width - 5, height - 5)

  if self.ui.list:is_empty() then
    local empty = (kind == "bag" or kind == "pocket" or kind == "sell")
      and "NO ITEMS" or "NO POKEMON"
    font:draw_codes(self:encode(empty), x + (wide and 8 or 14), 10)
  end

  -- The wide lists carry a name, a count and a price, which is 19 glyphs at
  -- eight pixels each. That leaves exactly 160, so the cursor column has to be
  -- tighter than it is on the short menus.
  local text_x = x + (wide and 8 or 14)
  local cursor_x = x + (wide and 1 or 6)

  for position, row in ipairs(rows) do
    local y = 8 + (position - 1) * 12
    font:draw_codes(self:encode(tostring(row.item)), text_x, y)
    if row.selected then
      love.graphics.setColor(0.1, 0.1, 0.1)
      love.graphics.rectangle("fill", cursor_x, y + 2, 5, 5)
    end
  end

  -- A shop counter shows what you have to spend, the way the games do.
  if kind == "mart" or kind == "sell" or kind == "mart_menu" then
    local label = ("MONEY ¥%d"):format(self.money)
    local box_width, box_height = 104, 22
    local box_y = game.SCREEN_HEIGHT - box_height
    love.graphics.setColor(1, 1, 1)
    love.graphics.rectangle("fill", 0, box_y, box_width, box_height)
    love.graphics.setColor(0.1, 0.1, 0.1)
    love.graphics.rectangle("line", 2.5, box_y + 2.5,
      box_width - 5, box_height - 5)
    font:draw_codes(self:encode(label), 8, box_y + 7)
  end

  love.graphics.setColor(1, 1, 1)
end

--- What the player is facing, if it has something to say.
-- @return pages, kind
function game:facing_text()
  local delta = FACING_DELTA[self.player.facing]
  local x = self.player.cell_x + delta[1]
  local y = self.player.cell_y + delta[2]

  -- Signposts are read by facing them; NPCs are talked to the same way.
  for _, bg in ipairs(self.map.bg_events or {}) do
    if bg.x == x and bg.y == y and bg.text then
      return bg.text, "sign"
    end
  end
  for _, object in ipairs(self.map.objects or {}) do
    if object.x == x and object.y == y and object.text then
      return object.text, "person"
    end
  end
  return nil
end

--- Interact with whatever is in front of the player, or advance the dialogue
-- already on screen.
--- The trainer in front of the player, if there is one and they have not
--- already been beaten.
function game:facing_trainer()
  local delta = FACING_DELTA[self.player.facing]
  local x = self.player.cell_x + delta[1]
  local y = self.player.cell_y + delta[2]

  for _, object in ipairs(self.map.objects or {}) do
    if object.x == x and object.y == y and object.trainer
      and not self.beaten[object.trainer.flag] then
      return object.trainer
    end
  end
  return nil
end

--- The item ball the player is facing, if it is still there.
-- @return the item block, and the key that says this one has been taken
function game:facing_item()
  local delta = FACING_DELTA[self.player.facing]
  local x = self.player.cell_x + delta[1]
  local y = self.player.cell_y + delta[2]

  for index, object in ipairs(self.map.objects or {}) do
    if object.x == x and object.y == y and object.item then
      -- Keyed by where it lies rather than by its event flag. The flag is what
      -- the cartridge uses, but map and position are unique by construction and
      -- do not depend on the flags being distinct, which has not been checked.
      local key = ("%d:%d"):format(self.map_index, index)
      if not self.taken[key] then
        return object.item, key
      end
    end
  end
  return nil
end

--------------------------------------------------------------------------------
-- What the script interpreter is allowed to do to the world.
--
-- Kept together and named `script_*` so the interpreter's reach is obvious.
-- Everything it can change goes through one of these.
--------------------------------------------------------------------------------

function game:script_flag(space, index)
  local store = self.script_flags[space]
  return store and store[index] == true
end

function game:set_script_flag(space, index, on)
  self.script_flags[space] = self.script_flags[space] or {}
  self.script_flags[space][index] = on or nil
end

function game:script_has_item(item)
  return self.bag:count(item) > 0
end

function game:script_give_item(item, quantity)
  return self.bag:add(item, quantity or 1) >= (quantity or 1)
end

function game:script_take_item(item, quantity)
  return self.bag:remove(item, quantity or 1)
end

function game:script_pocket_full()
  return self.bag:room_for(0) <= 0
end

function game:script_money()
  return self.money
end

function game:script_add_money(amount)
  self.money = math.max(0, self.money + amount)
end

--- Turn whoever is being spoken to towards the player.
-- The overworld draws NPCs facing down and does not carry a per-object facing
-- yet, so this is honest about doing nothing rather than pretending.
function game:face_player()
  return false
end

--- Run the script at an address, and keep running it until it wants something.
function game:run_script(bank, addr)
  if not self.script_code or not bank or not addr then
    return false
  end

  local machine = vm.new(self, self.script_code)
  if not machine:start(bank, addr) then
    return false
  end

  self.script = machine
  self:advance_script()

  -- A script that ran to the end without saying anything leaves the player
  -- facing a silent NPC. Reporting failure lets the caller fall back to the
  -- text pulled out at import, which is better than nothing at all.
  if not self.script and not self.dialogue and not machine.said_something then
    return false
  end
  return true
end

--- Push the running script along until it needs the player or finishes.
function game:advance_script()
  local machine = self.script
  if not machine then
    return
  end

  -- Bounded, because a script that only ever asks for prompts would otherwise
  -- spin here rather than at the interpreter's own step limit.
  for _ = 1, 64 do
    local status = machine:resume()

    if status ~= "waiting" then
      -- Anything the interpreter would not carry out is worth saying out loud
      -- rather than leaving the player facing a silent NPC.
      if status == "unsupported" then
        self:notify(("Script stopped at %s."):format(
          tostring(machine.stopped_on)))
      end
      self.script = nil
      return
    end

    local pending = machine.pending
    if pending and pending.kind == "text" then
      self.dialogue = { pages = pending.pages, page = 1 }
      return
    end
    -- A prompt has nothing of its own to draw, so it just carries on.
  end

  self.script = nil
end

--- The script the player is facing, if any.
-- @return the entry address
function game:facing_script()
  local delta = FACING_DELTA[self.player.facing]
  local x = self.player.cell_x + delta[1]
  local y = self.player.cell_y + delta[2]

  for _, bg in ipairs(self.map.bg_events or {}) do
    if bg.x == x and bg.y == y and bg.script
      and bg.kind ~= events_module.BGEVENT_ITEM then
      return bg.script
    end
  end
  for _, object in ipairs(self.map.objects or {}) do
    if object.x == x and object.y == y and object.script
      and not object.trainer and not object.item then
      return object.script
    end
  end
  return nil
end

--- The hidden item the player is facing, if it is still there.
--
-- These are background events, so they are found the same way a signpost is
-- read: stand in front and press the button. The real game wants the Itemfinder
-- to tell you a spot is worth trying, which is a hint rather than a lock.
function game:facing_hidden()
  local delta = FACING_DELTA[self.player.facing]
  local x = self.player.cell_x + delta[1]
  local y = self.player.cell_y + delta[2]

  for _, bg in ipairs(self.map.bg_events or {}) do
    if bg.x == x and bg.y == y and bg.hidden
      and not self.found[bg.hidden.flag] then
      return bg.hidden
    end
  end
  return nil
end

--- Turn up a hidden item.
function game:take_hidden(block)
  local name = self.item_names and self.item_names[block.item]
    or ("item %d"):format(block.item)

  if self.bag:add(block.item, 1) < 1 then
    self:say({ "You have no room for", ("the %s!"):format(name) })
    return false
  end

  -- Keyed by the cartridge's own event flag here, unlike the item balls. The
  -- flags are distinct across all but one pair, and that pair is the same item
  -- reachable from two squares, so sharing a key is the right behaviour.
  self.found[block.flag] = true
  self:say({ ("Found %s!"):format(name) })
  return true
end

--- The shopkeeper the player is facing, if there is one.
-- @return the mart index
function game:facing_mart()
  local delta = FACING_DELTA[self.player.facing]
  local x = self.player.cell_x + delta[1]
  local y = self.player.cell_y + delta[2]

  for _, object in ipairs(self.map.objects or {}) do
    if object.x == x and object.y == y and object.mart then
      return object.mart
    end
  end
  return nil
end

game.MART_ENTRIES = { "BUY", "SELL", "QUIT" }

--- Open a shop's counter: buy, sell, or leave.
function game:open_mart(index)
  if not self.marts[index] then
    return false
  end
  self.ui = { kind = "mart_menu", mart = index,
              list = menu.new(game.MART_ENTRIES, #game.MART_ENTRIES) }
  return true
end

--- What the shop has for sale.
function game:open_mart_buy(index)
  local list = self.marts[index]
  if not list then
    return false
  end

  local labels, stock = {}, {}
  for position, item in ipairs(list) do
    local record = self.item_records and self.item_records[item]
    local name = self.item_names and self.item_names[item] or ("item " .. item)
    local price = record and record.price or 0
    stock[position] = { item = item, name = name, price = price }
    -- Right-aligned prices would need a width the font does not expose, so the
    -- name is padded instead, by glyphs rather than by bytes.
    local shown = self:truncate(name, 13)
    labels[position] = ("%s%s¥%d")
      :format(shown, (" "):rep(13 - #self:encode(shown) + 1), price)
  end

  self.ui = { kind = "mart", mart = index, stock = stock,
              list = menu.new(labels, 6) }
  return true
end

--- What the shop will take off you.
function game:open_mart_sell(index)
  local contents = self.bag:sellable()
  local labels = {}
  for position, entry in ipairs(contents) do
    -- Nine glyphs of name, then the count and what the shop pays. That is what
    -- fits across 160 pixels once the cursor column is taken out.
    local name = self:truncate(entry.name, 9)
    labels[position] = ("%s%s x%-2d ¥%d")
      :format(name, (" "):rep(9 - #self:encode(name)), entry.count, entry.price)
  end
  self.ui = { kind = "sell", mart = index, contents = contents,
              list = menu.new(labels, 6) }
  return true
end

--- Sell some number of whatever the cursor is on.
function game:sell_item(entry, amount)
  amount = amount or 1
  if not self.bag:remove(entry.item, amount) then
    return false
  end

  self.money = self.money + entry.price * amount
  self:notify(("Sold %d %s. ¥%d now."):format(amount, entry.name, self.money))

  -- The list has changed underneath the cursor. An emptied bag goes back to the
  -- counter rather than showing nothing.
  if #self.bag:sellable() > 0 then
    self:open_mart_sell(self.ui.mart)
  else
    self:open_mart(self.ui.mart)
  end
  return true
end

--- Buy some number of whatever the cursor is on.
function game:buy_item(entry, amount)
  amount = amount or 1
  local cost = entry.price * amount

  if self.money < cost then
    self:say({ "You don't have", "enough money." })
    return false
  end

  local taken = self.bag:add(entry.item, amount)
  if taken < amount then
    -- Put back whatever did fit rather than charging for a partial sale.
    if taken > 0 then
      self.bag:remove(entry.item, taken)
    end
    self:say({ "You can't carry any", ("more %s."):format(entry.name) })
    return false
  end

  self.money = self.money - cost
  self:notify(("Bought %d %s. ¥%d left."):format(amount, entry.name,
    self.money))
  return true
end

-- How many of something the player could take on, given the price, what is
-- already held, and what a stack will hold.
function game:affordable(entry)
  return bag.affordable(entry.price, self.money, self.bag:room_for(entry.item))
end

--- Ask how many, before buying or selling.
function game:open_quantity(mode, entry)
  local most = mode == "buy" and self:affordable(entry)
    or math.min(bag.MAX_STACK, self.bag:count(entry.item))

  if most < 1 then
    if mode == "buy" and self.bag:count(entry.item) >= bag.MAX_STACK then
      self:say({ "You can't carry any", ("more %s."):format(entry.name) })
    else
      self:say({ "You don't have", "enough money." })
    end
    return false
  end

  self.ui = { kind = "quantity", mode = mode, entry = entry, amount = 1,
              most = most, mart = self.ui.mart }
  return true
end

--- Move the quantity dial. Up and down step by one and wrap, the way the games
-- do; left and right jump by ten and stop at the ends.
function game:quantity_move(delta, wrap)
  local ui = self.ui
  if wrap then
    ui.amount = (ui.amount - 1 + delta) % ui.most + 1
  else
    ui.amount = math.max(1, math.min(ui.most, ui.amount + delta))
  end
end

--- Go through with whatever the quantity prompt was asking about.
function game:quantity_confirm()
  local ui = self.ui
  local mode, entry, amount = ui.mode, ui.entry, ui.amount
  local mart = ui.mart

  if mode == "buy" then
    if self:buy_item(entry, amount) then
      self:open_mart_buy(mart)
    end
    return
  end

  self:sell_item(entry, amount)
end

--- Pick up an item ball.
function game:take_item(block, key)
  local name = self.item_names and self.item_names[block.item]
    or ("item %d"):format(block.item)

  local taken = self.bag:add(block.item, block.quantity)
  if taken < block.quantity then
    -- The ball stays on the ground, the way it does when the bag is full.
    self:say({ "You have no room for", ("the %s!"):format(name) })
    return false
  end

  self.taken[key] = true
  self:say({ ("Found %s!"):format(name) })
  return true
end

--- Put some lines of our own into the text box.
--
-- Dialogue read from the cartridge carries both the rendered string and the
-- character codes behind it, because the bitmap font draws codes rather than
-- text. Lines written here have to be encoded the same way or the font is
-- handed a nil.
function game:say(lines)
  local page = {}
  for index, line in ipairs(lines) do
    page[index] = { text = line, codes = self:encode(line) }
  end
  self.dialogue = { pages = { page }, page = 1 }
end

--- Build a trainer's party from the cached class tables.
-- @return party, trainer name
function game:trainer_party(class, id)
  local roster = self.trainer_classes and self.trainer_classes[class]
  local record = roster and roster[id]
  if not record then
    return nil
  end

  local party = {}
  for _, member in ipairs(record.party) do
    local base = self.base_stats and self.base_stats[member.species]
    if base then
      local instance = pokemon.new(member.species, base, { level = member.level })

      -- A trainer's Pokémon uses the moves the cartridge spells out where it
      -- does, and falls back to the species learnset where it does not.
      local known = {}
      for _, move in ipairs(member.moves or {}) do
        if move > 0 then
          known[#known + 1] = move
        end
      end
      instance.moves = #known > 0 and known
        or pokemon.moves_from_learnset(instance, self.learnset_records)
      instance.held_item = member.item

      party[#party + 1] = instance
    end
  end

  if #party == 0 then
    return nil
  end
  return party, record.name
end

--- Begin a trainer battle.
function game:start_trainer_battle(trainer)
  local party, name = self:trainer_party(trainer.class, trainer.id)
  if not party then
    self:notify(("no party for class %d trainer %d")
      :format(trainer.class, trainer.id))
    return false
  end

  local leader = self:party_leader()
  if not leader then
    return false
  end
  leader.hp = leader.stats.hp

  self.trainer = {
    flag = trainer.flag,
    class = trainer.class,
    id = trainer.id,
    name = name or "TRAINER",
    party = party,
    sent = 1,
  }

  self.battle = battle.new(leader, party[1], self.move_records or {},
    self.move_name_records or {}, self.species_names or {})
  self.battle_lines = {
    ("%s wants to fight!"):format(self.trainer.name),
    ("Sent out %s!"):format(self.species_names[party[1].species] or "?"),
  }
  self.battle_state = "message"
  self.battle_menu = 1
  return true
end

function game:interact()
  if self.battle then
    self:battle_advance()
    return
  end

  if self.dialogue then
    self.dialogue.page = self.dialogue.page + 1
    if self.dialogue.page > #self.dialogue.pages then
      self.dialogue = nil
      -- A script waiting on that text box carries on now it is closed.
      if self.script then
        self:advance_script()
      end
    end
    return
  end

  if self.player.moving then
    return
  end

  -- A trainer takes precedence: facing one starts a fight rather than a chat.
  local trainer = self:facing_trainer()
  if trainer and self:start_trainer_battle(trainer) then
    return
  end

  -- An item ball has no dialogue of its own; picking it up is the interaction.
  local block, key = self:facing_item()
  if block then
    self:take_item(block, key)
    return
  end

  -- A shopkeeper opens their counter rather than just saying their line.
  local mart = self:facing_mart()
  if mart and self:open_mart(mart) then
    return
  end

  -- A hidden item is a background event, so it comes before ordinary text:
  -- the square it sits on usually has something to say as well.
  local buried = self:facing_hidden()
  if buried then
    self:take_hidden(buried)
    return
  end

  -- Run the script if there is one. The text extracted at import is the
  -- fallback for the scripts the interpreter cannot start, so a signpost still
  -- reads even where the bytecode is beyond us.
  local addr = self:facing_script()
  if addr and self:run_script(self.map.script_bank, addr) then
    return
  end

  local pages = self:facing_text()
  if pages then
    self.dialogue = { pages = pages, page = 1 }
  end
end

function game:update(dt)
  -- Movement stops while a battle, a text box or a menu is up.
  if self.battle or self.dialogue or self.ui then
    return
  end

  if self.message_timer > 0 then
    self.message_timer = self.message_timer - dt
    if self.message_timer <= 0 then
      self.message = nil
    end
  end

  local event, cell_x, cell_y = self.player:update(dt, self:held_direction(),
    function(x, y)
      return self.world:can_enter(self.map, x, y)
    end)

  if event == "arrived" then
    -- Stepping off an edge into a connected map comes first, because the cell
    -- the player is now standing on does not exist on this map.
    local connection = self.world:connection_beyond(self.map, cell_x, cell_y)
    if connection then
      self:take_connection(connection, cell_x, cell_y)
      return
    end

    local warp = self.world:warp_at(self.map, cell_x, cell_y)
    if warp then
      self:take_warp(warp)
      return
    end

    -- Grass rolls for an encounter, and so does bare floor in a cave.
    local terrain = self.world:terrain(self.map, cell_x, cell_y)
    if wild.rolls_here(terrain, self.map.environment) then
      local met = wild.roll(self.map.encounters)
      if met then
        self:wild_encounter(met)
      end
    end
  end
end

--- Cross into a connected map, keeping the player's facing and momentum.
function game:take_connection(connection, cell_x, cell_y)
  local start = self.groups[connection.group]
  local index = start and (start + connection.number - 1)
  local destination = index and self.world:map(index)

  if not destination or destination.unparsed then
    -- Put the player back rather than stranding them off the edge.
    self.player:place(
      math.max(0, math.min(cell_x, self.map.width * world.CELLS_PER_BLOCK - 1)),
      math.max(0, math.min(cell_y, self.map.height * world.CELLS_PER_BLOCK - 1)))
    self:notify(("no map for group %d number %d")
      :format(connection.group, connection.number))
    return
  end

  local x, y = world.arrival(connection, cell_x, cell_y)

  -- Clamp, because the alignment can put the player just outside a map whose
  -- neighbour is wider than it is.
  x = math.max(0, math.min(x, destination.width * world.CELLS_PER_BLOCK - 1))
  y = math.max(0, math.min(y, destination.height * world.CELLS_PER_BLOCK - 1))

  self:enter(index, x, y, self.player.facing)
end

--- Follow a warp to its destination.
--
-- Warps name their target by map group and number plus which warp on that map
-- to arrive at, so this needs the group table the importer extracted. Without
-- it the destination cannot be resolved and the warp is reported instead of
-- taken.
function game:take_warp(warp)
  local group_start = self.groups[warp.destination_group]
  if not group_start then
    self:notify(("warp to group %d map %d: group table missing")
      :format(warp.destination_group, warp.destination_map))
    return
  end

  local index = group_start + warp.destination_map - 1
  local destination = self.world:map(index)
  if not destination or destination.unparsed then
    self:notify(("warp to group %d map %d: map did not decode")
      :format(warp.destination_group, warp.destination_map))
    return
  end

  -- Arrive standing on the warp the destination names.
  local arrival = (destination.warps or {})[warp.destination_warp]
  if arrival then
    self:enter(index, arrival.x, arrival.y)
  else
    self:enter(index)
  end
  self:notify(("map %d  %dx%d  %s"):format(index, destination.width,
    destination.height, destination.environment or "?"))
end

--- A wild Pokémon appeared.
--
-- There is no battle yet, so this announces the encounter through the text box.
-- When the battle engine exists this is where it hands over.
game.PARTY_LIMIT = 6

--- The player's party.
--
-- There is no save file and no starter choice yet, so it begins as one
-- Cyndaquil, built the moment it is first needed. Caught Pokémon join it.
function game:party_leader()
  self.party = self.party or {}

  if #self.party == 0 then
    local base = self.base_stats and self.base_stats[155]
    if not base then
      return nil
    end
    local starter = pokemon.new(155, base, { level = 10 })
    starter.moves = pokemon.moves_from_learnset(starter, self.learnset_records)
    self.party[1] = starter
  end

  -- The first member still standing leads.
  for _, member in ipairs(self.party) do
    if member.hp > 0 then
      return member
    end
  end
  return self.party[1]
end

--- Add a caught Pokémon to the party.
-- @return true when it joined, false when the party is full
function game:add_to_party(instance)
  self.party = self.party or {}
  if #self.party >= game.PARTY_LIMIT then
    return false
  end
  self.party[#self.party + 1] = instance
  return true
end

function game:wild_encounter(met)
  local base = self.base_stats and self.base_stats[met.species]
  local leader = self:party_leader()
  if not base or not leader then
    return
  end

  local opponent = pokemon.wild(met.species, base, met.level)
  opponent.moves = pokemon.moves_from_learnset(opponent, self.learnset_records)

  -- Heal the player's Pokémon between encounters; there is nowhere to rest yet.
  leader.hp = leader.stats.hp

  self.battle = battle.new(leader, opponent, self.move_records or {},
    self.move_name_records or {}, self.species_names or {})
  self.battle_lines = {
    ("Wild %s appeared!"):format(self.species_names[met.species] or "?"),
  }
  if opponent.shiny then
    self.battle_lines[#self.battle_lines + 1] = "It is shiny!"
  end

  -- The wild Pokémon's catch rate comes from its species record.
  self.battle_catch_rate = base.catch_rate or 255
  self.battle_state = "message"
  self.battle_menu = 1
end

game.BATTLE_ACTIONS = { "FIGHT", "BALL", "RUN" }

--- Throw a ball at the wild Pokémon.
function game:throw_ball()
  local opponent = self.battle.opponent

  -- The ball comes out of the bag now, so running out is a real outcome. Which
  -- ball, and therefore which multiplier, is whichever sits first in the ball
  -- pocket rather than an assumption that it is a plain Poke Ball.
  local ball = self.bag:first_ball()
  if not ball then
    -- Costs nothing: no ball leaves the bag and the turn is not spent.
    self.battle_lines = { "No BALLS left!" }
    return
  end

  local kind = catching.kind_for_name(ball.name)
  self.bag:remove(ball.item, 1)

  local caught, value = catching.attempt(opponent, self.battle_catch_rate, kind)

  local lines = { ("Used %s!"):format(ball.name) }

  if caught then
    if self:add_to_party(opponent) then
      lines[#lines + 1] = ("Caught %s!")
        :format(self.species_names[opponent.species] or "?")
      lines[#lines + 1] = ("Party: %d"):format(#self.party)
    else
      lines[#lines + 1] = "The party is full!"
    end
    self.battle.over = true
    self.battle.winner = "player"
  else
    local shakes = catching.shakes(value)
    if shakes == 0 then
      lines[#lines + 1] = "It missed entirely!"
    elseif shakes >= 3 then
      lines[#lines + 1] = "Almost had it!"
    else
      lines[#lines + 1] = ("It shook %d times."):format(shakes)
    end
    lines[#lines + 1] = "It broke free!"

    -- A failed throw costs the turn, so the wild Pokémon still attacks.
    local move = opponent.moves[math.random(1, math.max(#opponent.moves, 1))]
      or pokemon.STRUGGLE
    self.battle:strike(opponent, self.battle.player, move)
    for _, line in ipairs(self.battle.log) do
      lines[#lines + 1] = line
    end
  end

  self.battle_lines = lines
end

--- Cut a string to a number of glyphs, not a number of bytes.
--
-- "é" and "¥" are two bytes each in UTF-8, so string.sub counts them twice and
-- can cut one in half. That is how "POKé BALL" came out of a nine-byte trim as
-- "POKé BAL": eight letters where nine were asked for.
function game:truncate(str, glyphs)
  local out, count, i = {}, 0, 1
  while i <= #str and count < glyphs do
    local byte_value = str:byte(i)
    -- Two-byte sequences start with $C2 or $C3; nothing here needs more.
    local width = (byte_value == 0xC2 or byte_value == 0xC3) and 2 or 1
    out[#out + 1] = str:sub(i, i + width - 1)
    i = i + width
    count = count + 1
  end
  return table.concat(out)
end

--- Encode plain ASCII into the cartridge's character codes, so runtime messages
-- can be drawn with the same font as the cartridge's own text.
function game:encode(str)
  local codes = {}
  local i = 1
  while i <= #str do
    local char = str:sub(i, i)
    local byte_value = char:byte()

    -- "é" is two bytes in UTF-8, so it must be matched before the single-byte
    -- cases. It is $EA: that tile carries ink where $BA's is blank, which is
    -- what settled where the accent actually lives.
    if byte_value == 0xC3 and str:byte(i + 1) == 0xA9 then
      codes[#codes + 1] = 0xEA
      i = i + 2
      goto continue
    end

    -- "¥" is likewise two bytes in UTF-8, and prices are written with it.
    if byte_value == 0xC2 and str:byte(i + 1) == 0xA5 then
      codes[#codes + 1] = 0xF0
      i = i + 2
      goto continue
    end

    if char >= "A" and char <= "Z" then
      codes[#codes + 1] = 0x80 + byte_value - 65
    elseif char >= "a" and char <= "z" then
      codes[#codes + 1] = 0xA0 + byte_value - 97
    elseif char >= "0" and char <= "9" then
      codes[#codes + 1] = 0xF6 + byte_value - 48
    elseif char == " " then
      codes[#codes + 1] = 0x7F
    elseif char == "!" then
      codes[#codes + 1] = 0xE7
    elseif char == "." then
      codes[#codes + 1] = 0xE8
    elseif char == "/" then
      codes[#codes + 1] = 0xF3
    elseif char == "," then
      codes[#codes + 1] = 0xF4
    elseif char == "?" then
      codes[#codes + 1] = 0xE6
    elseif char == "-" then
      codes[#codes + 1] = 0xE3
    elseif char == "'" then
      codes[#codes + 1] = 0xE0
    elseif char == ":" then
      codes[#codes + 1] = 0x9C
    end

    i = i + 1
    ::continue::
  end
  return codes
end

--- Move the action cursor.
function game:battle_menu_move(delta)
  if not self.battle or self.battle_state ~= "menu" then
    return
  end
  local count = #game.BATTLE_ACTIONS
  self.battle_menu = ((self.battle_menu - 1 + delta) % count) + 1
end

--- Fight with the leader's first move.
function game:battle_fight()
  local leader = self.battle.player
  local opponent = self.battle.opponent
  local player_move = leader.moves[1] or pokemon.STRUGGLE
  -- The opponent picks at random; there is no battle AI yet.
  local opponent_move = opponent.moves[math.random(1, math.max(#opponent.moves, 1))]
    or pokemon.STRUGGLE

  self.battle_lines = self.battle:turn(player_move, opponent_move)
  if #self.battle_lines == 0 then
    self.battle_lines = { "Nothing happened." }
  end
end

--- Send out the trainer's next Pokémon, if they have one left.
-- @return true when another was sent, false when the trainer is beaten
function game:send_next_trainer_pokemon()
  local next_index = self.trainer.sent + 1
  local next_mon = self.trainer.party[next_index]

  if not next_mon then
    -- Out of Pokémon: the trainer is beaten, and stays beaten.
    self.beaten[self.trainer.flag] = true
    self.battle.over = true
    self.battle.winner = "player"
    self.battle_lines = {
      ("%s is out of"):format(self.trainer.name),
      "usable POKEMON!",
      ("%s won!"):format(self.trainer.name and "You" or "You"),
    }
    self.trainer = nil
    return true
  end

  self.trainer.sent = next_index
  self.battle.opponent = next_mon
  next_mon.stages = stages.new()
  self.battle_lines = {
    ("%s sent out"):format(self.trainer.name),
    ("%s!"):format(self.species_names[next_mon.species] or "?"),
  }
  return true
end

--- Advance the battle. A message waits for the player, then the action menu
-- appears; choosing an action produces the next message.
function game:battle_advance()
  if not self.battle then
    return
  end

  if self.battle.over then
    self.battle = nil
    self.battle_lines = nil
    self.battle_state = nil
    self.trainer = nil
    return
  end

  if self.battle_state == "message" then
    -- A trainer sends out the next Pokémon rather than losing outright.
    if self.trainer and self.battle.opponent.hp <= 0 then
      if self:send_next_trainer_pokemon() then
        return
      end
    end
    self.battle_state = "menu"
    return
  end

  local action = game.BATTLE_ACTIONS[self.battle_menu] or "FIGHT"
  if action == "FIGHT" then
    self:battle_fight()
  elseif action == "BALL" then
    if self.trainer then
      -- Balls are for wild Pokémon; a trainer's are not yours to take.
      self.battle_lines = { "Don't be a thief!" }
    else
      self:throw_ball()
    end
  elseif self.trainer then
    -- There is no running from a trainer.
    self.battle_lines = { "No running from a", "trainer battle!" }
  else
    -- Fleeing a wild battle always works for now. The real game weighs speed
    -- against the opponent's and counts attempts.
    self.battle_lines = { "Got away safely!" }
    self.battle.over = true
    self.battle.winner = "fled"
  end

  self.battle_state = "message"
end

--- Draw one health bar.
local function health_bar(x, y, width, current, maximum)
  love.graphics.setColor(0.1, 0.1, 0.1)
  love.graphics.rectangle("line", x - 0.5, y - 0.5, width + 1, 4)
  local fraction = math.max(0, current) / math.max(maximum, 1)
  love.graphics.setColor(0.1, 0.1, 0.1)
  love.graphics.rectangle("fill", x, y, math.floor(width * fraction), 3)
end

--- The battle screen, at the hardware's resolution.
function game:draw_battle()
  local leader = self.battle.player
  local opponent = self.battle.opponent

  love.graphics.clear(1, 1, 1)
  love.graphics.setColor(1, 1, 1)

  -- The opponent, drawn from its own front sprite.
  local sprite = self.world:species_sprite(opponent.species)
  if sprite then
    love.graphics.draw(sprite, game.SCREEN_WIDTH - sprite:getWidth() - 8, 6)
  end

  local function label(x, y, instance)
    local name = self.species_names[instance.species] or "?"
    if self.bitmap_font then
      self.bitmap_font:draw_codes(self:encode(name), x, y)
      self.bitmap_font:draw_codes(self:encode(("L%d"):format(instance.level)),
        x, y + 10)
    end
    health_bar(x, y + 21, 48, instance.hp, instance.stats.hp)
    if self.bitmap_font then
      self.bitmap_font:draw_codes(
        self:encode(("%d/%d"):format(instance.hp, instance.stats.hp)), x, y + 26)
    end
  end

  love.graphics.setColor(0.1, 0.1, 0.1)
  label(6, 8, opponent)
  label(88, 62, leader)

  -- The message box.
  local top = game.SCREEN_HEIGHT - 48
  love.graphics.setColor(1, 1, 1)
  love.graphics.rectangle("fill", 0, top, game.SCREEN_WIDTH, 48)
  love.graphics.setColor(0.1, 0.1, 0.1)
  love.graphics.rectangle("line", 2.5, top + 2.5, game.SCREEN_WIDTH - 5, 43)

  -- The action menu replaces the message while the player is choosing.
  if self.battle_state == "menu" and self.bitmap_font then
    for i, action in ipairs(game.BATTLE_ACTIONS) do
      local y = top + 6 + (i - 1) * 12
      self.bitmap_font:draw_codes(self:encode(action), 20, y)
      if i == self.battle_menu then
        love.graphics.setColor(0.1, 0.1, 0.1)
        love.graphics.rectangle("fill", 10, y + 2, 5, 5)
      end
    end
    love.graphics.setColor(1, 1, 1)
    return
  end

  -- The screen fits 19 glyphs at eight pixels each, so anything longer has to
  -- wrap rather than run off the edge.
  if self.bitmap_font then
    local wrapped = {}
    for _, line in ipairs(self.battle_lines or {}) do
      while #line > 19 do
        local cut = line:sub(1, 19):match(".*%s()") or 20
        wrapped[#wrapped + 1] = line:sub(1, cut - 1)
        line = line:sub(cut)
      end
      wrapped[#wrapped + 1] = line
    end

    -- Show the last four lines, so the most recent events stay visible.
    local first = math.max(1, #wrapped - 3)
    for i = first, #wrapped do
      self.bitmap_font:draw_codes(self:encode(wrapped[i]), 6,
        top + 6 + (i - first) * 10)
    end
  end

  love.graphics.setColor(1, 1, 1)
end

function game:draw(scale)
  local map = self.map

  local px, py = self.player:pixel_position(world.CELL_PIXELS)
  -- Centre the player, then clamp so the view never runs off the map.
  local camera_x = px - game.SCREEN_WIDTH / 2 + world.CELL_PIXELS / 2
  local camera_y = py - game.SCREEN_HEIGHT / 2 + world.CELL_PIXELS / 2
  camera_x = math.max(0, math.min(camera_x,
    map.width * world.BLOCK_PIXELS - game.SCREEN_WIDTH))
  camera_y = math.max(0, math.min(camera_y,
    map.height * world.BLOCK_PIXELS - game.SCREEN_HEIGHT))
  camera_x, camera_y = math.floor(camera_x), math.floor(camera_y)

  love.graphics.setCanvas(self.canvas)

  -- A battle replaces the overworld entirely.
  if self.battle then
    self:draw_battle()
    love.graphics.setCanvas()
    love.graphics.setColor(1, 1, 1)
    local bx = math.floor((love.graphics.getWidth() - game.SCREEN_WIDTH * scale) / 2)
    local by = math.floor((love.graphics.getHeight() - game.SCREEN_HEIGHT * scale) / 2)
    love.graphics.draw(self.canvas, bx, by, 0, scale, scale)
    return
  end

  love.graphics.clear(0, 0, 0)
  love.graphics.setColor(1, 1, 1)

  self.world:draw(map, camera_x, camera_y, game.SCREEN_WIDTH, game.SCREEN_HEIGHT)

  -- Warps, so doors are visible before overworld sprites exist.
  love.graphics.setColor(1, 0.4, 0.4, 0.5)
  for _, warp in ipairs(map.warps or {}) do
    love.graphics.rectangle("line",
      warp.x * world.CELL_PIXELS - camera_x + 0.5,
      warp.y * world.CELL_PIXELS - camera_y + 0.5,
      world.CELL_PIXELS - 1, world.CELL_PIXELS - 1)
  end

  -- NPCs. Sprites stand a little taller than their cell, so they are drawn
  -- shifted up by half a tile the way the original did.
  love.graphics.setColor(1, 1, 1)
  for index, object in ipairs(map.objects or {}) do
    local ox = object.x * world.CELL_PIXELS - camera_x
    local oy = object.y * world.CELL_PIXELS - camera_y - 4
    -- An item ball that has been picked up is gone from the map, not still
    -- lying there to be walked into.
    if object.item and self.taken[("%d:%d"):format(self.map_index, index)] then
      goto continue
    end
    if not self.world:draw_ow_sprite(object.sprite, ox, oy, "down") then
      love.graphics.setColor(0.4, 0.6, 1, 0.75)
      love.graphics.rectangle("fill", ox + 3, oy + 7,
        world.CELL_PIXELS - 6, world.CELL_PIXELS - 6)
      love.graphics.setColor(1, 1, 1)
    end
    ::continue::
  end

  -- The player. Sprite 1 is the player character.
  love.graphics.setColor(1, 1, 1)
  if not self.world:draw_ow_sprite(1, px - camera_x, py - camera_y - 4,
    self.player.facing) then
    love.graphics.rectangle("fill",
      px - camera_x + 2, py - camera_y + 2,
      world.CELL_PIXELS - 4, world.CELL_PIXELS - 4)
    love.graphics.setColor(0.1, 0.1, 0.1)
    local notch = {
      up = { 6, 0 }, down = { 6, 10 }, left = { 0, 6 }, right = { 10, 6 },
    }
    local offset = notch[self.player.facing]
    love.graphics.rectangle("fill",
      px - camera_x + 3 + offset[1], py - camera_y + 3 + offset[2], 4, 4)
  end

  -- The text box, drawn inside the canvas so it scales with everything else.
  if self.dialogue then
    local top = game.SCREEN_HEIGHT - BOX_HEIGHT
    love.graphics.setColor(1, 1, 1)
    love.graphics.rectangle("fill", 0, top, game.SCREEN_WIDTH, BOX_HEIGHT)
    love.graphics.setColor(0.1, 0.1, 0.1)
    love.graphics.rectangle("line", 2.5, top + 2.5,
      game.SCREEN_WIDTH - 5, BOX_HEIGHT - 5)

    local page = self.dialogue.pages[self.dialogue.page] or {}

    if self.bitmap_font then
      local line_height = self.bitmap_font:height() + 4
      for i, line in ipairs(page) do
        self.bitmap_font:draw_codes(line.codes, BOX_MARGIN,
          top + 8 + (i - 1) * line_height)
      end
    else
      local previous_font = love.graphics.getFont()
      love.graphics.setFont(self.font)
      local line_height = self.font:getHeight() + 1
      for i, line in ipairs(page) do
        love.graphics.print(line.text, BOX_MARGIN, top + 6 + (i - 1) * line_height)
      end
      love.graphics.setFont(previous_font)
    end

    -- The little marker showing there is more to read.
    if self.dialogue.page < #self.dialogue.pages then
      love.graphics.setColor(0.1, 0.1, 0.1)
      love.graphics.rectangle("fill", game.SCREEN_WIDTH - 10,
        game.SCREEN_HEIGHT - 10, 4, 4)
    end
    love.graphics.setColor(1, 1, 1)
  end

  -- Menus sit over the overworld, so the world stays visible behind the
  -- start menu the way it does in the original.
  if self.ui then
    self:draw_menu()
  end

  love.graphics.setCanvas()

  -- Scale up by whole pixels only.
  love.graphics.setColor(1, 1, 1)
  local offset_x = math.floor((love.graphics.getWidth() - game.SCREEN_WIDTH * scale) / 2)
  local offset_y = math.floor((love.graphics.getHeight() - game.SCREEN_HEIGHT * scale) / 2)
  love.graphics.draw(self.canvas, offset_x, offset_y, 0, scale, scale)

  if self.message then
    love.graphics.setColor(0, 0, 0, 0.7)
    love.graphics.rectangle("fill", 0, love.graphics.getHeight() - 28,
      love.graphics.getWidth(), 28)
    love.graphics.setColor(1, 1, 1)
    love.graphics.print(self.message, 10, love.graphics.getHeight() - 20)
  end
end

return game
