# gen2recomp

A reimplementation of Pokémon Gold, Silver, and Crystal in Lua and LÖVE, in the
same spirit as [gen1recomp](https://github.com/bryanthaboi/gen1recomp).

The engine is hand-written. Game data — species, moves, text, graphics, maps,
music — is extracted from a cartridge image that you supply. The image is
verified, read once during import, and released. **It is never copied into the
cache and it is never written to disk.** No ROM is included here, and this
project does not emulate the Game Boy.

## Status

Early. The data pipeline works and is verified against a real cartridge; the
engine does not exist yet.

| Area | State |
| --- | --- |
| Cartridge verification and identification | working |
| Bank / far-pointer addressing | working |
| LZ graphics decompression | working |
| 2bpp tile and BGR555 palette decoding | working |
| Species names, move names, base stats, move data | working |
| Pokémon front and back sprites | working, 250 of 251 species |
| Sprite palettes, normal and shiny | working |
| Tilesets: graphics, blocks, collision | working, 31 tilesets |
| Maps: headers, dimensions, block data, connections | working, 384 maps |
| Map events: warps, triggers, signposts, NPCs | working, all 384 maps |
| Overworld: rendering, grid movement, warps | working |
| Collision | provisional — see below |
| Overworld sprites: player and NPCs | working, 102 sprites |
| Unown's 26 forms | not located — see `src/rom/pics.lua` |
| Dialogue text and charmap | working |
| Map scripts | text-only: 175 of 2200 read |
| Script bytecode beyond text | not started |
| Battles, menus, audio | not started |
| Audio | not started |
| Engine (overworld, battle, menus) | not started |

You can walk around. Import a cartridge, press enter, and move with the arrow
keys or WASD; doors warp between maps, and the player and NPCs are drawn with
the cartridge's own sprites. Press Z or space to read a signpost.

113 tests pass against Crystal (USA/Europe) rev 1, SHA-1
`f2f52230b536214ef7c9924f483392993e226cfb`. Nothing is claimed to be correct
until it round-trips against content known independently of this code.

Offsets discovered in that cartridge, for reference — the importer finds these
itself and does not depend on them:

| Table | Offset | Bank |
| --- | --- | --- |
| Base stats | `0x051424` | `$14` |
| Species names | `0x053384` | `$14` |
| Move data | `0x041AFB` | `$10` |
| Move names | `0x1C9F29` | `$72` |
| Pokémon pic pointers | `0x120000` | `$48` |
| Trainer pic pointers | `0x128000` | `$4A` |
| Sprite palettes | `0x00A8D6` | `$02` |
| Tileset headers | `0x04D596` | `$13` |
| Map headers | `0x094034` | `$25` |
| Map group pointers | `0x094000` | `$25` |
| Overworld sprite table | `0x014736` | `$05` |

## Requirements

- [LÖVE 11.4 or newer](https://love2d.org/)
- A cartridge image you own, in `.gbc` form

## Running

```bash
love .
```

Drag your cartridge image onto the window. The importer reports what it found
and writes the extracted data under LÖVE's save directory, in `cache/<game>/`.

There are headless entry points for scripting, since drag-and-drop cannot be
automated:

```bash
love . --test "C:\path\to\crystal.gbc" report.txt
```

`--import` runs the real pipeline, `--probe-pics` is a format diagnostic. On
Windows, `scripts\test.ps1 -Rom <path>` wraps the test run and prints the report
(argument quoting matters — a ROM path with spaces silently truncates otherwise).

## How table offsets are found

Most tools in this space hardcode a table of ROM offsets per game and per
revision, which fails silently the moment it meets a dump it did not anticipate.
This project searches instead.

Every data table begins with known content — species 1 is always Bulbasaur,
move 1 is always Pound — so the first record can be encoded as a signature and
searched for. A candidate is only accepted once the entire table decodes without
a malformed record *and* spot checks on records we did not search for succeed:
Mew at index 151, Celebi at 251, Struggle's 1 PP. If two offsets both validate,
the import refuses to guess and says so.

The upshot is that Gold, Silver, Crystal, and their revisions all work from the
same code, and a dump that would have decoded into nonsense fails loudly.

Discovered offsets are recorded in each cache's `manifest.lua`.

## Layout

```
main.lua           entry point; importer UI
conf.lua           LÖVE configuration
src/rom/           cartridge decoding — header, banking, LZ, graphics, text
src/import/        import pipeline and the on-disk cache
src/util/          byte and bit helpers
docs/              format notes and architecture
tests/             decoder tests
```

## Legal

This repository contains no Nintendo, Creatures, or Game Freak assets and no
cartridge data. It requires a cartridge image that you provide. Pokémon and the
Gen 2 games are the property of their respective owners.
