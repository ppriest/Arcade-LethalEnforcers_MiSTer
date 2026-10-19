// SPDX-License-Identifier: GPL-3.0-or-later
//
// Lethal Enforcers' layer mixing and palette, as lethal.cpp screen_update draws:
// the background pen, layers D, C, B (priority bits 1, 2, 4), the sprites
// against a priority mask chosen by colour bits 4-5, layer A over everything;
// then the xBGR_555 palette, a shadowed pixel taking its colour from the shadow
// table (red x 0.6, lethal.cpp palette_w). Specification: render_model.py
// render() and render_sprites.blit's pixel rule.
//
// Two clocks from inputs to rgb. The palette RAM is the CPU's (bank4000 with
// CBNK = 1, 0x4400-0x7fff): byte address, high byte of an entry first.
//
// Pens. A tile pixel is 1024 * bank + 256 * colour + pixel (tile_callback with
// the gfx element's granularity of 16), which passes 0x2000 for the high banks:
// MAME then reads its shadow half, and so does this, through the same table. A
// sprite pixel is { bank, colour, pen } (sprite_callback, granularity 64).
//
// Shadows (PIXEL_OP_REBASE_TRANSTABLE16_PRIORITY with lethal's DRAWMODE_SHADOW_PRI):
// a shadow pixel whose mask passes the tiles under it darkens what ends up there,
// sprite or tile; layer A, drawn after, is not darkened.

module lethal_mixer (
    input               clk,
    input               pxl_cen,

    input        [11:0] lyr [4],        // { colour[3:0], pixel[7:0] } for A, B, C, D
    input        [15:0] spr,            // lethal_obj: { shadow, shadow class[1:0], colour[6:0], pen[5:0] }
    input         [7:0] pcu1, pcu2, pcu3,

    // palette RAM, CPU side
    input               pal_we,
    input        [13:0] pal_addr,
    input         [7:0] pal_din,
    output reg    [7:0] pal_dout,

    output reg   [23:0] rgb
);

// priority masks by sprite colour bits 4-5 (lethal.cpp sprite_callback)
function automatic [7:0] pmask( input [1:0] cls );
    case (cls)
        2'd0: pmask = 8'h00;
        2'd1: pmask = 8'hf0;
        2'd2: pmask = 8'hfc;
        default: pmask = 8'hfe;
    endcase
endfunction

wire [2:0] bank [4];
assign bank[0] = pcu1[2:0];
assign bank[1] = pcu1[6:4];
assign bank[2] = pcu2[2:0];
assign bank[3] = pcu2[6:4];

function automatic [13:0] tile_pen( input [2:0] b, input [3:0] c, input [7:0] p );
    tile_pen = {1'b0, b, 10'd0} + {2'd0, c, 8'd0} + {6'd0, p};
endfunction

wire        opq_b = lyr[1][7:0] != 8'd0;
wire        opq_c = lyr[2][7:0] != 8'd0;
wire        opq_d = lyr[3][7:0] != 8'd0;
wire        opq_a = lyr[0][7:0] != 8'd0;
wire [2:0]  t     = { opq_b, opq_c, opq_d };          // the tilemaps' priority bits
wire [13:0] under = opq_b ? tile_pen(bank[1], lyr[1][11:8], lyr[1][7:0]) :
                    opq_c ? tile_pen(bank[2], lyr[2][11:8], lyr[2][7:0]) :
                    opq_d ? tile_pen(bank[3], lyr[3][11:8], lyr[3][7:0]) :
                            { 1'b0, pcu3[6:4], 10'h3ff };    // back_colorbase
wire [5:0]  s_pen = spr[5:0];
wire [6:0]  s_col = spr[12:6];
wire [7:0]  s_msk = pmask(s_col[5:4]);              // Quartus 17: no select on a call
wire [7:0]  d_msk = pmask(spr[14:13]);
wire        s_ok  = s_pen != 6'd0 && !s_msk[t];
wire        d_ok  = spr[15] && !d_msk[t];
wire [13:0] s_idx = { 1'b0, pcu3[2:0], s_col[3:0], s_pen };
wire [13:0] mixed = (s_ok ? s_idx : under) | (d_ok ? 14'h2000 : 14'h0);
wire [13:0] idx   = opq_a ? tile_pen(bank[0], lyr[0][11:8], lyr[0][7:0]) : mixed;

// palette: 0x2000 entries, two byte lanes; entry e is bytes 2e (high), 2e+1
reg  [7:0] pal_hi [0:8191];
reg  [7:0] pal_lo [0:8191];
reg  [7:0] q_hi, q_lo, cq_hi, cq_lo;
reg        shd_l, codd;
always @(posedge clk) begin
    if (pal_we && !pal_addr[0]) pal_hi[pal_addr[13:1]] <= pal_din;
    if (pal_we &&  pal_addr[0]) pal_lo[pal_addr[13:1]] <= pal_din;
    cq_hi <= pal_hi[pal_addr[13:1]];
    cq_lo <= pal_lo[pal_addr[13:1]];
    codd  <= pal_addr[0];
end
always @* pal_dout = codd ? cq_lo : cq_hi;

// red x 0.6 of the 8-bit expansion of a 5-bit red (rgb_t's r() * PALETTE_DEFAULT_SHADOW_FACTOR, truncated)
// generated: int(((r << 3) | (r >> 2)) * 0.6), the same in float and double
function automatic [7:0] shadow_r( input [4:0] r );
    case (r)
        5'd0: shadow_r = 8'd0;  5'd1: shadow_r = 8'd4;  5'd2: shadow_r = 8'd9;  5'd3: shadow_r = 8'd14;
        5'd4: shadow_r = 8'd19;  5'd5: shadow_r = 8'd24;  5'd6: shadow_r = 8'd29;  5'd7: shadow_r = 8'd34;
        5'd8: shadow_r = 8'd39;  5'd9: shadow_r = 8'd44;  5'd10: shadow_r = 8'd49;  5'd11: shadow_r = 8'd54;
        5'd12: shadow_r = 8'd59;  5'd13: shadow_r = 8'd64;  5'd14: shadow_r = 8'd69;  5'd15: shadow_r = 8'd73;
        5'd16: shadow_r = 8'd79;  5'd17: shadow_r = 8'd84;  5'd18: shadow_r = 8'd88;  5'd19: shadow_r = 8'd93;
        5'd20: shadow_r = 8'd99;  5'd21: shadow_r = 8'd103;  5'd22: shadow_r = 8'd108;  5'd23: shadow_r = 8'd113;
        5'd24: shadow_r = 8'd118;  5'd25: shadow_r = 8'd123;  5'd26: shadow_r = 8'd128;  5'd27: shadow_r = 8'd133;
        5'd28: shadow_r = 8'd138;  5'd29: shadow_r = 8'd143;  5'd30: shadow_r = 8'd148;  5'd31: shadow_r = 8'd153;
        default: shadow_r = 8'd0;
    endcase
endfunction

always @(posedge clk) if (pxl_cen) begin
    q_hi  <= pal_hi[idx[12:0]];
    q_lo  <= pal_lo[idx[12:0]];
    shd_l <= idx[13];
end

wire [15:0] e = { q_hi, q_lo };
always @(posedge clk) if (pxl_cen) begin
    rgb[23:16] <= shd_l ? shadow_r(e[4:0]) : { e[4:0], e[4:2] };
    rgb[15: 8] <= { e[9:5],   e[9:7] };
    rgb[ 7: 0] <= { e[14:10], e[14:12] };
end

endmodule
