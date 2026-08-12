-- The Pokédex: which species have been seen, and which have been caught.
--
-- Two sets rather than one field with three states, because that is what the
-- games track and the two are recorded at different moments: a species is seen
-- the instant it appears on the other side of a battle, and caught only when it
-- ends up in the player's hands. Catching implies seeing — you cannot own one
-- you never met — and that implication lives here rather than at each of the
-- eight call sites, so no caller can register a catch and forget the sighting.
--
-- Nothing about the dex is read from the cartridge. What each species *is*
-- comes from the extracted tables; which ones this player has met is the
-- player's own history, so it belongs in the save.

local dex = {}
dex.__index = dex

--- @param count how many species this cache knows about
function dex.new(count)
  return setmetatable({
    count = count or 0,
    seen = {},
    caught = {},
  }, dex)
end

local function valid(self, species)
  return type(species) == "number" and species >= 1 and species <= self.count
end

--- Record a sighting. Returns true when this is the first.
function dex:see(species)
  if not valid(self, species) or self.seen[species] then
    return false
  end
  self.seen[species] = true
  return true
end

--- Record a catch. Returns true when this is the first.
--
-- Seeing follows from catching rather than being the caller's job to remember.
function dex:catch(species)
  if not valid(self, species) then
    return false
  end
  self.seen[species] = true
  if self.caught[species] then
    return false
  end
  self.caught[species] = true
  return true
end

function dex:is_seen(species)
  return self.seen[species] == true
end

function dex:is_caught(species)
  return self.caught[species] == true
end

local function tally(set)
  local total = 0
  for _, on in pairs(set) do
    if on then
      total = total + 1
    end
  end
  return total
end

function dex:seen_count()
  return tally(self.seen)
end

function dex:caught_count()
  return tally(self.caught)
end

--- The lowest-numbered species at or after `from` that has been seen.
-- Used to open the list on something worth looking at rather than at number 1
-- when the first hundred are blank.
function dex:first_seen(from)
  for species = from or 1, self.count do
    if self.seen[species] then
      return species
    end
  end
  return nil
end

--- Both sets as sorted lists, which is how they go into a save. Sparse numeric
-- keys round-trip more predictably as lists — the same choice the beaten
-- trainers and the hidden items make.
function dex:to_lists()
  local seen, caught = {}, {}
  for species in pairs(self.seen) do
    seen[#seen + 1] = species
  end
  for species in pairs(self.caught) do
    caught[#caught + 1] = species
  end
  table.sort(seen)
  table.sort(caught)
  return seen, caught
end

--- Rebuild from what a save holds.
function dex.from_lists(count, seen, caught)
  local instance = dex.new(count)
  for _, species in ipairs(seen or {}) do
    instance:see(species)
  end
  for _, species in ipairs(caught or {}) do
    instance:catch(species)
  end
  return instance
end

return dex
