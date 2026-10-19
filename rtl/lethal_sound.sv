// SPDX-License-Identifier: GPL-3.0-or-later
//
// Lethal Enforcers' sound board: the Z80B at 6 MHz, its program and RAM, the
// 054321's sound side and the 054539 (lethal.cpp sound_map, line 573):
//   0000-efff  program ROM (the 64 KB 191A02, in block RAM, loaded with the set)
//   f000-f7ff  RAM
//   f800-fa2f  054539
//   fc00-fc03  054321
// IRQ from the main CPU through jt054321 (held until the Z80's acknowledge,
// HOLD_LINE), NMI from the 054539's timer (line 723).
//
// The Z80 tests the 054539's RAM at power-on and reports the result to the main CPU
// (0x48ca bit 3; MAME reads 0x0f there).

module lethal_sound (
    input               rst,
    input               clk,                // 48 MHz
    input               cen,                // 6 MHz

    // program ROM load
    input               prog_we,
    input        [15:0] prog_addr,
    input         [7:0] prog_din,

    // 054321, main side
    input               snd_on,
    input         [3:0] m_addr,
    input               m_we,
    input         [7:0] m_din,
    output        [7:0] m_dout,

    output signed [15:0] left,
    output signed [15:0] right,

    // the sample ROM, SDRAM bank 3 (lethal_sdram's samples port)
    output       [17:0] smp_addr,
    output              smp_cs,
    input               smp_ok,
    input        [63:0] smp_data,
    output       [15:0] ovr             // the chip's late samples
);

wire [15:0] A;
wire [7:0]  dout;
reg  [7:0]  din;
wire        mreq_n, iorq_n, rd_n, wr_n, m1_n, int_n;
reg         nmi_n;
wire        wait_n;

// ---------------------------------------------------------------- memories
reg [7:0] prog [0:65535];
reg [7:0] ram  [0:2047];
reg [7:0] prog_q, ram_q;
wire      rom_cs = !mreq_n && A < 16'hf000;
wire      ram_cs = !mreq_n && A[15:11] == 5'b11110;
wire      k539_cs_a = !mreq_n && A >= 16'hf800 && A < 16'hfa30;
wire      k321_cs = !mreq_n && A[15:2] == 14'h3f00;          // fc00-fc03

always @(posedge clk) begin
    if (prog_we) prog[prog_addr] <= prog_din;
    prog_q <= prog[A];
    if (ram_cs && !wr_n) ram[A[10:0]] <= dout;
    ram_q <= ram[A[10:0]];
end

// ---------------------------------------------------------------- 054321
wire [7:0] k321_sdin;
reg        wr_l;
always @(posedge clk) wr_l <= !wr_n;
jt054321 u_321 (
    .rst     ( rst                  ),
    .clk     ( clk                  ),
    .maddr   ( m_addr               ),
    .mdout   ( m_din                ),
    .mdin    ( m_dout               ),
    .mwe     ( m_we                 ),
    .saddr   ( A[1:0]               ),
    .sdout   ( dout                 ),
    .sdin    ( k321_sdin            ),
    .swe     ( k321_cs && !wr_n && !wr_l ),
    .snd_on  ( snd_on               ),
    .siorq_n ( iorq_n | m1_n        ),
    .int_n   ( int_n                )
);

// ---------------------------------------------------------------- 054539
// one cs pulse per Z80 access, the Z80 held (WAIT) until the chip's ack
reg        k_busy, k_done;
reg        acc_l;
wire       acc     = k539_cs_a && (!rd_n || !wr_n);
wire       k_start = acc && !acc_l;
wire [7:0] k_dout;
wire       k_ack, k_timer;
always @(posedge clk) begin
    acc_l <= acc;
    if (rst || !acc) begin k_busy <= 1'b0; k_done <= 1'b0; end
    else begin
        if (k_start) k_busy <= 1'b1;
        if (k_ack) begin k_busy <= 1'b0; k_done <= 1'b1; end
    end
end
assign wait_n = !(acc && !k_done);

// the 054539 and its memories, volume and output (rtl/sound/lethal_k539.sv)
wire smp;
lethal_k539 u_k539 (
    .clk        ( clk           ),
    .rst        ( rst           ),
    .cs         ( k_start       ),
    .we         ( !wr_n         ),
    .addr       ( A[10:0]       ),
    .din        ( dout          ),
    .dout       ( k_dout        ),
    .ack        ( k_ack         ),
    .timer_out  ( k_timer       ),
    .vol_we     ( m_we          ),
    .vol_addr   ( m_addr        ),
    .vol_din    ( m_din         ),
    .smp_addr   ( smp_addr      ),
    .smp_cs     ( smp_cs        ),
    .smp_ok     ( smp_ok        ),
    .smp_data   ( smp_data      ),
    .smp        ( smp           ),
    .left       ( left          ),
    .right      ( right         ),
    .ovr        ( ovr           )
);

// NMI follows the timer's level (set_inputline: asserted while high)
always @(posedge clk) nmi_n <= !k_timer;

// ---------------------------------------------------------------- Z80
always @* begin
    din = 8'hff;
    if (rom_cs)       din = prog_q;
    else if (ram_cs)  din = ram_q;
    else if (k539_cs_a) din = k_dout;
    else if (k321_cs) din = k321_sdin;
end

jtframe_z80 u_z80 (
    .rst_n   ( ~rst     ),
    .clk     ( clk      ),
    .cen     ( cen      ),
    .wait_n  ( wait_n   ),
    .int_n   ( int_n    ),
    .nmi_n   ( nmi_n    ),
    .busrq_n ( 1'b1     ),
    .m1_n    ( m1_n     ),
    .mreq_n  ( mreq_n   ),
    .iorq_n  ( iorq_n   ),
    .rd_n    ( rd_n     ),
    .wr_n    ( wr_n     ),
    .rfsh_n  (          ),
    .halt_n  (          ),
    .busak_n (          ),
    .A       ( A        ),
    .din     ( din      ),
    .dout    ( dout     )
);

endmodule
