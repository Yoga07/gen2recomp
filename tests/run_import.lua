-- Headless import: runs the real pipeline and writes its report to a file.
--
--   love . --import <rom> <report>
--
-- The interactive path is drag-and-drop, which cannot be scripted, so this
-- exists to exercise the same code from the test scripts.

local importer = require("src.import.importer")
local cache = require("src.import.cache")

local run_import = {}

function run_import.run(rom_path, report_path)
  local log = {}
  local report, err = importer.run(rom_path, function(message)
    log[#log + 1] = message
  end)

  local lines = { "gen2recomp import", "rom: " .. tostring(rom_path), "" }
  for _, message in ipairs(log) do
    lines[#lines + 1] = "  " .. message
  end
  lines[#lines + 1] = ""

  if not report then
    lines[#lines + 1] = "FAILED: " .. tostring(err)
  else
    lines[#lines + 1] = importer.format_report(report)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "cache: " .. cache.location()
  end

  local fh = io.open(report_path, "w")
  if fh then
    fh:write(table.concat(lines, "\n") .. "\n")
    fh:close()
  end
  return report ~= nil
end

return run_import
