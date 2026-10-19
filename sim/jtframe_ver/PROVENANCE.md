# jtframe upstream tests: provenance

From <https://github.com/jotego/jtcores> at commit `f64dbe2fd4a93df954d74248bf65b4abe8d97a57`.
**Verbatim.** GPL-3.0-or-later (jtcores `LICENSE`). `.gitattributes` marks this directory `-text`.

| here | upstream |
|---|---|
| `sdram_bank64_rw/test.v` | `modules/jtframe/ver/sdram/sdram_bank64/rw_test/test.v` |
| `draw_scaling_single/` | `modules/jtframe/ver/video/draw_scaling_single/` |
| `draw_scaling_multi/` | `modules/jtframe/ver/video/draw_scaling_multi/` |
| `inc/test_tasks.vh` | `modules/jtframe/ver/inc/test_tasks.vh` |

Upstream's `sim.sh` and `gather.f` drivers are replaced by `scripts/run_vendored_tests.sh`, which
compiles the same tests against `rtl/`. Micron's `mt48lc16m16a2.v`, which the SDRAM test needs, is
"All rights reserved" with no redistribution grant, so it is read from a jtcores checkout and not
committed.
