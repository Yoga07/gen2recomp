# gen2recomp

A reimplementation of Pokémon Gold, Silver, and Crystal in Lua and LÖVE, in the
same spirit as [gen1recomp](https://github.com/bryanthaboi/gen1recomp).

The engine is hand-written. Game data — species, moves, text, graphics, maps,
music — is extracted from a cartridge image that you supply. The image is
verified, read once during import, and released. **It is never copied into the
cache and it is never written to disk.** No ROM is included here, and this
project does not emulate the Game Boy.

## Status

The data pipeline is verified against a real cartridge, and the engine runs:
you can walk the overworld, talk to people, fight wild Pokemon and catch them.

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
| Maps: headers, dimensions, block data, connections | working, 388 slots / 384 usable |
| Map events: warps, triggers, signposts, NPCs | working |
| Overworld sprites: player and NPCs | working, 102 sprites |
| Wild encounters, grass and water | working — 91 and 62 maps |
| Trainer parties | working — 532 trainers |
| Learnsets and evolutions | working — 2215 moves, 113 evolutions |
| Dialogue text and charmap | working — 1954 of 1963 text blocks |
| Font | working — the one hardcoded offset, see docs |
| Collision: terrain classification | working |
| **Engine:** overworld rendering, movement, warps | working |
| **Engine:** wild encounter trigger | working — grass, and cave floor |
| **Engine:** Pokémon stats and party | working |
| **Engine:** battles — types, damage, turn order | working |
| **Engine:** catching and party | working |
| **Engine:** save and load | working |
| Map scripts | interpreted — 1669 of 1771 run to an end |
| Standard scripts | working — 52, reached by jumpstd |
| **Engine:** yes-or-no prompts | working — 139 questions |
| Unown's 26 forms | not located — see `src/rom/pics.lua` |
| **Engine:** script interpreter | working — 14558 instructions decoded |
| **Engine:** status conditions and stat stages | working |
| Items: names, prices, pockets, effects | working — 255 items |
| **Engine:** the bag, and items in battle | working — 4 pockets |
| Item balls on the ground | working — 178 pickups |
| Hidden items | working — 85, keyed by event flag |
| Mart inventories | working — 34 shops, 27 shopkeepers |
| **Engine:** shop counters, buying and selling | working — by quantity |
| **Engine:** start menu, party list, summary | working |
| Audio | not started |
| Reading real .sav files | not started |
| **Engine:** map edge connections | working — 142 crossings |
| **Engine:** trainer battles | working — 518 trainers across 57 classes |

Import a cartridge and press enter. Move with the arrow keys or WASD; doors
warp between maps and routes run into each other at their edges, with the
player and NPCs drawn from the cartridge's own
sprites. Z or space reads a signpost or talks to someone. Walking in tall grass
starts a battle, where Z confirms and the arrows pick FIGHT, BALL or RUN — a
caught Pokemon joins your party. Balls come out of the bag and running out of
them is a real outcome. Item balls lying on the ground are picked up by facing
them and pressing Z, and stay picked up; so are the 85 items buried in the
ground, if you press Z on the right square. Talking to a shopkeeper opens their
counter, stocked with what that particular shop sells; they will buy things back
at half price, but not your key items. Pick an item and a dial asks how many —
up and down step by one, left and right by ten, and it will not let you dial
past what you can pay for or what the bag will hold. X opens the menu — party list, summaries,
and the bag, whose four pockets are filled from what the cartridge says each
item is. F5 saves, and the bag and your money go with it; a save is loaded
automatically.

402 tests pass against Crystal (USA/Europe) rev 1, SHA-1
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
| Grass encounters | `0x02A5E9` | `$0A` |
| Water encounters | `0x02B11D` | `$0A` |
| Trainer parties | `0x039A1F` | `$0E` |

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

## On pokecrystal

The script opcode table in `src/rom/script_ops.lua` — command names and operand
widths — is written from the [pokecrystal](https://github.com/pret/pokecrystal)
disassembly's documentation of the script macros.

Nothing from that project is vendored here. It is used as a reference for facts:
opcode numbers, operand widths, formula constants. Every one of those facts is
then validated against the cartridge by walking all 1,500 scripts and checking
where the walks land. Data continues to be *found* by signature search rather
than by hardcoded offset, so the importer still works across Gold, Silver and
Crystal from one code path.

## Legal

This repository contains no Nintendo, Creatures, or Game Freak assets and no
cartridge data. It requires a cartridge image that you provide. Pokémon and the
Gen 2 games are the property of their respective owners.
