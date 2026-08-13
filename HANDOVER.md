# Handover

Written at commit `6db0197` and updated since, 55 commits in, 716 tests passing
against Crystal and none failing — 734 with a second, deliberately wrong
cartridge supplied. This is what a new session needs to pick the work up.

`README.md` says what the project is and what state each area is in.
`docs/architecture.md` says *why* things are the way they are, and is where the
dead ends are recorded. Read both. This file is the working context that is not
in either.

---

## Running it

Nothing is on `PATH`. LÖVE lives in the scratchpad as a portable zip:

```
C:\Users\yoges\AppData\Local\Temp\claude\E--projects\<session>\scratchpad\love-11.5-win64\love.exe
```

A new session gets a **new scratchpad directory**, so LÖVE has to be downloaded
and unzipped again. It is a portable build — unzip and run, no install.

The cartridge and the save:

```
C:\Users\yoges\Downloads\Pokemon_ Crystal Version\Pokemon - Crystal Version (USA, Europe) (Rev 1).gbc
C:\Users\yoges\Downloads\Pokémon - Crystal Version\Pokémon - Crystal Version\Pokémon - Crystal Version.sav
```

The test wrapper, which is the command used most:

```bash
scripts\test.ps1 -Rom "<rom path>" [-Other "<a non-Gen-2 cartridge>"]
```

`-Other` is optional and skipped when absent. Given one, the suite runs every
locator against it and requires all of them to refuse — that is what tests the
README's "fails loudly" claim. A Gen 1 cartridge is the useful adversary; there
is one at `C:\Users\yoges\Downloads\Pokemon - Red Version (UE)[!] (1)\`.

It needs `$env:LOVE_EXE` pointing at `love.exe`.

`cache.FORMAT_VERSION` is 4 as of the whirlpool value. A cache written by an earlier
build is reported as stale and has to be re-imported rather than half-read, so
the first thing a new session does after checking out is usually `--import`.

Everything else goes through headless entry points, because drag-and-drop
cannot be scripted:

```bash
love . --test <rom> <report>
love . --import <rom> <report>
love . --shot <png> <mode>
love . --probe-<name> <rom> <report> [extra]
```

There are 39 probes. They are diagnostics kept from each investigation, not
tests — `--probe-vm`, `--probe-channels`, `--probe-terrain` and `--probe-time`
are the ones most likely to be useful again. `--shot <mode>` renders one frame
of the running game and exits; the modes are listed in `main.lua` and cover
every feature (`grass`, `catch`, `trainer`, `mart`, `sell`, `surf`, `cut`,
`strength`, `pc`, `boxcatch`, `exp`, `blackout`, `battleparty`, `battleheal`,
`yesno`, `scriptbattle`, `faceleft`, `dex`, `dexentry`, `poisoned`, `cured`,
`whirlpool`, `nowhirlpool`, and more). `dexentry`
takes an optional species number as a fourth argument, so a particular entry's
layout can be looked at rather than whichever one the demo picks.

### Three environment traps that have cost real time

1. **PowerShell `Start-Process -ArgumentList` joins array elements without
   quoting.** A ROM path with spaces is silently truncated and the run exits 0
   having done nothing. Every element must be quoted individually. This is why
   `scripts\test.ps1` exists.
2. **Lua's `io.open` goes through the Windows ANSI codepage.** A path with an
   accent in it — which is exactly where the save lives — arrives as UTF-8 and
   does not open. A file dropped on the window carries LÖVE's own handle and is
   fine; naming one on the command line is not. Copy it somewhere ASCII first.
3. **`replace_all` on a code edit matches indentation.** A partial replacement
   is a silent failure. This produced a bug that survived two fix attempts
   because the count did not move — see the interpreter section of the
   architecture notes.
4. **`Test-Path` treats `[` and `]` as wildcards.** ROM filenames from the usual
   dump sets are full of them — `Pokemon Red (UE)[!].gb` — so a plain
   `Test-Path` reports a file that is plainly there as missing. `scripts\test.ps1`
   uses `-LiteralPath` throughout. Same family as trap 1.
5. **`Get-Content -Raw` piped into `Set-Content` destroys UTF-8.** PowerShell 5.1
   reads as the ANSI codepage unless told otherwise, so every em dash and
   accented letter comes back as three Latin-1 characters and is then written
   out as UTF-8 again — double encoded, plus a BOM on the front. These files are
   full of both. Edit them with a tool that round-trips UTF-8; if a shell
   rewrite is unavoidable, pass `-Encoding UTF8` to *both* ends. `git diff`
   catches it immediately, which is the reason to look before committing.

---

## The discipline

This is the part worth preserving. It is not style, it is what has kept the
project correct.

**Nothing is claimed until it round-trips against content known independently
of this code.** A table is located by searching for a signature, then accepted
only when the whole thing decodes *and* spot checks land on records that were
not searched for.

**Two candidates means refuse, not guess.** Several locators return "validated
at N offsets; refusing to guess" and that has caught real ambiguity.

**Ask what a wrong answer would score.** This is the single most valuable habit
here. Examples that all nearly shipped:

- The hidden-item reading scored 74 of 85 — and chance was 74 of 85, because
  87% of byte values name a real item.
- The channel bytecode's extent measure gives a perfect score to a table of
  *zeros* — 148 of 148 when it was found, 256 of 256 now.
- A cut tree "gated a path" 62% of the time; rendering showed a wall line, and
  a wall has floor on both sides of every cell.
- The obstacle detector's first answer was the Pokémon Centre nurse.

**A thing that always produces output needs measuring, not sampling.** The
sound chip makes a noise whether or not it is right, so nothing about it is
judged by ear: frequencies are counted, duty cycles timed, shift-register
periods counted exactly. That found a missing output capacitor on the first
run, which no amount of listening would have isolated.

**Render it and look.** Bugs the tests could not see: column-major tiles, a
missing `/` glyph, text overrunning 160px, the battle bag never being drawn, an
Antidote healing nothing, POKéMON losing its accent. When something is on
screen, screenshot it.

**Negative results are deliverables.** The channel bytecode and the specials are
written up with the evidence for why they are not solved, and the degeneracy of
the vacuous metric is asserted as a *passing test* so nobody adopts it again.

**pokecrystal is a reference for facts, never vendored.** Opcode numbers,
operand widths, formula constants. Every borrowed fact is then validated against
the cartridge. Data is still *found* by search, so Gold and Silver work from one
code path.

---

## Where things stand

The extraction is close to complete: species, moves, stats, learnsets,
evolutions, sprites, palettes, tilesets, 388 maps, events, text, font,
encounters, 541 trainers, 255 items, 34 marts, 178 item balls, 85 hidden items,
57 machines, 100 songs, 251 Pokédex entries, 14 status cures, and 14558 decoded
script instructions.

The engine plays: overworld, warps, connections, wild and trainer battles,
catching, experience and levelling, evolution, fainting and blackout, switching,
the bag in and out of battle, shops, the script interpreter with yes/no prompts,
Surf, Cut, Strength, Whirlpool, storage boxes, the clock, the Pokédex, status
cures, and reading a real `.sav`.

### What is left, and what is in the way

| | state |
|---|---|
| Badges | tracked and gated, but nothing awards them |
| Audio playback | the chip is written; the channel bytecode is what is left |
| `special` routines | 127 of them, assembly, not runnable from bytecode |
| Unown's 26 forms | pic table locator does not find them |

The last four are walls, each documented with what was tried. **Do not attack
them by guessing.** If a new session wants one of them, the honest routes are:
an emulator to watch registers (audio, specials), or a Gold/Silver ROM to
cross-check the extraction.

Audio is the one worth reading the notes on before starting, because it is four
problems and only one of them is the wall:

1. **The tables.** The music table is done — 103 slots, 100 songs, 256 channel
   extents. It read 59 until the scripts were noticed indexing past its end.
2. **The channel bytecode.** The wall. The extent measure is degenerate as a
   *search objective* — width zero is admissible, so a table of zeros scores
   perfectly — but it is a perfectly good *test of a fixed hypothesis*. A width
   table proposed from outside, from the disassembly the script opcodes already
   came from or from an emulator's writes to `$FF10`–`$FF3F`, either walks all
   256 extents exactly or does not, and cannot bend itself to fit. That is the
   route, and it is the same one the script opcodes took.
3. **The sound chip.** ~~Not started~~ **done**, in `src/audio/apu.lua`. Four
   channels, the frame sequencer, the mixer and the output capacitor. It takes
   register writes at `$FF10`–`$FF3F`, so an emulator trace could be replayed
   into it unmodified. Verified by measurement rather than by ear — frequency
   within 0.037%, both noise periods exact — because a sound chip makes a noise
   whether or not it is right. `--probe-apu` writes a WAV and an oscilloscope
   trace into the save directory; the WAV has since been played back and
   confirmed as sounding right, which is a check on the things no measurement
   was written for rather than a substitute for the measurements.
4. **Wiring it in.** Small. `playsound` ×189, `playmusic` ×79, `cry` ×70 and
   `waitsfx` ×85 are currently in the interpreter's ignored list, and map
   headers already name a music id. `cry` operands run to 250, so they are
   species ids rather than indices into a cry table.

### The one unverified claim

`README.md` says all three games work from one code path. That is the design and
nothing hardcodes Crystal — but **it has only ever run against Crystal**. One
import against a Gold or Silver ROM would confirm it or find real bugs. This is
the highest-value thing a new session could do cheaply, and it needs a ROM from
the user: there is no Gold or Silver image on this machine, only Crystal and a
Gen 1 Red.

The *other* half of that claim — that a dump which would decode into nonsense
fails loudly — is now tested rather than asserted, using the Red image as an
adversary. It found a real bug: the sprite-palette locator was accepting Red.
That is worth knowing as a precedent. **Refusing the wrong cartridge and
accepting the right one are different claims**, and only the first is covered.

---

## Deviations from the games, on purpose

Each is a case where the cartridge's own logic is out of reach and a working
feature was preferred to a faithful dead end. All are recorded in
`docs/architecture.md`:

- The **PC is on the start menu**, not a machine you stand at.
- **Badges are not enforced**, because nothing can award them.
- The **starting bag and ¥3000** are engine stand-ins.
- **Blackout returns you to where the game began**, not the last Centre.
- A **full box rolls on to the next** instead of refusing.
- **`yesorno` answers no** when a caller resumes without answering.
- The **font offset is the one hardcoded value**, asserted then verified.
- The **dex prints no inch mark**, because the height is formatted in assembly
  and no dex text contains one to read the glyph off.

---

## Working style the user asked for

Keep going without stopping to check in; ask only when genuinely blocked or a
decision is needed. Commit and push each finished piece — the remote is
`https://github.com/Yoga07/gen2recomp.git` and pushing has standing approval.
Write the commit message as prose explaining *why*, including what was wrong
before. Update `README.md` (status table and test count) and
`docs/architecture.md` in the same commit.

Git on this machine: use a message file with `git commit -F`, because a
here-string containing `&` breaks PowerShell argument parsing. `git push` writes
progress to stderr, which PowerShell 5.1 wraps as `NativeCommandError` — the
push succeeded if the last line shows the ref update.
