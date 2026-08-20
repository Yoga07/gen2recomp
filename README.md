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
| Pokémon front and back sprites | working, 250 of 251 species — bank mapping solved, not assumed |
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
| **Engine:** experience, levelling, evolution | working — six growth curves |
| **Engine:** fainting, sending out the next, blackout | working |
| **Engine:** switching, and the bag in battle | working — FIGHT/PKMN/PACK/RUN |
| TM and HM move list | working — 57 machines |
| **Engine:** Surf | working — badges tracked but not earnable |
| Cut trees and boulders | working — found, not listed |
| **Engine:** Cut and Strength | working — trees fall, boulders push |
| **Engine:** Whirlpool | working — water you cannot cross without the HM |
| Whirlpool | working — collision `$24`, found by shape and confirmed by the art |
| **Engine:** save and load | working |
| Map scripts | interpreted — 1743 of 1771 run to an end |
| **Engine:** battles started by scripts | working — wild and trainer |
| Standard scripts | working — 52 in Crystal, 46 in Gold, found by anchoring |
| **Engine:** yes-or-no prompts | working — 139 questions |
| Movement blocks | working — 353 walks decoded |
| **Engine:** NPCs turn, walk and vanish | working |
| Unown's 26 forms | not located — see `src/rom/pics.lua` |
| **Engine:** script interpreter | working — 14558 instructions decoded |
| **Engine:** status conditions and stat stages | working |
| Items: names, prices, pockets, effects | working — 255 items |
| Status cures: which item undoes what | working — 14 items |
| **Engine:** the bag, and items in battle | working — 4 pockets |
| Item balls on the ground | working — 178 pickups |
| Hidden items | working — 85, keyed by event flag |
| Mart inventories | working — 34 shops, 27 shopkeepers |
| **Engine:** shop counters, buying and selling | working — by quantity |
| **Engine:** start menu, party list, summary | working |
| Pokédex entries: class, height, weight, text | working — 251 entries |
| **Engine:** the Pokédex | working — seen and caught, list and detail |
| **Engine:** storage boxes | working — 14 boxes of 20 |
| **Engine:** day/night clock | working — encounters and scripts |
| Music table | located — 103 slots, 100 songs, 256 channel extents |
| Channel bytecode | widths borrowed from pokecrystal — bounded above, see docs |
| Game Boy sound chip | working — measured against the hardware, and heard |
| **Engine:** music sequencer | working — 99 of 100 songs play, and sound right |
| **Engine:** music while you play | working — each map plays its own tune |
| Sound effect table | working — 207 slots, found behind the songs |
| **Engine:** sound effects | working — scripts play them over the music |
| Cries | working — 68 base cries, 251 species records, and they sound right |
| **Engine:** cries | working — scripts make Pokémon shout |
| Reading real .sav files | working — read from a real Crystal save |
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
item is. The Pokédex is there too: every species you have met and every one you
have owned, and a page on each with its sprite, its classification, its height
and weight, its typing, its base stats and the two pages of description the
cartridge itself carries, turned over with left and right. Each map plays its
own music, synthesised from the cartridge's channel data through a Game Boy
sound chip written from the hardware specification. F5 saves, and the
bag, your money and the dex go with it; a save is loaded automatically.

Drop a cartridge `.sav` onto the window while playing and its party comes
across. Nothing about the save's layout is hardcoded: the party is found by
checking that every member's stats come back out of the stat formula.

746 tests pass against Crystal (USA/Europe) rev 1, SHA-1
`f2f52230b536214ef7c9924f483392993e226cfb`, and a further 19 run when a second,
deliberately wrong cartridge is supplied — 765 in all. Nothing is claimed to be
correct until it round-trips against content known independently of this code.

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
| Pokédex entry pointers | `0x044378` | `$11` |
| Status cures | `0x00F071` | `$03` |
| Music table | `0x0E906E` | `$3A` |
| Sound effect table | `0x0E927C` | `$3A` |
| Base cries | `0x0E91B0` | `$3A` |
| Species cries | `0x0F2787` | `$3C` |

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

The second half of that is tested rather than asserted. Pass a non-Gen-2
cartridge as `-Other` and the suite runs every locator against it and requires
all of them to refuse:

```bash
scripts\test.ps1 -Rom "<crystal>" -Other "<a Gen 1 cartridge>"
```

A Gen 1 image is the interesting adversary, because it pads its species names to
the same ten bytes in nearly the same encoding — three of the six signatures do
occur in it, and validation is what throws them out. Finding that test also
found a real bug: the sprite-palette search used to accept a Pokémon Red image.
See the architecture notes.

The **first** half is no longer only a design claim either. A Pokémon Gold
cartridge has been imported, and every signature table located — at completely
different offsets from Crystal's, which is the whole point of searching rather
than hardcoding. All 250 of its sprites decode, in colour, from Gold's own
palettes.

Gold also broke an assumption worth recording. Its pic pointers are biased by a
constant like Crystal's, except that no constant works: Gold's pic region has a
hole where two banks hold other data, and the pics displaced by it are recorded
under the bank numbers the region skipped. The locator now solves for the whole
stored-bank-to-real-bank mapping rather than for one number, refusing when two
banks fit equally well. Crystal's answer comes back as the uniform `+$36` it
always was.

The standard-script table broke a second one. It is there in Gold, 46 entries at
`0x100000`, and the search had already found it and thrown it away: the rule
said half the entries must read as real routines, and Gold's standard scripts
are short enough that only 13 of 46 do, against 37 of Crystal's 52. That number
is a fact about the cartridge, not about the table. The table is now found by
what is true of it on both — it begins at the very start of the bank all its
entries name — and the strict count only has to beat the best run that is not
the table, which it does by 13 to 5 and 37 to 18. That also unblocked the
obstacle detector, so Gold's cut trees and boulders are found too.

One thing still fails on Gold, and it says so rather than guessing: the font,
whose Crystal offset is the one hardcoded value in the project, so the blind
search runs and declines between four candidates. See the handover.

Discovered offsets are recorded in each cache's `manifest.lua`.

## Layout

```
main.lua           entry point; importer UI
conf.lua           LÖVE configuration
src/rom/           cartridge decoding — header, banking, LZ, graphics, text
src/audio/         the Game Boy sound chip; knows nothing of the cartridge
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
