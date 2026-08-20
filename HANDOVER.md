# Handover

Written at commit `6db0197` and updated since, 64 commits in, 746 tests passing
against Crystal and none failing — 764 with a second, deliberately wrong
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

`cache.FORMAT_VERSION` is 5 as of the music banks. A cache written by an earlier
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

There are 45 probes. They are diagnostics kept from each investigation, not
tests — `--probe-vm`, `--probe-channels`, `--probe-terrain` and `--probe-time`
are the ones most likely to be useful again. `--shot <mode>` renders one frame
of the running game and exits; the modes are listed in `main.lua` and cover
every feature (`grass`, `catch`, `trainer`, `mart`, `sell`, `surf`, `cut`,
`strength`, `pc`, `boxcatch`, `exp`, `blackout`, `battleparty`, `battleheal`,
`yesno`, `scriptbattle`, `faceleft`, `dex`, `dexentry`, `poisoned`, `cured`,
`whirlpool`, `nowhirlpool`, and more). `dexentry`
takes an optional species number as a fourth argument, so a particular entry's
layout can be looked at rather than whichever one the demo picks.

### Six environment traps that have cost real time

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
6. **`perl -0pi` with a `\x{...}` escape re-encodes the whole file.** Same
   damage as trap 5, different tool. A single `\x{e9}` anywhere in the
   replacement makes the string wide, which puts perl's output handle into UTF-8
   mode, and every byte in the file gets encoded a second time — one two-line
   edit turned into 150 changed lines and every `é` into `Ã©`. Perl prints
   `Wide character in print` when it happens, which is the warning to stop on.
   Type the accented character literally or edit with something else. The tell
   in `git diff` is a stat far larger than the edit.

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
57 machines, 100 songs, 207 sound effects, 68 cries, 251 Pokédex entries, 14 status
cures, and 14558 decoded script instructions.

The engine plays: overworld, warps, connections, wild and trainer battles,
catching, experience and levelling, evolution, fainting and blackout, switching,
the bag in and out of battle, shops, the script interpreter with yes/no prompts,
Surf, Cut, Strength, Whirlpool, storage boxes, the clock, the Pokédex, status
cures, music on every map with sound effects and cries over it, and reading a
real `.sav`.

### What is left, and what is in the way

| | state |
|---|---|
| Badges | tracked and gated, but nothing awards them |

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
2. **The channel bytecode.** Widths are in `src/rom/music_ops.lua`, borrowed
   from the pokecrystal audio macros the way the script opcodes were. They score
   256 of 256 boundaries and 1045 of 1045 resolving addresses — **and that is
   bounded from above only.** A width one too large is caught; a width one too
   small is invisible, because the operand is then read as a note and a note is
   one byte, so the walk covers the same distance. An earlier version of this
   file claimed the measure was sound for a fixed hypothesis. It is not, and
   that is retracted. The remaining instrument for the direction the layout
   cannot see is **listening**, because a width one too small plays a spurious
   note rather than desynchronising anything.
   That has now been done twice. Three songs were rendered and played back and
   reported as the real tunes with no spurious notes, and then a song with six
   sound effects fired over it. Together that bounds from below the **18 of 40
   commands those actually executed** — 13 from the songs, 4 the effects add
   that no song reaches at all (`pitch_sweep`, `toggle_sfx`, `sfx_toggle_noise`,
   `music_f2`), and 1 more from the cries (`duty_cycle_pattern`), which is why
   each was worth hearing separately rather than as more of the same. Two more
   (`pitch_slide`, `sound_jump`) occur in the corpus and have not been heard;
   **20 never execute
   anywhere**, and for those the borrowed widths rest on nothing but the source
   they came from. Rendering more songs and more effects is the cheap way to
   extend this — `--probe-song <rom> <report> <index>` takes a song number.
3. **The sound chip.** ~~Not started~~ **done**, in `src/audio/apu.lua`. Four
   channels, the frame sequencer, the mixer and the output capacitor. It takes
   register writes at `$FF10`–`$FF3F`, so an emulator trace could be replayed
   into it unmodified. Verified by measurement rather than by ear — frequency
   within 0.037%, both noise periods exact — because a sound chip makes a noise
   whether or not it is right. `--probe-apu` writes a WAV and an oscilloscope
   trace into the save directory; the WAV has since been played back and
   confirmed as sounding right, which is a check on the things no measurement
   was written for rather than a substitute for the measurements.
4. **The sequencer.** Done, in `src/audio/sequencer.lua`. Runs on the frame
   clock, keeps the per-channel state, follows calls, loops and jumps. 99 of the
   100 songs play and 42253 notes are struck. `--probe-song` renders any of them
   to a WAV. Two caveats worth knowing before trusting what you hear: the wave
   channel's instrument and the noise channel's drum kit are **stand-ins**,
   because neither table has been located, so channels 3 and 4 are placeholders
   while 1 and 2 are real; and the **pitch table is not in the cartridge** in any
   shape found so far, so pitches are computed from equal temperament here. See
   `--probe-pitch` for that negative result — the best fit anywhere in two
   megabytes is 14% off and is a sine table.
5. **Wiring it into the game.** Done. Each map plays its own tune, and
   `playmusic` is no longer ignored. The channel data is cached as whole banks
   (`music_banks`), because `sound_call` goes anywhere inside a bank and songs
   share subroutines; a test asserts a song rendered from the cache is sample
   for sample identical to the same song rendered from the cartridge.
   `playsound` ×189 and `cry` ×70 are **still ignored on purpose**.
6. **Sound effects.** Done. The table is at `0x0E927C`, 207 slots, and
   `playsound` indexes it directly from zero. It was invisible because the song
   locator insists a header opens on channel 0, which every song does and no
   effect does — Gen 2 drives the four hardware channels from two sets of slots
   and effects use the second. The id mapping was settled by scoring **every**
   offset in the cartridge against the ids the scripts ask for: exactly one
   explains all 32, and running the same scan on `playmusic`, whose answer was
   already known, puts the song table top and so validates the method.
7. **Cries.** Done. Two structures: a block of **68 base cries** between the
   song and effect tables, and a **251-record table** (six bytes: base cry,
   pitch, length) at `0x0F2787` in Crystal and `0x0F2747` in Gold. Sixty-eight
   sounds make 251 voices — pitch falls and length grows as a family evolves.
   Pitch is **signed**; 28 species carry a negative one. Two traps, both worth
   knowing because they will recur: a header's channels **rise but need not be
   consecutive** (the first cry skips the wave channel, opening on 4, 5, 7), and
   the 13 bytes between the tables push a three-byte grid walk permanently out
   of phase with the cry block. The pitch is applied as a frequency offset,
   which is what the cartridge's own `pitch_offset` does; **how the length
   scales is inferred** as a multiplier against 256. The cries have since been
   played back and sound right, families included, which confirms that scaling
   is about right — but an ear cannot tell 256 from a divisor a few percent
   off, so the detail remains unmeasured.

### The claim, tested at last

`README.md` says all three games work from one code path. A **Pokémon Gold**
cartridge is now on this machine, at the repository root (gitignored — `*.gbc`
is, and must stay, excluded), and it has been imported.

**It largely holds.** Every signature table located at a completely different
offset from Crystal's, which is the whole point of searching rather than
hardcoding: base stats, species and move names, items, moves, 28 tilesets, 368
maps, 1241 warps, encounters, learnsets, trainers, marts, the machine list, the
status cures, the Pokédex entries, the music table, the sound effects, the
cries. Whirlpool comes out as collision `$24` on both.

Four things fail on Gold, and each is honest about it rather than wrong:

| | why |
|---|---|
| font | 4 offsets satisfy the layout; refuses to guess. Crystal's font is the one **hardcoded** offset and it does not apply here, so the blind search runs and correctly declines. |
| std_scripts | longest run of pointers is 6. The table is elsewhere or shaped differently in Gold. |
| obstacles | needs the standard scripts, so it is blocked by the row above rather than broken. |
| sprites | no offset validated as a pic pointer table — the bank bias that Crystal uses is `$36` and Gold's differs. |

Two more numbers are lower and worth a look rather than a shrug: **446 of 2060**
scripts read as text against Crystal's 893 of 2200, and **258** blocks
unreadable against Crystal's 21. Some of that is the missing standard-script
table; whether all of it is has not been checked.

So the next Gold job, in order: the pic table's bank bias, then the
standard-script table, which unblocks obstacles and probably much of the script
shortfall.

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
