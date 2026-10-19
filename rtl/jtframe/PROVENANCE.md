# jtframe HDL provenance

From <https://github.com/jotego/jtcores> at commit `f64dbe2fd4a93df954d74248bf65b4abe8d97a57`.
**Verbatim.** SPDX headers: `GPL-3.0-or-later`. `.gitattributes` marks this directory `-text`.

| file | upstream path | pulled in by |
|---|---|---|
| `jtframe_dual_ram.v` | `modules/jtframe/hdl/ram/` | jt053244, jtframe_sys6809, jtframe_z80, objdraw |
| `jtframe_dual_ram16.v` | `modules/jtframe/hdl/ram/` | jt053244 |
| `jtframe_dual_nvram.v` | `modules/jtframe/hdl/ram/` | jtframe_z80 |
| `jtframe_obj_buffer.v` | `modules/jtframe/hdl/ram/` | objdraw |
| `jtframe_toggle.v` | `modules/jtframe/hdl/` | jt053244_scan |
| `jtframe_ff.v` | `modules/jtframe/hdl/` | jtframe_sys6809 |
| `jtframe_sh.v` | `modules/jtframe/hdl/` | objdraw |
| `jtframe_draw.v`, `jtframe_objdraw.v`, `jtframe_objdraw_gate.v` | `modules/jtframe/hdl/video/` | the sprite draw, as jtcores' riders core uses it |
| `jtframe_z80wait.v` | `modules/jtframe/hdl/cpu/` | jtframe_sys6809, jtframe_z80 |
| `sdram/jtframe_sdram64*.v` (5 files) | `modules/jtframe/hdl/sdram/` | the SDRAM controller |

The closure was resolved by Verilator elaborating each top-level module against the upstream tree
and listing the files it read, not by grepping for instantiations.

Upstream tests covering files here: `modules/jtframe/ver/sdram/sdram_bank64` (the SDRAM
controller) and `modules/jtframe/ver/video/draw_scaling_single` and `draw_scaling_multi`
(`jtframe_draw`). Results are in `docs/ROADMAP.md`, Phase 0.
