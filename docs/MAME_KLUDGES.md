# MAME kludges this core reproduces

This project follows MAME, including where MAME is wrong (ROADMAP, "Design decisions"), so the
software model and the RTL reproduce MAME's guesses on purpose. This file lists each one that
touches an in-scope set: where it is in MAME, what the core does, and what would settle the real
behaviour.

It also records where a vendored, silicon-derived module disagrees with MAME and the module was
kept (ROADMAP, "Where a vendored module and MAME disagree").

This core's own approximations are not here; they are in `HACKS.md`.

Source references are to `src/mame/konami/lethal.cpp` unless named. MAME commit: `dedb5227403`.

**Core column:** *copies* MAME; *differs* (and why); *n/a* (not in the core's scope);
*not checked*.

Every set is `MACHINE_IMPERFECT_GRAPHICS`; `-listxml` also marks sound imperfect.

## Video

The model column is `scripts/render_model.py` and `scripts/render_sprites.py`, pixel-identical to
MAME on 23 captured frames of `lethalen`, `lethalenj` and `lethaleneae`. The RTL column is filled
in as each block is checked against the model.

| Kludge | MAME | Core | Would settle it |
|---|---|---|---|
| The doubled chips are one device each | Driver header TODO: "We currently cheat, using just one of each device but using alternate gfx layouts": the two 054157s become `K056832_BPP_8LE` (line 705), the two 053244s `set_bpp(6)` with `spritelayout_6bpp` (`k053244_k053245.cpp:60`) | copies: `tile_gfx`, `sprite_gfx`; RTL `lethal_tilemap` (8LE), `lethal_obj` (6 bpp) | The separated front-end/back-end chips against a PCB capture |
| Per-layer X offsets -4, -2, 0, +2, and -167 more under flip X | lines 416-428, `set_layer_offs`, no source given | copies: model (captured `m_layer_offs`), RTL `lethal_tilemap` `offs_x` | A PCB capture of the layer alignment |
| Sprite Y offset ±1 by tilemap flip Y | lines 431-434, `set_offsets(0, ±1)` | model copies (`draw_sprites`); RTL: part of the raster mapping, bitmap = raster + (105, 255) | — |
| Layer A over everything | line 445, "force A layer over top of everything" | copies: model `render`, RTL `lethal_mixer` | The board's mixer (052535 DACs fed by which chips) |
| Shadows: red × 0.6 | line 409 and `video_start`: shadow pen = pen + 0x2000 with red scaled by `PALETTE_DEFAULT_SHADOW_FACTOR` ("shadows are cyan") | copies: model `palette_rgb`, RTL `lethal_mixer` `shadow_r` | PCB footage of a shadow |
| Row scroll under flip Y reads 0x1E0 + 14 words further | `k054156_k054157_k056832.cpp:1575-1576`, `K056832_DRAW_FLAG_MIRROR` with flip Y; the comment reads "in xexex: K056832_DRAW_FLAG_MIRROR != flipy" | copies: model `draw_layer`, RTL `lethal_tilemap` `ls_word`. For layer D the read runs past the end of MAME's VRAM array, on invisible lines only; the model clamps those | A PCB capture of a row-scrolled layer |
| Sprites with priority code 0 after the first entry are dropped | `k053244_k053245.cpp:94` sets `m_z_rejection(0)`; lethal never calls `set_z_rejection` | model copies (`draw_sprites`); RTL differs, below | — |
| Whole frame drawn from the state at vblank start | MAME's screen update; the board reads registers and VRAM as it scans | model copies; RTL decision in Phase 1 (ROADMAP, "Design decisions") | `docs/write_timing_mame.txt` shows 2.1% of scroll-register writes outside vblank |
| Tile-ROM readback (VRD) unmapped | `bank4000_map`: `map(0xa000, 0xbfff).mirror(0x4000).unmaprw()` | not checked | — |

## Vendored modules that disagree with MAME

| Module | MAME says | The module does | Kept because | Would settle it |
|---|---|---|---|---|
| jt053244 (`rtl/video/lethal_obj.sv`), zoom | `k053244_k053245.cpp` `sprites_draw`: zoom = `(0x400000 + z/2) / z`, the centre from `(zoom * w) >> 13`, each tile's position and size rounded on its own, pixels sampled by `drawgfxzoom_core` | `jt053244_scan.sv`: offset tables (`zoffset`, `pzoffset`) and a zoom x line product for the rows; the drawer steps a 12-bit zoom accumulator | Modelled on the chip; shipped in jtcores' riders core; your decision to keep it | A PCB capture of a zoomed sprite |
| jt053244, two entries with one priority code | The first entry in RAM order keeps the slot (`sortedlist`) | The DMA writes each entry to the slot of its code, so the last one keeps it | As above | Not exercised by any capture |
| jt053244, z-rejection | Entries with priority code 0 after the first are skipped (`m_z_rejection` 0) | Not implemented | As above | Not exercised by any capture |
| gx_k054539 (`rtl/sound/lethal_k539.sv`), arithmetic | `k054539.cpp` `sound_stream_update`: each voice's value times `voltab * pantab` summed in doubles | Fixed point: the sum with 8 fraction bits, `voltab` Q24, `pantab` Q16 | KonamiGX's module; the differences are 1 LSB | Not needed: `scripts/check_k539.py` measures it |

Measured by `scripts/check_k539.py` (`lethalen`, 20 s from power-on with two coins and Start,
MAME's own register writes replayed into `lethal_k539`, MAME's speaker effects off): 99.60% of the
541,626 samples with sound are exact and all are within 1 LSB. `scripts/k539_model.py`, MAME's
algorithm in Python, is exact against MAME on all of them, so the 0.40% is the module's arithmetic.

Measured by `scripts/check_obj.py` and `scripts/classify_obj.py` on the 23 captures, the sprite layer
alone, at the core's raster mapping (bitmap = raster + (105, 255)):

| Model sprite | Same pixel | Different pen or colour | Only the model draws it |
|---|---|---|---|
| Not zoomed | 21,073 | 0 | 2 |
| Zoomed | 57,635 | 25,428 | 1,937 |

A further 1,945 pixels are drawn by the RTL where no model sprite is: the edges of zoomed sprites.
Shadows (one zoomed shadow sprite in the play captures): 2,524 pixels shadowed in both, 47 by the
model only, 57 by the RTL only, at the earlier shift of (104, 255).

Whole frames (`scripts/check_frame.py`: `lethal_tilemap`, `lethal_obj`, `lethal_mixer` and the
palette, against MAME's screenshots): 11 of the 23 captures are pixel-identical, among them every
frame without a zoomed sprite and all four `lethalenj` frames. Over all 23, the pixels that differ
are 18,535 on zoomed sprites, 1,337 where only the RTL draws a sprite, 1,276 at the edges of the
zoomed shadow sprite, and 2 on one unzoomed sprite (`lethalen-f4200_play`); none elsewhere.
