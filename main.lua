-- gen2recomp entry point.
--
-- With a cache present this boots the overworld. Without one it shows the
-- importer, which is also where you land after pressing escape.

local importer = require("src.import.importer")
local cache = require("src.import.cache")
local game_module = require("src.engine.game")

-- Headless entry points, since drag-and-drop cannot be scripted. Each module
-- exposes run(rom_path, report_path, extra).
local HEADLESS = {
  ["--test"] = "tests.harness",
  ["--import"] = "tests.run_import",
  ["--probe-pics"] = "tests.probe_pics",
  ["--probe-palettes"] = "tests.probe_palettes",
  ["--probe-tilesets"] = "tests.probe_tilesets",
  ["--probe-maps"] = "tests.probe_maps",
  ["--probe-connections"] = "tests.probe_connections",
  ["--probe-events"] = "tests.probe_events",
  ["--probe-collision"] = "tests.probe_collision",
  ["--probe-collision2"] = "tests.probe_collision2",
  ["--probe-ow-sprites"] = "tests.probe_ow_sprites",
  ["--probe-text"] = "tests.probe_text",
  ["--probe-font"] = "tests.probe_font",
  ["--probe-scripts"] = "tests.probe_scripts",
  ["--probe-walker"] = "tests.probe_walker",
  ["--probe-battle-data"] = "tests.probe_battle_data",
  ["--probe-trainers"] = "tests.probe_trainers",
  ["--probe-party-validator"] = "tests.probe_party_validator",
  ["--probe-items"] = "tests.probe_items",
  ["--probe-itemballs"] = "tests.probe_itemballs",
  ["--probe-marts"] = "tests.probe_marts",
  ["--probe-hidden"] = "tests.probe_hidden",
  ["--probe-vm"] = "tests.probe_vm",
  ["--probe-textfar"] = "tests.probe_textfar",
  ["--dump-tilesets"] = "tests.dump_tilesets",
  ["--dump-maps"] = "tests.dump_maps",
}

local state = {
  screen = "idle", -- idle | importing | report | error | playing
  lines = {},
  scroll = 0,
  pending_path = nil,
  game = nil,
  scale = 3,
  shot = nil,
}

local font

local function set_lines(str)
  state.lines = {}
  for line in (str .. "\n"):gmatch("(.-)\n") do
    state.lines[#state.lines + 1] = line
  end
  state.scroll = 0
end

local function first_cached_game()
  local games = cache.list_games()
  for _, entry in ipairs(games) do
    if entry.current then
      return entry.game
    end
  end
  return nil
end

local function start_game(game_id, map_index)
  local instance, why = game_module.new(game_id, map_index)
  if not instance then
    state.screen = "error"
    set_lines(("could not start the game\n\n%s\n\npress escape to go back")
      :format(tostring(why)))
    return false
  end
  state.game = instance
  state.screen = "playing"
  return true
end

local function show_idle()
  state.screen = "idle"
  state.game = nil

  local games = cache.list_games()
  local lines = { "gen2recomp", "" }

  if #games == 0 then
    lines[#lines + 1] = "Drag a Pokemon Gold, Silver, or Crystal cartridge image"
    lines[#lines + 1] = "onto this window to import it."
    lines[#lines + 1] = ""
    lines[#lines + 1] = "The image is verified, read once, and released. It is not"
    lines[#lines + 1] = "copied into the cache and it is not written anywhere on disk."
  else
    lines[#lines + 1] = "imported:"
    for _, entry in ipairs(games) do
      lines[#lines + 1] = ("  %s%s"):format(entry.manifest.name or entry.game,
        entry.current and "" or "  (stale cache, re-import needed)")
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "press enter to walk around"
    lines[#lines + 1] = "drag another cartridge onto the window to re-import"
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = ("cache: %s"):format(cache.location())
  set_lines(table.concat(lines, "\n"))
end

function love.load(args)
  args = args or {}

  for i, value in ipairs(args) do
    local module = HEADLESS[value]
    if module then
      local rom_path, report_path = args[i + 1], args[i + 2]
      -- A crash here would otherwise be swallowed by LOVE's error screen, which
      -- nothing is watching in headless mode.
      local ok, result = xpcall(function()
        return require(module).run(rom_path, report_path, args[i + 3])
      end, debug.traceback)
      if not ok then
        local fh = io.open(report_path, "w")
        if fh then
          fh:write("harness crashed:\n" .. tostring(result) .. "\n")
          fh:close()
        end
      end
      love.event.quit((ok and result) and 0 or 1)
      return
    end

    -- Render one frame of the overworld to a PNG and exit, so the engine can be
    -- checked without a human at the keyboard.
    if value == "--shot" then
      state.shot = {
        path = args[i + 1],
        map_index = tonumber(args[i + 2]),
        sign = (args[i + 2] == "sign" or args[i + 2] == "npc"
          or args[i + 2] == "grass" or args[i + 2] == "catch"
          or args[i + 2] == "catchsave" or args[i + 2] == "party"
          or args[i + 2] == "menu" or args[i + 2] == "connection"
          or args[i + 2] == "trainer" or args[i + 2] == "bag"
          or args[i + 2] == "pocket" or args[i + 2] == "balls"
          or args[i + 2] == "item" or args[i + 2] == "itemgone"
          or args[i + 2] == "mart" or args[i + 2] == "buy"
          or args[i + 2] == "sell" or args[i + 2] == "hidden"
          or args[i + 2] == "hiddengone" or args[i + 2] == "quantity"
          or args[i + 2] == "bulk" or args[i + 2] == "script")
          and args[i + 2] or nil,
        frames = 2,
      }
    end
  end

  love.window.setTitle("gen2recomp")
  love.keyboard.setKeyRepeat(false)
  font = love.graphics.newFont(13)
  love.graphics.setFont(font)
  love.graphics.setDefaultFilter("nearest", "nearest")

  local game_id = first_cached_game()
  if game_id then
    if not start_game(game_id, state.shot and state.shot.map_index) then
      return
    end
    if state.shot and state.shot.sign == "script" then
      state.game:show_script_demo()
    elseif state.shot and (state.shot.sign == "hidden"
      or state.shot.sign == "hiddengone") then
      state.game:show_hidden_demo(state.shot.sign == "hiddengone")
    elseif state.shot and (state.shot.sign == "mart"
      or state.shot.sign == "buy" or state.shot.sign == "sell"
      or state.shot.sign == "quantity" or state.shot.sign == "bulk") then
      state.game:show_mart_demo(state.shot.sign ~= "mart" and state.shot.sign
        or nil)
    elseif state.shot and (state.shot.sign == "item"
      or state.shot.sign == "itemgone") then
      state.game:show_item_demo(state.shot.sign == "itemgone")
    elseif state.shot and state.shot.sign == "balls" then
      state.game:open_pocket("balls")
    elseif state.shot and state.shot.sign == "pocket" then
      state.game:open_pocket("items")
    elseif state.shot and state.shot.sign == "bag" then
      state.game:open_bag()
    elseif state.shot and state.shot.sign == "trainer" then
      state.game:show_trainer_demo()
    elseif state.shot and state.shot.sign == "connection" then
      state.game:show_connection_demo()
    elseif state.shot and state.shot.sign == "party" then
      state.game:show_party_demo()
    elseif state.shot and state.shot.sign == "menu" then
      state.game:open_menu()
    elseif state.shot and (state.shot.sign == "grass" or state.shot.sign == "catch"
      or state.shot.sign == "catchsave") then
      state.game:show_first_encounter(state.shot.sign)
    elseif state.shot and state.shot.sign then
      state.game:show_first_sign(state.shot.sign)
    end
  else
    show_idle()
    if state.shot then
      love.event.quit(1)
    end
  end
end

function love.filedropped(file)
  state.pending_path = file:getFilename()
  state.screen = "importing"
  set_lines("importing...")
end

local function run_pending_import()
  local path = state.pending_path
  state.pending_path = nil

  local log = {}
  local report, err = importer.run(path, function(message)
    log[#log + 1] = message
  end)

  if not report then
    state.screen = "error"
    set_lines(table.concat({
      "import failed", "", err, "", "log:",
      "  " .. table.concat(log, "\n  "), "", "press escape to go back",
    }, "\n"))
    return
  end

  state.screen = "report"
  set_lines(table.concat({
    importer.format_report(report), "",
    ("cache written to %s"):format(cache.location()), "",
    "press enter to walk around, escape to go back",
  }, "\n"))
end

function love.update(dt)
  if state.screen == "importing" and state.pending_path then
    run_pending_import()
  elseif state.screen == "playing" then
    state.game:update(dt)
  end
end

function love.keypressed(key)
  if state.screen == "playing" then
    -- A menu takes every key it recognises before anything else sees it.
    if state.game.ui and state.game:menu_key(key) then
      return
    end

    if key == "x" and not state.game.battle and not state.game.dialogue then
      state.game:open_menu()
    elseif key == "z" or key == "space" or key == "return" then
      state.game:interact()
    elseif state.game.battle and (key == "up" or key == "w") then
      state.game:battle_menu_move(-1)
    elseif state.game.battle and (key == "down" or key == "s") then
      state.game:battle_menu_move(1)
    elseif key == "escape" then
      show_idle()
    elseif key == "f5" then
      state.game:save()
    elseif key == "f11" then
      love.window.setFullscreen(not love.window.getFullscreen())
    elseif key == "=" or key == "+" then
      state.scale = math.min(8, state.scale + 1)
    elseif key == "-" then
      state.scale = math.max(1, state.scale - 1)
    end
    return
  end

  if key == "escape" then
    if state.screen == "idle" then
      love.event.quit()
    else
      show_idle()
    end
  elseif key == "return" then
    local game_id = first_cached_game()
    if game_id then
      start_game(game_id)
    end
  elseif key == "up" then
    state.scroll = math.max(0, state.scroll - 1)
  elseif key == "down" then
    state.scroll = math.min(math.max(0, #state.lines - 1), state.scroll + 1)
  end
end

function love.wheelmoved(_, dy)
  if state.screen ~= "playing" then
    state.scroll = math.max(0, math.min(math.max(0, #state.lines - 1),
      state.scroll - dy * 3))
  end
end

function love.draw()
  if state.screen == "playing" then
    love.graphics.clear(0.02, 0.02, 0.03)
    state.game:draw(state.scale)

    if state.shot then
      state.shot.frames = state.shot.frames - 1
      if state.shot.frames <= 0 then
        local data = state.game.canvas:newImageData()
        local fh = io.open(state.shot.path, "wb")
        if fh then
          fh:write(data:encode("png"):getString())
          fh:close()
        end
        love.event.quit(0)
      end
    end
    return
  end

  love.graphics.clear(0.06, 0.07, 0.09)
  local line_height = font:getHeight() + 4
  local visible = math.floor((love.graphics.getHeight() - 32) / line_height)

  love.graphics.setColor(0.85, 0.87, 0.9)
  for i = 1, visible do
    local line = state.lines[i + state.scroll]
    if not line then
      break
    end
    love.graphics.print(line, 16, 16 + (i - 1) * line_height)
  end
  love.graphics.setColor(1, 1, 1)
end
