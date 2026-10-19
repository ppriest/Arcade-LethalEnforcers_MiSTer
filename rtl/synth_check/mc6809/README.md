# mc6809i standalone Fmax — Phase 0 exit criterion 4

A Quartus project holding `jtframe_sys6809` (mc6809i, its clock enables and SDRAM wait, 8 KB work
RAM), Lethal's ROM banking, and `jtframe_sdram64` serving the program ROM from bank 0 behind a
one-word tag. Inputs are registered, outputs land in flops and the pins are virtual, so the report
is register to register. The SDRAM controller is at the settings this core will start from: `HF=0`
(below 66 MHz), 16-bit bursts on every bank and on the programming port.

```
cd rtl/synth_check/mc6809
python ../../../scripts/hwlock.py --require-no-jtag
quartus_sh --flow compile mc6809_fmax -c mc6809_fmax > compile.log
quartus_sta -t worst.tcl                        # -> worst_paths.txt
```

## Result

5CSEBA6U23I7, Quartus 17.0.2 Lite, `HIGH PERFORMANCE EFFORT`, seed 1, constrained at 100 MHz
(`mc6809_fmax.sdc`) so the limit shows as negative slack:

| corner | Fmax |
|---|---|
| Slow 1100mV 100°C | **79.81 MHz** |
| Slow 1100mV −40°C | 81.54 MHz |

| resource | used |
|---|---|
| ALMs | 1,751 |
| registers | 1,187 |
| M10K | 8 (the work RAM) |
| DSP | 0 |

The five worst paths run inside mc6809i, from `tmp[5]` and an operand selector to `ea[11]`, the
effective-address calculation: about 11.8 ns of data delay.

## What it decides

The core clocks the CPU at the 48 MHz `clk_sys` and enables it at 3 MHz. 79.81 MHz against 48 MHz
is a single placement's figure (LESSONS_LEARNED, "[Seta] A clean STA summary is a property of one
placement, not of the design"), but the gap is wide: the clock plan in `docs/ROADMAP.md` stands.

`mc6809_fmax.sdc` produced these figures and is committed with them. The core's own `.sdc` is
separate and is measured again when the CPU is wired in.
