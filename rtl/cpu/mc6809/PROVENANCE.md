# mc6809i and its wrapper: provenance

From <https://github.com/jotego/jtcores> at commit `f64dbe2fd4a93df954d74248bf65b4abe8d97a57`,
path `modules/jtframe/hdl/cpu/`. **Verbatim.** `.gitattributes` marks this directory `-text`.

| file | licence | origin |
|---|---|---|
| `mc6809i.v` | BSD, below | Greg Miller's cycle-accurate MC6809, <https://github.com/cavnex/mc6809> at `17e94a6ef163be8b79a9b15b2e814847b6062f0f`, as modified in jtcores |
| `jtframe_sys6809.v` | GPL-3.0-or-later | jotego: clock enables, SDRAM wait with cycle recovery, internal RAM |

**Licence of `mc6809i.v`.** The file's header carries only "Copyright (c) 2016, Greg Miller".
Upstream's `documentation/LICENSE.md` offers the standard BSD licence or a binary-only modified
licence, and asks that one be selected. This project selects the **standard BSD licence** (the
three-clause text in that file). It permits redistribution of modified source and is compatible
with GPL-3.0-or-later. Its notice goes in `THIRD-PARTY.md`.

**jtcores' changes against cavnex upstream**, from a diff of the two files: E and Q become clock
enables `cen_E`/`cen_Q` on one `clk`; an `OP` output marks opcode fetches; NMI edge detection is
synchronous; Verilator lint pragmas and simulation-only signals are added.

The HD63C09E is run as a 6809: `docs/HARDWARE_NOTES.md`, "CPUs and chips". No upstream test covers
mc6809i, in jtcores or in cavnex/mc6809.
