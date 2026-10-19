// SPDX-License-Identifier: GPL-3.0-or-later
//
// Lethal Enforcers' SDRAM: jtframe_sdram64 at 48 MHz (docs/ROADMAP.md, "Memory plan").
//
// BANKS, one per client class (lowest number, highest priority):
//   0  main program, 256 KB, behind a 64-line cache of 8 bytes (the CPU must see
//      ROM data within 9 clocks: ROADMAP, "Measured: mc6809i against ROM latency")
//   1  tile rows, 8 bytes each: the region's first 2 MB give bytes 0-3, the second 2 MB
//      bytes 4-7, so a row is one 64-bit burst
//   2  sprite words, 8 bytes: 191A05/191A04 in 0-3, 191A06 in 4-5, 6-7 never written
//   3  054539 samples, 2 MB (Phase 3)
//
// DOWNLOAD (ioctl index 0, the .mra's byte stream; scripts/build_mra.py writes it in
// this order, and these localparams are what it reads):
//   (the DL_* localparams at the top of the module)
// A region byte at offset o goes to its bank's byte address:
//   main, samples: o
//   tiles, sprites: { o[20:2], o[21], o[1:0] } -- row o[20:2], half o[21], byte o[1:0]
//   191A06, sent as the file: byte j is the region's 0x200000 + 4*(j>>1) + j[0]
//     (ROM_LOAD32_WORD; the region's zero bytes are not sent)
// Bytes are paired into little-endian words (even byte low).
//
// READ DATA. A burst's first word lands in bits 15:0 (jtframe_sdram64), so a row's
// byte k is bits 8k+7..8k. Tile rows are handed out byte 0 in bits 63:56
// (lethal_tilemap's order); sprite words as they are (lethal_obj's).

module lethal_sdram #(
    // 1 on the board: SDRAM_CLK lags clk by 5555 ps (rtl/pll), so read data comes a
    // clock earlier than at zero phase (jtframe's JTFRAME_SHIFT)
    parameter SHIFTED = 0
) (
    input               rst,
    input               clk,                // 48 MHz
    output              init,

    // download
    input               dl_active,          // ioctl_download for index 0
    input               dl_wr,
    input        [24:0] dl_addr,
    input         [7:0] dl_data,
    output              dl_wait,
    output       [24:0] dl_end,             // the stream's length (DDR3 fast load)
    output              snd_we,
    output       [15:0] snd_addr,
    output        [7:0] snd_data,

    input               rfsh,               // a refresh burst, once a line

    // main program
    input        [17:0] main_addr,
    input               main_cs,
    output              main_ok,
    output        [7:0] main_data,
    // tile rows: rom_ok one clock, rom_cs dropped by the client after
    input        [18:0] tile_addr,
    input               tile_cs,
    output reg          tile_ok,
    output reg   [63:0] tile_data,
    // sprite words: obj_ok while obj_addr is the word held
    input        [20:2] obj_addr,
    input               obj_cs,
    output              obj_ok,
    output       [47:0] obj_data,
    // samples (Phase 3): a 64-bit granule
    input        [20:3] smp_addr,
    input               smp_cs,
    output reg          smp_ok,
    output reg   [63:0] smp_data,

    inout        [15:0] sdram_dq,
    output       [12:0] sdram_a,
    output              sdram_dqml,
    output              sdram_dqmh,
    output        [1:0] sdram_ba,
    output              sdram_nwe,
    output              sdram_ncas,
    output              sdram_nras,
    output              sdram_ncs,
    output              sdram_cke
);

// ---------------------------------------------------------------- download
localparam [24:0] DL_MAIN    = 25'h0000000;    // 0x40000  main program
localparam [24:0] DL_TILES   = 25'h0040000;    // 0x400000 MAME's k056832 region
localparam [24:0] DL_SPRITES = 25'h0440000;    // 0x200000 MAME's k053244 region, first half
localparam [24:0] DL_SPR06   = 25'h0640000;    // 0x100000 191A06
localparam [24:0] DL_SOUND   = 25'h0740000;    // 0x10000  Z80 program (block RAM)
localparam [24:0] DL_SAMPLES = 25'h0750000;    // 0x200000 MAME's k054539 region
localparam [24:0] DL_END     = 25'h0950000;

assign dl_end = DL_END;

wire in_main = dl_addr <  DL_TILES;
wire in_tile = dl_addr >= DL_TILES   && dl_addr < DL_SPRITES;
wire in_obj  = dl_addr >= DL_SPRITES && dl_addr < DL_SPR06;
wire in_o6   = dl_addr >= DL_SPR06   && dl_addr < DL_SOUND;
wire in_snd  = dl_addr >= DL_SOUND   && dl_addr < DL_SAMPLES;
wire in_smp  = dl_addr >= DL_SAMPLES && dl_addr < DL_END;
wire [24:0] o_tile = dl_addr - DL_TILES;
wire [24:0] o_obj  = dl_addr - DL_SPRITES;
wire [24:0] o_o6   = dl_addr - DL_SPR06;
wire [24:0] o_smp  = dl_addr - DL_SAMPLES;

assign snd_we   = dl_wr && in_snd;
assign snd_addr = 16'(dl_addr - DL_SOUND);
assign snd_data = dl_data;

// the bank and byte address a download byte goes to
reg [1:0]  dl_ba;
reg [22:0] dl_byte;
always @* begin
    dl_ba = 2'd0; dl_byte = 23'd0;
    if (in_main)      begin dl_ba = 2'd0; dl_byte = 23'(dl_addr); end
    else if (in_tile) begin dl_ba = 2'd1; dl_byte = { 1'b0, o_tile[20:2], o_tile[21], o_tile[1:0] }; end
    else if (in_obj)  begin dl_ba = 2'd2; dl_byte = { 1'b0, o_obj[20:2],  1'b0,  o_obj[1:0] }; end
    else if (in_o6)   begin dl_ba = 2'd2; dl_byte = { 1'b0, o_o6[19:1],   2'b10, o_o6[0]     }; end
    else if (in_smp)  begin dl_ba = 2'd3; dl_byte = 23'(o_smp); end
end

// pair the bytes: the even one is held, the odd one writes the word
reg  [7:0]  even_b;
reg         pw_req, pw_wr;
reg  [21:0] pw_addr;
reg  [1:0]  pw_ba;
reg  [15:0] pw_data;
wire        prog_rdy, prog_ack, prog_dst, prog_dok;
always @(posedge clk) begin
    if (rst) begin pw_req <= 1'b0; pw_wr <= 1'b0; end
    else begin
        if (dl_wr && !in_snd && (in_main || in_tile || in_obj || in_o6 || in_smp)) begin
            if (!dl_byte[0]) even_b <= dl_data;
            else begin
                pw_req  <= 1'b1;
                pw_wr   <= 1'b1;
                pw_addr <= dl_byte[22:1];
                pw_ba   <= dl_ba;
                pw_data <= { dl_data, even_b };
            end
        end
        if (prog_ack) pw_wr  <= 1'b0;
        if (prog_rdy) pw_req <= 1'b0;
    end
end
assign dl_wait = pw_req;

// ---------------------------------------------------------------- read ports
wire [3:0]  ack, dst, dok, rdy;
wire [15:0] dout;
reg  [3:0]  rd;
reg  [21:0] ba_addr [4];
reg  [63:0] acc [4];
reg  [3:0]  done;               // the clock after rdy: acc[] complete

genvar i;
generate for (i = 0; i < 4; i++) begin : g_acc
    always @(posedge clk) begin
        if (dok[i]) acc[i] <= { dout, acc[i][63:16] };
        done[i] <= rdy[i];
    end
end endgenerate

// main program cache: 64 lines of 8 bytes
reg  [63:0] cdata [0:63];
reg  [11:0] ctag  [0:63];
reg  [63:0] cvalid;
wire [5:0]  c_idx = main_addr[8:3];
wire        c_hit = cvalid[c_idx] && ctag[c_idx] == main_addr[17:9];
reg  [63:0] c_line;
reg         c_fill;
reg  [17:3] c_faddr;
always @(posedge clk) c_line <= cdata[c_idx];
// the line read is the clock after the address: a hit answers then
reg         hit_l;
reg  [17:0] haddr_l;
always @(posedge clk) begin
    hit_l   <= c_hit && main_cs;
    haddr_l <= main_addr;
end
assign main_ok   = hit_l && haddr_l == main_addr && main_cs;
assign main_data = c_line[{haddr_l[2:0], 3'd0} +: 8];

always @(posedge clk) begin
    if (rst || init) begin
        cvalid <= 64'd0; c_fill <= 1'b0; rd[0] <= 1'b0;
    end else begin
        if (main_cs && !c_hit && !c_fill) begin
            c_fill <= 1'b1; c_faddr <= main_addr[17:3];
            ba_addr[0] <= { 5'd0, main_addr[17:3], 2'd0 };
            rd[0] <= 1'b1;
        end
        if (ack[0]) rd[0] <= 1'b0;
        if (c_fill && done[0]) begin
            cdata[c_faddr[8:3]]  <= acc[0];
            ctag[c_faddr[8:3]]   <= { 3'd0, c_faddr[17:9] };
            cvalid[c_faddr[8:3]] <= 1'b1;
            c_fill <= 1'b0;
        end
    end
end

// tiles: one row per request
reg t_busy;
always @(posedge clk) begin
    tile_ok <= 1'b0;
    if (rst || init) begin t_busy <= 1'b0; rd[1] <= 1'b0; end
    else begin
        if (tile_cs && !t_busy && !tile_ok) begin
            t_busy <= 1'b1; rd[1] <= 1'b1; ba_addr[1] <= { tile_addr, 2'd0 };
        end
        if (ack[1]) rd[1] <= 1'b0;
        if (t_busy && done[1]) begin
            t_busy  <= 1'b0;
            tile_ok <= 1'b1;
            tile_data <= { acc[1][7:0], acc[1][15:8], acc[1][23:16], acc[1][31:24],
                           acc[1][39:32], acc[1][47:40], acc[1][55:48], acc[1][63:56] };
        end
    end
end

// sprites: the word held, answered while the address is it
reg        o_busy, o_valid;
reg [20:2] o_tag;
reg [47:0] o_word;
assign obj_ok   = obj_cs && o_valid && o_tag == obj_addr;
assign obj_data = o_word;
always @(posedge clk) begin
    if (rst || init) begin o_busy <= 1'b0; o_valid <= 1'b0; rd[2] <= 1'b0; end
    else begin
        if (obj_cs && !obj_ok && !o_busy) begin
            o_busy <= 1'b1; o_valid <= 1'b0; o_tag <= obj_addr;
            rd[2] <= 1'b1; ba_addr[2] <= { obj_addr, 2'd0 };
        end
        if (ack[2]) rd[2] <= 1'b0;
        if (o_busy && done[2]) begin
            o_busy <= 1'b0; o_valid <= 1'b1; o_word <= acc[2][47:0];
        end
    end
end

// samples
reg s_busy;
always @(posedge clk) begin
    smp_ok <= 1'b0;
    if (rst || init) begin s_busy <= 1'b0; rd[3] <= 1'b0; end
    else begin
        if (smp_cs && !s_busy && !smp_ok) begin
            s_busy <= 1'b1; rd[3] <= 1'b1; ba_addr[3] <= { 1'b0, smp_addr, 2'd0 };
        end
        if (ack[3]) rd[3] <= 1'b0;
        if (s_busy && done[3]) begin s_busy <= 1'b0; smp_ok <= 1'b1; smp_data <= acc[3]; end
    end
end

jtframe_sdram64 #(
    .AW(22), .HF(0), .MISTER(1), .SHIFTED(SHIFTED),
    .BA0_LEN(64), .BA1_LEN(64), .BA2_LEN(64), .BA3_LEN(64), .PROG_LEN(16),
    .BA0_WEN(0), .BA1_WEN(0), .BA2_WEN(0), .BA3_WEN(0)
) u_sdram (
    .rst        ( rst           ),
    .clk        ( clk           ),
    .init       ( init          ),
    .ba0_addr   ( ba_addr[0]    ),
    .ba1_addr   ( ba_addr[1]    ),
    .ba2_addr   ( ba_addr[2]    ),
    .ba3_addr   ( ba_addr[3]    ),
    .rd         ( rd            ),
    .wr         ( 4'd0          ),
    .ba0_din    ( 16'd0 ), .ba0_dsn( 2'b11 ),
    .ba1_din    ( 16'd0 ), .ba1_dsn( 2'b11 ),
    .ba2_din    ( 16'd0 ), .ba2_dsn( 2'b11 ),
    .ba3_din    ( 16'd0 ), .ba3_dsn( 2'b11 ),
    .prog_en    ( dl_active | pw_req ),   // the last pair lands after the DDR3 copy ends
    .prog_addr  ( pw_addr       ),
    .prog_rd    ( 1'b0          ),
    .prog_wr    ( pw_wr         ),
    .prog_din   ( pw_data       ),
    .prog_dsn   ( 2'b00         ),
    .prog_ba    ( pw_ba         ),
    .prog_dst   ( prog_dst      ),
    .prog_dok   ( prog_dok      ),
    .prog_rdy   ( prog_rdy      ),
    .prog_ack   ( prog_ack      ),
    .rfsh       ( rfsh          ),
    .ack        ( ack           ),
    .dst        ( dst           ),
    .dok        ( dok           ),
    .rdy        ( rdy           ),
    .dout       ( dout          ),
    .sdram_dq   ( sdram_dq      ),
    .sdram_a    ( sdram_a       ),
    .sdram_dqml ( sdram_dqml    ),
    .sdram_dqmh ( sdram_dqmh    ),
    .sdram_ba   ( sdram_ba      ),
    .sdram_nwe  ( sdram_nwe     ),
    .sdram_ncas ( sdram_ncas    ),
    .sdram_nras ( sdram_nras    ),
    .sdram_ncs  ( sdram_ncs     ),
    .sdram_cke  ( sdram_cke     )
);

endmodule
