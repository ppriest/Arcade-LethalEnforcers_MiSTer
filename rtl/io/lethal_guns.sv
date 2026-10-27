// SPDX-License-Identifier: GPL-3.0-or-later
//
// Lethal Enforcers' light guns, as lethal.cpp reads them (guns_r, gunsaux_r):
//
//   X = v * 287 / 255 + 16    0x40d4/0x40d6 read X >> 1, 0x40db bits 7/6 X bit 0
//   Y = v * 223 / 255 + 10    0x40d5/0x40d7 read 232 - Y, or 0 when Y <= 0x0b or >= 0xe8
//
// with v the 0-255 value of MAME's LIGHTGUN port. Both are 256-entry tables built at
// elaboration (no multiplier). PORT_REVERSE (lethalenj) reads 255 - v on both axes.
//
// Forked from gx_guns.sv (rtl/io/PROVENANCE.md): the aim (stick, d-pad, mouse), the
// reload and the crosshair are its. Its held position (vx, vy) is in screen space, 0 at
// the top left, and the port's v is that position. On the FLIP_Y sets the game's Y
// falls as the port rises, and the flip turns that into screen-down. Measured on the
// board: with ~vy the shots landed mirrored in Y about the crosshair, X matching.
// Reload holds the trigger with v at an off-screen Y.
//
// The crosshair is at v / 256 of the 288 x 224 window: x = v + v/8, y = vy - vy/8.

module lethal_guns (
    input             clk,
    input             rst,         // the guns to the centre
    input      [31:0] joy0,        // joystick_0/1: right, left, down, up, B1, B2 from bit 0
    input      [31:0] joy1,
    input      [15:0] ana0,        // joystick_l_analog_0: { Y, X }, signed
    input      [15:0] ana1,
    input      [24:0] mouse,       // hps_io's ps2_mouse: bit 24 toggles a packet, Y positive up
    input       [1:0] mode0,       // the stick: 0 Auto, 1 Aim, 2 D-pad
    input       [1:0] mode1,
    input       [1:0] ms_who,      // the mouse: 0 P1, 1 P2, 2 off
    input             rev,         // PORT_REVERSE on both axes
    output reg  [7:0] gun [4],     // 0x40d4-0x40d7
    output reg  [1:0] xlsb,        // 0x40db bits 7, 6
    output reg  [1:0] trig,        // { P2, P1 } trigger, the reload's included

    // the crosshair
    input             show,
    input             pxl_cen,
    input             lhbl,
    input             lvbl,
    input      [23:0] rgb_in,
    output reg [23:0] rgb_out
);

// the inputs, registered here: hps_io drives them from clk_sys, the same clock
reg  [31:0] j [0:1];
reg  [15:0] a [0:1];
reg  [24:0] ms;
reg         ms_t, lvbl_l;
always @(posedge clk) begin
    j[0] <= joy0; j[1] <= joy1; a[0] <= ana0; a[1] <= ana1;
    ms <= mouse; ms_t <= ms[24]; lvbl_l <= lvbl;
end
wire       ms_ev  = ms[24] ^ ms_t;
wire       frame  = lvbl_l && !lvbl;
wire [1:0] ms_sel = { ms_who == 2'd1, ms_who == 2'd0 };
wire [1:0] mode [0:1];
assign mode[0] = mode0; assign mode[1] = mode1;

localparam [7:0] DEAD = 8'd8;       // below this the axis is at rest
localparam [7:0] FULL = 8'd96;      // at or above it, Auto moves as the d-pad

function [7:0] mag( input [7:0] v );                // of a signed byte
    mag = v[7] ? 8'd0 - v : v;
endfunction
// v + d, held to 0..255
function [7:0] step( input [7:0] v, input signed [9:0] d );
    reg signed [10:0] t;
    begin
        t = $signed({ 3'b000, v }) + { d[9], d };
        step = t < 11'sd0 ? 8'd0 : t > 11'sd255 ? 8'd255 : t[7:0];
    end
endfunction

reg  [7:0] vx [0:1];
reg  [7:0] vy [0:1];
reg  [7:0] ax, ay;
reg        sx, sy, lx, ly;
reg  [3:0] dir;                     // up, down, left, right
integer g;
always @(posedge clk) begin
    for( g=0; g<2; g=g+1 ) begin
        ax = a[g][7:0]; ay = a[g][15:8];
        lx = mag(ax) >= DEAD; ly = mag(ay) >= DEAD;
        sx = mode[g] == 2'd2 ? lx : mode[g] == 2'd1 ? 1'b0 : mag(ax) >= FULL;
        sy = mode[g] == 2'd2 ? ly : mode[g] == 2'd1 ? 1'b0 : mag(ay) >= FULL;
        dir = { j[g][3] | (ay[7] & sy), j[g][2] | (!ay[7] & sy),
                j[g][1] | (ax[7] & sx), j[g][0] | (!ax[7] & sx) };
        if( rst ) begin
            vx[g] <= 8'h80; vy[g] <= 8'h80;
        end else if( ms_ev && ms_sel[g] ) begin
            vx[g] <= step( vx[g], $signed({ {2{ms[4]}}, ms[15:8] }) );
            vy[g] <= step( vy[g], -$signed({ {2{ms[5]}}, ms[23:16] }) );
        end else begin
            if( dir[1:0] != 2'b00 ) begin
                if( frame ) vx[g] <= step( vx[g], dir[0] ? 10'sd2 : -10'sd2 );
            end else if( lx ) vx[g] <= ax ^ 8'h80;
            if( dir[3:2] != 2'b00 ) begin
                if( frame ) vy[g] <= step( vy[g], dir[2] ? 10'sd2 : -10'sd2 );
            end else if( ly ) vy[g] <= ay ^ 8'h80;
        end
    end
end

// the reload: button 2, or the mouse's right button for its player
wire [1:0] rld = { j[1][5] | (ms_sel[1] & ms[1]), j[0][5] | (ms_sel[0] & ms[1]) };
always @(posedge clk)
    trig <= { j[1][4] | (ms_sel[1] & ms[0]), j[0][4] | (ms_sel[0] & ms[0]) } | rld;

// MAME's GUNX / GUNY, as tables
reg [8:0] tx [0:255];
reg [7:0] ty [0:255];
integer t;
initial for (t = 0; t < 256; t = t + 1) begin
    tx[t] = 9'((t * 287) / 255 + 16);
    ty[t] = 8'((t * 223) / 255 + 10);
end

wire [7:0] px0 = rev ? ~vx[0] : vx[0],  px1 = rev ? ~vx[1] : vx[1];
wire [7:0] py0 = rev ? ~vy[0] :  vy[0], py1 = rev ? ~vy[1] :  vy[1];
reg  [8:0] x0, x1;
reg  [7:0] y0, y1;
reg  [1:0] rld1;
always @(posedge clk) begin
    x0 <= tx[px0]; x1 <= tx[px1];
    y0 <= ty[py0]; y1 <= ty[py1];
    rld1 <= rld;
end

function [7:0] gy( input [7:0] y, input off );
    gy = off || y <= 8'h0b || y >= 8'he8 ? 8'd0 : 8'd232 - y;
endfunction

always @(posedge clk) begin
    gun[0] <= x0[8:1]; gun[1] <= gy(y0, rld1[0]);
    gun[2] <= x1[8:1]; gun[3] <= gy(y1, rld1[1]);
    xlsb   <= { x0[0], x1[0] };
end

// ---------------------------------------------------------- crosshair
reg  [8:0] hc, vc;
reg        lhbl_l;
always @(posedge clk) if( pxl_cen ) begin
    lhbl_l <= lhbl;
    if( !lvbl ) vc <= 0;
    else if( lhbl_l && !lhbl ) vc <= vc + 9'd1;
    hc <= lhbl ? hc + 9'd1 : 9'd0;
end

wire [7:0] vx0 = vx[0], vx1 = vx[1], vy0 = vy[0], vy1 = vy[1];
reg  [8:0] cx0, cy0, cx1, cy1;
always @(posedge clk) begin
    cx0 <= { 1'b0, vx0 } + 9'(vx0 >> 3); cy0 <= { 1'b0, vy0 } - 9'(vy0 >> 3);
    cx1 <= { 1'b0, vx1 } + 9'(vx1 >> 3); cy1 <= { 1'b0, vy1 } - 9'(vy1 >> 3);
end

function on_cross( input [8:0] x, input [8:0] y, input [8:0] cx, input [8:0] cy );
    reg [8:0] dx, dy;
    begin
        dx = x >= cx ? x - cx : cx - x;
        dy = y >= cy ? y - cy : cy - y;
        on_cross = (dx == 0 && dy <= 6 && dy >= 2) || (dy == 0 && dx <= 6 && dx >= 2);
    end
endfunction

wire c0 = on_cross( hc, vc, cx0, cy0 );
wire c1 = on_cross( hc, vc, cx1, cy1 );

always @* begin
    rgb_out = rgb_in;
    if( show && lhbl && lvbl ) begin
        if( c0 ) rgb_out = 24'hff2020;
        else if( c1 ) rgb_out = 24'h20ff20;
    end
end

endmodule
