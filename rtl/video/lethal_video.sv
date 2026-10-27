// SPDX-License-Identifier: GPL-3.0-or-later
//
// Lethal Enforcers' video: raster timing, the tilemaps (lethal_tilemap), the
// sprites (lethal_obj, jt053244), the mixer and palette (lethal_mixer).
//
// RASTER. 384 x 262 at a 6 MHz pixel (lethal.cpp line 695), counted in display
// coordinates X 0..383, L 0..261, visible X 24..311, L 16..239. Each display pixel
// shows MAME's bitmap pixel
//     x = flip_x ? 335 - X : X        y = flip_y ? 255 - L : L
// where flip_x/flip_y are the cabinet orientation (MAME's ORIENTATION_FLIP_X/Y,
// from the .mra) and the OSD flip. The renderers draw MAME's bitmap, the game's
// own screen flip included; the orientation only chooses which bitmap line is
// drawn next and which way the line buffers are read. That is exact because the
// tilemap renders any line on request and jt053244 evaluates each line from the
// vdump it latches.
//
// TIMING. A tile line takes up to ~2,300 clocks (sim/tilemap_tb, 9-clock ROM), so
// the tilemap starts line L+2 at X = 312 of line L (3,840 clocks before it is
// shown). jt053244 draws at its hs, X = 331 of line L, for line L+2, with vdump =
// y + 255: the raster mapping measured in sim/obj_tb (MAME bitmap y = vdump - 255).
// The sprite line buffer is read at x + OBJ_DX.
//
// The pixel pipeline: buffers read at the pixel's ce_pix, mixed on the fourth clock
// after, two mixer stages: rgb, blanking and syncs are 2 pixels behind X (sim/video_tb).

module lethal_video #(
    parameter [9:0] OBJ_DX = 10'd105
) (
    input               rst,
    input               clk,                // 48 MHz
    input               ce_pix,             // 6 MHz
    input               ce_2x,              // 12 MHz, aligned with ce_pix

    input               orient_flipx,       // MAME orientation of the set
    input               orient_flipy,
    input               osd_flip,
    input         [4:0] layer_en,           // debug: { sprites, D, C, B, A }; all ones to play

    // CPU side
    input               tm_reg_we,
    input         [5:0] tm_reg_addr,
    input         [7:0] tm_reg_din,
    input               vram_we,
    input               vram_rd,
    input        [12:0] vram_addr,
    input         [7:0] vram_din,
    output        [7:0] vram_dout,
    input               objram_we,
    input        [10:0] objram_addr,
    input         [7:0] objram_din,
    output        [7:0] objram_dout,
    input               objreg_we,
    input         [3:0] objreg_addr,
    input         [7:0] objreg_din,
    input               pal_we,
    input        [13:0] pal_addr,
    input         [7:0] pal_din,
    output        [7:0] pal_dout,
    input         [7:0] pcu1, pcu2, pcu3,

    // ROMs
    output       [18:0] tile_addr,
    output              tile_cs,
    input               tile_ok,
    input        [63:0] tile_data,
    output       [20:2] obj_addr,
    output              obj_cs,
    input               obj_ok,
    input        [47:0] obj_data,

    output reg   [23:0] rgb,
    output reg          hblank,
    output reg          vblank,
    output reg          hsync,
    output reg          vsync,
    output reg          vblank_irq,         // one clock at the start of vblank
    output              tile_unsupported,
    output       [15:0] tile_lost
);

// ---------------------------------------------------------------- raster
reg [8:0] X, L;
always @(posedge clk) begin
    if (rst) begin
        X <= 9'd0; L <= 9'd0;
    end else if (ce_pix) begin
        if (X == 9'd383) begin
            X <= 9'd0;
            L <= L == 9'd261 ? 9'd0 : L + 9'd1;
        end else X <= X + 9'd1;
    end
end

wire flip_x = orient_flipx ^ osd_flip;
wire flip_y = orient_flipy ^ osd_flip;

function automatic [8:0] bitmap_y( input [8:0] l, input fy );
    bitmap_y = fy ? 9'd255 - l : l;
endfunction

wire [8:0] L1 = L == 9'd261 ? 9'd0 : L + 9'd1;
wire [8:0] L2 = L >= 9'd260 ? L - 9'd260 : L + 9'd2;

// ---------------------------------------------------------------- tilemaps
wire        tm_busy;
wire [11:0] tm_pix [4];
wire        tm_start = ce_pix && X == 9'd312;

lethal_tilemap u_tiles (
    .clk        ( clk           ),
    .rst        ( rst           ),
    .reg_we     ( tm_reg_we     ),
    .reg_addr   ( tm_reg_addr   ),
    .reg_din    ( tm_reg_din    ),
    .vram_we    ( vram_we       ),
    .vram_rd    ( vram_rd       ),
    .vram_addr  ( vram_addr     ),
    .vram_din   ( vram_din      ),
    .vram_dout  ( vram_dout     ),
    .line_start ( tm_start      ),
    .line_y     ( bitmap_y(L2, flip_y) ),
    .lb_rev     ( flip_x        ),
    .busy       ( tm_busy       ),
    .unsupported( tile_unsupported ),
    .dbg_lost   ( tile_lost     ),
    .rom_addr   ( tile_addr     ),
    .rom_cs     ( tile_cs       ),
    .rom_ok     ( tile_ok       ),
    .rom_data   ( tile_data     ),
    .rd_x       ( X - 9'd24     ),
    .rd_pix     ( tm_pix        )
);

// ---------------------------------------------------------------- sprites
// jt053244's hs from X = 331 for 32 pixels. The same hs swaps its line buffers, so
// the line it starts drawing at the hs of line L is swapped in at the hs of L+1 and
// shown during L+2: vdump is that line's
wire        obj_hs  = X >= 9'd331 && X < 9'd363;
wire [8:0]  obj_v   = bitmap_y(L2, flip_y) + 9'd255;
wire [8:0]  x_bmp   = flip_x ? 9'd335 - X : X;
wire [15:0] obj_pix;
// a disabled layer reads as transparent (pixel 0)
wire [11:0] mix_lyr [4];
genvar le;
generate for (le = 0; le < 4; le++) begin : g_len
    assign mix_lyr[le] = layer_en[le] ? tm_pix[le] : 12'd0;
end endgenerate

lethal_obj #(.HFIX(0)) u_obj (
    .rst        ( rst           ),
    .clk        ( clk           ),
    .pxl_cen    ( ce_pix        ),
    .pxl2_cen   ( ce_2x         ),
    .hdump      ( 9'd0          ),
    .rd_x       ( {1'b0, x_bmp} + OBJ_DX ),
    .vrender    ( obj_v         ),
    .hs         ( obj_hs        ),
    // lvbl is high over the visible lines; jt053244's DMA triggers two lines
    // after its fall
    .lvbl       ( ~(L < 9'd16 || L > 9'd239) ),
    .ram_we     ( objram_we     ),
    .ram_addr   ( objram_addr   ),
    .ram_din    ( objram_din    ),
    .ram_dout   ( objram_dout   ),
    .reg_we     ( objreg_we     ),
    .reg_addr   ( objreg_addr   ),
    .reg_din    ( objreg_din    ),
    .dma_bsy    (               ),
    .rom_addr   ( obj_addr      ),
    .rom_cs     ( obj_cs        ),
    .rom_ok     ( obj_ok        ),
    .rom_data   ( obj_data      ),
    .pxl        ( obj_pix       )
);

// ---------------------------------------------------------------- mixer
reg  [3:0] cen_sh;
always @(posedge clk) cen_sh <= { cen_sh[2:0], ce_pix };
wire mix_cen = cen_sh[3];
wire [23:0] mix_rgb;

lethal_mixer u_mix (
    .clk        ( clk           ),
    .pxl_cen    ( mix_cen       ),
    .lyr        ( mix_lyr       ),
    .spr        ( layer_en[4] ? obj_pix : 16'd0 ),
    .pcu1       ( pcu1          ),
    .pcu2       ( pcu2          ),
    .pcu3       ( pcu3          ),
    .pal_we     ( pal_we        ),
    .pal_addr   ( pal_addr      ),
    .pal_din    ( pal_din       ),
    .pal_dout   ( pal_dout      ),
    .rgb        ( mix_rgb       )
);

// blanking and syncs, delayed to match: rgb for pixel X is out two pixels later
reg [3:0] hb_sh, vb_sh, hs_sh, vs_sh;
always @(posedge clk) begin
    vblank_irq <= ce_pix && X == 9'd0 && L == 9'd240;
    if (ce_pix) begin
        hb_sh <= { hb_sh[2:0], X < 9'd24 || X > 9'd311 };
        vb_sh <= { vb_sh[2:0], L < 9'd16 || L > 9'd239 };
        hs_sh <= { hs_sh[2:0], X >= 9'd336 && X < 9'd368 };
        vs_sh <= { vs_sh[2:0], L >= 9'd244 && L < 9'd247 };
        hblank <= hb_sh[0];
        vblank <= vb_sh[0];
        hsync  <= hs_sh[0];
        vsync  <= vs_sh[0];
        rgb    <= mix_rgb;
    end
end

endmodule
