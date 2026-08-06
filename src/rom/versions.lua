-- Identification of the three Gen 2 cartridges.
--
-- Identification is deliberately layered. The cartridge header tells us which
-- game we have and is impossible to fake accidentally; the SHA-1 pins down the
-- exact revision, which matters because Gold/Silver rev 1 moved data around.
-- A hash we do not recognise is a warning, not a rejection: it means we cannot
-- assume revision-specific offsets, so the importer falls back to scanning.

local versions = {}

-- Title and game code as they appear at $0134 and $013F. Crystal's title field
-- famously reads "PM_CRYSTAL" rather than following the POKEMON_ pattern, and
-- its game code is the string "BYTE".
versions.games = {
  gold = {
    id = "gold",
    name = "Pokémon Gold",
    title = "POKEMON_GLD",
    game_codes = { AAUE = "usa", AAUD = "germany", AAUF = "france",
                   AAUI = "italy", AAUS = "spain", AAUJ = "japan" },
    default_bank_count = 128, -- 2 MiB
  },
  silver = {
    id = "silver",
    name = "Pokémon Silver",
    title = "POKEMON_SLV",
    game_codes = { AAXE = "usa", AAXD = "germany", AAXF = "france",
                   AAXI = "italy", AAXS = "spain", AAXJ = "japan" },
    default_bank_count = 128,
  },
  crystal = {
    id = "crystal",
    name = "Pokémon Crystal",
    title = "PM_CRYSTAL",
    game_codes = { BYTE = "usa_europe", BYTJ = "japan" },
    default_bank_count = 128,
  },
}

-- Revision fingerprints.
--
-- These SHA-1s come from public dump databases and have NOT been checked
-- against a cartridge here. Treat an entry as a hint that names a revision, not
-- as an authority: `identify` reports the computed hash either way, and a miss
-- only downgrades us to scan-based offset discovery. Add entries as dumps are
-- confirmed rather than trusting this table blindly.
versions.revisions = {
  ["f4cd194bdee0d04ca4eac29e09b8e4e9d818c133"] =
    { game = "crystal", region = "usa_europe", revision = 0, verified = false },
  ["f2f52230b536214ef7c9924f483392993e226cfb"] =
    { game = "crystal", region = "usa_europe", revision = 1, verified = false },
}

--- Match a parsed header against the known cartridges.
-- @param info table from header.parse
-- @param sha1 lowercase hex digest of the whole image, or nil
-- @return descriptor table, or nil plus a reason
function versions.identify(info, sha1)
  local game
  for _, candidate in pairs(versions.games) do
    if info.title == candidate.title then
      game = candidate
      break
    end
  end

  if not game then
    return nil, ("cartridge title %q is not Pokémon Gold, Silver, or Crystal")
      :format(info.title)
  end

  local region = game.game_codes[info.game_code]
  local fingerprint = sha1 and versions.revisions[sha1]

  if fingerprint and fingerprint.game ~= game.id then
    return nil, ("SHA-1 %s belongs to %s but the header says %s; the dump is " ..
      "inconsistent"):format(sha1, fingerprint.game, game.id)
  end

  return {
    game = game.id,
    name = game.name,
    region = region,
    region_known = region ~= nil,
    revision = fingerprint and fingerprint.revision or nil,
    revision_known = fingerprint ~= nil,
    sha1 = sha1,
    banks = info.banks,
  }
end

--- Human-readable one-liner for the launcher and the import log.
function versions.describe(descriptor)
  local parts = { descriptor.name }
  if descriptor.region_known then
    parts[#parts + 1] = ("(%s)"):format(descriptor.region)
  else
    parts[#parts + 1] = "(unrecognised region)"
  end
  if descriptor.revision_known then
    parts[#parts + 1] = ("rev %d"):format(descriptor.revision)
  else
    parts[#parts + 1] = "rev unknown"
  end
  return table.concat(parts, " ")
end

return versions
