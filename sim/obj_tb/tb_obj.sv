// SPDX-License-Identifier: GPL-3.0-or-later
//
// lethal_obj against a MAME capture: scripts/check_obj.py builds the inputs,
// runs this, and compares with scripts/render_sprites.py.
//
//   +ram=<hex>     the 053245 RAM as the DMA copied it, 2048 bytes, one per line
//   +regs=<hex>    the 16 053244 registers, one per line
//   +rom=<hex>     sprite ROM words, 48 bits a line (lethal_obj's ROM format)
//   +out=<file>    for each vdump line 0x110..0x1ef: "vdump" then 384 pixels, hdump 0x20..0x19f
//   +romlat=<n>    clocks from a ROM address to rom_ok
//
// Raster counters as jtcores' 051962 timer runs them for the Konami sprite
// chips: hdump 0x20..0x19f, vdump 0xf8..0x1ff, visible 0x110..0x1ef, hs from
// hdump 0x34 for 32 pixels; the drawer is given vrender = vdump + 1.

`timescale 1ns/1ps

module tb_obj;

reg clk = 0;
always #10.4167 clk = ~clk;
reg rst = 1;

reg [2:0] cnt8 = 0;
always @(posedge clk) cnt8 <= cnt8 + 3'd1;
wire pxl_cen  = cnt8 == 3'd7;
wire pxl2_cen = cnt8[1:0] == 2'd3;

reg  [8:0] hdump = 9'h020, vdump = 9'h0f8;
always @(posedge clk) if (pxl_cen) begin
    if (hdump == 9'h19f) begin
        hdump <= 9'h020;
        vdump <= vdump == 9'h1ff ? 9'h0f8 : vdump + 9'd1;
    end else hdump <= hdump + 9'd1;
end
wire       hs      = hdump >= 9'h034 && hdump < 9'h054;
wire       lvbl    = vdump >= 9'h110 && vdump <= 9'h1ef;
wire [8:0] vrender = vdump == 9'h1ff ? 9'h0f8 : vdump + 9'd1;

reg         ram_we = 0, reg_we = 0;
reg  [10:0] ram_addr = 0;
reg  [ 7:0] ram_din, reg_din;
reg  [ 3:0] reg_addr;
wire [ 7:0] ram_dout;
wire        dma_bsy, rom_cs;
wire [20:2] rom_addr;
reg         rom_ok;
reg  [47:0] rom_data;
wire [15:0] pxl;

lethal_obj dut (
    .rst(rst), .clk(clk), .pxl_cen(pxl_cen), .pxl2_cen(pxl2_cen),
    .hdump(hdump), .rd_x(10'd0), .vrender(vrender), .hs(hs), .lvbl(lvbl),
    .ram_we(ram_we), .ram_addr(ram_addr), .ram_din(ram_din), .ram_dout(ram_dout),
    .reg_we(reg_we), .reg_addr(reg_addr), .reg_din(reg_din), .dma_bsy(dma_bsy),
    .rom_addr(rom_addr), .rom_cs(rom_cs), .rom_ok(rom_ok), .rom_data(rom_data),
    .pxl(pxl)
);

reg [47:0] rom [0:(1<<19)-1];
integer romlat = 3, lat = 0;
reg [20:2] last_a;
always @(posedge clk) begin
    last_a <= rom_addr;
    if (!rom_cs || rom_addr != last_a) lat <= 0;
    else if (lat < romlat) lat <= lat + 1;
    rom_data <= rom[rom_addr];
end
always @* rom_ok = rom_cs && rom_addr == last_a && lat >= romlat;


integer nstart = 0, nscan = 0;
reg dbg = 0;
initial dbg = $test$plusargs("debug");
reg hs_l2 = 0;
always @(posedge clk) begin
    hs_l2 <= hs;
    if (dut.u_scan.u_scan.dr_start && dut.u_scan.u_scan.cen2) nstart++;
    if (hs && !hs_l2) begin
        if (dbg && vdump >= 9'h118 && vdump < 9'h130)
            $display("vdump %03x: draws %0d done %0d scan_obj %0d", vdump, nstart, dut.u_scan.u_scan.done, dut.u_scan.u_scan.scan_obj);
        nstart = 0;
    end
end

task automatic wreg(input [3:0] a, input [7:0] d);
    @(posedge clk); reg_we <= 1; reg_addr <= a; reg_din <= d;
    @(posedge clk); reg_we <= 0;
endtask

string ramf, regf, romf, outf;
// the frame log, sampled on the pixel enables themselves: vdump 0x110..0x1ef,
// each line from hdump 0x20, the pixel the buffer shows at that hdump
integer fo;
reg     logging = 0, in_line = 0;
integer logged = 0, npx = 0;
always @(posedge clk) if (logging && pxl_cen && logged < 224) begin
    if (hdump == 9'h020 && vdump >= 9'h110 && vdump <= 9'h1ef && !in_line) begin
        $fwrite(fo, "%03x", vdump);
        in_line <= 1;
        npx = 0;
    end
    if (in_line || (hdump == 9'h020 && vdump >= 9'h110 && vdump <= 9'h1ef)) begin
        $fwrite(fo, " %04x", pxl);
        npx = npx + 1;
        if (npx == 384) begin
            $fwrite(fo, "\n");
            in_line <= 0;
            logged  <= logged + 1;
        end
    end
end
integer f, k, v, frame;
reg [7:0] regs [16];

initial begin
    if (!$value$plusargs("ram=%s", ramf) || !$value$plusargs("regs=%s", regf) ||
        !$value$plusargs("rom=%s", romf) || !$value$plusargs("out=%s", outf)) begin
        $display("need +ram= +regs= +rom= +out="); $finish;
    end
    void'($value$plusargs("romlat=%d", romlat));
    $readmemh(romf, rom);
    repeat (10) @(posedge clk);
    rst = 0;
    f = $fopen(ramf, "r");
    for (k = 0; k < 2048; k++) begin
        void'($fscanf(f, "%h\n", v));
        @(posedge clk); ram_we <= 1; ram_addr <= 11'(k); ram_din <= 8'(v);
        @(posedge clk); ram_we <= 0;
    end
    $fclose(f);
    f = $fopen(regf, "r");
    for (k = 0; k < 16; k++) begin void'($fscanf(f, "%h\n", v)); regs[k] = 8'(v); end
    $fclose(f);
    for (k = 0; k < 6; k++) wreg(4'(k), regs[k]);
    wreg(4'd6, 8'd0);                      // the DMA, as lethal's vblank write
    @(posedge dma_bsy); @(negedge dma_bsy);
    // let a whole frame go by, then log the next one
    @(posedge clk); while (!(vdump == 9'h10f && hdump == 9'h020 && pxl_cen)) @(posedge clk);
    @(posedge clk); while (!(vdump == 9'h10f && hdump == 9'h020 && pxl_cen)) @(posedge clk);
    fo = $fopen(outf, "w");
    logging = 1;
    wait (logged == 224);
    $fclose(fo);
    $display("DONE");
    $finish;
end

endmodule
