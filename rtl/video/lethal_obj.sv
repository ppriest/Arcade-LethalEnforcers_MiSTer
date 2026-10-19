// SPDX-License-Identifier: GPL-3.0-or-later
//
// Lethal Enforcers' sprites: the 053245 RAM, jtcores' jt053244 (scan and DMA)
// and its line drawer at 6 bpp (lethal_objdraw_gate6).
//
// jt053244 is the chip modelled from the silicon, not MAME's k053244: where its
// output differs from MAME's frames, the difference is recorded in
// docs/MAME_KLUDGES.md ("Vendored modules that disagree with MAME") and kept.
//
// The wiring follows jtcores' riders core (jtriders_obj.v): the drawer takes
// ~hflip and SWAPH=1 because the ROM rows are in MAME's bit order (leftmost
// pixel in bit 7), and the tile number reaches the ROM through the same bit
// shuffle as MAME's (code bits 5,3,1 are the tile row, 4,2,0 the column).
//
// ROM: one word per 8 pixels of a sprite row, word index
//   { code[13:6], row[2:0], col[2:0], ysub[3], half, ysub[2:0] }
// with rom_data[31:0] the 4 bytes at 4 * index in the region's first 2 MB,
// byte k (memory order) in bits 8k+7..8k, and rom_data[47:32] the 2 bytes at
// 0x200000 + 4 * index (191A06, ROM_LOAD32_WORD). Planes, MSB first, are
// { F+8, F+0, 24, 16, 8, 0 } (spritelayout_6bpp): bits [47:40], [39:32],
// [31:24], ..., [7:0].
//
// Output per pixel at the drawer's read position: { shadow, shadow class[1:0], colour[6:0], pen[5:0] }.
// The shadow store keeps three bits, { 1, colour[5:4] } of the shadow sprite that
// set it and 0 otherwise, so the mixer can apply that sprite's priority mask; a
// shadow-only pixel writes nothing else to the buffer.
// lethal.cpp sprite_callback: colour[5:4] picks the priority mask, colour[3:0]
// plus the PCU3 sprite base the palette block; pen 63 of a shadow sprite is shadow.

module lethal_obj #(
    // added to the mirrored X under the 053244's flip X (jt053244 HFLIP_OFFSET). 118 puts
    // the unzoomed sprites of a flipped frame (lethalenj) at the same raster position,
    // relative to MAME's bitmap, as an unflipped one's: bitmap = raster + (105, 255)
    // for every unzoomed sprite of every capture (scripts/classify_obj.py)
    parameter [9:0] HFLIP_OFFSET = 10'd118,
    // 1: the drawer reads the line buffer at its own count after hdump (jtframe's HFIX),
    // as sim/obj_tb measures; 0: at rd_x, which lethal_video drives in any order
    parameter       HFIX = 1
) (
    input               rst,
    input               clk,
    input               pxl_cen,
    input               pxl2_cen,
    input        [8:0]  hdump,          // 0x20..0x19f
    input        [9:0]  rd_x,           // line buffer read address when HFIX = 0
    input        [8:0]  vrender,        // the line being drawn: 0xf8..0x1ff
    input               hs,
    input               lvbl,

    // 053245 RAM, bank4000 0x1000-0x17ff: byte offset, high byte of a word first
    input               ram_we,
    input        [10:0] ram_addr,
    input         [7:0] ram_din,
    output        [7:0] ram_dout,
    // 053244 registers, bank4000 0x0840-0x084f
    input               reg_we,
    input         [3:0] reg_addr,
    input         [7:0] reg_din,
    output              dma_bsy,

    output       [20:2] rom_addr,
    output              rom_cs,
    input               rom_ok,
    input        [47:0] rom_data,

    output       [15:0] pxl            // { shadow, shadow's class[1:0], colour[6:0], pen[5:0] }
);

// ---------------------------------------------------------------- 053245 RAM
wire [13:1] dma_addr;
wire [15:0] dma_data;
reg  [ 7:0] ram_hi [0:1023];
reg  [ 7:0] ram_lo [0:1023];
reg  [ 7:0] cpu_q_hi, cpu_q_lo, dma_hi, dma_lo;
reg         cpu_odd;

always @(posedge clk) begin
    if (ram_we && !ram_addr[0]) ram_hi[ram_addr[10:1]] <= ram_din;
    if (ram_we &&  ram_addr[0]) ram_lo[ram_addr[10:1]] <= ram_din;
    cpu_q_hi <= ram_hi[ram_addr[10:1]];
    cpu_q_lo <= ram_lo[ram_addr[10:1]];
    cpu_odd  <= ram_addr[0];
    dma_hi   <= ram_hi[dma_addr[10:1]];
    dma_lo   <= ram_lo[dma_addr[10:1]];
end
assign ram_dout = cpu_odd ? cpu_q_lo : cpu_q_hi;
assign dma_data = { dma_hi, dma_lo };

// ---------------------------------------------------------------- 053244
wire        dr_start, dr_busy, hflip, vflip, hz_keep, pre_shd;
wire [15:0] code;
wire [ 6:0] attr;
wire [ 9:0] hpos;
wire [ 3:0] ysub;
wire [11:0] hzoom;
wire [21:1] rmrd_addr;
wire [ 7:0] st_dout;

jt053244 #(.HFLIP_OFFSET(HFLIP_OFFSET)) u_scan (
    .rst        ( rst           ),
    .clk        ( clk           ),
    .pxl2_cen   ( pxl2_cen      ),
    .pxl_cen    ( pxl_cen       ),
    .cs         ( reg_we        ),
    .cpu_we     ( reg_we        ),
    .cpu_addr   ( reg_addr      ),
    .cpu_dout   ( {8'd0, reg_din} ),
    .cpu_dsn    ( 2'b10         ),
    .rmrd_addr  ( rmrd_addr     ),
    .dma_addr   ( dma_addr      ),
    .dma_data   ( dma_data      ),
    .dma_bsy    ( dma_bsy       ),
    .code       ( code          ),
    .attr       ( attr          ),
    .hflip      ( hflip         ),
    .vflip      ( vflip         ),
    .hpos       ( hpos          ),
    .ysub       ( ysub          ),
    .hzoom      ( hzoom         ),
    .hz_keep    ( hz_keep       ),
    .hdump      ( hdump         ),
    .vdump      ( vrender       ),
    .lvbl       ( lvbl          ),
    .hs         ( hs            ),
    .pxl        ( 9'd0          ),
    .shd        ( pre_shd       ),
    .dr_start   ( dr_start      ),
    .dr_busy    ( dr_busy       ),
    .debug_bus  ( 8'd0          ),
    .st_addr    ( 8'd0          ),
    .st_dout    ( st_dout       )
);

// ---------------------------------------------------------------- drawer
wire [22:2] pre_addr;           // { code[15:0], half, ysub[3:0] }
wire [15:0] buf_d;              // the buffer's write data, unmodified (jtframe_objdraw's wiring)

function [5:0] tile_conv( input [5:0] x );     // jtriders_obj's paroda_conv
    tile_conv = { x[5], x[3], x[1], x[4], x[2], x[0] };
endfunction

// code & 0x3fff (lethal.cpp sprite_callback)
assign rom_addr = { pre_addr[20:13], tile_conv(pre_addr[12:7]), pre_addr[5], pre_addr[6], pre_addr[4:2] };

lethal_objdraw_gate6 #(
    .AW(10), .CW(16), .PW(6+10), .LATCH(1), .SWAPH(1),
    .ZW(12), .ZI(6), .ZENLARGE(1),
    .FLIP_OFFSET(9'h12), .KEEP_OLD(0), .HFIX(HFIX),
    .SHADOW(1), .SW(3), .SHADOW_PEN(63), .ALPHA(0), .ALPHAW(6)
) u_draw (
    .rst        ( rst           ),
    .clk        ( clk           ),
    .pxl_cen    ( pxl_cen       ),
    .hs         ( hs            ),
    .flip       ( 1'b0          ),
    .hdump      ( HFIX ? {1'b0, hdump} : rd_x ),
    .draw       ( dr_start      ),
    .busy       ( dr_busy       ),
    .code       ( code          ),
    .xpos       ( hpos          ),
    .ysub       ( ysub          ),
    .trunc      ( 2'd0          ),
    .hzoom      ( hzoom         ),
    .hz_keep    ( hz_keep       ),
    .hflip      ( ~hflip        ),
    .vflip      ( vflip         ),
    .pal        ( { pre_shd, pre_shd & attr[5], pre_shd & attr[4], attr } ),
    .rom_addr   ( pre_addr      ),
    .rom_cs     ( rom_cs        ),
    .rom_ok     ( rom_ok        ),
    .rom_data   ( rom_data      ),
    .buf_pred   ( buf_d         ),
    .buf_din    ( buf_d         ),
    .pxl        ( pxl           )
);

endmodule
