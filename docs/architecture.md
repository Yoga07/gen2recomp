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
98 records against the 251 needed. What settles it is hue.

Note that with only two colours stored, the light slot holds whatever dominates
the lit areas rather than the creature's "main" colour. Oddish's light colour is
the green of its leaves, not the blue of its body.

### How weak "structure narrows it down" actually was

This section used to end at "what settles it is hue: Bulbasaur is green,
Charmander red, Pikachu yellow", and the module said in its own header that the
251-record run was "a signature nothing else in the cartridge satisfies".

Both claims were wrong, and neither was ever measured. Counting properly:

| | offsets surviving |
|---|---|
| 251 consecutive colour-shaped records | **34,026** |
| ...that are also green, red and yellow at 1, 4 and 25 | **461** |
| ...under all eight hues now checked | **1** |

The structural test is satisfied tens of thousands of times, because any stretch
of ROM where the top bit of every other byte happens to be clear qualifies —
which is most of a cartridge. So hue was carrying the entire decision, and three
hues left 461 candidates standing. **The locator returned the first of them**,
which on Crystal is the real table. It was right by scan order rather than by
validation, and every other search in this project would have refused.

What exposed it was running the locators against a cartridge they were never
meant to read. The palette search was the one thing that **accepted a Pokémon
Red image**, confidently and silently.

### Choosing more hues, and the six that had to be dropped

Fourteen species were proposed from outside this code and each was checked
against the located table before being trusted. **Six failed**, and they failed
for the reason recorded above rather than because anything was wrong: only two
colours are stored, and the light slot holds whatever dominates the lit areas.
Squirtle's reads yellow — its plastron. Lapras and Snorlax both read red,
Chikorita yellow, Porygon red, and Voltorb is grey enough that no channel leads.

Those are bad checks, not a bad table. Bending each expectation to match what
the table said would have turned the list into a fit to Crystal instead of a set
of facts about Pokémon, so they were dropped. The eight that survive — adding
Caterpie, Psyduck, Magikarp, Totodile and Celebi — take 461 to 1, and the
locator now collects every candidate and refuses when more than one survives,
which is the rule the rest of the project already followed.

The general lesson is the one this document keeps relearning, in a place nobody
had thought to look: **a validation step nobody has counted is a guess with good
manners.** "Structure narrows it down, known content decides" was true as far as
it went, and the number it left standing was 461.

## Refusing a cartridge this was never meant to read

The README claims that a dump which would decode into nonsense fails loudly.
That had been asserted for fifty commits without evidence, because the only
cartridge ever fed to the importer was the one it was written for.

The importer does refuse a Gen 1 image — on the **title string**, which is the
weakest check in the project and says nothing whatever about the searches. So
the test runs the searches directly, with the version gate out of the way.

A Gen 1 cartridge is the right adversary rather than random noise. It carries
species names in nearly the same encoding, padded to the same ten bytes, and
tables of its own for moves, items and base stats. It is exactly the dump that
would decode into plausible garbage if validation were only as strong as the
signature that found it — and **three of the six named tables do have their
signature occur in it**. `BULBASAUR` padded to ten bytes is in Pokémon Red,
because Gen 1 pads its names the same way.

All three are then thrown out by whole-table validation and the spot checks,
which is the claim being tested: the signature is the search, and the validation
is what makes the search safe. Seventeen locators, seventeen refusals — after
the palette one was fixed, which is how the weakness above was found in the
first place.

This is asserted in the suite rather than left as a probe, and it takes the
second cartridge as an optional argument so an ordinary run skips it:

```
scripts\test.ps1 -Rom <crystal> -Other <any non-Gen-2 cartridge>
```

**What this still does not establish** is the other half of the claim: that
Gold and Silver work from the same code path. Refusing a Gen 1 image says the
searches reject what they should reject; it says nothing about whether they
accept what they should accept. That needs a Gold or Silver ROM, and there is
not one on this machine.

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

## Finding uncompressed graphics

Overworld sprites resisted every technique that had worked so far. There is no
LZ block to index, so the trick that found the Pokémon pics does not apply, and
the graphics are not laid out in table order, so entries cannot be chained by
size either — that was tried under both two- and three-byte pointers and found
nothing. Constraining on field shape found no run remotely long enough for the
118 distinct sprite ids the game's NPCs use.

What worked was finding the data first, and the useful idea was how to
recognise it. The obvious test for "looks like art" — uses most of the palette,
no single colour dominant — is actively misleading, because **compressed data is
near-random and satisfies it perfectly**. Ranking banks that way just returns
the Pokémon pic banks at 100%.

Spatial coherence separates them. Neighbouring pixels in a drawing are usually
the same colour; in random bytes they agree about a quarter of the time.
Counting horizontal agreement across every tile in every bank put the overworld
sprites in the `$30`s and the font in `$3E`, which reduced the table search to
"where is there a long run of pointers into those banks".

### The size field is not the size

An entry is six bytes: address, VRAM allocation, bank, type, palette. Byte 2
reads `$C0` for almost every entry, which looks exactly like a length — twelve
tiles — and is not one. It is how much the game copies into VRAM, while the
graphic in ROM is twelve tiles for a standing sprite and twenty-four for a
walking one. Reading it as a ROM length finds seven entries and rejects the
rest.

The real extent comes from the gap to the next entry's address, the same way a
tileset's block count comes from the gap between its block and collision
pointers. Assuming `$C0` universally stops the table at 68 of 102 entries: still
sprites, such as an item lying on the ground, allocate `$40`.

## Text, and finding an opcode by what it points at

Dialogue was the one thing that needed no reverse engineering to *read*: the
charmap was already proven by decoding all 251 species and move names, so
scanning for long runs of readable bytes finds it directly. 4,825 strings, in
banks scattered across the cartridge.

Dialogue is not a bare string, though. It is a small bytecode: `$00` opens a
block, `$50` and `$57` close it, and the rest describe how the text box behaves
— `$4F` breaks a line, `$51` clears the box for a new page, `$58` waits for the
player. Rendering all of those as newlines would lose the difference between a
line break and a new box, so the decoder returns pages of lines and the engine
pages through them.

The interesting part was connecting scripts to that text without knowing a
single opcode. Every signpost already had a script pointer from the event
decoder. Taking those 792 scripts, looking for a two-byte pointer in their
opening bytes that landed on a string the scanner had already found, and asking
what byte sat immediately before it, gives the answer directly: `$53` accounts
for 193 hits and `$4C` for 15. `$53` is jumptext — show a message and end.

That trick generalises. When two structures are known and the mapping between
them is not, the mapping is often recoverable by looking at what sits next to
the known values.

### Choosing opcodes against a measured noise floor

A second text opcode was added by measuring rather than guessing. For every
opcode that commonly opens a script, count what fraction of its two-byte
operands decode as dialogue:

| opcode | decodes as text | |
| --- | --- | --- |
| `$53` | 215 of 289 | 74% |
| `$51` | 144 of 351 | 41% |
| `$6B` | 40 of 316 | 13% |
| `$47` | 8 of 96 | 8% |
| `$0C` | 1 of 152 | 0.7% |

`$0C` is the control. Its operands are plainly not addresses — they are small
ids — so its 0.7% is simply how often arbitrary bytes happen to decode as
dialogue. Having that baseline is what makes the rest interpretable: `$53` and
`$51` are unambiguous, and adding `$51` took coverage from 175 scripts to 377.

`$6B` and `$47` were left out. Thirteen percent is well clear of the noise
floor and they may take a text pointer in some form, but at that rate a
meaningful share of what they produced would be wrong, and dialogue attributed
to the wrong character is worse than no dialogue.

Names in the opcode table are descriptive, not authoritative. `$53` shows a
message and ends the script; `$51`'s semantics beyond "its operand is a text
pointer" are unknown, so it is called `showtext_51` rather than given a name it
might not deserve.

### Substitution codes

Dialogue embeds codes the text engine replaces at display time — `<PLAYER>`,
`<RIVAL>`, `POKé`, `TRAINER` and others — sharing the range with the layout
controls. A decoder that does not know them rejects any line containing one,
which is most of the interesting dialogue in the game: adding them took `$53`'s
hit rate from 159 of 289 to 215.

### What is honestly not done

377 of 2,200. Signposts are mostly a single instruction and mostly work; NPC
scripts branch, check flags, give items and move people around, and none of that
is interpreted. The decoder reads only the first instruction and returns nothing
rather than guessing, so what it produces is trustworthy and the rest is visibly
absent instead of quietly wrong.

## Inferring the opcode table

There is no operand-width table to read, and 256 opcodes at unknown widths is
far too large a space to guess in. What makes it tractable is that scripts are
stored back to back, so sorting the entry points within a bank gives each
script's extent from the gap to the next one.

That converts guessing into a constraint. A correct width is one where walking a
script consumes its extent *exactly* and stops on a terminating instruction;
wrong widths desynchronise and sail past the boundary. Widths can then be
learned:

- A script whose whole extent is one instruction fixes that opcode directly and
  marks it terminating. 633 scripts are exactly three bytes, which bootstraps
  the common openers at two operand bytes.
- With some widths known, a script that walks cleanly up to a single unknown
  fixes that one too.
- Repeat.

Every proposal is a vote, accepted only when several scripts agree and almost
none disagree, so one misread extent cannot poison the table. The result is 24
opcodes, and across 1,502 scripts with known extents: 764 walk to a terminator,
711 of those landing exactly on the boundary, and **zero overrun**. Zero
overruns is the real evidence — a wrong width shows up as a walk that runs past
the end of its script, and none do.

### Solving two unknowns at once does not work

The obvious next step is to break the deadlock on opcodes like `$6B`, which
opens 249 scripts and never once appears mid-script, so there is no position
from which its width can be read off alone. Searching for pairs of widths that
jointly explain a script sounds like the answer.

It was tried and it is much worse. Two free unknowns across widths 0-8 give
enough freedom that almost any script admits *some* assignment, and requiring
uniqueness barely filters it. The table it produced assigned six opcodes the
maximum width of 8 — the signature of a search fitting noise — lost the
correctly-learned `$51` and `$53`, and introduced 52 overruns where there had
been none.

The lesson is about the ratio of constraint to freedom. Single-unknown inference
works because one script pins one number. Two unknowns and one equation is
underdetermined, and dressing it up as a search does not add information.

### The inference was mostly wrong, and its own metric could not tell

Checked against the real table afterwards, the inference got **13 of 24 widths
wrong**. It reported zero overruns throughout.

That metric was vacuous, and the reason is worth keeping. Every opcode the
method could learn was marked *terminating*, because the only evidence available
was "this opcode accounts for the rest of the script". A walk that stops at its
first instruction can never run past the end of anything. The measure was
structurally incapable of failing, and it was presented as the main evidence
that the widths were right.

The right instinct, applied too late: ask what a metric would look like if the
thing it measures were broken. "Zero overruns" had the same value under a
correct table and under a table of nonsense.

With the real widths most opcodes continue rather than terminate, so overruns
become possible again and the number means something: 168 of 1,502, against
1,170 scripts walking to completion and 833 landing exactly on a boundary.

The parts the inference did get right are the ones the dialogue work rested on —
`$51` and `$53` at two operand bytes and terminating, `$0C` at two — so nothing
downstream was wrong. That is luck rather than method.

## The font, and the one hardcoded offset

The font is 1bpp: one byte per row, one bit per pixel. Reading it as 2bpp pairs
each glyph with its neighbour, one into each bitplane, and produces an alphabet
that is *almost* right — which looks like a palette problem and is a format
problem. A character's tile is its code minus `$40`.

**This is the only hardcoded offset in the project, and it is deliberate.**

Everything else is found by search, because a wrong hardcoded offset yields
plausible garbage rather than an error. The font defeated that. Ink density
alone matches 28 offsets. Adding spatial coherence left exactly one — in bank
`$5C`, and it was wrong, which is the worst possible outcome: a confident,
unique, incorrect answer. Adding letterform relations left three, none of them
the font.

The reason is structural. Every other table validates against something: a
length field, a pointer that must resolve, a second record that has to agree. A
font is just pixels, and plenty of other pixels look similar under every cheap
measure. There is nothing for a search to check itself against.

So the offset is asserted and then verified, and the blind search survives as a
fallback that reports loudly rather than guessing. The verification is
deliberately looser than the search heuristics — holding the real font to tuned
thresholds is exactly what rejected it.

Two method notes worth keeping. The bias was first read off a 128-pixel-wide
render by counting rows, which gave `$60` and was wrong by two rows; measuring
per-tile ink and looking for the blank space glyph gave `$40`. And the way it
was finally settled was rendering a string whose correct appearance was known —
"ROUTE 38", lifted from a signpost the script decoder had already read — at
every candidate bias and seeing which row came out legible. When a heuristic
keeps producing confident wrong answers, render the thing and look at it.

## Collision, and two wrong assumptions

Collision values are global terrain constants, classified in
`src/rom/collision.lua`: floor, tall grass, water, ledges, warps, furniture, and
everything else blocking. The walkable share of the world drops from 58% under
the old provisional rule to 44%, which is a far more believable number once
water, counters, ledges and cut trees stop counting as passable.

The earlier survey that could not settle this was asking the wrong question. It
counted what the game's NPCs stand on and found 466 of them apparently on `$07`,
seemingly disproving `$07` as wall. The flaw was the premise: NPCs are placed on
counters and furniture and behind blocking terrain all the time — a shop clerk
stands behind a counter, not on the floor — so "an NPC is here" was never
evidence that a tile is walkable.

Adopting the real constants then failed two tests, and both were the tests'
fault rather than the classification's.

**Doors are walls.** 544 of Crystal's 1,300 warps sit on `$07`. A door is a wall
tile with a warp on it; the player walks *into* it and the warp fires on the
attempt. So "every warp is walkable" is false, and the engine needs
`can_enter` — walkable, or carrying a warp — as distinct from `walkable`.

**Caves have no grass.** Only 25 of the 91 maps with encounter tables have any
grass tiles. Wild Pokémon in caves and dungeons appear on ordinary floor, so the
encounter check consults the map's environment as well as the terrain.

One thing remains unexplained and is left that way: 25 maps have grass tiles and
no encounter table. It is logged rather than asserted around, because picking a
threshold that happens to pass would hide it.

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

## Battles

The damage formula is integer arithmetic from end to end, because the hardware
had no other kind and the truncation is load-bearing — rounding at the wrong
step gives damage that is close and wrong.

    base   = (2 * level / 5 + 2) * power * attack / defence / 50
    crit   doubles that
    + 2
    STAB   x1.5 when the move shares a type with its user
    type   x2 or x0.5 per defending type, or x0
    spread x(217..255) / 255
    at least 1, unless the type chart said no effect

Type effectiveness is kept in tenths so the whole calculation stays in
integers, and a double weakness stays exact rather than accumulating float
error.

Two Gen 2 specifics that a table copied from a later generation would get
wrong, so both are asserted: **physical or special is decided by the move's
type, not per move** — everything from normal through steel is physical, fire
onwards is special — and **Dark is immune to Psychic**, with Ghost super
effective against it.

### Movesets are a stand-in

Level-up learnsets are not extracted yet. `pokemon.default_moves` picks damaging
moves whose type the species shares, strongest first, capped by level. That
produces a Pokémon that can fight and is not what the real game would give it.
Replacing it with real learnsets is the next battle-side job, and it is called a
stand-in in the code so nobody mistakes it for the real thing.

What else is absent, deliberately rather than by oversight: status conditions,
stat stages, move effects beyond damage, move priority, catching, items, and
switching. The battle loop is the skeleton those hang from.

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

## Saves are the engine's state, not the cartridge's

A save here is the engine's own state serialised as Lua, not Gen 2's SRAM
layout. Emulating SRAM would mean designing for data the engine does not have —
boxes, badges, money, the Pokédex — and binding the save to Crystal's structure
before there is anything to put in it. Reading a real `.sav` so a player can
import their own progress is a separate feature, and a worthwhile one.

Saves sit beside the cache but are not part of it, and the distinction matters:
the cache is derived from a cartridge and can be rebuilt by re-importing, while
a save is the only copy of what the player did. Clearing one must never clear
the other.

**Stats are deliberately not stored.** A Pokémon is its species, level and DVs,
and everything else follows, so the save keeps only those plus current HP and
recomputes the rest on load. That keeps saves small, and it means a correction
to the stat formula reaches saves already written instead of baking the old
numbers in permanently. Current HP is genuine state rather than derivation, so
it is stored — and clamped on load, in case a formula fix lowered the maximum
since.

A save whose `format_version` does not match is refused rather than
half-interpreted, the same rule the cache uses.

## Status and stat stages

Stat stages are a table, not a formula, and that is the point. The multipliers
are **not symmetric**: +1 is 150% but -1 is 66%, not 75%. Anyone deriving them
from `1 + n/2` gets the whole negative half subtly wrong, so the table is
transcribed and the asymmetry is asserted.

Two status effects deliberately sit outside the stage system. Burn halves attack
and paralysis quarters speed, and the game applies both where the stat is read
rather than as stages — so they stack with stages instead of competing with
them, and clearing the status restores the stat exactly.

Paralysis affecting speed is what makes it change *turn order*, not just how
often a Pokémon acts. That is easy to miss if speed is read raw when deciding
who goes first, and the test for it puts a paralysed Pokémon against an
identical unparalysed one.

Stages are per battle and are discarded when it ends. Status is not: it
persists, which is why it belongs on the Pokémon and gets saved.

### Effects that always happen, and effects that ride along

The move effect byte distinguishes these and the distinction matters. A plain
effect is the move's whole purpose and always applies — Thunder Wave only
paralyses. A `_HIT` effect accompanies damage and fires on the move's effect
chance, which is out of 255 rather than 100.

`src/engine/move_effects.lua` covers the status and stat-stage effects and
reports anything else as unmodelled rather than silently doing nothing. Most of
the hundred-odd effect values — multi-hit, recoil, drain, one-hit knockouts,
weather, protection, the many one-move specials — are still absent.

## Map connections

A connection record follows the attributes record, one per set bit in the
connection mask, in north/south/west/east order, twelve bytes each: destination
map group and number, a pointer into that map's block data, where the strip
lands in the overworld buffer, the strip length, the destination's width, two
alignment bytes, and a window pointer.

The connection macro was not in the files reachable from the reference, so the
layout was reasoned rather than read — and then **checked rather than trusted**.
Byte 7 is supposed to be the destination map's width, and every destination has
its own header saying what its width really is. Scoring all twelve byte
positions against that gives byte 7 at 142 of 142, with the next best at 31%.
That is not a layout anyone has to take on faith.

The two alignment bytes turn out to mean different things depending on which
one lies along the direction of travel. The one on the axis of travel is the
arrival coordinate outright — a west connection into a ten-block-wide map gives
19, its rightmost cell; a north connection into an eighteen-block-tall map gives
35, its bottom row. The perpendicular one is an offset added to where the player
was, which is what keeps them lined up when the two maps are different sizes.
Both can be negative, so they are read as signed bytes.

Crossing is checked before warps in the arrival handler, because once the player
has stepped over an edge the cell they occupy does not exist on the current map
and nothing else can be asked about it sensibly.

## Trainer battles

An object event packs a palette and an object type into one byte as two nibbles.
Which type value means "trainer" is a constant we do not have, so it was found
by asking which value's objects have a script that parses as a twelve-byte
trainer block: type 2 manages 332 of 333, and the other types none.

A trainer object's script points at that block rather than at bytecode — event
flag, class, id, then four text pointers — and the class and id reach a party
through a class table whose entries are near pointers to the first trainer of
each class.

Two mistakes are worth recording because both produced confident wrong answers.

**A loose validator makes a classifier look useless.** The first trainer-block
check only required class and id to be non-zero, and 812 of the 1134
non-trainer objects satisfied it. That made the type nibble appear to
discriminate nothing. Bounding class and id to real ranges cut it to 188.

**Reading a table until the first failure truncates it at the first awkward
entry.** The class table stops resolving at class 51 and then resumes: classes
55 to 57 are plainly real, holding KEITH, GRUNT and EUSINE. Stopping at the
first miss gave 50 classes; tolerating gaps and stopping after several
consecutive misses gives 56.

**One missing glyph costs a whole class.** The character map had no entry for
`$E9`, and the twins are stored as "AMY & MAY", so the walk through their class
stopped at the ampersand and every trainer after it became unreachable. Adding
it took the table from 56 classes to 57 and the walk from 508 trainers to 518.
The neighbouring `$EA` is the accented e; `$BA`, which had been carrying it,
draws a blank tile, so the font settled which byte was which. `$BA` to `$BF`
are still mapped, but as escapes rather than as glyphs to be trusted.

Every class now walks from its first entry to the start of the next without a
rejection, and the tests assert that at 100% rather than bounding it, because
the failure mode is silent: a truncated class looks exactly like a short one.
The only walk that stops early is the last, which runs into the zero padding at
the end of its bank.

### Where the table ends

The table holds 57 classes and that is all of them, ending on EUSINE. Map
objects name classes 58 to 62 and 66, and a contiguous block like that looks
much more like a truncated table than like noise, so it was worth checking. The
words at those positions read `$8085`, `$8A8B` and `$848D` — not near pointers
at all, but the text of the first class's names. Parties continuing in a later
bank were ruled out the same way.

### What is not reached

156 of 332 objects carrying the trainer type nibble agree with the class table.
That number used to read 274, and it fell because it stopped being wrong: the
walk to the id-th trainer of a class was unbounded, so an object asking for
class 25 id 10 — when class 25 is SABRINA and holds exactly one trainer — ran
past the end and returned a stranger's party rather than nothing.

The shortfall is not the party validator. Reading class and id from byte 2 of
the block resolves 156, against 47 for the next best offset and zero for most
others, so the layout is right and the remainder are not trainer blocks. They
are objects the type nibble puts in the trainer bucket whose script pointer
leads somewhere else, and the way to move the number is to classify them
properly, not to loosen what counts as agreement. The engine already treats a
non-resolving object as not a trainer, so these start no battle.

The tests assert this as a floor, so the number can be improved but cannot
quietly get worse.

## Items

Two tables, found in different ways because they offer different holds.

The names are text, so they go the way the move names went: "MASTER BALL" is
always item 1, and the names are packed with the terminator between them rather
than padded. It occurs once in the cartridge, at 0x1C8000, and 255 names read
out of it before the run stops on a byte that is not a character.

One thing had to change to read them. Item 5 is not stored as "POKE BALL" but
as `$54` followed by " BALL", `$54` being the single glyph that draws POKe — the
same substitution code the dialogue engine expands. The name validator only
accepted charmap bytes, so it rejected the table at its fifth record. Both the
validator and the decoder now take a flag for whether substitutions count as
characters, which is off for everything except item names.

### Finding a table with no text in it

The attributes have nothing to search for, so the anchor is the prices. Master
Ball is free, Ultra Ball is 1200, Great Ball 600 and Poke Ball 200, and those
four sit at known distances from each other. Searching for all four at once, at
every stride from 5 to 10, gives exactly one hit: stride 7 at 0x0067C1. Every
other stride gives nothing at all.

Five more prices were held back from the search and checked afterwards —
Antidote, Full Restore, Potion, Rare Candy, Full Heal — and all five land. They
are evidence precisely because they took no part in the fit.

### Reading the fields off the data

The seven bytes are price, held effect, parameter, property, pocket, menu. That
order was read off the cartridge rather than assumed, by dumping items whose
pocket is not in doubt and looking for the column where they disagree:

- **byte 5** takes only the values 1 to 4 across all 255 items, and a ball, a
  potion, a bicycle and a TM each take a different one. That is the pocket.
- **byte 3** is 20 for Potion and 10 for Berry, which is how much HP each
  restores. The parameter identifies itself.
- **byte 4** is only ever `00`, `40`, `80` or `C0`. The Bicycle is `$80` and the
  HMs are `$C0`, which fits registerable-but-untossable and neither.
- **byte 6** splits into two nibbles: balls are `$06`, usable in battle and
  useless outside, while a Potion is `$55`, usable in both.

Nothing in the engine is keyed on an item id. A Super Potion heals more than a
Potion because the cartridge says 60 against 20, and the pocket listing puts the
Heavy, Level, Lure, Fast, Friend, Moon, Love and Park balls with the other balls
without any of them being named in the code. Which multiplier a ball uses is the
one place a name is read, and only to tell Master, Ultra and Great from the
rest; the conditional balls fall through to the plain multiplier, which is what
they are worth when their condition is not met.

### The status cures, and a search that finds itself in a shop

An item's parameter says *how much* — a Potion's 20, a Super Potion's 60 — and
nothing in the engine is keyed on an item id because of it. The status cures
break that scheme: **an Antidote's parameter is 0**, because what it does is not
a quantity. For a long time those items were refused rather than guessed at, so
every Antidote in the game silently did nothing.

The missing half is fourteen three-byte records terminated by `$FF`:

```
09 F0 08   ANTIDOTE     poison
0A F1 10   BURN HEAL    burn
0B F2 20   ICE HEAL     freeze
0C F3 07   AWAKENING    sleep
0D F4 40   PARLYZ HEAL  paralysis
26 F6 FF   FULL HEAL    everything
```

The third byte is a mask over the Gen 2 status byte, which packs sleep into the
low three bits and gives poison, burn, freeze and paralysis one bit each above
them — which is why the masks are single bits and `$07`, and why `$FF` reads as
"all of it".

#### Where the ids are says almost nothing

The obvious search is "where do the curing items' ids appear together", and it
is close to worthless. **The five single-status cures are items 9, 10, 11, 12
and 13 — consecutive.** Every ascending run of bytes in two megabytes contains
all five, and so does every shop stocking a Pokémon Centre's worth of medicine.

The first run of this search returned three hits at stride 7, all of them inside
the mart lists, which is exactly the trap: a shop that sells every status cure
contains every status cure's id by definition, and there are 34 shops. Scored
against other runs of five consecutive ids the real five are unremarkable — 330
places at stride 2, where the average run manages 296 and four of thirty-two
sampled runs do at least as well.

A first attempt at a noise floor made it look far better than it was, by scoring
sets of six *random* ids. Random ids are not consecutive, so they scored zero
and the real set looked extraordinary. **The control has to match the shape of
the thing it is controlling for**, not merely its size.

#### What is sharp is what sits beside them

A status mask has very few bits set, and six different items must undo six
different things. So the demand is not that the ids be near each other but that
each be accompanied, at a fixed distance, by a byte that is distinct from the
others and sparse. Across every stride and every distance, that leaves one
candidate that reads as statuses at all — and it reads perfectly: six items
whose effect nobody disputes, mapped one-to-one onto six separate,
non-overlapping bit positions.

#### The eight records that confirm it

Six records found the table. The other eight took no part in it, and every one
lands:

| item | undoes | |
|---|---|---|
| PSNCUREBERRY | poison | the name says so outright |
| PRZCUREBERRY | paralysis | so does this one |
| MINT BERRY | sleep | |
| **ICE BERRY** | **burn** | crossed |
| **BURNT BERRY** | **freeze** | crossed the other way |
| FULL RESTORE, HEAL POWDER, MIRACLEBERRY | everything | |

The two crossed berries are the best evidence in the set. An ice berry soothing
a burn and a burnt berry thawing a freeze is precisely the pairing somebody
guessing from the names would invert, and the table gets both the right way
round without being asked.

There is one more agreement to have for free. The middle byte is a second
encoding of the same fact — `$F0` wherever the mask is poison, `$F1` wherever it
is burn — and it is one-to-one with the mask across all fourteen records. Two
readings of the same thing agreeing everywhere is worth asserting, so it is.

#### In the engine

Nothing names an Antidote. An item undoes a status because the cartridge says
so, the same way a Super Potion heals more than a Potion because the cartridge
says 60 against 20. Two details are not obvious:

- **An item can do both.** A Full Restore carries a parameter *and* a mask, so
  restoring health and clearing a status are asked separately rather than as a
  choice between them.
- **Toxic is poison.** The engine models badly-poisoned as its own status, but
  the cartridge has one poison bit and no separate toxic one, so whatever undoes
  poison undoes both. Leaving that out would have made an Antidote fail on the
  worse poison — a hole in exactly the case a player would notice.

A cure aimed at the wrong status does nothing *and is not spent*, which is the
behaviour that distinguishes a real check from a shrug.

### Item balls, and how the type nibble was finally pinned down

An object's type nibble was read as 0 script, 1 item ball, 2 trainer, but only
the trainer value had ever been checked against anything, and the note claiming
the other types never parse as trainer blocks was wrong — 188 of them do.

The item ball settles it, because it can be shown rather than argued. Its
script pointer leads to two bytes rather than to bytecode: an item and a
quantity. Reading a byte pair as an item is weak on its own; 85% of the trainer
objects pass that test too, since most byte pairs name some item. What is not
weak is the spread. Reading the second byte with no filtering at all:

| nibble | objects | distinct values in that byte |
|---|---|---|
| 0 (script) | 898 | 209 |
| **1 (item ball)** | **178** | **1 — always `$01`** |
| 2 (trainer) | 332 | 3 |

Every item ball in the game holds exactly one thing. That uniformity is what
identifies the type, not the plausibility of the item id. All 178 decode, and
none of them names one of the unused TERU-SAMA slots.

Picking one up is keyed by map and object index rather than by the object's
event flag. The flag is what the cartridge uses, but position is unique by
construction and does not rest on the flags being distinct, which has not been
checked. A taken ball stops being drawn and stops being interactive, and the
set of taken balls is saved with the game.

## Marts

A mart list is a count, that many item ids, then `$FF`. That shape is far too
common to search for: **320 offsets in Crystal read as a mart list**, and all but
34 of them are coincidence. Finding one proves nothing.

Three things together identify the real table. The lists sit back to back in one
block. A run of near pointers lands on those lists and on nothing else. And the
part that settles it — **the pointer table ends at exactly the offset of the first
list it points at**. A table of 34 pointers whose own end is the first thing it
points at is not something noise produces. The tests assert that equality
directly rather than trusting the search that found it.

The contents confirm themselves. Mart 1 is Cherrygrove's four — Potion, Antidote,
Parlyz Heal, Awakening — which is known independently of this code. Marts 10 to
13 are the same three TMs with one or two more added, which is the Goldenrod
department store's machine floor changing as the story moves on. One shop sells
nothing but the five vitamins, another nothing but the X items, and one sells
TinyMushroom and SlowpokeTail, which is Team Rocket's sale in Azalea.

### Which shop belongs to whom

A shopkeeper is an ordinary script object; what marks them out is a `pokemart`
command in the script they run. The opcode table gives `$94` three argument
bytes, and walking every map script says how they are laid out: the first byte
is 0 in 27 of the 29 reachable cases, and the word after it is different almost
every time. A dialogue variant repeats; an index does not. Reading that word as
a 0-based mart index resolves 27 shopkeepers onto 26 distinct shops.

That is 27 of 34, not all of them, and the reason is the same one that limits
the dialogue walk: it stops at conditionals. A shop opened from behind an `if`
is not reached. The tests assert the count as a floor.

### Selling

There is one price per item and the counter halves it, rounding down, so the
sell price is a rule rather than a second table to find.

What a shop will take is read off the cartridge and not listed anywhere: an item
can be sold if it has a price *and* the bit that lets it be tossed is set. That
one bit is what holds back the Bicycle, the Coin Case, the Card Key and the HMs,
which is why no enumeration of key items appears in the engine. The conditions
are checked with an "and", and there is a test that no item in the whole table
is sellable for nothing, which is what an "or" would have produced.

### One more byte-versus-glyph trap

The sell list showed "POKé BAL" where "POKé BALL" was meant. Trimming a name to
nine characters with `string.sub` counts bytes, and "é" is two of them in UTF-8,
so nine bytes is eight letters. Names are now cut by glyph. The same distinction
bit once already, in the character map — it is worth expecting.

## The script interpreter

Talking to someone used to show text pulled out at import. Now it runs their
script.

The text walk stops at the first conditional on purpose: following one arm would
report dialogue the player may never see. An interpreter has no such excuse — it
will know at runtime which arm is taken, so it needs both decoded. Traversing
the whole reachable graph from every entry point reaches **98% of them**, and the
32 that fail all stop on opcodes above `$A9`, past the end of the table, which
suggests they are not scripts at all.

The engine only ever reads the cache, so the bytecode is decoded at import into
**13116 instructions**, keyed by bank and address rather than gathered into
per-script lists. Scripts jump into each other and share tails, so an
address-keyed table dedupes them and makes a jump a lookup. Text is resolved at
the same time, because the engine cannot go back to the cartridge for it.

### Two pieces of state, and one way to get them wrong

Gen 2 scripts carry a carry flag, set by the check commands, and a one-byte
working register that `setval` loads. `iftrue` and `iffalse` test the carry;
`ifequal` and `ifnotequal` compare the register. Conflating the two makes
branches go the wrong way while every instruction still decodes perfectly —
there is nothing to see in a disassembly, only wrong behaviour later.

The same trap sits in the flags. `setevent` and `setflag` are two separate
spaces, not two names for one, and merging them would let event 5 and flag 5
collide. They are kept apart and there is a test that says so.

### Three kinds of command

- **Implemented** — control flow, text, event flags, items, money.
- **Ignored** — movement, music, emotes, camera. The script carries on as though
  they had happened. An NPC will not walk, but the conversation after the
  walking still runs, which is the difference between a script that works and
  one that stops dead.
- **Refused** — battles, warps, trades, giving Pokémon. These change the world in
  ways the engine cannot honour, so the script stops and says so. A silent no-op
  would look like a working script that quietly did nothing.

### What the test caught

Running all 1719 entry points through the interpreter found bugs no amount of
reading would have:

**621 scripts jumped into undecoded ground**, because `jumpstd` is a terminator
— the decoder stops after it — and the interpreter was treating it as an
ignorable no-op and stepping past into bytes that were never recorded. Any
command that ends a script has to end it even when its effect is not
implemented.

That left 378, then 13, as each unchecked transfer of control was found: jumps to
invalid targets, far calls into banks the decoder declined, `jumptext` where the
text did not decode, and returning from a call whose next instruction was
unreadable. Every one now names what happened instead of leaving the program
counter pointing at nothing.

The last 13 were the most instructive. They came from a `replace_all` that
matched a four-space indent and so missed the one fall-through sitting at two —
the ignored-command branch, the single most-travelled line in the interpreter.
The count did not move at all across two fixes, which is what gave it away.

**1624 of 1719 now run to an end**, none lost, none runaway. The 94 refused stop
at `startbattle` and its kin. Of those that end early, 278 leave through
`jumpstd` for the standard-script table, which is not located yet, and 340 reach
a text command whose text would not decode.

The tests report the ignored commands by name and count, so an approximation
cannot quietly grow into a misrepresentation.

## The standard scripts, and two false tables on the way

`jumpstd` and `callstd` do not carry an address. Their operand is an index into
a table of the game's common routines, and 278 scripts left through one of them.
The operands say so on their own: 26 distinct values, all between 0 and 51,
against five stragglers in the thousands that turn out to be misparsed scripts.

Finding the table took two wrong answers first, and both were wrong for the same
reason.

**"The bytes decode until a terminator" is far too weak.** Two instructions
satisfy it, so any pointer landing on a byte that happens to be `$91` passes. One
candidate had a run of 104 entries, every one of them aimed at the *same* such
byte. Another had 53 entries whose targets marched forward in a constant
nine-byte step — a uniform data table, not routines, which vary in length.

Tightening the test to "at least three instructions, and something recognisable
among them" killed both. What it also did was cut the front off the real table:
the search reports where a valid *run* starts, which is not where the table
starts if the first entries are short routines the strict test rejects. Walking
backwards from the run found 22 more entries and then a wall of zeros.

The table begins at **0x0BC000 — the first byte of bank $2F** — and holds
**52 entries** of bank-then-address, every one naming bank `$2F`. The highest
index any script asks for is **51**. Those two numbers were arrived at
separately, from the map scripts on one side and the cartridge layout on the
other, and they agree exactly.

The entries read as what they should be: `getcurlandmarkname; opentext;
farwritetext; waitbutton; closetext; end` is the signpost that tells you where
you are, and `faceplayer; opentext; farwritetext; promptbutton; checkitem;
iftrue; ...` is the NPC who asks whether you are carrying something.

Wiring them in took the interpreter from 1396 text boxes across a full run to
**2833**, and `jumpstd` no longer appears among the reasons scripts stop — the
only two left are the misparsed operands, 3084 and 3853.

## The machine list, and why badges are not earnable yet

The items are named TM01 to TM50 and HM01 to HM07, which says nothing about
what is on them. Somewhere there is a list of 57 move ids in that order.

A run of 57 distinct valid move ids is not convincing on its own — **626
offsets in Crystal satisfy that**. What settles it is the tail: the last seven
have to decode, through the move-name table this project validates separately,
to the seven field moves in HM order. **Exactly one of the 626 does**, and the
rest of that list then reads as the real thing: TM01 DynamicPunch, TM06 Toxic,
TM26 Earthquake, TM44 Rest.

So nothing in the engine names a move id. Surf is whatever HM03 says it is.

### Badges are written but not enforced

A field move needs two things in the games: someone who knows it, and the badge
that licenses it. Only the first is enforced here, and the reason is worth
stating rather than leaving as a silent gap.

Nothing awards badges. Earning one happens inside a `special` call the
interpreter cannot run, and gym leaders cannot be picked out of the trainer
tables either. That last part was measured rather than assumed: the trainer
classes holding **exactly one** trainer are Will, Bruno, Karen, Koga, Lance,
Brock, Misty, Lt. Surge, Erika, Janine, Sabrina, Blaine, Red, Blue and Eusine —
the Kanto leaders and the Elite Four. **All eight Johto leaders are missing**,
because in Crystal they carry rematch parties and so hold several entries each.
"One trainer in the class" picks out the wrong half of the gyms.

Gating Surf on a badge that can never be earned would make it permanently
useless, which is worse than an ungated Surf. So `can_use_field_move` returns
both facts — who can do it, and whether the badge is held — and the caller
currently acts on the first. The tests assert both halves separately so the
distinction cannot blur.

## The time of day

Crystal is built around it. The grass tables carry three separate sets of
encounters, and scripts branch on it.

`checktime` takes one byte, and what that byte means was measured rather than
assumed: across every reachable script the operand is only ever **1, 2 or 4** —
single bits, never a combination. That is a mask of three periods, not an index
and not a count.

Which bit is which comes from somewhere already established. The grass tables
store morning, day and night in that order, so the clock takes its period names
and their order straight from `encounters.times` rather than restating them.
There is one place the ordering lives, so the encounter tables and the script
masks cannot drift apart.

The boundaries are Gen 2's: morning from 04, day from 10, night from 18. Night
is the one that cannot be written as a single range because it crosses
midnight, so there is a test that 23:00 and 00:00 are the same period.

The cartridge read a clock on the board; this reads the host's, which gives the
same three-way split. The game exposes the period through one method rather than
calling the clock directly, so forcing a time for a screenshot or a test affects
what is in the grass as well as which way a script branches.

## The storage boxes

Fourteen boxes of twenty. Nothing here is read from the cartridge: the boxes
live in save RAM rather than in the ROM, so there is no table to find, and the
counts are the game's written down because there is nowhere else for them to
come from.

What it fixes is a real loss. Catching with a full party used to print "the
party is full" **after the ball had already been spent** — the catch succeeded
and was thrown away. It goes to a box now.

A full current box rolls on to the next rather than refusing. The games make you
change box by hand; rolling on loses nothing and there is a message either way.
The last Pokémon in the party cannot be put away, because there would be nothing
left to walk around with.

Boxes are saved with the same packing the party uses. A stored Pokémon is the
same kind of thing as a carried one; only where it lives differs.

### Reached from the menu, which is a deviation

The PC is on the start menu rather than being a machine you stand at. The real
one is a map object whose script only jumps to a routine the interpreter cannot
run, so there is nothing to talk to. Putting it on the menu is a departure from
the games and is recorded as one, rather than the boxes being unreachable.

### Cut trees and boulders are not terrain

The obvious place to look for a cut tree is the collision data, and that search
produced a confident wrong answer. `$B2` appears 2356 times, is classified
blocking, and **62% of its cells have walkable ground on opposite sides** — the
shape of a gate. Rendering the map with the most of them showed **long
horizontal runs of wall across open floor**. A wall line has floor above and
below every cell of it, so the gate measure was counting a fence as a doorway.
The statistic was an artefact of the metric, and only looking caught it.

They are objects. What marks them out is that their script goes straight to a
standard routine and they have no dialogue of their own — an ordinary NPC talks.

That signature is not enough on its own either, and the second wrong answer is
the more instructive one: **the Pokémon Centre nurse matched it**. Twenty-two of
her, every one indoors, every one jumping straight to the same routine, and she
ranked as the most enclosed thing in the game.

What separates her is the routine. Hers greets you; the ones that clear an
obstacle contain no text at all, because what they do is done in assembly. With
that filter the answer comes out clean:

| | objects | enclosed |
|---|---|---|
| boulder | 24 | **100%** |
| cut tree | 16 | 37% |

Boulders are a cave and gym-puzzle obstacle, cut trees an outdoor one, and the
split is not close. No sprite id appears anywhere in this project — the importer
finds both and the engine uses what it found.

Cutting hides the tree the same way a taken item ball is hidden: the object
stays in the map record and the runtime state says it is no longer there.
Strength does not move a boulder; it makes the boulder movable, and walking into
it afterwards is what pushes, one cell at a time, into anywhere the player could
themselves have stood.

### Whirlpool, and asking the question the other way round

This was open for a long time, and the note that stood here said why: about two
dozen values are water, and nothing about a value's number distinguishes one of
them. That was true, and it was also the wrong question. "Which of these values
is the whirlpool" has no answer, because it is a question about the value.

What a whirlpool must *do* is answerable, and all three parts are measurable:
it is needed in a handful of places, it is one cell rather than a stretch of
coastline, and it has water on both sides because you cross it. Measured across
every water value on every map:

| value | cells | maps | clusters | mean cluster | in a channel |
|---|---|---|---|---|---|
| `$21` | 64 | 2 | 18 | 3.6 | 0% |
| `$23` | 714 | 13 | 29 | 24.6 | 0% |
| **`$24`** | **29** | **4** | **29** | **1.0** | **89%** |
| `$27` | 1809 | 47 | 250 | 7.2 | 43% |
| `$29` | 11263 | 73 | 496 | 22.7 | 2% |
| `$33` | 18 | 4 | 6 | 3.0 | 0% |

`$24` is the only value whose **every occurrence is a single isolated cell** —
29 cells in 29 clusters — and the only rare one sitting in open water. `$32` also
manages mean cluster size 1, on three cells, but none of them has water on both
sides, so it is not something anyone would ever cross.

#### The measurement is a fit; the art is the evidence

Everything above is a statistic about where a value sits, and this section
exists because that kind of statistic has produced two confident wrong answers
already — the cut tree that "gated a path" 62% of the time was a fence, and the
obstacle detector's first answer was the Pokémon Centre nurse. Both were caught
by rendering the thing and looking at it.

So that is what settled this too. Rendering every block that carries each
candidate shows `$21` as the pier at Olivine, `$23` as plain water and indoor
tiling, `$33` as a wave pattern — and **`$24` as a spiral**. One block, one
swirl, in the tilesets the sea routes use. A whirlpool looks like a whirlpool
and nothing else here does.

There is a second, independent check that costs nothing: **where** the four maps
are. Three are routes and one is a cave. A whirlpool guards sea routes; a
waterfall would be mostly caves, so the split says which of the two field moves
this value belongs to without either being assumed.

The first gating measure tried was the one that had failed before, in its global
form: flood the map's water, flood it again with the candidate removed, and see
whether the sea falls apart. `$24` splits nothing on any of its four maps, which
looked at first like a refutation and is not. A whirlpool in Crystal does not
dam a channel — it guards a way in, sitting in open water that surrounds it on
every side. The measure was answering a question about geography that the
feature does not have.

#### In the engine

The value is found at import and written to the cache, so nothing names `$24` —
Gold and Silver work from the same code and a cartridge where it lands elsewhere
still works. `can_enter` gains one more condition: while surfing, water is
enterable unless it is a whirlpool and nobody in the party knows the move, which
comes through the machine list the same way Surf does.

Unlike a cut tree or a boulder, **a whirlpool is not cleared away**. The water
stays a whirlpool once you are past it, so there is no runtime state to keep —
the only question is whether the party can cross, asked afresh each step.

### Surf

Water was already a distinct collision kind, so riding on it is a matter of
letting `can_enter` accept water while surfing and land while not. Getting on is
facing water and pressing the button; getting off is riding onto solid ground,
which is noticed when the step completes rather than being a separate action.

Facing deep water with nothing that can swim says so.

## Reading a real cartridge save

A Game Boy save is 32 KiB of battery-backed RAM, and where things sit inside it
differs between Gold, Silver and Crystal and between localisations. So this uses
no offsets at all. It searches, and it validates by a much sharper rule than
"these bytes look plausible".

A party member stores its DVs, its stat experience, its level — **and its
computed stats**. Those are not independent: the stats follow from the rest
through the same formula the battle engine already uses. A run of bytes where
all six stats reproduce from the DVs and level is not a coincidence, and one
where they do not is not a party, whatever else it resembles.

That gives a locator which needs to be told nothing. Every offset in the save is
tried, and if more than one validates the reader refuses rather than picking the
first — two matches would mean the check is weaker than it looks.

### It works on a real save

Run against a real Crystal save, the reader recovers the party without being
told anything about where it sits:

```
1  TYPHLOSION  L100 359/359 HP  atk 266 def 254 spd 298 spa 316 spd 268
2  NOCTOWL     L100 403/403 HP  atk 198 def 198 spd 238 spa 250 spd 290
3  MANTINE     L100 333/333 HP  atk 178 def 238 spd 238 spa 258 spd 378
4  TYRANITAR   L100 403/403 HP  atk 366 def 318 spd 220 spa 288 spd 298
5  DELIBIRD    L100 293/293 HP  atk 208 def 188 spd 248 spa 228 spd 188
6  GRANBULL    L100 383/383 HP  atk 338 def 248 spd 188 spa 218 spd 218
```

That is **36 independent arithmetic agreements** — six members, six stats each —
against base stats pulled from the cartridge and DVs pulled from the save. It is
not the sort of thing a wrong reading produces.

### Two copies, which is not ambiguity

The first run on that save refused it: two offsets validated, `0x1A65` and
`0x2865`, and refusing to choose was the rule. That rule was too blunt. A
cartridge keeps a **backup copy** of everything it saves, `0xE00` apart here, so
every real save has two parties in it and the old reader would have refused all
of them.

Copies that say the same thing are one party written twice, and the first is
read. Copies that disagree mean a save caught mid-write, and choosing between
them is genuinely not this code's decision, so that still refuses.

Testing that distinction took two goes. The first attempt corrupted the backup
and checked it was refused — and it passed for the wrong reason: a corrupt
backup fails the stat check outright, so it is not a competing answer at all,
just an absent one. The test now builds a **second valid party at a different
level**, checks that both are found, and only then checks that the reader
declines to pick. The corrupt-backup case is kept too, asserting the opposite:
that a broken copy does *not* stop the good one being read.

### The other tests

A party built from the formula is **hidden in 32 KiB of noise at an offset the
reader is not told** and has to be found — that tests the search rather than the
arithmetic. The same party rebuilt with **one stat byte changed by one** has to
be refused, which is what says the arithmetic is doing the work rather than the
shape.

The Gen 1 Red save covers the negative: 32 KiB of genuine save data, every
offset tried, no false positive. A Gen 1 save does contain a party, just not one
laid out this way, so refusing it is a stronger result than refusing noise.

### One thing worth knowing about paths

These files are usually kept somewhere called "Pokémon - Crystal Version", and
Lua's `io.open` goes through the Windows ANSI codepage, so a path with an accent
in it arrives as UTF-8 and does not open. A file dropped on the window comes
with LOVE's own handle, which does not have that problem, so that is what the
drop path uses. Naming such a file on the command line still fails, and says so
rather than reporting that no party was found.

## The music table, and what is not there

A song is a header followed by one command stream per channel. The header is a
run of three-byte entries — a channel index, then a near pointer — and the first
byte also carries how many channels there are in its top two bits. `$C0` means
"four channels, this is channel 0", and the entries after it must then read 1, 2
and 3.

That packing is specific, but on its own it only *allows* a header. What
confirms one is that **the header ends exactly where its first channel begins**:
the entries are contiguous with the data they point at, so the arithmetic has to
close.

The table is spread across banks `$3A`, `$3B` and `$3D` — which is why the first
search found only 10. It required every entry to name the same bank, the
sharpening that had worked for the standard scripts, and music does not fit in
one bank. Reading the bank per entry and then walking backwards from the run,
the way the standard-script table needed, gives the front of it.

### It was truncated at 59, and the scripts said so

The next version of this said the table held **59 songs**, and it did not. It
stopped at the first slot that failed to decode — the same mistake the trainer
class table made, and the map headers made before that.

What caught it was the game asking for something that was not there.
`playmusic` names a song by index, and across every decoded script the operands
include **78, 93, 96 and 97**, all past the end of a 59-entry table. A table
that the game itself indexes past the end of is not the whole table.

Walking straight on past the break finds it continues to index 102, with only
**three** slots in between that do not decode — 59, 78 and 91, each an isolated
single miss. Index 103 names bank `$C0`, which this cartridge does not have, and
nothing decodes for a long way after. The table is **103 slots**, of which 100
decode.

The entries past the break were checked before being believed, against
properties measured from the original 59 that the new ones took no part in
establishing:

| | first 59 | past the break |
|---|---|---|
| channels | 210 | 149 |
| bytes below `$D0` | 73% | 73% |
| channels opening with a byte the first 59 used | — | **147 of 149** |

Same data, and the table had simply been cut short. That also nearly doubles the
material available to anyone attacking the channel bytecode: **256 channel
extents rather than 148**.

Slots that do not decode are kept as placeholders, for the reason the map
headers needed the same treatment: **entries are addressed by position**.
Dropping one would not merely lose a song, it would shift every song after it
and silently rewire which music plays where.

Of the 100 that decode, **89 close exactly**. The other eleven are short by one
byte — and by *exactly* one byte, every time, with no other value appearing.
That uniformity is the useful part: a scattered mismatch would mean the shape
was wrong, while a single repeated offset means the shape is right and there is
one padding convention here that has not been identified. It is flagged rather
than rounded off, and there is a test that the mismatches stay uniform.

Channel counts come out at two songs with two channels, 37 with three and 61
with four, and every song's channel pointers climb in order.

The general lesson is the one this document has now recorded three times, and
the new part is how it was caught. A locator that stops at the first awkward
entry produces a table that is *internally* consistent — every entry in it is
real — so nothing about the table itself complains. What complains is another
part of the cartridge indexing past its end. **When one structure names
positions in another, that naming is a bounds check nobody has to write.**

### The channel bytecode: a negative result

Channel data is contiguous — channel 1 runs up to where channel 2 begins — so
the boundaries are known for **256 channels** across the 100 songs that decode.
That is exactly the lever that validated the script opcode widths: a walk has to
land on the boundary, never over and never short, and all of them have to agree
at once.

**It does not work here, and the reason is worth writing down.**

With every command one byte wide, a walk consumes one byte at a time and lands
on the boundary every single time. A table of all zeros scores 256 out of 256.
The measure cannot tell a correct width table from a table that says nothing,
which is the same vacuousness that got the script widths wrong on the first
attempt — there it was marking every opcode as terminating, so a walk could
never overrun; here it is allowing width zero, so a walk can never drift.

Adding a second constraint did not rescue it. `$FF` is what most channels end
on, so under a correct parse it should only be met at the end, and every earlier
one is a byte that should have been swallowed as somebody's operand. Scoring
that too, and hill-climbing from four random starts — this was run against the
148 extents the truncated table gave, and the scores below are that run's:

| run | score | widths |
|---|---|---|
| from zero | 1391 | — |
| restart 1 | 1402 | different |
| restart 2 | 1401 | different |
| restart 3 | 1402 | different |
| restart 4 | 1401 | different |

Four searches, four near-identical scores, four different answers. **Nothing
agreed with anything.** The problem is underdetermined by the evidence
available, and a hill-climbed table that scored 1402 would have looked
authoritative and been invented.

The restart-agreement check is the only reason this was caught rather than
shipped, and it is worth reaching for whenever a search is doing the deciding.
The degeneracy is now asserted in the test suite — a table of zeros satisfying
the extents completely is a *passing* test — so the measure cannot be adopted
again by someone who has not read this. That assertion is computed from
whatever the table currently yields, so widening it from 148 extents to 256
re-checked the degeneracy rather than leaving a stale number behind: more
evidence does not help, because the flaw is in the measure and not in the
sample size.

The hill-climb has **not** been re-run at 256 extents. There would be little
point: what defeats it is that width zero is admissible, which no amount of
extra data changes. What *would* change the picture is a width table proposed
from outside — from the disassembly the script opcodes were already taken from,
or from an emulator's writes to the sound registers. **The extent measure is
vacuous as a search objective and perfectly sound as a test of a fixed
hypothesis**: a table supplied from elsewhere either walks all 256 extents
exactly or it does not, and unlike a search it cannot bend itself to fit. That
is the same shape as the script opcodes, where inference reported zero overruns
while getting 13 of 24 widths wrong, and the real widths made the number mean
something again.

### What does stand

- 256 channel extents, **73% of their bytes below `$D0`**, consistent with
  notes being pitch and length packed into one byte. (This read 148 extents and
  72% before the table turned out to be truncated at 59 of its 103 slots.)
- 44 distinct command bytes, heavily concentrated: `$DC`, `$D5`, `$D4` and `$D6`
  are half of all commands between them.
- A channel opens with one of **only six** bytes — `$DA`, `$DB`, `$EF`, `$E1`,
  `$D8`, `$D9` — which is what setting up an instrument before playing looks
  like.
- most channels end on `$FF` — 89 of the 210 in the first 59 songs, and 57 of
  the 149 in the slots the truncation had been hiding.

Getting further needs a different kind of evidence than byte layout: an emulator
to watch the sound registers, or the note pitches recovered by ear against a
recording. Neither is bytecode archaeology, which is what this project is set up
to do.

## The sound chip

The chip exists now. It is the one part of the audio problem that needed no
reverse engineering at all: the hardware is documented, so it can be written
from the specification and then measured. Two square channels, a 32-sample
wavetable, a noise generator, the 512 Hz frame sequencer that drives lengths,
sweep and envelopes, and the stereo mixer.

It takes register writes addressed the way the hardware is, `$FF10` to `$FF3F`,
so a trace lifted from an emulator could be replayed into it without
translation — which matters, because that is one of the two routes left for the
channel bytecode.

### Why it is not stepped one clock at a time

The master clock is 4194304 Hz against an output of 44100, so a cycle-accurate
loop would run 95 iterations per sample and 4.2 million per second of audio.
Each unit keeps a countdown instead and the chip advances in chunks to whatever
happens next, which for a 440 Hz square is a few thousand steps a second.

That has a second benefit worth more than the speed. A chunk is by construction
a span over which nothing changes, so the output level can be accumulated
multiplied by its duration and divided at the end of the sample — **an exact box
filter over the sample period, for free**. Point-sampling a square wave at
44.1 kHz aliases audibly; this does not.

### A sound chip makes a noise either way

This is the failure mode nothing else in the project has. Every other decoder is
checked against content known independently, and a wrong answer produces
garbage. A wrong sound chip produces *sound*, and "I can hear something" is the
audio equivalent of the extent measure that scored a table of zeros perfectly.

So nothing is judged by ear. Ask for 440 Hz and the output is measured for
440 Hz by counting zero crossings; ask for a 12.5% duty cycle and the output is
measured for how long it stays above zero; the shift register's period is
counted exactly, against numbers the hardware fixes at 32767 and 127.

| | asked for | measured |
|---|---|---|
| frequency | the hardware's `131072/(2048-n)` | within **0.037%** |
| duty cycles | 0.125 / 0.25 / 0.5 / 0.75 | 0.127 / 0.251 / 0.500 / 0.749 |
| noise, 15-bit | period 32767 | **32767** |
| noise, 7-bit | period 127 | **127** |
| length of 32 | silence at 0.1250s | 0.1277s |

### ...and then somebody listens anyway

The demo `--probe-apu` writes was played back and reported as sounding right.
That is worth recording and worth being precise about, because it is a
different kind of evidence from everything above rather than a stronger one.

Measurement is what establishes the chip is correct: it can say that 440 Hz
came out at 440 Hz and that the shift register repeats after exactly 32767
shifts. An ear cannot say either of those things. What an ear catches is the
whole class of faults that are obvious in aggregate and invisible to any
particular measurement — a channel silently missing from the mix, clicks
between notes, a stereo image collapsed to one side, aliasing that the numbers
pass over because they only ever looked at zero crossings.

So the order matters and it is the order used here: measure first, because
"it makes a noise" proves nothing; listen afterwards, because a chip that
satisfies every measurement written for it can still be wrong in a way nobody
thought to measure.

### The capacitor is not a refinement

The measurements found a missing piece of hardware on the first run, which is
the whole reason for taking them. A falling envelope kept a **constant** peak
amplitude.

The chip was right and the model was incomplete. A channel whose digital level
is 0 is not silent: its DAC holds a steady voltage at the bottom of its range.
What makes that silence is the capacitor on the way out of the chip, which
passes changes and blocks anything constant. Without one, a falling envelope
does not shrink the waveform towards zero — it slides it downwards towards a
floor that never moves, so the loudness never changes. Every channel switching
on or off would also have stepped the whole mix and clicked.

One pole of high-pass, with the charge factor the hardware's own time constant
gives, and the envelope falls to nothing where it should. There is now a test
that a 12.5% duty tone — the least symmetric one available — averages to within
0.005 of zero.

### Two failures that were the measurement's fault

Worth recording, because telling "the code is wrong" from "the question is
wrong" is most of the work in this project.

**The seven-bit shift register appeared to have no period at all.** It does, but
what repeats is the audible sequence rather than the whole register. In
seven-bit mode bits 0 to 6 form a closed register and bits 7 to 14 become a
delay line with no feedback into them, fed by a sequence whose longest run of
ones is shorter than eight — so the full fifteen bits can never all be set again
and never revisit the value a trigger loads, while the output carries on
repeating every 127 shifts. Measuring the register said "no period"; measuring
what the channel actually emits says 127.

**A note with a length appeared not to stop.** Switching a channel off steps the
mix, and the capacitor answers a step with a decaying transient, so a window
beginning at the moment of the cut is never silent however correct the chip is.
Moving the window would have been fitting the test to the answer. Measuring
*when* the sound ends instead tests the length counter's timing, which is the
thing worth knowing, and it lands within a block of the exact eighth of a second
that 32 ticks at 256 Hz gives.

### What is still missing

The chip is a chip. Nothing drives it yet, because what would drive it is the
channel bytecode, and that is still the wall. `playsound`, `cry` and `playmusic`
remain among the commands the interpreter steps over.

### Movement

`applymovement` names an object and points at a little language of its own: one
byte per step. The terminator is `$47`, and that was measured rather than
assumed — it ends **all 307** blocks the scripts point at, within 56 bytes, while
`$FF`, which is the terminator every other structure in this cartridge uses and
therefore the obvious guess, **never appears at all**. What sits after the `$47`
is usually a text block, which is the other half of the confirmation.

The commands come in groups of four, with the direction in the low two bits in
the same down-up-left-right order the object events use:

| bytes | meaning |
|---|---|
| `$00`–`$03` | turn on the spot |
| `$04`–`$07` | turn and step |
| `$08`–`$0B` | step slowly |
| `$0C`–`$0F` | step |
| `$10`–`$13` | step quickly |

Only two things matter to the engine: which way the object ends up facing, and
where it ends up standing. All 353 movement commands in the game decode, over
1523 steps, the longest walk being 56 — a cutscene rather than someone stepping
aside.

Movements are applied at once rather than animated. There is no walking
animation for anyone but the player, and a script that waited on an animation
which never finished would hang.

### Objects have a present tense now

The map record is what the cartridge says. What the scripts have done since is
kept separately, keyed by map and object index, and that is what the drawing
reads: which way each object faces, how far it has walked from where it started,
and whether it is still there at all. That state is what let `faceplayer` stop
being a no-op, and `disappear` and `appear` do what they say.

Checking a facing by looking at an 8-pixel sprite in a screenshot is not
checking anything, so the demo says the answer out loud instead. Approaching the
same NPC from either side:

```
PLAYER STANDS LEFT      PLAYER STANDS RIGHT
NPC FACES LEFT          NPC FACES RIGHT
```

The two differ, and each is the direction the player is actually standing in.
The first NPC tried never turned at all, which was not a bug: a shopkeeper
behind a counter has no reason to call `faceplayer`, and a script that never
turns anyone proves nothing either way. The demo now keeps looking until it
finds one that does.

### The special commands, and what is honestly knowable

`special` calls a routine written in assembly. There are **127 distinct ones** in
the reachable script graph, and they cannot be run from bytecode — there is no
Z80 interpreter here and the routines are machine code, not script.

The obvious next move is to identify individual ones from context and implement
those. It does not work, and it is worth recording why rather than leaving it as
an open invitation. Reading the nearest preceding text for each index gives a
*scene*, not a routine: indices 48, 50, 51 and 157 all sit beside "A comfy bed!
Time to sleep", because a bed is a sequence — fade out, heal, fade in, restart
the music — and every step is its own special. Thirteen different indices appear
near text about healing, and none dominates. Naming any one of them HealParty
would be a guess wearing the clothes of a fact, which is the failure this
document keeps a list of.

What *is* knowable is how much it costs. Measuring where the specials sit:

| what follows a special | share |
|---|---|
| nothing within three instructions | **70%** |
| a branch within two | 24% |

Seven in ten cost nothing at all downstream. The rest feed a conditional, and
there the old behaviour was quietly wrong: stepping over the special left the
carry flag holding whatever check ran before it, so the branch followed
unrelated history.

Now a special clears the carry and the register to a definite no, and records
that the answer is not a real one. The next conditional to read it counts itself
as a guess and spends the flag; a genuine check clears it. That turns an unknown
into a number: across every script in the game, **680 specials are stepped over
and 45 branches are taken on a result the interpreter did not produce** — under
seven percent. The tests assert the mechanism directly on scripts built for the
purpose, including that a carry set by an earlier `checkevent` does not survive
a special.

### Fighting when a script says so

A scripted battle is two commands, not one: something is loaded — a wild
Pokémon by species and level, or a trainer by class and id — and then
`startbattle` fights it. Keeping the loaded combatant on the interpreter rather
than handing it straight to the engine matters, because a script can load one
and then branch away without ever fighting.

`startbattle` is the first command that has to *wait on the world*. Text waits
for a button and a question waits for an answer, but both resolve inside the
same conversation. A battle takes over the screen entirely, and the script
resumes when it ends — so the interpreter steps its program counter past
`startbattle` before yielding, and the engine wakes it from `end_battle`.

The outcome is recorded before the wake-up, so `checkjustbattled` on the very
next instruction reads the right thing.

Blacking out is the exception: it clears the waiting script rather than
resuming it. The player has been carried out of the building the script was
running in, and carrying on where it left off would be the wrong story.

This took **unsupported scripts from 95 to 21** and the ones running to an end
from 1669 to **1743 of 1771**. What still refuses is trades, warps, elevators
and giving away Pokémon — each of which changes the world in a way the engine
cannot honour yet.

### Answering the question

`yesorno` became the most common ignored command the moment the standard scripts
were reachable, because so many of them ask something. Ignoring it was the worst
of the options: the carry flag would hold whatever the previous check had set,
so the branch would follow unrelated history.

Now the interpreter stops and waits. It yields a choice, the engine puts YES and
NO above the text box — the words that asked the question stay on screen
underneath, which is where the asking happened — and the answer sets the carry
the branch then tests. The program counter deliberately does not move until the
answer arrives, so answering is what advances it.

This is worth having rather than defaulting, and there is a measurement that
says so: running every script twice, saying yes throughout and then no
throughout, **139 questions are asked and 82 scripts end differently** depending
on the reply. A prompt that changed nothing would be decoration.

A caller that resumes without answering still gets a defined result. Declining
is the documented default — it is the answer that spends no money and takes no
items — and there is a test that an unanswered question comes back false even
when the carry was true beforehand, because that is exactly the stale-history
bug the prompt exists to avoid.

## The text codes that were costing a third of the dialogue

340 scripts ended at a text command whose text would not decode, which looked
like an indirection the decoder did not know — a pointer to a pointer. It was
not. Those blocks start with `$00`, which is already the correct opening byte,
so the pointers were fine and the decoder was choking on something inside.

Walking each failing block by hand and recording the first byte it could not
account for gave the answer, in context:

| bytes | reads as | so |
|---|---|---|
| `That` `$D4` ` a NUGGET` | That's a NUGGET | `$D4` is `'s` |
| `didn` `$D5` | didn't | `$D5` is `'t` |
| `they` `$D3` `e` | they're | `$D3` is `'re` |
| `I` `$D6` `e got` | I've got | `$D6` is `'ve` |

`$D0` to `$D6` are the English contractions, in alphabetical order: `'d 'l 'm
'r 's 't 'v`. They had been mapped at `$BA` to `$BF`, copied from Gen 1, where
in Crystal those tiles are blank — the blankness that got them demoted to
escapes earlier was the clue, and this is where they actually live. Adding them
fixed 784 blocks on its own.

### Glyph or control, settled by the font again

Two codes were left. `$75` stopped 377 blocks and `$14` stopped 45.

`$14` was easy: it sits exactly where a name belongs — `Hello, <14>!` — and
maps below the font entirely, so it draws no glyph of its own. `$01` gave itself
away in the same manner: the two bytes after it read `$D099`, which is Game Boy
work RAM, so it prints a name out of a buffer and those two bytes are an operand
rather than letters.

`$75` was the interesting one, and the ink measurement said *glyph* — 32 pixels,
against 21 for `'d` and 0 for the space. But ink says something is drawn there,
not that the byte means it. Printing the tile settles it:

```
$75 -> tile 53      $80 -> tile 64 ('A')
  ########            ...#....
  ########            ..#.#...
  ########            ..#.#...
  ########            .#...#..
  ........            .#####..
  ........            #.....#.
  ........            #.....#.
  ........            ........
```

A solid block four rows deep is not a letter. Combined with `$75` turning up at
172 different positions rather than one fixed spot, and every block containing
it reading as correct English once it is passed over, it is a control. What it
instructs the text engine to do is not known here, so it is named for what it
does on screen, which is nothing.

**1954 of 1963 text targets now decode, against 873 before.** Text extraction at
import went from 480 of 2200 scripts to 893, and the interpreter went from
showing 616 text boxes across a full run to 1396. The nine that still fail all
carry a `$00` in a position the decoder treats as "this is not dialogue", and
relaxing that check to win six blocks would weaken a test the whole locator
leans on.

## The Pokédex, and a table with nothing to search for

Every other table in this project is found by encoding its first record as a
signature. Species 1 is BULBASAUR, move 1 is POUND, item 1 is the MASTER BALL.
A Pokédex entry has no such handle: its first field is a classification, and a
classification is just a word.

So the search is on shape, and the shape had to be read off the cartridge rather
than guessed at. The first guess — a word, some bytes, then a description —
found **nothing at any gap from zero to eight**, which was at least a loud
failure rather than a plausible one. Dumping the bytes around a classification
the dex is known to contain gave the record immediately:

```
SEED@  CC 00  96 00  While it is young,<4E>it uses the<4E>nutrients that are@
                     stored in the<4E>seeds on its back<4E>in order to grow.@
```

Two things about the encoding are why the first attempt found nothing, and both
are the kind of difference that produces zero results rather than wrong ones.
**The line break inside a dex entry is `$4E`**, not the `$4F` a text box uses.
And **`$50` is a page break as well as the terminator**, so a record ends on the
*second* one. A decoder written for dialogue stops at the first page and then
fails to find anything after it.

`$CC` is 204, which reads as 2'04"; `$96` is 150, which reads as 15.0lb. Those
are Bulbasaur's, and neither took any part in finding the table.

### The one sharp constraint is arithmetic, not textual

Everything else about the shape is "looks like text", which is weak. What is not
weak is that **a height in feet and inches cannot carry a twelfth inch**.

That single check is what makes the count land. Scanning the whole cartridge for
the shape finds **exactly 251 records** — the species count, arrived at from the
other end and never told to the search. Dropping the feet-and-inches check and
scanning again finds **288**. So the constraint is doing real work, and the
count with it in place is not something the rest of the shape would have reached
on its own.

The page count was measured the same way rather than assumed:

| pages per record | records found | of them back to back |
|---|---|---|
| 1 | 251 | **0** |
| **2** | **251** | **247** |
| 3 | 125 | 0 |
| 4 | 0 | 0 |

One page finds the same 251 records and puts *none* of them adjacent, which is
what a half-read record looks like. Two puts 247 of 251 back to back, and the
four breaks are not failures — they are the four places the table changes bank.

### The bank split fell out rather than being asked for

The 251 records land in four runs of **64, 64, 64 and 59**, in banks `$60`,
`$6E`, `$73` and `$74`. That is the cartridge storing its dex text by species
range, and the search knew nothing whatever about banks. A shape search
reproducing the game's own partitioning is a stronger result than the count on
its own.

### Order comes from a pointer table, and the margin is the evidence

The records are in dex order but nothing in a record says which species it
belongs to, so the order comes from a run of near pointers landing on them and
on nothing else — the same lever that settled the marts. The longest such run in
the cartridge is **251 long. The next longest is 6.** That is not a margin noise
produces, and the run ends of its own accord at exactly 251 rather than needing
to be cut off.

A near pointer carries no bank, so 13 of the 251 name an address that two
different banks both hold a record at. Rather than assume the obvious tiebreak,
the resolution is required to be **unique**: the lowest monotone assignment and
the highest monotone assignment are both computed, and the answer is accepted
only where they agree. Two different assignments would mean the constraint is
weaker than it looks, which is a refusal rather than a coin toss. They agree
everywhere, and as a separate check, address order reproduces pointer order at
all **238** of the pointers that were never ambiguous in the first place.

### The inch mark is not identified, and is left off

The dex prints a height as feet and inches. The feet mark is the apostrophe at
`$E0`, which the font settled long ago. The inch mark is missing, and that is a
gap rather than a style choice.

The reason is structural, and it is the same reason the specials are out of
reach: **the height is stored as a number and formatted by the game's own
assembly**, so there is no dex text anywhere in the cartridge containing an inch
mark to read the code off. Printing the unmapped tiles below the letters — the
method that settled `$75` as a control rather than a letter — turns up several
marks that could plausibly be one and nothing that decides between them.

A guessed glyph would be a wrong character on screen for the sake of appearing
complete. `HT 2'04` carries the meaning without one.

### Seen and caught are two sets, and eight places write to them

The dex tracks two states, not one field with three values, because they are
recorded at different moments: a species is seen the instant it appears on the
far side of a battle, and caught only when it ends up in the player's hands.

Catching implies seeing, and that implication lives in `dex:catch` rather than
at each of the eight call sites — a wild encounter, both trainer paths, the
starter, a thrown ball, anything joining the party, an evolution, and a party
imported from a real cartridge save. Any of those could have registered a catch
and forgotten the sighting.

Two of them are worth naming. **A catch is registered before the caught Pokémon
is put anywhere**, because a catch made with a full party and full boxes is
still a catch and the dex should say so. And **an evolution registers the
species it became**, because nothing else would: an evolution never passes back
through the code that adds to the party.

A save written before any of this existed still shows what the player owns,
because loading registers the party and the boxes as caught regardless of what
the save's dex field says.

## Hidden items, and measuring what chance looks like

Background event type 7 is a hidden item. A background event is y, x, type, then
two bytes, and for the ordinary types those two bytes point at text. For type 7
they point at something else, and working out what nearly went wrong.

The obvious first reading is that the two bytes hold the item inline. It scored
**74 of 85**, which looks convincing until you ask what a wrong reading would
have scored. Only the unused TERU-SAMA slots fail the "is this a real item"
test, so **222 of 255 byte values pass it — 87%**. And 87% of 85 is 74. That
reading scored *exactly chance*. Reading the bytes as pointing straight at the
item, the way an item ball's script does, scored 63 — *below* chance.

| reading | hits out of 85 |
|---|---|
| the two bytes are the item | 74 — chance is 74 |
| they point at the item | 63 — worse than chance |
| **they point at a flag, then the item** | **85** |

What settled it was giving up on hypotheses and dumping the bytes. The records
are three long and sit three apart, and the first byte increments along them:
`88 00 3F`, `89 00 11`, `8A 00 26` at consecutive offsets. That is a two-byte
event flag followed by the item. The earlier probe had already noticed that "the
byte after the item is always $00" and treated it as a curiosity — it was the
flag's high half, and it was the answer.

All 85 decode. The items are the ones Gen 2 buries: Max Potion nine times, Full
Heal eight, Full Restore seven, Revive six, Rare Candy five. The wrong readings
produced scattered one-offs, which is its own tell.

The tests keep all three readings and assert the gap between them, so the
evidence for the layout lives in the suite rather than only in this document.

Finding one is keyed by the cartridge's own event flag, unlike the item balls,
which are keyed by position. Here the flags are distinct across all but one
pair, and that pair is the same item reachable from two squares, so sharing a
key is the behaviour you want.

### Buying and selling several

Picking something at a counter opens a dial rather than transacting. Up and down
step by one and wrap; left and right jump by ten and stop at the ends.

The dial cannot be wound past what is actually possible: its ceiling is the
smaller of what the money buys and what the bag has room for, so a shop with
¥3000 and Great Balls at ¥600 stops at five. That ceiling is
`bag.affordable(price, money, room)`, kept out of the engine and away from LÖVE
so the arithmetic is checked on its own — a free item is bounded by room alone,
which is the case a plain division gets wrong.

Buying still checks that everything fits before charging, and puts back whatever
did fit if it does not. Without that, a purchase of five into a stack with room
for three would take the money for five and hand over three. The bag's `add`
returns how many it actually took, which is what makes the check possible, and
`remove` is all-or-nothing so selling four when three are held cannot half
happen.

### What is not there yet

The scripts that hand out items and set your money are not interpreted, so the
starting bag and the starting ¥3000 are stand-ins written in the engine rather
than something the cartridge granted. The Itemfinder does not exist, so a hidden
item is found by pressing the button on the right square rather than by being
told which square to try.
