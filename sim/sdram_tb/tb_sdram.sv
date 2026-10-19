// SPDX-License-Identifier: GPL-3.0-or-later
//
// lethal_sdram with Micron's MT48LC16M16A2 model (Icarus): scripts/check_sdram.py
// writes a download as "address byte" lines and a list of reads as "port address"
// lines, runs this, and checks the data against MAME's regions.
//   ports: 0 main (byte), 1 tile row, 2 sprite word, 3 sample granule

`timescale 1ns/1ps

module tb_sdram;

parameter SHIFTED = 0;             // 1: the chip's clock lags 5555 ps, as SDRAM_CLK on the board

reg clk = 0;
always #10.4167 clk = ~clk;
reg rst = 1;
wire clk_chip;
assign #(SHIFTED ? 5.555 : 0) clk_chip = clk;

reg         dl_active = 0, dl_wr = 0;
reg  [24:0] dl_addr;
reg  [7:0]  dl_data;
wire        dl_wait, init, snd_we;
reg  [17:0] main_addr = 0;  reg main_cs = 0;  wire main_ok;  wire [7:0]  main_data;
reg  [18:0] tile_addr = 0;  reg tile_cs = 0;  wire tile_ok;  wire [63:0] tile_data;
reg  [20:2] obj_addr  = 0;  reg obj_cs  = 0;  wire obj_ok;   wire [47:0] obj_data;
reg  [20:3] smp_addr  = 0;  reg smp_cs  = 0;  wire smp_ok;   wire [63:0] smp_data;

wire [15:0] dq;
wire [12:0] a;
wire [1:0]  ba;
wire        dqml, dqmh, nwe, ncas, nras, ncs, cke;

lethal_sdram #(.SHIFTED(SHIFTED)) dut (
    .rst(rst), .clk(clk), .init(init),
    .dl_active(dl_active), .dl_wr(dl_wr), .dl_addr(dl_addr), .dl_data(dl_data), .dl_wait(dl_wait), .dl_end(),
    .snd_we(snd_we), .snd_addr(), .snd_data(),
    .rfsh(1'b0),
    .main_addr(main_addr), .main_cs(main_cs), .main_ok(main_ok), .main_data(main_data),
    .tile_addr(tile_addr), .tile_cs(tile_cs), .tile_ok(tile_ok), .tile_data(tile_data),
    .obj_addr(obj_addr), .obj_cs(obj_cs), .obj_ok(obj_ok), .obj_data(obj_data),
    .smp_addr(smp_addr), .smp_cs(smp_cs), .smp_ok(smp_ok), .smp_data(smp_data),
    .sdram_dq(dq), .sdram_a(a), .sdram_dqml(dqml), .sdram_dqmh(dqmh), .sdram_ba(ba),
    .sdram_nwe(nwe), .sdram_ncas(ncas), .sdram_nras(nras), .sdram_ncs(ncs), .sdram_cke(cke)
);

mt48lc16m16a2 sdram (
    .Clk(clk_chip), .Cke(cke), .Cs_n(ncs), .Ras_n(nras), .Cas_n(ncas), .We_n(nwe),
    .Addr(a), .Ba(ba), .Dq(dq), .Dqm({dqmh, dqml})
);

// a stalled port or download ends the run rather than hanging it
initial begin #50ms; $display("TIMEOUT"); $finish; end

string fdl, frd, fout;
integer f, fo, k, port, addr, v, n;
initial begin
    if (!$value$plusargs("dl=%s", fdl) || !$value$plusargs("rd=%s", frd) || !$value$plusargs("out=%s", fout)) begin
        $display("need +dl= +rd= +out="); $finish;
    end
    repeat (20) @(posedge clk);
    rst = 0;
    wait (init == 0);
    repeat (10) @(posedge clk);
    dl_active = 1;
    f = $fopen(fdl, "r"); n = 0;
    while ($fscanf(f, "%h %h\n", addr, v) == 2) begin
        @(posedge clk); while (dl_wait) @(posedge clk);
        dl_wr <= 1; dl_addr <= addr; dl_data <= v;
        @(posedge clk); dl_wr <= 0;
        n = n + 1;
        if (n % 4096 == 0) $display("downloaded %0d", n);
    end
    $fclose(f);
    // end the download the clock after the last byte, as gx_rom_loader does: the
    // last pair must still be written and dl_wait must fall
    @(posedge clk); dl_active = 0;
    k = 0;
    while (dl_wait && k < 1000) begin @(posedge clk); k = k + 1; end
    if (dl_wait) begin $display("DL_WAIT STUCK"); $finish; end
    repeat (20) @(posedge clk);
    $display("DOWNLOADED %0d bytes", n);
    repeat (20) @(posedge clk);
    f  = $fopen(frd, "r");
    fo = $fopen(fout, "w");
    while ($fscanf(f, "%d %h\n", port, addr) == 2) begin
        case (port)
        0: begin @(posedge clk); main_addr <= addr; main_cs <= 1;
                 @(posedge clk); while (!main_ok) @(posedge clk);
                 $fwrite(fo, "0 %x %02x\n", addr, main_data); main_cs <= 0; end
        1: begin @(posedge clk); tile_addr <= addr; tile_cs <= 1;
                 @(posedge clk); while (!tile_ok) @(posedge clk);
                 $fwrite(fo, "1 %x %016x\n", addr, tile_data); tile_cs <= 0; end
        2: begin @(posedge clk); obj_addr <= addr; obj_cs <= 1;
                 @(posedge clk); while (!obj_ok) @(posedge clk);
                 $fwrite(fo, "2 %x %012x\n", addr, obj_data); obj_cs <= 0; end
        3: begin @(posedge clk); smp_addr <= addr; smp_cs <= 1;
                 @(posedge clk); while (!smp_ok) @(posedge clk);
                 $fwrite(fo, "3 %x %016x\n", addr, smp_data); smp_cs <= 0; end
        endcase
        repeat (4) @(posedge clk);
    end
    $fclose(f); $fclose(fo);
    $display("READ DONE");
    $finish;
end

endmodule
