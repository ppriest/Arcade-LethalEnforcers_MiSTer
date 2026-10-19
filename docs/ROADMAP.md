# Lethal Enforcers — MiSTer Core Roadmap

**This roadmap is a proposal until the user approves it. No phase executes before that approval,
and a phase whose scope changes goes back for approval.**

## Context

Goal: a DE10-nano MiSTer core for Konami's GX191 board (Lethal Enforcers), emulated by MAME's
`konami/lethal.cpp` and the devices it instantiates — a Quartus 17.0.2 Verilog/SystemVerilog
project producing one `.rbf` and a `.mra` per supported set, reusing proven open components where
they exist. The facts this plan rests on, with their sources, are in
[`HARDWARE_NOTES.md`](HARDWARE_NOTES.md).

**Every chip on this board already has RTL, most of it in jtcores, and jtcores is the first
choice wherever a module exists (user's direction).** The HD63C09E main CPU is the one part with no
RTL anywhere, and a MAME trace shows the game runs only 6809 instructions on it, so jtframe's
`mc6809i` serves. What is genuinely new:

1. Lethal's video glue: the 8 bpp tile pixel path from two 054157s, the 6 bpp sprite path from two
   053244s, and the mixer and shadow table from `lethal.cpp`'s `screen_update`.
2. The CBNK/VRD bank window, the 8 KB ROM banking and the rest of the main-CPU glue.
3. Lethal's gun scaling, on GX's `gx_guns.sv`.

Everything else is a port with verification.

Cross-cutting findings from the previous cores are in **[`LESSONS_LEARNED.md`](LESSONS_LEARNED.md)**.
Working practice built on them is in **[`WORKFLOW.md`](WORKFLOW.md)**.

## Progress

**Phase 4: all nine sets have an `.mra`** (`scripts/build_mra.py`), each image re-read with
`mra.py` and equal to the RTL's stream, each with its own program ROM, EEPROM image and DIP layout
from the driver. Hiscore for the three sets `hiscore.dat` covers (`scripts/hs_ready.py`: `lethalen`
writes its table at frame 348, `lethalenub` and `lethalenead` at 419). Only `lethalen` and
`lethalenj` have run on hardware.

**Phase 3 (sound) is under way: the 054539 path is checked against MAME in simulation; the
board has not played it yet.**

- `rtl/sound/lethal_k539.sv`: the 054539 with its RAM, its samples on SDRAM bank 3, the 054321's
  volume and enables, lethal.cpp's speaker routing. `scripts/check_k539.py` replays MAME's own
  register writes into it: of 541,626 samples with sound, 99.60% exact, all within 1 LSB
  (`MAME_KLUDGES.md` says why). MAME is captured with its speaker effects off.
- Whole board (`check_system.py --audio --coin`): the Z80's 35,126 writes to the 054539 match
  MAME's in order and value; sounds start up to a sample apart in time.

**Phase 2 is under way: `lethalen` and `lethalenj` boot on a DE10-nano and play, silent.**

- On the board: both sets pass the power-on ROM test into attract (`debug/hw/lethalen_boot5.png`,
  `debug/hw/lethalenj_boot1.png`); you played them and reported them working except the gun's Y,
  mirrored about the crosshair, fixed in `a2767ef` and not yet re-checked. Bring-up faults found:
  SDRAM never refreshed (`rfsh` tied off: U4 BAD), and the DDR3 copy's last byte pair left
  `ioctl_wait` high (the OSD froze).
- Built, both revisions meeting timing at `11f7f73`: HDMI rotation, vertical crop, the H1 debug
  page. Not yet checked on the board: flip screen against the paused frame turned 180 degrees,
  Pause, CRT Adjust, DIPs, EEPROM and hiscore saving, rotation.

- Whole board from reset, no replay (`sim/system_tb`, `scripts/check_system.py`): main CPU writes
  match MAME's boot trace for 292,853 of 323,623; the first difference is a stacked PC one
  instruction apart (an IRQ taken one instruction later). Frame 290 of the run is pixel-identical
  to MAME's frame 300 capture of `lethalen`.
- SDRAM (`rtl/lethal_sdram.sv`): download and all four ports against MAME's regions with Micron's
  model, at zero phase and with the chip clocked 5555 ps late as on the board: 477 of 477 reads
  (`scripts/check_sdram.py [--shifted]`).
- `.mra` (`scripts/build_mra.py`): `lethalen`, `lethalenj`; each image re-read with `mra.py` and
  equal to the stream the RTL expects.
- Top level (`LethalEnforcers.sv`): DDR3 fast load, mod byte, DIPs, EEPROM load and save, keyboard,
  guns with the crosshair, Pause, OSD flip, CRT Adjust, scaling. Not yet: HDMI rotation, hiscore
  (it needs a second port on the 6809's work RAM).
- Video top (`rtl/video/lethal_video.sv`): raster, orientation by render order, the three blocks.
  `scripts/check_video.py` on all 23 captures: 10 frames pixel-identical to MAME (all four
  `lethalenj`), every other differing pixel on a zoomed sprite or its edge. Timing found in that
  bench: jt053244's hs both starts a line and swaps its buffers, so it draws two lines ahead;
  the sprite buffer is read at bitmap x + 105 (`OBJ_DX`) in both read directions.

Phase 1, done, with the sprite exception you chose:

- Model (`scripts/render_model.py`, `render_sprites.py`): 23 captures of `lethalen`, `lethalenj`
  and `lethaleneae`, attract and play, 0 pixels differ from MAME.
- Tilemaps (`rtl/video/lethal_tilemap.sv`, derived from KonamiGX's `gx_tilemap`): every layer pixel
  of the same 23 captures matches the model (`scripts/check_tilemap.py`). jt05415x is not used
  ("Component reuse map").

- Sprites: jt053244 kept (your decision) and extended to 6 bpp: `rtl/video/lethal_obj.sv`. On the
  23 captures every unzoomed sprite pixel matches MAME (21,073 pixels) and zoomed sprites differ in
  a third of their pixels; recorded in `MAME_KLUDGES.md`. Raster mapping: MAME bitmap (x, y) is
  jt053244's (hdump - 105, vdump - 255), for flipped and unflipped sets alike (`HFLIP_OFFSET` 118).
- Mixer and palette (`rtl/video/lethal_mixer.sv`): whole frames from the three blocks
  (`scripts/check_frame.py`) are pixel-identical to MAME on 11 of 23 captures; every other
  differing pixel lies on a zoomed sprite or its edge (`MAME_KLUDGES.md`).
- Not covered by a capture: sprites sharing a priority code, z-rejection, priority class 3,
  mirrored sprites (one), line-map pages, layers wider or taller than a page.

Phase 0, done:

- Roadmap approved. `develop` branch, nothing pushed.
- Every reused module vendored, byte-identical to its upstream blob (135 files checked).
- mc6809i matches MAME's bus trace through 36 vblank IRQs: 323,623 writes of 323,623, and the idle
  loop's iteration count per frame equal in all 35 complete frames.
- Measured: VRAM pages used, the video-write sweep on all nine sets, SDRAM throughput at 48 MHz,
  mc6809i's Fmax and its tolerance of ROM latency.

## Game scope

| Set | Version | Unique ROM | Inputs | Orientation | MAME flags |
|---|---|---|---|---|---|
| `lethalen` | UAE | `191uae01.u4`, `lethalenue.nv` | `lethalen` | FLIP_Y | IMPERFECT_GRAPHICS |
| `lethalenub` | UAB | `191uab01.u4`, `lethalenub.nv` | `lethalen` | FLIP_Y | IMPERFECT_GRAPHICS |
| `lethalenua` | UAA | `191uaa01.u4`, `lethalenua.nv` | `lethalen` | FLIP_Y | IMPERFECT_GRAPHICS |
| `lethalenux` | US, proto/hack | `191xxx01.u4`, `lethalenux.nv` | `lethalen` | FLIP_Y | IMPERFECT_GRAPHICS |
| `lethaleneae` | EAE | `191eae01.u4`, `lethaleneae.nv` | `lethalene` | FLIP_Y | IMPERFECT_GRAPHICS |
| `lethalenead` | EAD | `191ead01.u4`, `lethalenead.nv` | `lethalene` | FLIP_Y | IMPERFECT_GRAPHICS |
| `lethaleneab` | EAB | `191eab01.u4`, `lethaleneab.nv` | `lethalene` | FLIP_Y | IMPERFECT_GRAPHICS |
| `lethaleneaa` | EAA | `191_a01.u4`, `lethaleneaa.nv` | `lethalene` | FLIP_Y | IMPERFECT_GRAPHICS |
| `lethalenj` | JAD | `191jad01.u4`, `lethalenj.nv` | `lethalenj` | FLIP_X | IMPERFECT_GRAPHICS |

Shared by all nine: Z80 program 64 KB, tiles 4 MB, sprites 3 MB, samples 2 MB. Loaded bytes per
set: 9,764,992.

### Scope decision

- **In scope:** all nine sets. One memory map, one screen, one chipset; 9.3 MB fits the 32 MB
  module (user's direction: 32 MB, no DDR3 during play).
- **Out of scope:** Lethal Enforcers II, which is Konami GX hardware and already in the KonamiGX
  core.
- **First target:** `lethalen`, the parent and the set the trace was taken on.
- **Second target:** `lethalenj`, for the Japanese inputs, the reversed gun axes and FLIP_X.

## Hardware reality (from the driver, not assumption)

Line numbers are `lethal.cpp` at MAME `dedb5227403`.

### Chips

| Chip | Part | Clock | Source |
|---|---|---|---|
| Main CPU | HD63C09E, run as a 6809 | 3 MHz (24/8) | line 683 |
| Sound CPU | Z80B | 6 MHz (24/4) | line 686 |
| Tilemaps | 054156 + 2x 054157, 4 layers, 8 bpp | 6 MHz pixel | lines 703-707 |
| Sprites | 053245 + 2x 053244, 6 bpp, shadows | 6 MHz pixel | lines 709-713 |
| Collision | 054000 | - | line 715 |
| Sound latch | 054321 | - | line 720 |
| Sound | 054539 | 18.432 MHz | lines 722-725 |
| EEPROM | ER5911, 128x8 | - | line 691 |

### Clocks

Board clocks: 24 MHz crystal (main CPU /8, Z80 /4, pixel /4) and 18.432 MHz crystal (054539).
Pixel clock 6 MHz, 384x262 total, 59.637 Hz (line 695).

**`clk_sys` = 48.000 MHz, SDRAM on the same clock.** 48 = 8 x 6 MHz pixel clock, 2 x 24 MHz,
and above 18.432 MHz. It is the lowest value at or above 48 MHz that is an integer multiple of the
pixel clock, so no other candidate is considered.

| Enable | Ratio from 48 MHz | Exact |
|---|---|---|
| Pixel (`ce_pix`) | 1/8 | yes |
| Pixel x2 (sprite chip's `pxl2_cen`) | 1/4 | yes |
| Main CPU, mc6809i E/Q quadrature at 3 MHz | 1/16 per E, Q offset by 4 | yes |
| Z80 | 1/8 | yes |
| 054539 at 18.432 MHz | 48/125, Bresenham | yes |
| 054539 sample tick, 48 kHz | 1/1000 | yes |

No clock is inexact, so nothing goes into `HACKS.md` for clocks. The main CPU waits on SDRAM for
program fetches; it gets the T80 treatment from LESSONS_LEARNED ([MS32] "A T80 waiting on SDRAM is
a slow Z80: repay the lost clock enables"), with the catch-up measured in Phase 0.

### Interrupts

- Main IRQ at vblank start, gated by the 054156 IRQ enable, `HOLD_LINE` (line 477). No FIRQ or
  NMI source. The vectors are read from 0xfff0-0xffff in Phase 0.
- Z80 IRQ on any main-CPU access to 0x4090, `HOLD_LINE` (line 490).
- Z80 NMI from the 054539 timer (line 723).

### Memory map

In `HARDWARE_NOTES.md`, "Memory map". The parts that shape RTL:

- 0x0000-0x1fff is an 8 KB window into the 256 KB program, 32 banks, set at 0x40dc.
- 0x4000-0x7fff is a window selected by CBNK (0x40c4 bit 4): registers, sprite RAM and VRAM, or
  palette RAM. The fixed registers at 0x4000-0x40df take precedence in both banks.
- VRD (`HARDWARE_NOTES.md`, schematic table) selects tile-ROM readback; MAME leaves it unmapped
  and so will this core, logged in `MAME_KLUDGES.md`.

### Video

- Four tilemaps at 8 bpp: the 054156 generates addresses and each 054157 supplies 4 bits.
- Sprites at 6 bpp: the 053245 holds the list; each 053244 supplies part of the pixel.
- Fixed mixing order (lines 436-447): background pen, layer D, C, B, sprites against a priority
  mask chosen by sprite colour bits 4-5, layer A on top.
- Palette 0x2000 xBGR_555 entries, plus a shadow table with red scaled by 0.6 (line 409). A
  32-entry table replaces the multiply.
- MAME fakes the doubled chips with one device each and alternate graphics layouts (driver TODO).
  The core models the result, and the entry goes in `MAME_KLUDGES.md`.

### Sound

Z80 with 2 KB RAM, the 054321 latches and volume, and the 054539 with 32 KB RAM (the 84256) and
2 MB of samples. Stereo, with a Mono DIP.

### Protection

The 054000 collision chip at 0x4880 (bank 0). jtcores ships a model (`jtk054000`).

### Per-game configuration

Through the `.mra`: the program ROM and EEPROM image, the DIP block (three layouts), the gun axis
direction (the Japanese set reverses both axes), and the orientation (FLIP_X for `lethalenj`).

## Component reuse map

| block | plan | source |
|---|---|---|
| Main CPU | Port `mc6809i` with a sticky illegal-opcode probe | jtcores `modules/jtframe/hdl/cpu/mc6809i.v` at `451c630da`; header gives copyright (Greg Miller, 2016), licence to confirm |
| Sound CPU | Port `jtframe_z80` (T80s) | jtcores `modules/jtframe/hdl/cpu/`, T80 BSD-style |
| 054156/054157, 8 bpp | `rtl/video/lethal_tilemap.sv`, derived from GX's `gx_tilemap.sv`: five pages, external line scroll, MAME's flip, 8LE. jt05415x was vendored and removed: 13-bit tile codes where Lethal's reach 0x89BB, a byte-wide attribute RAM, a 4 bpp pixel path, flip as a plain mirror, no mirrored row-scroll read; its README calls it a reconstruction in progress | KonamiGX `rtl/video/gx_tilemap.sv` at `89124d4`, GPL-3.0-or-later |
| 053245/053244 | Port `jt053244` + `jt053244_scan`; object draw as `jtriders_obj` | jtcores `cores/riders/hdl/`, GPL-3.0-or-later, shipped in jtriders |
| 6 bpp sprite pixel path | Written from MAME's 6 bpp layout | `k053244_k053245.cpp` |
| Mixer, palette, shadows | Written from the software model | `lethal.cpp` lines 400-450 |
| 054000 | Port `jtk054000` | jtcores `cores/simson/hdl/jtk054000.v`, shipped in jtsimson |
| 054321 | Port `jt054321` | jtcores `cores/riders/hdl/jt054321.v` |
| 054539 | Port GX's `gx_k054539.sv`. jtcores' `jt539` is a submodule not checked out locally, and `jotego/jt539` returns 404 to this account | KonamiGX `rtl/sound/gx_k054539.sv` at `89124d4`, GPL-3.0-or-later, written from MAME |
| ER5911 EEPROM | Port `jt5911`, `PROG=0` (128x8) | jtcores `modules/jteeprom/hdl/jt5911.sv` |
| Light guns, crosshair | Port GX's `gx_guns.sv` with Lethal's scaling (lines 452-529) | KonamiGX `rtl/gx_guns.sv` at `89124d4` |
| SDRAM | `jtframe_sdram64` with bank interleave | jtcores `modules/jtframe/hdl/sdram/` |
| CRT Adjust | rmonic79's `crt_adjust.sv` | skill `references/crt_adjust.md` |
| Hiscore | `Hiscore.v` | skill `references/hiscore.md` |

## On-chip RAM budget

M10K counts at the width each RAM is read; 553 blocks on the device. The framework's own baseline
is measured on the first build.

| Memory | Size | M10K |
|---|---|---|
| Work RAM | 8 KB | 8 |
| Palette | 16 KB | 16 |
| VRAM: pages 0, 1, 4, 5 and the line-scroll page, measured | 5 x 8 KB | 40 |
| Sprite RAM + snapshot | 2 x 2 KB | 4 |
| Z80 RAM | 2 KB | 2 |
| 054539 RAM | 32 KB | 32 |
| Z80 program, in BRAM | 64 KB | 64 |
| Line buffers, tiles and sprites | - | about 20 |
| EEPROM | 128 B | 1 |
| **Total** | | **187** |

VRAM is settled: `scripts/mame_vram_pages.py` saw only those five pages written, on all nine sets
in attract and in play. The core maps CPU page selects onto five physical pages; a write to any
other page is counted on the debug page, since MAME would keep it.

## Memory plan

SDRAM, 32 MB, one copy of each region, loaded once from the `.mra`.

DDR3: the fast ROM load, then, during play, only the HDMI rotator (`screen_rotate_two`) when the
OSD's Rotation is on: it writes each frame to the HPS framebuffer for a turned monitor. You asked
for HDMI rotation; nothing of the game touches DDR3 in play, and the two masters never overlap
(the loader runs with the board in reset).


| SDRAM bank | Contents | Bytes |
|---|---|---|
| 0 | main program 256 KB, behind a 64-line cache (highest priority) | 256 KB |
| 1 | tiles: one 8-byte row a burst, the region's two halves side by side | 4 MB |
| 2 | sprites: one 8-byte word a burst, 191A06 in bytes 4-5 | 3 MB used of 4 |
| 3 | samples (Phase 3) | 2 MB |

As built (`rtl/lethal_sdram.sv`): one client class a bank. The approved plan split the
tiles over two banks; one 64-bit burst per row does the same job, since a row's 8 bytes are one
access.

**Per-line fetch arithmetic, estimated.** A line is 384 pixels x 8 = 3,072 clocks at 48 MHz.

| Client | Per line | Clocks |
|---|---|---|
| Tiles: 4 layers x 37 tiles x 8 bytes, as 148 four-word bursts | 1,184 B | about 1,480 at 10 clocks a burst |
| Sprites: up to 48 16-pixel rows x 12 bytes, a guess until Phase 1 | 576 B | about 960 |
| Main CPU program, through a cache | - | under 200 |
| 054539 samples, 8 channels at 48 kHz | about 25 B | under 50 |
| **Total** | | **about 2,700 of 3,072** |

That is 88% of the line at the pessimistic 10 clocks a burst. Splitting the tiles over two banks
and interleaving them with the sprites hides the activates, which is what `jtframe_sdram64` does;
at 6 clocks a burst the tiles take about 890 clocks. The sprite figure is measured in Phase 1. If
the measured total does not fit at 48 MHz, the numbers come to you before any clock change.

**Measured: `jtframe_sdram64` at 48 MHz** (upstream's `sdram_bank64` test, MiSTer DQM mode,
reads only). Two banks at full load: 61 MB/s, 66.7% of the bus. Four banks, each requester idle
half the time: 65 MB/s, with worst-case latencies of 311 clocks on bank 0 and 3,123 on bank 3, the
lowest priority. The estimate above needs about 28 MB/s for tiles and sprites.

**Measured: mc6809i against ROM latency** (`sim/boot_tb`, 35 frames of game code after the IRQ is
enabled). At 0 or 9 clocks from address to data the run is identical, cycle for cycle; at 16 clocks
the same work takes 28% longer, at 32 clocks 103% longer. The main CPU's ROM therefore sits behind a
small line cache with SDRAM bank 0's priority, so that a hit answers within 9 clocks and a miss is
rare.

No DDR3 client during play.

## Design decisions

**Follow MAME, including where MAME is wrong, and write down every place that is.** Each goes in
`docs/MAME_KLUDGES.md` when it is implemented.

**Where a vendored module and MAME disagree, record it and keep the module.** jt05415x is built
from furrtek's silicon schematics and treats them as the source of truth; a disagreement with MAME
goes to `docs/MAME_KLUDGES.md`.

**Every approximation of this core's own goes in `docs/HACKS.md`** in the commit it lands.

**Transcribe the reference literally first, then look for the chip.**

**One `.rbf` for all nine sets.** Per-set differences are `.mra` configuration.

**Two Quartus revisions, `LethalEnforcers_stp` and `LethalEnforcers`,** differing only by a
`DEBUG_ISSP` macro.

**Licence: GPL-3.0-or-later.** jtcores and the KonamiGX modules are GPL-3.0-or-later; T80 is
BSD-style; mc6809i's licence is confirmed before it is vendored. Recorded in `THIRD-PARTY.md`.
`sys/` is never edited.

**Per-scanline rendering from buffered sprite RAM.** Nothing in the driver shows a frame buffer.
The snapshot is the 053244's own DMA: register 6 copies sprite RAM into the chip's buffer
(`k053244_k053245.cpp` line 251), the game writes it in vblank, and the sweep found no sprite-RAM
write in vblank on any set (`docs/write_timing_mame.txt`). jt053244's DMA serves as is.

**Tilemap VRAM and registers are read live, per line, as the chip does.** VRAM is written all frame.
The scroll registers are written in vblank 97.9% of the time, and the rest are single writes; MAME
draws each frame from the state at vblank start, so the two differ only for those. Phase 1 compares
both against captures and records the choice in `MAME_KLUDGES.md`.

**No multiplies, no divides, in 2D pipelines.** The shadow scale is a table; the gun scaling is a
256-entry table or shift-and-add.

**jtcores modules first.** Where jtcores has a module for a chip, it is used, even over a
sibling-core module. The exceptions are the 054539 and the guns, where jtcores has no available
module.

**The main CPU is mc6809i, not a 6309.** A MAME 0.289 trace of `lethalen`, 150 s with coin,
start and firing, executed 17,318,327 instructions at 8,118 distinct sites and used no
6309-only instruction. No HD6309 RTL exists to port. The trace covers attract and the first
stage only, so the `_stp` build carries a sticky probe that latches the PC of any opcode mc6809i
does not implement. If it ever fires, the 6309 extensions are a new phase, brought to you first.
Timing: with the vblank IRQ at the board's rate, mc6809i's idle loop runs the same number of
iterations per frame as MAME's HD6309 in all 35 complete frames compared, so its cycle counts agree
with MAME's emulation mode at that resolution. The 6309's trap vector at 0xFFF0 is 0xFFFF in every
set.

**SDRAM controller: `jtframe_sdram64`, not Sorgelig's `sdram.sv`.** It interleaves the four banks,
which the fetch arithmetic above relies on, and it is what the reused jtcores video modules were
built against.

**Gun reload is a button.** MAME reloads on a shot with Y off screen (`guns_r`, line 498). The core adds
a Reload button that fires off screen, as GX does for Lethal Enforcers II. Logged in `HACKS.md`.

## Pitfalls that already bind decisions here

| Entry | What it binds here |
|---|---|
| Diagnosis discipline: "Suspect your own integration before any vendored module" | jt053244, jt05415x and mc6809i are suspected last |
| [MS32] "A T80 waiting on SDRAM is a slow Z80: repay the lost clock enables" | The main CPU and the Z80 both fetch from SDRAM |
| [GX] "A game that reads its EEPROM without writing it needs the driver's default image" | Each set ships its `.nv` in the `.mra` |
| [GX] "A per-line object scan that runs out of time drops sprites without an error" | Sprite overrun counter on the debug page |
| [Seta] "Latch the sprite list and the video registers at the same point unless evidence separates them" | Snapshot point from the sweep |
| [HyperNG64] "Check a large set's regions for byte-identical copies before sizing memory" | Done: only program and EEPROM differ across sets |
| "Exercise the ISA extensions you depend on, deliberately" | The illegal-opcode probe on the 6309 |

## Phased roadmap

**Phase 0 — Vendoring spike and the measurements. The gate.**

Vendor every module in the reuse map into `rtl/` with a `PROVENANCE.md` per directory. Run every
upstream testbench unchanged before editing anything. Stand mc6809i up in `rtl/synth_check/` with
the bus wrapper and the SDRAM transport and nothing else.

Exit criteria:

1. Every vendored module's own tests pass unchanged, on arrival. — **Met.** Upstream has tests for
   `jtframe_sdram64` and `jtframe_draw` only; `scripts/run_vendored_tests.sh` runs them against
   `rtl/`: 4 of 4 pass, the SDRAM test at upstream's clock and at 48 MHz in MiSTer DQM mode. The
   other modules have no upstream test (each `PROVENANCE.md` says so); Phase 1 benches them.
2. mc6809i boots `lethalen` and matches MAME's bus trace access by access. — **Met.**
   `scripts/boot_bench.py lethalen 14500000 --irq`: 323,623 of 323,623 writes match MAME in
   address, data and order; every replayed I/O read is at the address MAME read; every ROM byte
   MAME read in the window was read. The window spans the boot and 36 vblank IRQs.
3. Measured CPI on game code. — **Met.** 35 frames after the IRQ is enabled: 434,734 instructions
   in 1,775,172 E cycles, 4.08 E cycles each, at exactly 3 MHz. Execution only: SDRAM stall costs
   nothing up to 9 clocks of ROM latency, 28% at 16 and 103% at 32 ("Memory plan").
4. Standalone Fmax and area. — **Met.** `rtl/synth_check/mc6809`: 79.81 MHz at the slow 100°C
   corner with `jtframe_sdram64` in, 1,751 ALMs, 8 M10K, no DSP. The 48 MHz plan stands.
5. **Lethal-specific.** — **Met.**
   - VRAM pages: 0, 1, 4, 5 and the line-scroll page only, all nine sets ("On-chip RAM budget").
   - Video-write sweep: attract and play, 1,800 frames, all nine sets, in
     `docs/write_timing_mame.txt` ("Design decisions").
   - HD6309 against mc6809i timing: equal idle-loop counts per frame (criterion 2's run).
   - mc6809i's licence: BSD, `THIRD-PARTY.md`.

**Phase 1 — Video, against a software model.**

`mame_capture.py` plus a `render_model.py` that reproduces `lethal.cpp`'s `screen_update` and the
two devices, pixel-exact on captured frames first. Then jt05415x and jt053244 against the model,
layer by layer. Exit: `lethalen` renders frames pixel-identical to MAME's for a captured set of
scenes, silent, in simulation. If jt05415x cannot reach that, GX's `gx_tilemap.sv` replaces it,
with the reason in this file.

Exit, as amended by your decision to keep jt053244: — **Met.** The model is pixel-identical to MAME
on 23 captures; `lethal_tilemap` matches the model on every layer pixel of all 23; whole RTL frames
match MAME on 11, and the rest differ only on zoomed sprites, measured and recorded.

**Phase 2 — Hardware bring-up and the first games.**

SDRAM with all clients, ROM download, `.mra` generation, inputs, DIPs, EEPROM, the ISSP probe and
the OSD debug page. Light guns: mouse, sticks and d-pad aiming, Reload, and the crosshair, on the
`H2` OSD page. The standard feature set: CRT Adjust, hiscore, fast DDR ROM loading, HDMI scaling
and crop, HDMI rotation, audio mix, Pause, and flip screen through one path, verified against the
unflipped frame rotated 180 degrees. Exit: `lethalen` and `lethalenj` boot and play on a
DE10-nano, silent.

**Phase 3 — Sound.**

Z80, jt054321 and the 054539 from GX, driven by register-write traces captured from MAME. Exit:
correct audio by ear and by a decoded capture against MAME's output.

**Phase 4 — The rest of the list, and accuracy.**

The remaining seven sets' `.mra` files, with the DIP layouts and EEPROM images.
`docs/MAME_KLUDGES.md` and `docs/HACKS.md` say what is still not right.

**Phase 5 — none proposed.**

**Phase 6 — Savestates, state dumps and cheats.** Optional. Not before Phase 4, but the RTL is
written for it from Phase 1: reachable RAM ports and a current `docs/STATE.md`.

## Verification strategy

- MAME is a reference generator driven from scripts: boot traces, VRAM and register dumps,
  palette dumps, register-write logs.
- The software model comes before the RTL; the RTL is checked against the model.
- Every vendored module is verified against MAME before it is wired to anything.
- Layouts are verified before ROMs are involved.
- `.mra` files are generated and checked byte for byte against an image built from `ROM_START`.
- Worst cases are measured in the RTL with saturating counters.

## Repository setup

Seeded from MiSTer-devel/Template_MiSTer, split into the `LethalEnforcers_stp` and
`LethalEnforcers` revisions; Quartus 17.0.2. Conventions are in [`WORKFLOW.md`](WORKFLOW.md).

## Open items

~~**mc6809i's licence.**~~ Closed: upstream offers the standard BSD licence, selected in
`THIRD-PARTY.md`.

**jt539.** The jtcores submodule is not checked out and `jotego/jt539` returns 404 to this
account. GX's 054539 is the plan; if jt539 becomes available it is compared first.

~~**jt05415x maturity.**~~ Closed: not used ("Component reuse map").

~~**Sprite engine: jt053244, or written from the model.**~~ Closed: jt053244, your decision; its
differences from MAME are in `MAME_KLUDGES.md`. The question as it was put: jt053244's scanner is modelled on the chip,
not on MAME: it walks sprite RAM in address order where MAME sorts by the 7-bit priority code with
the first-drawn sprite winning; its zoom uses hardware-style tables and a zoom x line multiply where
MAME computes `(0x400000 + z/2) / z` and rounds each tile's position; it has no z-rejection. 139 of
the 242 sprites in the captures are zoomed, so it cannot match MAME's frames, and its drawer
(`jtframe_objdraw`) is 4 bpp. A MAME-exact engine is feasible: the worst captured line has 723
sprite pixels in 42 tile rows, about 1,300 clocks of a 3,072-clock line; MAME's per-pixel priority
and shadow rules reduce to a small per-pixel record resolved in the mixer; the divisions happen once
per sprite per frame. Your decision.

**6309 coverage.** The trace covers attract and the first stage. The illegal-opcode probe watches
the rest on hardware.

## Next steps

1. ~~Approval of this roadmap.~~
2. ~~Phase 0.~~ Results under "Phased roadmap".
3. Phase 1: `mame_capture.py` frames for `lethalen`, `render_model.py` from `lethal.cpp`'s
   `screen_update`, then jt05415x and jt053244 against it.
