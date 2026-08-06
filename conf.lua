-- LOVE configuration. Runs before any module loads, so it cannot require
-- anything from src/.

function love.conf(t)
  t.identity = "gen2recomp"
  t.version = "11.4"
  t.console = false

  -- The Game Boy Color renders 160x144. We present an integer multiple of that
  -- so every source pixel maps to the same number of screen pixels; anything
  -- else produces uneven tile edges that are very visible on this art.
  t.window.title = "gen2recomp"
  t.window.width = 160 * 4
  t.window.height = 144 * 4
  t.window.resizable = true
  t.window.minwidth = 160
  t.window.minheight = 144
  t.window.vsync = 1

  -- Nothing here needs physics, and the touch ports do not want the extra
  -- modules resident.
  t.modules.physics = false
  t.modules.joystick = true
  t.modules.touch = true
end
