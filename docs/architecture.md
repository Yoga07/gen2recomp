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
