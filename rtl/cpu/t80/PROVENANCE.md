# T80 and its wrapper: provenance

From <https://github.com/jotego/jtcores> at commit `f64dbe2fd4a93df954d74248bf65b4abe8d97a57`,
paths `modules/jtframe/hdl/cpu/` and `modules/jtframe/hdl/cpu/t80/`. **Verbatim.**
`.gitattributes` marks this directory `-text`.

| file | licence |
|---|---|
| `T80.vhd`, `T80_ALU.vhd`, `T80_MCode.vhd`, `T80_Reg.vhd`, `T80s.vhd` | BSD-style; Daniel Wallner 2001-2002, Sorgelig 2018 (headers) |
| `T80s.v` | no header; a Verilog conversion of the VHDL above, same terms |
| `jtframe_z80.v` | GPL-3.0-or-later |

Quartus builds the VHDL (`jtframe_z80` with `VHDLZ80` defined); Verilator builds `T80s.v`.
LESSONS_LEARNED, "[BallySente] A vendored CPU may be simulated from a different source than
Quartus builds", applies: a disagreement between the two is checked before it is believed.
