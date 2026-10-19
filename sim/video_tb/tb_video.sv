// SPDX-License-Identifier: GPL-3.0-or-later
//
// lethal_video, the whole video top, on a MAME capture: scripts/check_video.py
// writes the inputs, runs this, and compares the frame with MAME's screenshot.
//
//   +vram= +regs= +tiles=      as sim/tilemap_tb (VRAM writes, 054156 words, tile rows)
//   +ram= +oregs= +sprites=    as sim/obj_tb (053245 bytes, 053244 registers, sprite words)
//   +pal=                      the 16 KB palette, a byte a line
//   +pcu=                      PCU1, PCU2, PCU3
//   +orient=<0|1|2>            0 none, 1 flip Y (US/EU sets), 2 flip X (lethalenj)
//   +romlat=<n>                clocks from a ROM request to its data, both ROMs
//   +out=<file>                the visible frame in display order, "rrggbb" a pixel
//   +dx=<n>                    lethal_video OBJ_DX override is a parameter: -GOBJ_DX=

`timescale 1ns/1ps

module tb_video;

parameter [9:0] OBJ_DX = 10'd105;

reg clk = 0;
always #10.4167 clk = ~clk;
reg rst = 1;
reg [2:0] c8 = 0;
always @(posedge clk) c8 <= c8 + 3'd1;
wire ce_pix = c8 == 3'd7;
wire ce_2x  = c8[1:0] == 2'd3;

reg  orient_fx = 0, orient_fy = 0;
reg         tm_reg_we = 0, vram_we = 0, objram_we = 0, objreg_we = 0, pal_we = 0;
reg  [5:0]  tm_reg_addr;
reg  [7:0]  tm_reg_din, vram_din, objram_din, objreg_din, pal_din;
reg  [12:0] vram_addr;
reg  [10:0] objram_addr;
reg  [3:0]  objreg_addr;
reg  [13:0] pal_addr;
reg  [7:0]  pcu [3];
wire [7:0]  vram_dout, objram_dout, pal_dout;
wire [18:0] tile_addr;
wire [20:2] obj_addr;
wire        tile_cs, obj_cs, hblank, vblank, hsync, vsync, vblank_irq, unsup;
reg         tile_ok = 0, obj_ok = 0;
reg  [63:0] tile_data;
reg  [47:0] obj_data;
wire [23:0] rgb;
wire [15:0] lost;

lethal_video #(.OBJ_DX(OBJ_DX)) dut (
    .rst(rst), .clk(clk), .ce_pix(ce_pix), .ce_2x(ce_2x),
    .orient_flipx(orient_fx), .orient_flipy(orient_fy), .osd_flip(1'b0), .layer_en(5'h1f),
    .tm_reg_we(tm_reg_we), .tm_reg_addr(tm_reg_addr), .tm_reg_din(tm_reg_din),
    .vram_we(vram_we), .vram_rd(1'b0), .vram_addr(vram_addr), .vram_din(vram_din), .vram_dout(vram_dout),
    .objram_we(objram_we), .objram_addr(objram_addr), .objram_din(objram_din), .objram_dout(objram_dout),
    .objreg_we(objreg_we), .objreg_addr(objreg_addr), .objreg_din(objreg_din),
    .pal_we(pal_we), .pal_addr(pal_addr), .pal_din(pal_din), .pal_dout(pal_dout),
    .pcu1(pcu[0]), .pcu2(pcu[1]), .pcu3(pcu[2]),
    .tile_addr(tile_addr), .tile_cs(tile_cs), .tile_ok(tile_ok), .tile_data(tile_data),
    .obj_addr(obj_addr), .obj_cs(obj_cs), .obj_ok(obj_ok), .obj_data(obj_data),
    .rgb(rgb), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync),
    .vblank_irq(vblank_irq), .tile_unsupported(unsup), .tile_lost(lost)
);

// ROMs: tiles answer rom_ok for a clock after the latency (lethal_tilemap's handshake),
// sprites hold rom_ok while the address is unchanged (jtframe's)
reg [63:0] trom [0:(1<<19)-1];
reg [47:0] orom [0:(1<<19)-1];
integer romlat = 3, tlat = 0, olat = 0;
reg [20:2] olast;
always @(posedge clk) begin
    tile_ok <= 0;
    if (tile_cs && !tile_ok) begin
        if (tlat >= romlat) begin tile_data <= trom[tile_addr]; tile_ok <= 1; tlat <= 0; end
        else tlat <= tlat + 1;
    end else tlat <= 0;
    olast <= obj_addr;
    if (!obj_cs || obj_addr != olast) olat <= 0; else if (olat < romlat) olat <= olat + 1;
    obj_data <= orom[obj_addr];
end
always @* obj_ok = obj_cs && obj_addr == olast && olat >= romlat;

task automatic w_tm(input [5:0] a, input [7:0] d);
    @(posedge clk); tm_reg_we <= 1; tm_reg_addr <= a; tm_reg_din <= d; @(posedge clk); tm_reg_we <= 0;
endtask
task automatic w_or(input [3:0] a, input [7:0] d);
    @(posedge clk); objreg_we <= 1; objreg_addr <= a; objreg_din <= d; @(posedge clk); objreg_we <= 0;
endtask

string f_vram, f_regs, f_tiles, f_ram, f_oregs, f_spr, f_pal, f_pcu, f_out;
integer f, fo, k, v, n, page, plane, tile, data, orient, x, y;
reg [15:0] regw [32];
reg [7:0]  oregs [16];
reg logging = 0;
integer nlog = 0;

// log the visible pixels of one frame, in display order
always @(posedge clk) if (logging && ce_pix && !hblank && !vblank && nlog < 224*288) begin
    $fwrite(fo, "%06x\n", rgb);
    nlog <= nlog + 1;
end

initial begin
    if (!$value$plusargs("vram=%s", f_vram) || !$value$plusargs("regs=%s", f_regs) ||
        !$value$plusargs("tiles=%s", f_tiles) || !$value$plusargs("ram=%s", f_ram) ||
        !$value$plusargs("oregs=%s", f_oregs) || !$value$plusargs("sprites=%s", f_spr) ||
        !$value$plusargs("pal=%s", f_pal) || !$value$plusargs("pcu=%s", f_pcu) ||
        !$value$plusargs("out=%s", f_out)) begin
        $display("missing plusargs"); $finish;
    end
    void'($value$plusargs("romlat=%d", romlat));
    orient = 1; void'($value$plusargs("orient=%d", orient));
    orient_fy = orient == 1; orient_fx = orient == 2;
    $readmemh(f_tiles, trom);
    $readmemh(f_spr, orom);
    f = $fopen(f_pcu, "r"); for (k = 0; k < 3; k++) begin void'($fscanf(f, "%h\n", v)); pcu[k] = 8'(v); end $fclose(f);
    f = $fopen(f_regs, "r"); for (k = 0; k < 32; k++) void'($fscanf(f, "%h\n", regw[k])); $fclose(f);
    f = $fopen(f_oregs, "r"); for (k = 0; k < 16; k++) begin void'($fscanf(f, "%h\n", v)); oregs[k] = 8'(v); end $fclose(f);
    repeat (10) @(posedge clk);
    rst = 0;
    // VRAM, page by page, through the 054156's page select
    f = $fopen(f_vram, "r"); page = -1;
    while ($fscanf(f, "%d %d %d %h\n", n, plane, tile, data) == 4) begin
        if (n != page) begin
            page = n;
            if (page == 16) w_tm(6'd1, 8'h02);
            else begin w_tm(6'd1, 8'h00); w_tm(6'd51, 8'(((page >> 2) << 3) | (page & 3))); end
        end
        @(posedge clk); vram_we <= 1; vram_addr <= { 2'(plane), 11'(tile) }; vram_din <= 8'(data);
        @(posedge clk); vram_we <= 0;
    end
    $fclose(f);
    for (k = 0; k < 32; k++) begin w_tm(6'({k[4:0], 1'b0}), regw[k][15:8]); w_tm(6'({k[4:0], 1'b1}), regw[k][7:0]); end
    f = $fopen(f_ram, "r");
    for (k = 0; k < 2048; k++) begin
        void'($fscanf(f, "%h\n", v));
        @(posedge clk); objram_we <= 1; objram_addr <= 11'(k); objram_din <= 8'(v); @(posedge clk); objram_we <= 0;
    end
    $fclose(f);
    f = $fopen(f_pal, "r");
    for (k = 0; k < 16384; k++) begin
        void'($fscanf(f, "%h\n", v));
        @(posedge clk); pal_we <= 1; pal_addr <= 14'(k); pal_din <= 8'(v); @(posedge clk); pal_we <= 0;
    end
    $fclose(f);
    for (k = 0; k < 6; k++) w_or(4'(k), oregs[k]);
    w_or(4'd6, 8'd0);
    // two whole frames, then log the third from its first visible pixel
    repeat (2) @(posedge vblank_irq);
    @(posedge vblank_irq);
    @(posedge clk); while (!(vblank == 0 && hblank == 0 && ce_pix)) @(posedge clk);
    fo = $fopen(f_out, "w");
    logging = 1;
    wait (nlog == 224 * 288);
    $fclose(fo);
    $display("FRAME logged, unsupported %0d lost %0d", unsup, lost);
    $finish;
end

endmodule
