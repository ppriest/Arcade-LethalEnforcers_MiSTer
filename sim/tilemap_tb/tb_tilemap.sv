// SPDX-License-Identifier: GPL-3.0-or-later
//
// lethal_tilemap against a MAME capture: scripts/check_tilemap.py builds the
// inputs, runs this, and compares with scripts/render_model.py's layers.
//
//   +vram=<hex>    the capture's VRAM writes: "page plane tile byte" lines, the
//                  five pages the game uses
//   +regs=<hex>    the 32 054156 register words, one per line
//   +rom=<hex>     tile rows, { first half 4 bytes, second half 4 bytes } per
//                  line, row = code * 8 + y
//   +out=<file>    for each bitmap line 16..239: "y layer" then 288 values
//   +romlat=<n>    clocks from rom_cs to rom_ok
//   +rev=1         render with lb_rev set

`timescale 1ns/1ps

module tb_tilemap;

reg clk = 0;
always #10.4167 clk = ~clk;
reg rst = 1;

reg         reg_we = 0;
reg  [5:0]  reg_addr;
reg  [7:0]  reg_din;
reg         vram_we = 0;
reg  [12:0] vram_addr;
reg  [7:0]  vram_din;
wire [7:0]  vram_dout;
reg         line_start = 0;
reg  [8:0]  line_y;
reg         lb_rev = 0;
wire        busy, unsupported;
wire [15:0] dbg_lost;
wire [18:0] rom_addr;
wire        rom_cs;
reg         rom_ok = 0;
reg  [63:0] rom_data;
reg  [8:0]  rd_x;
wire [11:0] rd_pix [4];

lethal_tilemap dut (
    .clk(clk), .rst(rst),
    .reg_we(reg_we), .reg_addr(reg_addr), .reg_din(reg_din),
    .vram_we(vram_we), .vram_rd(1'b0), .vram_addr(vram_addr), .vram_din(vram_din), .vram_dout(vram_dout),
    .line_start(line_start), .line_y(line_y), .lb_rev(lb_rev),
    .busy(busy), .unsupported(unsupported), .dbg_lost(dbg_lost),
    .rom_addr(rom_addr), .rom_cs(rom_cs), .rom_ok(rom_ok), .rom_data(rom_data),
    .rd_x(rd_x), .rd_pix(rd_pix)
);

reg [63:0] rom [0:(1<<19)-1];
integer romlat = 3, lat = 0;
longint rom_reads = 0;
always @(posedge clk) begin
    rom_ok <= 0;
    if (rom_cs && !rom_ok) begin
        if (lat >= romlat) begin
            rom_data <= rom[rom_addr];
            rom_ok   <= 1;
            lat      <= 0;
            rom_reads <= rom_reads + 1;
        end else lat <= lat + 1;
    end else lat <= 0;
end

task automatic wreg(input [5:0] a, input [7:0] d);
    @(posedge clk); reg_we <= 1; reg_addr <= a; reg_din <= d;
    @(posedge clk); reg_we <= 0;
endtask

string vfile, rfile, romfile, outfile;
integer fv, fr, fo, k, n, page, plane, tile, data, y, l, x;
reg [15:0] regw [32];
longint line_clocks, max_line = 0, sum_line = 0, nlines = 0;

initial begin
    if (!$value$plusargs("vram=%s", vfile) || !$value$plusargs("regs=%s", rfile) ||
        !$value$plusargs("rom=%s", romfile) || !$value$plusargs("out=%s", outfile)) begin
        $display("need +vram= +regs= +rom= +out="); $finish;
    end
    void'($value$plusargs("romlat=%d", romlat));
    void'($value$plusargs("rev=%d", k)); lb_rev = k == 1;
    $readmemh(romfile, rom);
    fr = $fopen(rfile, "r");
    for (k = 0; k < 32; k++) void'($fscanf(fr, "%h\n", regw[k]));
    $fclose(fr);
    repeat (10) @(posedge clk);
    rst = 0;
    // VRAM through the CPU window: select each page with register 0x19, or
    // register 0 bit 1 for the line-scroll page
    fv = $fopen(vfile, "r");
    page = -1;
    while ($fscanf(fv, "%d %d %d %h\n", n, plane, tile, data) == 4) begin
        if (n != page) begin
            page = n;
            if (page == 16) wreg(6'd1, 8'h02);
            else begin
                wreg(6'd1, 8'h00);
                wreg(6'd51, 8'(((page >> 2) << 3) | (page & 3)));     // register 0x19 low byte
            end
        end
        @(posedge clk); vram_we <= 1; vram_addr <= { 2'(plane), 11'(tile) }; vram_din <= 8'(data);
        @(posedge clk); vram_we <= 0;
    end
    $fclose(fv);
    for (k = 0; k < 32; k++) begin
        wreg(6'({k[4:0], 1'b0}), regw[k][15:8]);
        wreg(6'({k[4:0], 1'b1}), regw[k][7:0]);
    end
    fo = $fopen(outfile, "w");
    // render line y, then start y + 1 and read y's half while it renders
    for (y = 16; y <= 240; y++) begin
        // hold line_start until the renderer has taken it
        @(posedge clk); line_start <= 1; line_y <= 9'(y);
        @(posedge clk); line_start <= 0;
        @(posedge clk);
        while (!busy) @(posedge clk);
        line_clocks = 2;
        if (y > 16) begin
            for (l = 0; l < 4; l++) begin
                $fwrite(fo, "%0d %0d", y - 1, l);
                for (x = 0; x < 288; x++) begin
                    rd_x <= 9'(x);
                    @(posedge clk); @(negedge clk);
                    $fwrite(fo, " %03x", rd_pix[l]);
                    line_clocks += 1;
                end
                $fwrite(fo, "\n");
            end
        end
        while (busy) begin @(posedge clk); line_clocks += 1; end
        if (y < 240) begin
            if (line_clocks > max_line) max_line = line_clocks;
            sum_line += line_clocks; nlines += 1;
        end
    end
    $fclose(fo);
    $display("LINES %0d, render clocks a line: max %0d, mean %0d (romlat %0d; reads overlap the next render)",
             nlines, max_line, sum_line / nlines, romlat);
    $display("UNSUPPORTED %0d LOST %0d ROMREADS %0d", unsupported, dbg_lost, rom_reads);
    $finish;
end

endmodule
