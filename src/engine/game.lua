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

  instance:enter(start_index or instance:default_map())
  return instance
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
function game:show_first_encounter()
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
              -- Run one turn so the screenshot shows a battle in progress
              -- rather than only the opening line.
              if self.battle then
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
function game:interact()
  if self.battle then
    self:battle_advance()
    return
  end

  if self.dialogue then
    self.dialogue.page = self.dialogue.page + 1
    if self.dialogue.page > #self.dialogue.pages then
      self.dialogue = nil
    end
    return
  end

  if self.player.moving then
    return
  end

  local pages = self:facing_text()
  if pages then
    self.dialogue = { pages = pages, page = 1 }
  end
end

function game:update(dt)
  -- Movement stops while a battle or a text box is up.
  if self.battle or self.dialogue then
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
--- Give the player a Pokémon to fight with.
--
-- There is no save file and no starter choice yet, so the party is one
-- Cyndaquil, built the moment it is first needed.
function game:party_leader()
  if not self.party_member then
    local base = self.base_stats and self.base_stats[155]
    if not base then
      return nil
    end
    self.party_member = pokemon.new(155, base, { level = 10 })
    self.party_member.moves =
      pokemon.default_moves(self.party_member, self.move_records or {})
  end
  return self.party_member
end

function game:wild_encounter(met)
  local base = self.base_stats and self.base_stats[met.species]
  local leader = self:party_leader()
  if not base or not leader then
    return
  end

  local opponent = pokemon.wild(met.species, base, met.level)
  opponent.moves = pokemon.default_moves(opponent, self.move_records or {})

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
  self.battle_menu = 1
end

--- Encode plain ASCII into the cartridge's character codes, so runtime messages
-- can be drawn with the same font as the cartridge's own text.
function game:encode(str)
  local codes = {}
  for i = 1, #str do
    local char = str:sub(i, i)
    local byte_value = char:byte()
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
  end
  return codes
end

--- Advance the battle: run a turn, or dismiss it once it is over.
function game:battle_advance()
  if not self.battle then
    return
  end

  if self.battle.over then
    self.battle = nil
    self.battle_lines = nil
    return
  end

  local leader = self.battle.player
  local opponent = self.battle.opponent
  local player_move = leader.moves[self.battle_menu] or leader.moves[1]
    or pokemon.STRUGGLE
  -- The opponent picks at random; there is no battle AI yet.
  local opponent_move = opponent.moves[math.random(1, math.max(#opponent.moves, 1))]
    or pokemon.STRUGGLE

  self.battle_lines = self.battle:turn(player_move, opponent_move)
  if #self.battle_lines == 0 then
    self.battle_lines = { "Nothing happened." }
  end
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
  for _, object in ipairs(map.objects or {}) do
    local ox = object.x * world.CELL_PIXELS - camera_x
    local oy = object.y * world.CELL_PIXELS - camera_y - 4
    if not self.world:draw_ow_sprite(object.sprite, ox, oy, "down") then
      love.graphics.setColor(0.4, 0.6, 1, 0.75)
      love.graphics.rectangle("fill", ox + 3, oy + 7,
        world.CELL_PIXELS - 6, world.CELL_PIXELS - 6)
      love.graphics.setColor(1, 1, 1)
    end
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
