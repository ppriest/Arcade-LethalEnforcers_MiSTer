// SPDX-License-Identifier: GPL-3.0-or-later
//
// Standalone Fmax and area for mc6809i in jtframe_sys6809, with its program
// ROM fetched through jtframe_sdram64, on the DE10-nano's Cyclone V
// (5CSEBA6U23I7). Phase 0 exit criterion 4, docs/ROADMAP.md. Not part of the core.
//
// The CPU is clocked at clk and enabled at its rate (cen, divided by 4 inside
// the wrapper), so the number constrains the clock, not the 3 MHz CPU.
// ROM reads go to SDRAM bank 0 a 16-bit word at a time, behind a one-word
// tag: the transport the core will start from, not its final cache.
// Peripheral reads come from a registered input port. Pins are virtual (.qsf)
// and every output lands in a flop, so the report is register to register.
module mc6809_fmax_top (
    input  logic        clk,
    input  logic        rst,
    input  logic [ 7:0] io_din,
    input  logic        nirq,
    output logic [ 7:0] sig,

    inout  wire  [15:0] sdram_dq,
    output logic [12:0] sdram_a,
    output logic        sdram_dqml, sdram_dqmh,
    output logic [ 1:0] sdram_ba,
    output logic        sdram_nwe, sdram_ncas, sdram_nras, sdram_ncs, sdram_cke
);
    logic        r_rst, r_nirq;
    logic [ 7:0] r_io;
    logic [ 1:0] cendiv;
    wire         cen = &cendiv;     // clk/4, as tb_boot

    always_ff @(posedge clk) begin
        r_rst  <= rst;
        r_nirq <= nirq;
        r_io   <= io_din;
        cendiv <= cendiv + 2'd1;
    end

    wire [15:0] A;
    wire        RnW, VMA, cpu_cen;
    wire [ 7:0] ram_dout, cpu_dout;
    logic [7:0] cpu_din;
    logic [4:0] rbank;

    wire ram_cs = A[15:13] == 3'b001;
    wire rom_cs = A[15] | (A[15:13] == 3'b000);
    wire [17:0] rom_a = A[15] ? {3'b111, A[14:0]} : {rbank, A[12:0]};

    // one-word ROM tag in front of SDRAM bank 0
    logic [16:0] tag;
    logic        tag_ok, busy;
    logic [15:0] word;
    wire         hit    = tag_ok && tag == rom_a[17:1];
    wire         rom_ok = hit;

    wire  [3:0]  ack, dst, dok, rdy;
    wire  [15:0] dout;
    wire         init;

    always_ff @(posedge clk) begin
        if( r_rst ) begin
            tag_ok <= 0;
            busy   <= 0;
        end else begin
            if( rom_cs && !hit && !busy && !init ) begin
                busy   <= 1;
                tag    <= rom_a[17:1];
                tag_ok <= 0;
            end
            if( busy && dok[0] ) word <= dout;
            if( busy && rdy[0] ) begin
                busy   <= 0;
                tag_ok <= 1;
            end
        end
    end

    jtframe_sdram64 #(.AW(22), .HF(0), .BA0_LEN(16), .BA1_LEN(16), .BA2_LEN(16), .BA3_LEN(16), .PROG_LEN(16),
                      .BA0_WEN(0)) u_sdram(
        .rst      ( r_rst ), .clk( clk ), .init( init ),
        .ba0_addr ( {4'd0, tag} ), .ba1_addr( 22'd0 ), .ba2_addr( 22'd0 ), .ba3_addr( 22'd0 ),
        .rd       ( {3'd0, busy & ~rdy[0]} ), .wr( 4'd0 ),
        .ba0_din  ( 16'd0 ), .ba0_dsn( 2'b11 ), .ba1_din( 16'd0 ), .ba1_dsn( 2'b11 ),
        .ba2_din  ( 16'd0 ), .ba2_dsn( 2'b11 ), .ba3_din( 16'd0 ), .ba3_dsn( 2'b11 ),
        .prog_en  ( 1'b0 ), .prog_addr( 22'd0 ), .prog_rd( 1'b0 ), .prog_wr( 1'b0 ),
        .prog_din ( 16'd0 ), .prog_dsn( 2'b11 ), .prog_ba( 2'd0 ),
        .prog_dst (), .prog_dok(), .prog_rdy(), .prog_ack(),
        .rfsh     ( 1'b0 ),
        .ack( ack ), .dst( dst ), .dok( dok ), .rdy( rdy ), .dout( dout ),
        .sdram_dq ( sdram_dq ), .sdram_a( sdram_a ), .sdram_dqml( sdram_dqml ),
        .sdram_dqmh( sdram_dqmh ), .sdram_ba( sdram_ba ), .sdram_nwe( sdram_nwe ),
        .sdram_ncas( sdram_ncas ), .sdram_nras( sdram_nras ), .sdram_ncs( sdram_ncs ),
        .sdram_cke( sdram_cke )
    );

    always_comb cpu_din = ram_cs ? ram_dout : rom_cs ? (rom_a[0] ? word[7:0] : word[15:8]) : r_io;

    always_ff @(posedge clk)
        if( cpu_cen && !RnW && A == 16'h40dc ) rbank <= cpu_dout[4:0];

    jtframe_sys6809 #(.RAM_AW(13), .RECOVERY(1)) u_sys(
        .rstn( ~r_rst ), .clk( clk ), .cen( cen ), .cpu_cen( cpu_cen ),
        .nIRQ( r_nirq ), .nFIRQ( 1'b1 ), .nNMI( 1'b1 ), .irq_ack(),
        .bus_busy( 1'b0 ),
        .A( A ), .RnW( RnW ), .VMA( VMA ),
        .ram_cs( ram_cs ), .rom_cs( rom_cs ), .rom_ok( rom_ok ),
        .ram_dout( ram_dout ), .cpu_dout( cpu_dout ), .cpu_din( cpu_din )
    );

    always_ff @(posedge clk)
        sig <= {^A[15:8], ^A[7:0], ^cpu_dout, RnW, VMA, cpu_cen, ^rbank, init};
endmodule
