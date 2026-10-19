// SPDX-License-Identifier: GPL-3.0-or-later
//
// lethal_k539 alone, driven by MAME's register writes: scripts/check_k539.py.
//
//   +smp=<hex>      the 2 MB sample ROM, an 8-byte granule a line, byte 0 lowest
//   +writes=<file>  "W <sample> <reg> <data>", "R <sample> 22d 00" (a read of 0x22d moves
//                   the RAM pointer; scripts/mame/k539_writes.lua): MAME's
//                   write at time t, with <sample> = floor(t * 48000)
//   +phase=<n>      a write logged at sample s is applied before sample s + n starts
//   +out=<file>     "left right" each 48 kHz sample
//   +n=<samples>    how many samples to run
// "V <sample> <active> <volume>" lines set the 054321 as MAME had it at that frame.

`timescale 1ns/1ps

module tb_k539;

reg clk = 0;
always #10.4167 clk = ~clk;
reg rst = 1;

reg         cs = 0, we = 0;
reg  [10:0] addr;
reg  [7:0]  din;
wire        ack;
reg         vol_we = 0;
reg  [3:0]  vol_addr;
reg  [7:0]  vol_din;
wire [17:0] smp_addr;
wire        smp_cs, smp;
reg         smp_ok = 0;
reg  [63:0] smp_data;
wire signed [15:0] left, right;

lethal_k539 dut (
    .clk(clk), .rst(rst),
    .cs(cs), .we(we), .addr(addr), .din(din), .dout(), .ack(ack), .timer_out(),
    .vol_we(vol_we), .vol_addr(vol_addr), .vol_din(vol_din),
    .smp_addr(smp_addr), .smp_cs(smp_cs), .smp_ok(smp_ok), .smp_data(smp_data),
    .smp(smp), .left(left), .right(right), .ovr()
);

// the sample ROM, a few clocks a granule
reg [63:0] srom [0:262143];
integer slat = 0;
always @(posedge clk) begin
    smp_ok <= 0;
    if (smp_cs && !smp_ok) begin
        if (slat >= 7) begin smp_data <= srom[smp_addr]; smp_ok <= 1; slat <= 0; end
        else slat <= slat + 1;
    end else slat <= 0;
end

// samples, and clocks since the last strobe
integer smp_n = 0, since = 0;
always @(posedge clk) begin
    if (smp) begin smp_n <= smp_n + 1; since <= 0; end
    else since <= since + 1;
end

integer fo = 0;
// +rvlog=<file>: each reverb word write "<sample> <word> <data>" (debugging)
integer frv = 0;
always @(posedge clk) if (frv != 0 && dut.r_req) $fwrite(frv, "%0d %0d %0d\n", smp_n, dut.r_word, $signed(dut.r_data));
always @(posedge clk) if (fo != 0 && smp) $fwrite(fo, "%0d %0d\n", left, right);

task automatic wr(input [10:0] a, input [7:0] d);
    begin
        @(posedge clk); cs <= 1; we <= 1; addr <= a; din <= d;
        @(posedge clk); cs <= 0;
        while (!ack) @(posedge clk);
    end
endtask

task automatic rd(input [10:0] a);
    begin
        @(posedge clk); cs <= 1; we <= 0; addr <= a;
        @(posedge clk); cs <= 0;
        while (!ack) @(posedge clk);
    end
endtask

task automatic vol(input [3:0] a, input [7:0] d);
    begin
        @(posedge clk); vol_we <= 1; vol_addr <= a; vol_din <= d;
        @(posedge clk); vol_we <= 0;
    end
endtask

string f_smp, f_wr, f_out, tag, f_rv;
integer f, k, s, r, d, phase = 1, n = 0;
initial begin
    if (!$value$plusargs("smp=%s", f_smp) || !$value$plusargs("writes=%s", f_wr) ||
        !$value$plusargs("out=%s", f_out) || !$value$plusargs("n=%d", n)) begin
        $display("need +smp= +writes= +out= +n="); $finish;
    end
    void'($value$plusargs("phase=%d", phase));
    if ($value$plusargs("rvlog=%s", f_rv)) frv = $fopen(f_rv, "w");
    $readmemh(f_smp, srom);
    repeat (10) @(posedge clk);
    rst = 0;
    fo = $fopen(f_out, "w");
    f = $fopen(f_wr, "r");
    while ($fscanf(f, "%s %d %h %h\n", tag, s, r, d) == 4) begin
        if (tag == "V") begin              // the 054321 as MAME had it at that frame
            while (smp_n < s) @(posedge clk);
            vol(4'd2, 8'd0);
            for (k = 0; k < 32'(d); k++) vol(4'd3, 8'd1);
            vol(4'd0, 8'(r));
            continue;
        end
        if (tag != "W" && tag != "R") continue;
        // before sample s + phase starts: during sample s + phase - 1, after its work
        while (smp_n < s + phase - 1 || (smp_n == s + phase - 1 && since < 700)) @(posedge clk);
        if (smp_n > s + phase - 1) $display("late write at sample %0d (wanted before %0d)", smp_n, s + phase);
        if (tag == "W") wr(11'(r), 8'(d));
        else            rd(11'(r));
    end
    $fclose(f);
    while (smp_n < n) @(posedge clk);
    $fclose(fo);
    if (frv != 0) $fclose(frv);
    $display("DONE %0d samples", smp_n);
    $finish;
end

endmodule
