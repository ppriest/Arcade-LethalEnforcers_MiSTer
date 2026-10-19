# jt053244 (053245/053244 sprites) provenance

From <https://github.com/jotego/jtcores> at commit `f64dbe2fd4a93df954d74248bf65b4abe8d97a57`.
**Verbatim.** SPDX headers: `GPL-3.0-or-later`. `.gitattributes` marks this directory `-text`.

| file | upstream path |
|---|---|
| `jt053244.sv`, `jt053244_scan.sv` | `cores/riders/hdl/` |
| `jt053246_dma.v`, `jt053246_mmr.v` | `cores/simson/hdl/` |

Shipped in jtcores' riders core (Sunset Riders, TMNT: Turtles in Time, Lightning Fighters, Golfing
Greats). `jt053246_mmr.v` is committed upstream and regenerates identically
(`scripts/regen_mmr.sh --check`).

The local jtcores fork (`ppriest/jtcores` at `451c630da`) changes `jt053246_dma.v` for its Xexex
core. This copy is jotego's, not the fork's.

Lethal pairs two 053244s for 6 bpp. The chip emits sprite codes and line addresses; the pixel width
is outside it, in this core's sprite draw. No upstream unit test: riders' `ver/` holds game-level
simulations that need jtframe's build system.

Dependencies: `jtframe_dual_ram`, `jtframe_dual_ram16`, `jtframe_toggle` in `../../jtframe/`.

## Modified copies here

| file | from | change |
|---|---|---|
| `lethal_draw6.v` | jtframe `jtframe_draw.v` | six bitplanes: 48-bit ROM word, 6-bit pixel |
| `lethal_objdraw_gate6.v` | jtframe `jtframe_objdraw_gate.v` | the same widths; instantiates `lethal_draw6`; `PACKED` dropped |

Each carries a GPLv3 5(a) notice in its header; the unmodified files are in `../reference/`.
`../lethal_obj.sv` wires them as jtcores' `jtriders_obj.v` does, with `HFLIP_OFFSET` 118.
