# LethalEnforcers: hardware notes

What the board is, from MAME and any other source, each fact with where it came from.

Source: MAME `src/mame/konami/lethal.cpp` at commit `dedb5227403` (`mame0289-1527`), and
`mame -listxml` from MAME 0.289. Device files: `konami/k054156_k054157_k056832.cpp`,
`konami/k053244_k053245.cpp`, `konami/k054000.cpp`, `konami/konami_helper.cpp`,
`sound/k054321.cpp`, `sound/k054539.cpp`, `machine/eepromser.cpp`. Everything here is MAME's
model unless marked otherwise. Line numbers are `lethal.cpp`'s.

## Sets

All nine verify against MAME 0.289's `-verifyroms`. Driver lines 957-968. Every set carries
`MACHINE_IMPERFECT_GRAPHICS | MACHINE_SUPPORTS_SAVE`; `-listxml` adds sound `imperfect`.

| Set | Version | Program ROM | Inputs | Orientation |
|---|---|---|---|---|
| `lethalen` (parent) | UAE, 11/19/92 | `191uae01.u4` | `lethalen` | FLIP_Y |
| `lethalenub` | UAB, 09/01/92 | `191uab01.u4` | `lethalen` | FLIP_Y |
| `lethalenua` | UAA, 08/17/92 | `191uaa01.u4` | `lethalen` | FLIP_Y |
| `lethalenux` | unknown US, 08/06/92, fails ROM test | `191xxx01.u4` | `lethalen` | FLIP_Y |
| `lethaleneae` | EAE, 11/19/92 | `191eae01.u4` | `lethalene` | FLIP_Y |
| `lethalenead` | EAD, 11/11/92 | `191ead01.u4` | `lethalene` | FLIP_Y |
| `lethaleneab` | EAB, 10/14/92 | `191eab01.u4` | `lethalene` | FLIP_Y |
| `lethaleneaa` | EAA, 09/09/92 | `191_a01.u4` | `lethalene` | FLIP_Y |
| `lethalenj` | JAD, 12/04/92 | `191jad01.u4` | `lethalenj` | FLIP_X |

Region CRCs compared across sets (`-listxml`): only the 256 KB main program and the 128-byte
EEPROM image differ. The Z80 program, tile, sprite and sample ROMs are byte-identical in all
nine. One `.rbf`; per-set differences are the program ROM, the EEPROM image, the DIP layout,
the gun axis direction and the orientation.

Total ROM per set: 9,764,992 bytes loaded (`-listxml`).

| Region | Bytes loaded | Region size | Layout |
|---|---|---|---|
| `maincpu` | 0x40000 | 0x40000 | one 27C4001 |
| `soundcpu` | 0x10000 | 0x10000 | one 27C512 |
| `k056832` (tiles) | 0x400000 | 0x400000 | four 1 MB, `ROM_LOAD32_WORD` pairs |
| `k053244` (sprites) | 0x300000 | 0x400000, `ERASE00` | three 1 MB, `ROM_LOAD32_WORD`; top 1 MB zero |
| `k054539` (samples) | 0x200000 | 0x200000 | one 2 MB |
| `eeprom` | 0x80 | 0x80 | default NVRAM per set |

## CPUs and chips

| Tag | Part | Clock | Role | Existing RTL |
|---|---|---|---|---|
| `maincpu` | HD63C09E | 3 MHz, 24/8 (line 683, "verified on pcb") | main | jtframe `mc6809i` (6809 only). No HD6309 RTL found; not needed, see below |
| `soundcpu` | Z80B | 6 MHz, 24/4 (line 686, "verified on pcb") | sound | jtframe `jtframe_z80` (T80) |
| `k056832` | 054156 + two 054157 | pixel clock | four tilemaps, 8 bpp | jtcores `modules/jt05415x`; KonamiGX `gx_tilemap.sv` |
| `k053244` | 053245A + two 053244A | pixel clock | sprites, 6 bpp | jtcores `cores/riders/hdl/jt053244.sv` |
| `k054000` | 054000 | - | collision / protection | jtcores `cores/simson/hdl/jtk054000.v` |
| `k054321` | 054321 (inside 054986A) | - | sound latches, volume | jtcores `cores/riders/hdl/jt054321.v` |
| `k054539` | 054539 | 18.432 MHz (line 722) | 8-channel PCM/ADPCM | KonamiGX `rtl/sound/gx_k054539.sv` |
| `eeprom` | ER5911, 128x8 (line 691) | - | settings | jtcores `modules/jteeprom/hdl/jt5911.sv`, `PROG=0` |
| - | 052535 x3 | - | video DAC | none needed |

**The HD6309 runs 6809 code only, as far as play reaches.** A MAME 0.289 debugger trace of
`lethalen`, 150 s headless with coin, start and firing (the run reached play and the continue
screen), executed 17,318,327 instructions at 8,118 distinct PC/instruction sites. None used a
6309-only instruction (no `LDMD`, `TFM`, register-to-register ops, `W`/`E`/`F`/`Q` register
use, `MULD`, `DIVD`, bit ops). Coverage is the attract loop and the first stage only. The
only Verilog core claiming 6309 support, `freecores/6809_6309_compatible_core`, says in its
`TODO.txt` that "HD6309 compatibility [is] totally missing".

## Clocks

| Clock | Value | Source |
|---|---|---|
| Crystal | 24.000 MHz | PCB notes in the driver header |
| Crystal | 18.432 MHz | PCB notes; line 722 |
| Main CPU | 3.000 MHz (24/8) | line 683 |
| Sound CPU | 6.000 MHz (24/4) | line 686 |
| Pixel clock | 6.000 MHz (24/4) | line 695 |
| 054539 | 18.432 MHz, sample rate 18.432 MHz / 384 = 48 kHz | line 722; `k054539.cpp` |

Line rate 6 MHz / 384 = 15.625 kHz; frame rate 6 MHz / (384 x 262) = 59.637 Hz. The driver's
PCB notes measured HSync 15.2038 kHz and VSync 59.6380 Hz; the frame rate agrees, the line rate
in the notes does not match 262 lines at that frame rate and is not used.

## Video

`screen.set_raw(24 MHz/4, 384, 24, 312, 262, 16, 240)` (line 695): 288x224 visible of 384x262,
6 MHz pixel clock. `-listxml`: 59.637405 Hz. Aspect 4:3.

- **Tilemaps.** 054156 plus two 054157 in parallel, giving four layers (A-D) at 8 bpp. MAME
  models one K056832 with `K056832_BPP_8LE` (line 705) and external line-scroll RAM (line 707).
  Tile colour: `layer_colorbase[layer] + ((color & 0x3c) << 2)`, the base from the PCU1/PCU2
  palette-bank registers.
- **Sprites.** 053245 (front end, sprite RAM 0x800 bytes) plus two 053244 in parallel for
  6 bpp (line 711). Sprite colour bits 4-5 select one of four priority masks (lines 343-376).
  Shadows on, with priority (line 713).
- **Mixing** (lines 413-450): background pen `back_colorbase`, then layers D, C, B with
  priority bits 1, 2, 4, then sprites against those priorities, then layer A over everything.
- **Palette.** 0x2000 entries, xBGR_555, in 16 KB of RAM behind the CBNK bank (line 700). The
  first 0x400 bytes are not CPU-visible.
- **Shadows** use a second 0x2000-entry table: the same colour with red scaled by 0.6
  (`PALETTE_DEFAULT_SHADOW_FACTOR`, line 409), so shadows are cyan.
- **Flip.** The game sets the 054156's flip bits; MAME's `screen_update` shifts the layer
  offsets by 167 under X flip (lines 416-428) and moves the sprites one pixel under Y flip
  (lines 431-434). The orientation flag then flips the screen back: FLIP_Y for the US and
  European sets, FLIP_X for the Japanese set.
- **What MAME says it does not emulate** (driver header TODO): the doubled 054157 and 053244
  are faked with one device and alternate graphics layouts; "maybe some sprite placement
  issues". BTANB: shadows stay on screen during the white muzzle flash.

## Memory map

Main CPU, `main_map` (line 531):

| Address | What |
|---|---|
| 0x0000-0x1fff | program ROM, banked in 8 KB pages (0x40dc, 32 entries) |
| 0x2000-0x3fff | work RAM, 8 KB |
| 0x4000-0x403f | 054156 registers (write) |
| 0x4040-0x404f | 054157 registers (write) |
| 0x4080 | watchdog (read) |
| 0x4090 | sound IRQ (read or write) |
| 0x40c4 | control: EEPROM DI/CS/CLK, MUT, CBNK (bank), SHD0/1 |
| 0x40c8, 0x40cc, 0x40d0 | palette banks PCU1-3 |
| 0x40d4-0x40d7 | gun X/Y, both players |
| 0x40d8 | DSW, EEPROM DO and ready |
| 0x40d9 | coins, service, triggers, starts |
| 0x40db | gun X low bits |
| 0x40dc | ROM bank |
| 0x4000-0x7fff | `bank4000` window, selected by CBNK; the fixed registers above take precedence |
| 0x8000-0xffff | program ROM 0x38000-0x3ffff |

`bank4000_map` (line 552), CBNK=0: 053244 registers 0x4840, 054000 0x4880, 054321 0x48c0,
053245 sprite RAM 0x5000-0x57ff, 054156 VRAM 0x6000-0x7fff (code lo/hi, attribute lo/hi, 2 KB
each). CBNK=1: palette RAM 0x4400-0x7fff.

Sound CPU, `sound_map` (line 573): ROM 0x0000-0xefff, RAM 0xf000-0xf7ff, 054539 0xf800-0xfa2f,
054321 0xfc00-0xfc03.

**Interrupts.** Main IRQ at vblank start when the 054156 IRQ enable is set, `HOLD_LINE`
(line 477). The enable is word 3 bit 0 (`is_irq_enabled`), written at 0x4007; `lethalen` first sets
it at main-CPU access 13,860,704, frame 347 (MAME Lua tap).

Vectors, read from each set's program ROM at 0x3fff0:

| set | IRQ | RESET | FIRQ, NMI, SWI, SWI2, SWI3 | 0xFFF0 (6309 trap) |
|---|---|---|---|---|
| `lethalen`, `lethalenj` | 0x8859 / 0x885E | 0x80E0 | 0xE291 | 0xFFFF |
| `lethalenub`, `lethaleneab`, `lethaleneaa` | 0x883F | 0x80DE | 0xE291 | 0xFFFF |
| `lethaleneae`, `lethalenead` | 0x8857 | 0x80DE | 0xE291 | 0xFFFF |
| `lethalenua` | 0x881A | 0x80DC | 0xE288 | 0xFFFF |
| `lethalenux` | 0x8822 | 0x80D9 | 0xE368 | 0xFFFF |

The shared handler is `ORCC #$D0; BRA *` (MAME `unidasm` on `191uae01.u4`): only IRQ and RESET are
live. The 6309's illegal-instruction trap vector is 0xFFFF in every set.

**Video write timing** (`docs/write_timing_mame.txt`, all nine sets, attract and play): sprite RAM
is never written in vblank; the 053244's register 6, which copies sprite RAM into the chip's buffer
(`k053244_k053245.cpp` line 251), is written in vblank; VRAM is written all frame; the scroll
registers are written in vblank 97.9% of the time. Sound IRQ on any main access to 0x4090, `HOLD_LINE` (line 490). Sound NMI from the
054539 timer (line 723).

**VRAM size.** MAME allocates 16 pages of 8 KB for the K056832 (`k054156_k054157_k056832.cpp`
line 398). **Measured: Lethal writes pages 0, 1, 4 and 5, every tile of each, plus page 16 (the
external line-scroll page), and no others**, on all nine sets in attract and in play
(`scripts/mame_vram_pages.py`, 3,600 frames attract on `lethalen`, 7,200 frames with coin and play
on each set). That is 40 KB. By position on the driver's PCB layout, three MN4464 (8Kx8) and two LH5116 (2Kx8)
sit beside the 054156/054157: 24 KB plus 4 KB, the same 24 KB jotego's Moo Mesa wiring uses
for this chip pair. The fourth MN4464, beside the 054000, is taken to be the work RAM; the two
CY7C185 the palette; the 84256 the 054539's RAM. How many pages Lethal uses is measured with a
write tap in Phase 0.

## Inputs

Two light guns, each a trigger plus X and Y, read as positions (lines 452-529); MAME has no
light sensing. A shot with Y outside 0x0b-0xe8 reads 0: off screen, which reloads. Coins 1-2,
service, test, starts 1-2. DSW: language, game type, coin mechanism, stereo or mono; the
Japanese set marks all four unknown, the European set marks the language unused. EEPROM holds
the rest of the settings.

## Feasibility

Not a large board: 8-bit CPUs at 3 and 6 MHz, 9.3 MB of ROM, existing RTL for every chip.
No feasibility section needed.
