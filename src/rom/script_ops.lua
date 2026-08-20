-- Crystal's script opcode table.
--
-- Operand widths and command names here are reference facts, taken from the
-- pret/pokecrystal disassembly's script macros. Nothing from that project is
-- vendored: this is a table of numbers written from documentation, and every
-- entry is validated against the cartridge by walking all 1500 scripts and
-- requiring the walks to land exactly on script boundaries.
--
-- That validation is the point. The earlier attempt inferred widths from script
-- extents alone and got more than half of them wrong while reporting zero
-- overruns, because it marked every opcode it learned as terminating — and a
-- walk that stops at the first instruction can never overrun. With most opcodes
-- now known to continue, an overrun is possible again, so the measure means
-- something.
--
-- A map id is two bytes (group then number), which is why several commands are
-- wider than their operand list first suggests.

local script_ops = {}

local MAP_ID = 2
local POINTER = 2
local FAR_POINTER = 3
local MONEY = 3 -- three-byte big-endian quantity

-- opcode -> { name, operands, ends }
-- `ends` marks commands after which linear execution does not continue: script
-- terminators, and unconditional jumps that transfer control away.
script_ops.table = {
  [0x00] = { "scall", POINTER },
  [0x01] = { "farscall", FAR_POINTER },
  [0x02] = { "memcall", POINTER },
  [0x03] = { "sjump", POINTER, true },
  [0x04] = { "farsjump", FAR_POINTER, true },
  [0x05] = { "memjump", POINTER, true },
  [0x06] = { "ifequal", 1 + POINTER },
  [0x07] = { "ifnotequal", 1 + POINTER },
  [0x08] = { "iffalse", POINTER },
  [0x09] = { "iftrue", POINTER },
  [0x0A] = { "ifgreater", 1 + POINTER },
  [0x0B] = { "ifless", 1 + POINTER },
  [0x0C] = { "jumpstd", POINTER, true },
  [0x0D] = { "callstd", POINTER },
  [0x0E] = { "callasm", FAR_POINTER },
  [0x0F] = { "special", POINTER },
  [0x10] = { "memcallasm", POINTER },
  [0x11] = { "checkmapscene", MAP_ID },
  [0x12] = { "setmapscene", MAP_ID + 1 },
  [0x13] = { "checkscene", 0 },
  [0x14] = { "setscene", 1 },
  [0x15] = { "setval", 1 },
  [0x16] = { "addval", 1 },
  [0x17] = { "random", 1 },
  [0x18] = { "checkver", 0 },
  [0x19] = { "readmem", POINTER },
  [0x1A] = { "writemem", POINTER },
  [0x1B] = { "loadmem", POINTER + 1 },
  [0x1C] = { "readvar", 1 },
  [0x1D] = { "writevar", 1 },
  [0x1E] = { "loadvar", 2 },
  [0x1F] = { "giveitem", 2 },
  [0x20] = { "takeitem", 2 },
  [0x21] = { "checkitem", 1 },
  [0x22] = { "givemoney", 1 + MONEY },
  [0x23] = { "takemoney", 1 + MONEY },
  [0x24] = { "checkmoney", 1 + MONEY },
  [0x25] = { "givecoins", POINTER },
  [0x26] = { "takecoins", POINTER },
  [0x27] = { "checkcoins", POINTER },
  [0x28] = { "addcellnum", 1 },
  [0x29] = { "delcellnum", 1 },
  [0x2A] = { "checkcellnum", 1 },
  [0x2B] = { "checktime", 1 },
  [0x2C] = { "checkpoke", 1 },
  [0x2D] = { "givepoke", 4 },
  [0x2E] = { "giveegg", 2 },
  [0x2F] = { "givepokemail", POINTER },
  [0x30] = { "checkpokemail", POINTER },
  [0x31] = { "checkevent", POINTER },
  [0x32] = { "clearevent", POINTER },
  [0x33] = { "setevent", POINTER },
  [0x34] = { "checkflag", POINTER },
  [0x35] = { "clearflag", POINTER },
  [0x36] = { "setflag", POINTER },
  [0x37] = { "wildon", 0 },
  [0x38] = { "wildoff", 0 },
  [0x39] = { "xycompare", POINTER },
  [0x3A] = { "warpmod", 1 + MAP_ID },
  [0x3B] = { "blackoutmod", MAP_ID },
  [0x3C] = { "warp", MAP_ID + 2 },
  [0x3D] = { "getmoney", 2 },
  [0x3E] = { "getcoins", 1 },
  [0x3F] = { "getnum", 1 },
  [0x40] = { "getmonname", 2 },
  [0x41] = { "getitemname", 2 },
  [0x42] = { "getcurlandmarkname", 1 },
  [0x43] = { "gettrainername", 3 },
  [0x44] = { "getstring", POINTER + 1 },
  [0x45] = { "itemnotify", 0 },
  [0x46] = { "pocketisfull", 0 },
  [0x47] = { "opentext", 0 },
  [0x48] = { "reanchormap", 1 },
  [0x49] = { "closetext", 0 },
  [0x4A] = { "writeunusedbyte", 1 },
  [0x4B] = { "farwritetext", FAR_POINTER },
  [0x4C] = { "writetext", POINTER },
  [0x4D] = { "repeattext", 2 },
  [0x4E] = { "yesorno", 0 },
  [0x4F] = { "loadmenu", POINTER },
  [0x50] = { "closewindow", 0 },
  [0x51] = { "jumptextfaceplayer", POINTER, true },
  [0x52] = { "farjumptext", FAR_POINTER, true },
  [0x53] = { "jumptext", POINTER, true },
  [0x54] = { "waitbutton", 0 },
  [0x55] = { "promptbutton", 0 },
  [0x56] = { "pokepic", 1 },
  [0x57] = { "closepokepic", 0 },
  [0x58] = { "_2dmenu", 0 },
  [0x59] = { "verticalmenu", 0 },
  [0x5A] = { "loadpikachudata", 0 },
  [0x5B] = { "randomwildmon", 0 },
  [0x5C] = { "loadtemptrainer", 0 },
  [0x5D] = { "loadwildmon", 2 },
  [0x5E] = { "loadtrainer", 2 },
  [0x5F] = { "startbattle", 0 },
  [0x60] = { "reloadmapafterbattle", 0 },
  [0x61] = { "catchtutorial", 1 },
  [0x62] = { "trainertext", 1 },
  [0x63] = { "trainerflagaction", 1 },
  [0x64] = { "winlosstext", POINTER * 2 },
  [0x65] = { "scripttalkafter", 0 },
  [0x66] = { "endifjustbattled", 0 },
  [0x67] = { "checkjustbattled", 0 },
  [0x68] = { "setlasttalked", 1 },
  [0x69] = { "applymovement", 1 + POINTER },
  [0x6A] = { "applymovementlasttalked", POINTER },
  [0x6B] = { "faceplayer", 0 },
  [0x6C] = { "faceobject", 2 },
  [0x6D] = { "variablesprite", 2 },
  [0x6E] = { "disappear", 1 },
  [0x6F] = { "appear", 1 },
  [0x70] = { "follow", 2 },
  [0x71] = { "stopfollow", 0 },
  [0x72] = { "moveobject", 3 },
  [0x73] = { "writeobjectxy", 1 },
  [0x74] = { "loademote", 1 },
  [0x75] = { "showemote", 3 },
  [0x76] = { "turnobject", 2 },
  [0x77] = { "follownotexact", 2 },
  [0x78] = { "earthquake", 1 },
  [0x79] = { "changemapblocks", FAR_POINTER },
  [0x7A] = { "changeblock", 3 },
  [0x7B] = { "reloadmap", 0 },
  [0x7C] = { "refreshmap", 0 },
  [0x7D] = { "writecmdqueue", POINTER },
  [0x7E] = { "delcmdqueue", 1 },
  [0x7F] = { "playmusic", POINTER },
  [0x80] = { "encountermusic", 0 },
  [0x81] = { "musicfadeout", POINTER + 1 },
  [0x82] = { "playmapmusic", 0 },
  [0x83] = { "dontrestartmapmusic", 0 },
  [0x84] = { "cry", POINTER },
  [0x85] = { "playsound", POINTER },
  [0x86] = { "waitsfx", 0 },
  [0x87] = { "warpsound", 0 },
  [0x88] = { "specialsound", 0 },
  [0x89] = { "autoinput", FAR_POINTER },
  [0x8A] = { "newloadmap", 1 },
  [0x8B] = { "pause", 1 },
  [0x8C] = { "deactivatefacing", 1 },
  [0x8D] = { "sdefer", POINTER },
  [0x8E] = { "warpcheck", 0 },
  [0x8F] = { "stopandsjump", POINTER, true },
  [0x90] = { "endcallback", 0, true },
  [0x91] = { "end", 0, true },
  [0x92] = { "reloadend", 1, true },
  [0x93] = { "endall", 0, true },
  [0x94] = { "pokemart", 1 + POINTER },
  [0x95] = { "elevator", POINTER },
  [0x96] = { "trade", 1 },
  [0x97] = { "askforphonenumber", 1 },
  [0x98] = { "phonecall", POINTER },
  [0x99] = { "hangup", 0 },
  [0x9A] = { "describedecoration", 1 },
  [0x9B] = { "fruittree", 1 },
  [0x9C] = { "specialphonecall", POINTER },
  [0x9D] = { "checkphonecall", 0 },
  [0x9E] = { "verbosegiveitem", 2 },
  [0x9F] = { "verbosegiveitemvar", 2 },
  [0xA0] = { "swarm", 1 + MAP_ID },
  [0xA1] = { "halloffame", 0, true },
  [0xA2] = { "credits", 0, true },
  [0xA3] = { "warpfacing", 1 + MAP_ID + 2 },
  [0xA4] = { "battletowertext", 1 },
  [0xA5] = { "getlandmarkname", 2 },
  [0xA6] = { "gettrainerclassname", 2 },
  [0xA7] = { "getname", 3 },
  [0xA8] = { "wait", 1 },
  [0xA9] = { "checksave", 0 },
}

-- The one command Crystal has that Gold does not.
--
-- Gold's list is this one with `farjumptext` taken out, so every command above
-- $52 is one number lower there. Three independent measurements say so, and
-- each is sharper than the last:
--
--   * The project's width inference, which learns from where scripts end rather
--     than from any specification, reads $52 as taking two operand bytes on
--     Gold where this table says three. Two is a near pointer, three is a far
--     one.
--   * Walks land exactly on their script boundary 787 times under the shorter
--     list against 463 under this one, while doing the same to Crystal drops it
--     from 833 to 368. Crystal never uses $52 in a map script, which is why the
--     difference went unnoticed and why the cartridge that has the command
--     offers no evidence about its width.
--   * Every one of Gold's 288 movement blocks decodes under the shorter list.
--     That one took a detour: the test that counts them named $69 and $6A
--     directly, so it was reading Crystal's applymovement out of Gold's shifted
--     scripts and reported 6 of 341, which looks exactly like evidence against
--     the shift. It was evidence against the test.
--
-- Reading Gold with this list is quiet rather than loud. The walk still lands
-- plausibly, text simply comes out of the wrong bytes, and the import reports a
-- smaller number without saying anything is wrong: 446 of 2060 scripts yielding
-- text rather than 824, and 261 unreadable blocks rather than 21.
script_ops.INSERTED = 0x52

--- This list with the inserted command removed and everything above it slid
-- down by one, which is the list the older cartridges use.
local function without_inserted(source)
  local variant = {}
  for opcode, entry in pairs(source) do
    if opcode < script_ops.INSERTED then
      variant[opcode] = entry
    elseif opcode > script_ops.INSERTED then
      variant[opcode - 1] = entry
    end
  end
  return variant
end

-- Which commands take a pointer to a text block, by name rather than by number,
-- so that they follow the command wherever a variant puts it. Getting this
-- wrong is quiet: the walk still lands correctly and the text simply comes out
-- of the wrong bytes.
local NEAR_TEXT = {
  writetext = true, jumptextfaceplayer = true, jumptext = true,
}
local FAR_TEXT = { farwritetext = true, farjumptext = true }

--- Adopt a command list, deriving everything keyed by opcode from it.
function script_ops.use(commands, variant)
  script_ops.commands = commands
  script_ops.variant = variant
  script_ops.text_commands = {}
  script_ops.far_text_commands = {}
  for opcode, entry in pairs(commands) do
    if NEAR_TEXT[entry[1]] then
      script_ops.text_commands[opcode] = entry[1]
    elseif FAR_TEXT[entry[1]] then
      script_ops.far_text_commands[opcode] = entry[1]
    end
  end
end

--- Widths and terminators in the shape the walker wants.
function script_ops.widths(commands)
  local widths, terminators, names = {}, {}, {}
  for opcode, entry in pairs(commands or script_ops.commands) do
    names[opcode] = entry[1]
    widths[opcode] = entry[2]
    if entry[3] then
      terminators[opcode] = true
    end
  end
  return widths, terminators, names
end

--- Decide which list this cartridge uses, and adopt it.
--
-- The measure is the one the widths were validated with in the first place: a
-- wrong width desynchronises the walk, so it sails past the end of the script
-- instead of landing on it. Whichever list lands more of the cartridge's own
-- scripts exactly on their boundary is the list the cartridge was built with.
--
-- @param sorted script entry points, from script_table.collect_entries
-- @return the variant name, and how each scored
function script_ops.select(rom, sorted)
  -- Required here rather than at the top because script_table is a consumer of
  -- this module's tables, and only this function needs it.
  local script_table = require("src.rom.script_table")

  local best
  local scores = {}
  for _, candidate in ipairs({
    { variant = "crystal", commands = script_ops.table },
    { variant = "gold", commands = without_inserted(script_ops.table) },
  }) do
    local widths, terminators = script_ops.widths(candidate.commands)
    local counts = script_table.score(rom, sorted,
      { widths = widths, terminators = terminators })
    candidate.exact = counts.exact
    scores[candidate.variant] = counts.exact
    if not best or counts.exact > best.exact then
      best = candidate
    end
  end

  script_ops.use(best.commands, best.variant)
  return best.variant, scores
end

-- Crystal's list until a cartridge says otherwise.
script_ops.use(script_ops.table, "crystal")

return script_ops
