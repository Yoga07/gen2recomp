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

### What is not there yet

The scripts that hand out items and set your money are not interpreted, so the
starting bag and the starting ¥3000 are stand-ins written in the engine rather
than something the cartridge granted. Selling is not implemented, only buying,
and buying is one at a time rather than by quantity. The hidden items — the ones
found with the Itemfinder rather than seen on the ground — are a different
structure that has not been looked at.
