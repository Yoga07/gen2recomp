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

### What this has and has not bought

The table is real and validated, and it gives a disassembler. It has not
increased how much dialogue is readable, and it is worth being clear why: every
opcode learned so far is a terminating one, so a walk stops at the first
instruction and finds exactly the text that reading the first instruction
already found. Coverage stays at 377.

Getting past that needs the non-terminating opcodes, and those are precisely the
ones single-unknown inference cannot reach. The way through is probably more
constraint rather than more search — script extents from a second source, or
opcodes whose operands can be recognised independently, the way text pointers
were.

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
