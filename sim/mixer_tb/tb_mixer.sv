// SPDX-License-Identifier: GPL-3.0-or-later
//
// lethal_mixer on a whole frame: scripts/check_frame.py writes the inputs from
// the tilemap and sprite benches' outputs, runs this, and compares with MAME.
//
//   +pix=<file>   224 x 288 lines "A B C D spr", hex, bitmap lines 16..239, columns 24..311
//   +pal=<file>   the 16 KB palette, one byte a line
//   +pcu=<file>   PCU1, PCU2, PCU3, one a line
//   +out=<file>   one "rrggbb" a pixel, same order

`timescale 1ns/1ps

module tb_mixer;

reg clk = 0;
always #10.4167 clk = ~clk;

reg  [11:0] lyr [4];
reg  [15:0] spr;
reg  [ 7:0] pcu [3];
reg         pal_we = 0;
reg  [13:0] pal_addr = 0;
reg  [ 7:0] pal_din;
wire [ 7:0] pal_dout;
wire [23:0] rgb;

lethal_mixer dut (
    .clk(clk), .pxl_cen(1'b1), .lyr(lyr), .spr(spr),
    .pcu1(pcu[0]), .pcu2(pcu[1]), .pcu3(pcu[2]),
    .pal_we(pal_we), .pal_addr(pal_addr), .pal_din(pal_din), .pal_dout(pal_dout),
    .rgb(rgb)
);

string pixf, palf, pcuf, outf;
integer f, fo, k, v, a, b, c, d, s, n;

initial begin
    if (!$value$plusargs("pix=%s", pixf) || !$value$plusargs("pal=%s", palf) ||
        !$value$plusargs("pcu=%s", pcuf) || !$value$plusargs("out=%s", outf)) begin
        $display("need +pix= +pal= +pcu= +out="); $finish;
    end
    f = $fopen(pcuf, "r");
    for (k = 0; k < 3; k++) begin void'($fscanf(f, "%h\n", v)); pcu[k] = 8'(v); end
    $fclose(f);
    f = $fopen(palf, "r");
    for (k = 0; k < 16384; k++) begin
        void'($fscanf(f, "%h\n", v));
        @(posedge clk); pal_we <= 1; pal_addr <= 14'(k); pal_din <= 8'(v);
    end
    @(posedge clk); pal_we <= 0;
    $fclose(f);
    f  = $fopen(pixf, "r");
    fo = $fopen(outf, "w");
    // two clocks from inputs to rgb: run the stream with that lag
    n = 0;
    while ($fscanf(f, "%h %h %h %h %h\n", a, b, c, d, s) == 5) begin
        lyr[0] = 12'(a); lyr[1] = 12'(b); lyr[2] = 12'(c); lyr[3] = 12'(d); spr = 16'(s);
        @(posedge clk); @(posedge clk); @(negedge clk);
        $fwrite(fo, "%06x\n", rgb);
        n++;
    end
    $fclose(f); $fclose(fo);
    $display("PIXELS %0d", n);
    $finish;
end

endmodule
