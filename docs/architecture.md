# Architecture

## The shape of the thing

Three layers, in dependency order:

```
src/rom/      decode cartridge bytes into Lua values   (knows the ROM format)
src/import/   orchestrate, validate, persist           (knows the cache format)
src/          the engine                               (knows neither)
```

The rule that keeps this honest: **the engine never sees a ROM.** It reads the
cache. That means the engine can be developed, tested, and modded without a
cartridge present, and it means a broken decoder shows up as a failed import
rather than as a subtly wrong battle calculation three months later.

## Cartridge handling

`src/rom/rom.lua` owns the image. It is loaded with plain Lua `io` (the file
lives wherever the player keeps it, not in the save directory), held for the
duration of one import, and dropped via `Rom:release()`.

Addressing follows the hardware. The SM83 sees bank 0 at `$0000-$3FFF` and the
switched bank at `$4000-$7FFF`, so `Rom:offset(bank, addr)` maps a far pointer
to a flat file offset — and treats an address below `$4000` as bank 0 regardless
of the bank byte beside it, which is the trap that catches most naive readers.

Gen 2 is MBC3 with a real-time clock. The RTC is not a detail we can ignore
later: the day/night cycle, Pokémon breeding timers, the Bug-Catching Contest,
and the daily event flags all read it.

## Why offsets are searched for, not hardcoded

See the README for the mechanism. The design reason is that a hardcoded offset
table has no failure mode — a wrong entry produces data, not an error. Signature
search plus whole-table validation plus spot checks has exactly one failure
mode, and it is loud.

The cost is that each new table needs a validator and a couple of spot checks
written before it can be extracted. That is the right trade: writing the
validator is how you find out you understood the format.

## Cache format

`cache/<game>/` holds generated Lua modules, one per table, plus PNGs for
graphics and a `manifest.lua` recording the dump's SHA-1, the discovered
offsets, and a `format_version`. When a decoder's output changes shape, bump
`cache.FORMAT_VERSION`; stale caches are re-imported rather than partially read.

Data is serialised as Lua source rather than a binary blob because it is
diffable. Comparing two imports — or an import against a disassembly — is a
routine operation while the decoders are being built.

## Two traps in the Gen 2 sprite format

Both cost real time to find, and neither fails loudly if you get it wrong.

**Pic pointers carry a biased bank.** Entries are `(bank, address)`, but every
pic lives in a contiguous run of high banks, so the stored bank is small and the
game adds a constant — `$36` in Crystal — before switching. A reader that
treats the byte as a literal bank finds nothing at all, which is at least
honest. `src/rom/pics.lua` tries the known constant first and solves for it
otherwise.

**Front pics are longer than their footprint.** A species' front pic does not
decompress to `width * height * 16` bytes. Crystal animates front sprites and
appends the extra frames inside the same compressed block, so species 1
decompresses to 688 bytes where its 5x5 footprint accounts for only 400. 250 of
251 species carry frames. The base sprite is the leading `width * height` tiles.
A validator demanding an exact size rejects the real table and then happily
accepts a false one 22 entries later.

A third trap is subtler: pic tiles are stored **column-major**. Laying them out
row-major yields a sprite that is recognisably the right creature and entirely
scrambled, which is easy to mistake for a palette problem.

## Palettes store two colours, not four

A sprite palette is white, two stored colours, then black. Only the middle pair
is in the ROM, so a record is four BGR555 words — a light/dark pair for the
normal palette and another for shiny — and the table is 8 bytes per species
rather than the 32 a four-colour palette would need.

Locating it needed the same structure-plus-known-content approach as the data
tables. Structure alone is too weak: "four 15-bit words" matches every
zero-filled region in the cartridge. The tempting extra constraint — that the
first colour of each pair is the brighter one — sounds like it must hold of a
light/dark pair and does not; enforcing it caps the longest run in the ROM at
98 records against the 251 needed. What settles it is hue: Bulbasaur is green,
Charmander red, Pikachu yellow.

Note that with only two colours stored, the light slot holds whatever dominates
the lit areas rather than the creature's "main" colour. Oddish's light colour is
the green of its leaves, not the blue of its body.

## Tilesets, and why block count is derived

A Gen 2 map is a grid of *blocks*, not tiles. A tileset supplies both halves of
the indirection: 8x8 tile graphics, and a block table where each block is a 4x4
arrangement of those tiles. Drawing a map is therefore map cell to block, block
to sixteen tiles.

The header is fifteen bytes — three far pointers (graphics, blocks, collision)
then three words (tile animation, an unused zero, palette map). The unused word
and the relationship between the block and collision pointers are what identify
the table: collision begins exactly where the block table ends.

That relationship is also how block count is obtained, because **it is not
stored anywhere**. Crystal's tilesets run to 64 or 128 blocks — 26 of the 31 use
64 — so assuming a constant finds almost nothing. Dividing the pointer gap by
the 16 bytes a block occupies gives the count directly, and the fact that the
gap is always a whole number of blocks is itself strong evidence the header was
read correctly.

Thirteen of the 31 tilesets index past the end of their own tile sheet. Those
tiles are loaded separately by the game — roofs vary by region, and some tiles
are shared across tilesets — so this is a known gap rather than a decoding
error. Blockset renders show it as blank 8x8 holes.

## Maps, and two records that validate each other

A map is described by two records in different places. A nine-byte header names
the tileset, environment and music and points at a twelve-byte attributes
record, which carries the border block, the dimensions in blocks, far pointers
to the block data and the script header, the event pointer, and a four-bit mask
saying which edges connect to neighbouring maps.

Block data is `width * height` bytes, one block id per cell, row-major. Each
block expands through the tileset into 4x4 tiles, so one map cell is 32x32
pixels.

The mutual dependency is what makes this findable without offsets. A header is
only credible if the attributes record it points at has sane dimensions and a
block pointer that resolves; the attributes record is only credible if its block
data fits in the ROM. Requiring a run of headers that all satisfy both is
already strong, and the confirmation is that **every block id in every map falls
inside the block count of the tileset its header names** — 384 maps, 36,535
blocks, no violations. Map headers and tileset headers are found by separate
searches in different banks, so that agreement is not something a wrong offset
produces.

### Validation finds the region; enumeration fills it

These must be separate steps, and conflating them was a real bug rather than an
untidiness.

Headers are addressed *by position*: a warp names its destination as a map group
plus an index counted from that group's first header. Four of Crystal's headers
fail the validator, appearing as a 36-byte gap between two runs. The first
version of this code simply omitted them — which shifted every later map down by
four and silently rewired the warp graph. It looked fine: the maps all rendered,
the block ids all checked out, and 75 warps quietly pointed at the wrong
buildings.

What caught it was walking the whole warp graph and asking whether each
destination actually contains the arrival warp it names. Fixing the enumeration
took the failures from 75 to 6.

So the runs are now used only to find where the table begins and ends, and every
nine-byte slot in that span becomes an entry. Slots that do not decode are kept
as placeholders with `attributes = nil`. 388 slots, 384 usable.

The general lesson: when data is addressed by position, dropping an
unparseable entry is far more damaging than keeping a broken one, because it
corrupts everything after it instead of just itself.

Two figures stay honest rather than asserted to zero. Eight warps lead into the
four undecodable headers. Six name an arrival index their destination lacks, and
that one is unexplained. Both are under half a percent, and the tests bound them
tightly enough that a regression trips.

## Event headers, and what a bounds check is actually for

Each map's attributes record points at an event header: two filler bytes, then
four counted arrays in a fixed order — warps (5 bytes each), coordinate triggers
(8), background events such as signposts (5), and object events, meaning NPCs
and ground items (13).

The order was never in doubt; the record sizes were. Rather than guess, every
plausible combination was tried against all 384 maps and scored on whether warps
and NPCs landed inside their own map's bounds. One combination parses 383 maps
and finds 1,296 warps. The near-misses parse a similar number of maps but find
*zero* warps — they are degenerate parses that read every count as zero and
never desynchronise because they never advance. Counting what a layout finds,
not just whether it survives, is what separates them.

Script-pointer positions were found the same way: read every byte offset in a
record as a 16-bit word and count how often it lands in the switchable bank
window. The real field is valid essentially always (100% for signposts and
triggers, 96% for objects, whose remainder is null), and every other offset is
far below that. Warps show no such field, correctly — they have no script.

Once the layout was settled the bounds check had done its job, and keeping it as
a hard error was wrong. Object count and record size are both fixed, so a stray
position cannot desynchronise anything, and one Crystal map really does place an
NPC outside its own dimensions. `events.decode` now flags such objects rather
than rejecting the map. The distinction matters generally: a test that discovers
a format is not automatically a good invariant to enforce afterwards.

Verification is visual and unambiguous. Rendering a map with warps, signposts
and NPCs overlaid puts every warp on a door, every signpost on a sign tile, and
every NPC on walkable ground. Coordinates read from a wrong offset scatter.

## Collision is provisional

`world.WALL_COLLISION = $07` and everything else is walkable. That is not right,
and the code says so.

The evidence for `$07` is strong and visual: tinting it across whole maps lands
it exactly on buildings, cliff faces and ledges. The evidence against treating
everything else as passable is equally clear — doors, water and rock faces are
distinct values that are not all walkable, and the current rule reports 58% of
all cells walkable, which is too generous.

Two attempts to derive the meaning of the remaining values did not settle it.
Surveying which values sit under the game's 1,300 warps and 1,466 NPCs — places
the player provably stands — returns thirty distinct values, and 466 NPCs
apparently stand on `$07` itself, which contradicts it being a wall. Testing
both quadrant orderings changed nothing (52% versus 50%), so the lookup is not
misindexed.

That contradiction is unresolved. It is good enough to walk around with and it
is not correct, which is why it is one constant with a comment rather than a
table pretending to authority.

## The engine reads only the cache

`src/engine/` never sees a cartridge. It loads what the importer wrote and
nothing else, which is what keeps a decoder bug showing up as a failed import
rather than as a subtly wrong game months later.

Three coordinate systems meet in the overworld and mixing them up is the easiest
mistake available: blocks are 32x32 pixels and index the map data, cells are
16x16 and are what the player walks on at two per block edge, and collision is
stored per cell as four bytes per block. Rendering goes to a 160x144 canvas —
the hardware's resolution — scaled by whole numbers only, because fractional
scaling makes tile edges visibly uneven on this art.

## What is not decided yet

- **Map representation.** Gen 2 maps are block-based: a tileset defines 4x4-tile
  blocks, and a map is a grid of block IDs plus a connections record. Whether
  the engine works in blocks or flattens to tiles at import time is open.
- **Script execution.** gen1recomp hand-writes map scripts as Lua. Gen 2 has
  substantially more of them across two regions. An alternative is to interpret
  the original script bytecode, which is far less work and far less moddable.
  This is the biggest open architectural question in the project.
- **Audio.** The Gen 2 sound engine is a bytecode sequencer driving four
  channels. Synthesising it at runtime from the extracted channel programs is
  the approach gen1recomp took and is almost certainly right here too.
