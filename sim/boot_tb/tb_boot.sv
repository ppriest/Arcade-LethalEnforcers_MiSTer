// SPDX-License-Identifier: GPL-3.0-or-later
//
// Phase 0 boot bench: mc6809i in jtframe_sys6809, against MAME's boot trace.
//
//   +rom=<hex>      the 256 KB program, one byte per line ($readmemh)
//   +replay=<file>  MAME's I/O reads, in order (compare_boot_trace.py replay)
//   +out=<file>     this CPU's bus trace, MAME's format (seq rw addr mask data)
//   +n=<count>      accesses to log before stopping
//   +romlat=<clks>  clocks from a ROM address to rom_ok (0: the same clock)
//   +irq=1          take the vblank IRQ (lethal.cpp vblank(), line 477)
//
// Lethal's main map (lethal.cpp main_map): ROM bank 0x0000-0x1fff (8 KB pages,
// bank register 0x40dc), work RAM 0x2000-0x3fff, I/O and the bank4000 window
// 0x4000-0x7fff, ROM 0x8000-0xffff = program 0x38000-0x3ffff. Every read that is
// neither ROM nor RAM is answered from the replay file, so the bench needs no
// peripherals.
//
// IRQ: vblank starts at line 240 of 262, 384 pixels a line at 6 MHz, so every
// 262*384*8 = 804864 clocks at 48 MHz, the first 240*384*8 = 737280 clocks
// after reset (MAME's screen starts at line 0 at time 0). It is raised when
// the 054156's IRQ enable (word 3 bit 0, written at 0x4007) is set, and held
// until the CPU fetches the vector: MAME's HOLD_LINE.
//
// A bus cycle is the span between two cen_E pulses: the address is taken at
// cen_Q, data at the next cen_E, which is when mc6809i latches a read. Cycles
// with VMA low (the 6809's dummy cycles) are not logged.

`timescale 1ns/1ps

module tb_boot;

reg clk = 0;
always #10.4167 clk = ~clk;     // 48 MHz

reg  rstn = 0;
reg  [1:0] cendiv = 0;
wire cen = cendiv == 2'd3;      // 12 MHz: jtframe_sys6809 divides by 4 to the 3 MHz E
always @(posedge clk) cendiv <= cendiv + 2'd1;

wire [15:0] A;
wire        RnW, VMA, cpu_cen;
wire [ 7:0] ram_dout, cpu_dout;
reg  [ 7:0] cpu_din;
reg  [ 4:0] rbank = 0;
reg         irq_en = 0, irq_hold = 0;
wire        irq_ack;

wire ram_cs = A[15:13] == 3'b001;
wire rom_cs = A[15] | (A[15:13] == 3'b000);
reg  rom_ok;

jtframe_sys6809 #(.RAM_AW(13), .RECOVERY(1)) u_sys(
    .rstn       ( rstn      ),
    .clk        ( clk       ),
    .cen        ( cen       ),
    .cpu_cen    ( cpu_cen   ),
    .nIRQ       ( ~irq_hold ),
    .nFIRQ      ( 1'b1      ),
    .nNMI       ( 1'b1      ),
    .irq_ack    ( irq_ack   ),
    .bus_busy   ( 1'b0      ),
    .A          ( A         ),
    .RnW        ( RnW       ),
    .VMA        ( VMA       ),
    .ram_cs     ( ram_cs    ),
    .rom_cs     ( rom_cs    ),
    .rom_ok     ( rom_ok    ),
    .ram_dout   ( ram_dout  ),
    .cpu_dout   ( cpu_dout  ),
    .cpu_din    ( cpu_din   )
);

wire cen_E = u_sys.u_sys6809.cen_E;
wire cen_Q = u_sys.u_sys6809.cen_Q;
wire op    = u_sys.u_sys6809.OP;

// ---- vblank IRQ
integer irq_on = 0;
integer vcnt = 804864 - 737280;
longint nirqs = 0;
always @(posedge clk) if( rstn ) begin
    vcnt <= vcnt == 804864 - 1 ? 0 : vcnt + 1;
    if( vcnt == 804864 - 1 && irq_on != 0 && irq_en ) begin
        irq_hold <= 1;
        nirqs    <= nirqs + 1;
    end else if( irq_ack ) irq_hold <= 0;
end

// ---- program ROM with Lethal's banking
reg  [7:0] rom[0:'h3ffff];
wire [17:0] rom_a = A[15] ? {3'b111, A[14:0]} : {rbank, A[12:0]};

// ---- ROM latency: rom_ok rises ROMLAT clocks after the ROM address settles
integer romlat = 0, lat = 0;
reg [17:0] last_rom_a = 18'h3ffff;
always @(posedge clk) begin
    if( rom_a != last_rom_a || !rom_cs ) lat <= 0;
    else if( lat < romlat ) lat <= lat + 1;
    last_rom_a <= rom_a;
end
always @* rom_ok = romlat == 0 ? 1'b1 : (rom_a == last_rom_a && lat >= romlat);

// ---- I/O replay
integer frep, nrep = 0;
reg [7:0] io_data = 8'hff;
reg       io_valid = 0;
integer   ra, rm, rd, got;

// ---- trace
integer fout, nmax = 200000, seq = 0;
reg [15:0] cyc_a;
reg        cyc_rnw, cyc_vma, cyc_live = 0;

// ---- counters, from reset and from the game's first IRQ enable ("game")
longint clocks = 0, ecycles = 0, ops = 0, stall = 0;
longint g_clocks = 0, g_ecycles = 0, g_ops = 0, g_stall = 0;
reg     game = 0;

always @* begin
    cpu_din = ram_cs ? ram_dout : rom_cs ? rom[rom_a] : io_data;
end

always @(posedge clk) if( rstn ) begin
    clocks <= clocks + 1;
    if( rom_cs && !rom_ok ) stall <= stall + 1;
    if( irq_en ) game <= 1;
    if( game ) begin
        g_clocks <= g_clocks + 1;
        if( rom_cs && !rom_ok ) g_stall <= g_stall + 1;
        if( cen_E ) g_ecycles <= g_ecycles + 1;
        if( cen_E && op ) g_ops <= g_ops + 1;
    end
    if( cen_Q ) begin
        cyc_a    <= A;
        cyc_rnw  <= RnW;
        cyc_vma  <= VMA;
        cyc_live <= 1;
        // an I/O read takes the next replayed value now; it is latched at the next cen_E
        if( VMA && RnW && !ram_cs && !rom_cs ) begin
            got = $fscanf(frep, "%h %h %h\n", ra, rm, rd);
            if( got != 3 ) begin
                $display("replay exhausted after %0d reads, at %04X", nrep, A);
                io_data = 8'hff;
            end else begin
                if( ra[15:0] != A )
                    $display("I/O read %0d: CPU reads %04X, MAME read %04X", nrep + 1, A, ra[15:0]);
                io_data = rd[7:0];
            end
            nrep = nrep + 1;
        end
    end
    if( cen_E ) begin
        ecycles <= ecycles + 1;
        if( op ) ops <= ops + 1;
        if( cyc_live && cyc_vma ) begin
            seq = seq + 1;
            $fwrite(fout, "%0d\t%s\t%04X\tFF\t%02X\n", seq, cyc_rnw ? "r" : "w", cyc_a,
                    cyc_rnw ? cpu_din : cpu_dout);
            if( !cyc_rnw && cyc_a == 16'h40dc ) rbank <= cpu_dout[4:0];
            if( !cyc_rnw && cyc_a == 16'h4007 ) irq_en <= cpu_dout[0];
            if( seq >= nmax ) begin
                $fwrite(fout, "# %0d accesses logged\n", seq);
                $fclose(fout);
                $display("TRACE %0d accesses, %0d I/O reads replayed", seq, nrep);
                $display("CYCLES clocks=%0d E=%0d opcode-fetch E cycles=%0d rom-stall clocks=%0d romlat=%0d irqs=%0d",
                         clocks, ecycles, ops, stall, romlat, nirqs);
                $display("GAME   clocks=%0d E=%0d opcode-fetch E cycles=%0d rom-stall clocks=%0d",
                         g_clocks, g_ecycles, g_ops, g_stall);
                $finish;
            end
        end
    end
end

string romfile, repfile, outfile;
initial begin
    if( !$value$plusargs("rom=%s", romfile) ) begin $display("need +rom="); $finish; end
    if( !$value$plusargs("replay=%s", repfile) ) begin $display("need +replay="); $finish; end
    if( !$value$plusargs("out=%s", outfile) ) begin $display("need +out="); $finish; end
    void'($value$plusargs("n=%d", nmax));
    void'($value$plusargs("romlat=%d", romlat));
    void'($value$plusargs("irq=%d", irq_on));
    frep = $fopen(romfile, "r");
    if( frep == 0 ) begin $display("cannot open %s", romfile); $finish; end
    $fclose(frep);
    $readmemh(romfile, rom);
    frep = $fopen(repfile, "r");
    if( frep == 0 ) begin $display("cannot open %s", repfile); $finish; end
    fout = $fopen(outfile, "w");
    $fwrite(fout, "# mc6809i bus accesses from reset (tb_boot), romlat %0d\n# seq\trw\taddr\tmask\tdata\n", romlat);
    repeat (40) @(posedge clk);
    rstn = 1;
end

endmodule
