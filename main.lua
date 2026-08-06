-- gen2recomp entry point.
--
-- At this stage the application is the importer and a viewer for what it
-- extracted. The engine will be layered on top once the data pipeline is
-- trustworthy; being able to read the decoded tables back is what makes that
-- judgement possible.

local importer = require("src.import.importer")
local cache = require("src.import.cache")

local state = {
  screen = "idle", -- idle | importing | report | error
  lines = {},
  scroll = 0,
  progress = {},
  message = nil,
  pending_path = nil,
}

local font

local function set_lines(str)
  state.lines = {}
  for line in (str .. "\n"):gmatch("(.-)\n") do
    state.lines[#state.lines + 1] = line
  end
  state.scroll = 0
end

local function describe_existing_caches()
  local games = cache.list_games()
  if #games == 0 then
    return nil
  end
  local lines = { "already imported:" }
  for _, entry in ipairs(games) do
    lines[#lines + 1] = ("  %s  %s%s"):format(
      entry.manifest.name or entry.game,
      entry.manifest.sha1 and entry.manifest.sha1:sub(1, 12) or "?",
      entry.current and "" or "  (stale cache format, re-import needed)"
    )
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = ("cache location: %s"):format(cache.location())
  return table.concat(lines, "\n")
end

local function show_idle()
  state.screen = "idle"
  local existing = describe_existing_caches()
  set_lines(table.concat({
    "gen2recomp",
    "",
    "Drag a Pokemon Gold, Silver, or Crystal cartridge image onto this",
    "window to import it.",
    "",
    "The image is verified, read once, and released. It is not copied",
    "into the cache and it is not written anywhere on disk.",
    "",
    existing or "nothing imported yet.",
  }, "\n"))
end

function love.load(args)
  -- Headless mode: `love . --test <rom> <report>` runs the decoder tests and
  -- exits. LOVE has no usable stdout on Windows, so the report is a file.
  local headless = {
    ["--test"] = "tests.harness",
    ["--import"] = "tests.run_import",
    ["--probe-pics"] = "tests.probe_pics",
  }
  for i, value in ipairs(args or {}) do
    local module = headless[value]
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
  end

  love.window.setTitle("gen2recomp")
  love.keyboard.setKeyRepeat(true)
  font = love.graphics.newFont(14)
  love.graphics.setFont(font)
  show_idle()
end

function love.filedropped(file)
  state.pending_path = file:getFilename()
  state.screen = "importing"
  state.progress = { "starting import" }
  set_lines("importing...")
end

--- The import runs on the frame after the drop so the "importing" screen is
-- actually painted first; it is fast enough that threading it would add more
-- complexity than it removes.
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
      "import failed",
      "",
      err,
      "",
      "log:",
      "  " .. table.concat(log, "\n  "),
      "",
      "press escape to go back",
    }, "\n"))
    return
  end

  state.screen = "report"
  set_lines(table.concat({
    importer.format_report(report),
    "",
    ("cache written to %s"):format(cache.location()),
    "",
    "press escape to go back",
  }, "\n"))
end

function love.update()
  if state.screen == "importing" and state.pending_path then
    run_pending_import()
  end
end

function love.keypressed(key)
  if key == "escape" then
    if state.screen == "idle" then
      love.event.quit()
    else
      show_idle()
    end
  elseif key == "up" then
    state.scroll = math.max(0, state.scroll - 1)
  elseif key == "down" then
    state.scroll = math.min(math.max(0, #state.lines - 1), state.scroll + 1)
  elseif key == "pageup" then
    state.scroll = math.max(0, state.scroll - 20)
  elseif key == "pagedown" then
    state.scroll = math.min(math.max(0, #state.lines - 1), state.scroll + 20)
  end
end

function love.wheelmoved(_, dy)
  state.scroll = math.max(0, math.min(math.max(0, #state.lines - 1), state.scroll - dy * 3))
end

function love.draw()
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

  if #state.lines > visible then
    love.graphics.setColor(0.4, 0.42, 0.46)
    love.graphics.print(
      ("%d/%d"):format(state.scroll + 1, #state.lines),
      love.graphics.getWidth() - 80,
      love.graphics.getHeight() - 24
    )
  end

  love.graphics.setColor(1, 1, 1)
end
