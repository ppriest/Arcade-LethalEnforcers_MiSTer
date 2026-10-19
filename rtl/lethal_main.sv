// SPDX-License-Identifier: GPL-3.0-or-later
//
// Lethal Enforcers' main CPU board: the HD63C09E run as a 6809 (mc6809i in
// jtframe_sys6809, docs/HARDWARE_NOTES.md "CPUs and chips"), lethal.cpp's main_map
// and bank4000_map, the ER5911 EEPROM, the 054000 and the 054321's main side.
//
// main_map (lethal.cpp line 531):
//   0000-1fff  program ROM, 8 KB banks (0x40dc)    2000-3fff  work RAM
//   4000-403f  054156 registers (write)             4040-404f  054157 (write, unused)
//   4080       watchdog (read)                      4090       sound IRQ (read or write)
//   40c4       control: EEPROM DI/CS/CLK, CBNK      40c8/cc/d0 PCU1-3
//   40d4-40d7  guns                                 40d8       DSW, EEPROM DO and ready
//   40d9       inputs                               40db       gun X low bits
//   40dc       ROM bank                             8000-ffff  ROM 0x38000-0x3ffff
//   4000-43ff  otherwise unmapped; 4400-7fff the bank4000 window:
//   CBNK = 0:  4840-484f 053244, 4880-489f 054000, 48c0-48cf 054321, 5000-57ff 053245,
//              6000-7fff 054156 VRAM (2 KB planes: code lo, code hi, attr lo, attr hi)
//   CBNK = 1:  4400-7fff palette RAM, byte (address - 0x4000)
// Unmapped reads return 0, as MAME's.
//
// The CPU runs on cen (12 MHz; jtframe_sys6809 divides it by four to the 3 MHz E)
// gated by pause. ROM comes from rom_* (the SDRAM path), which the wrapper waits
// for, catching the lost cycles up (docs/ROADMAP.md, "Memory plan").

module lethal_main (
    input               rst,
    input               clk,
    input               cen,            // 12 MHz
    input               pause,

    // program ROM: byte address in the 256 KB image
    output       [17:0] rom_addr,
    output              rom_cs,
    input               rom_ok,
    input         [7:0] rom_data,

    // video
    input               vblank_irq,     // one clock at vblank start
    output reg          tm_reg_we,
    output        [5:0] tm_reg_addr,
    output        [7:0] cpu_dout,
    output              vram_we,
    output              vram_rd,
    output       [12:0] vram_addr,
    input         [7:0] vram_dout,
    output              objram_we,
    output       [10:0] objram_addr,
    input         [7:0] objram_dout,
    output              objreg_we,
    output        [3:0] objreg_addr,
    output              pal_we,
    output       [13:0] pal_addr,
    input         [7:0] pal_dout,
    output reg    [7:0] pcu1, pcu2, pcu3,

    // sound: 054321 main side, sound IRQ
    output              snd_on,         // the Z80's IRQ (jt054321 snd_on)
    output        [3:0] snd_addr,
    output              snd_we,
    input         [7:0] snd_dout,

    // inputs, active low as the board reads them
    input         [7:0] inputs,         // 0x40d9: coin 1, coin 2, service, test, trigger 1, 2, start 1, 2
    input         [3:0] dsw,            // 0x40d8 bits 7-4: sound output, coin mechanism, game type, language
    input         [7:0] gun [4],        // 0x40d4-0x40d7: P1 X >> 1, P1 Y, P2 X >> 1, P2 Y
    input         [1:0] gun_xlsb,       // 0x40db bits 7, 6: P1, P2 X bit 0

    // EEPROM image (128 bytes), loaded and saved by the top level
    input               nv_we,
    input         [6:0] nv_addr,
    input         [7:0] nv_din,
    output        [7:0] nv_dout,
    output              nv_changed,
    input               nv_clr,

    // work RAM's second port (0x2000-0x3fff as 0-0x1fff), for hiscore: data the clock after
    input        [12:0] hs_addr,
    input               hs_we,
    input         [7:0] hs_din,
    output        [7:0] hs_dout
);

// ---------------------------------------------------------------- CPU
wire [15:0] A;
wire        RnW, VMA, cpu_cen;
wire [ 7:0] ram_dout;
reg  [ 7:0] cpu_din;
reg         irq_hold;
wire        irq_ack;

wire ram_cs   = A[15:13] == 3'b001;
assign rom_cs = (A[15] | A[15:13] == 3'b000) && !rst;
reg  [4:0]  rbank;
assign rom_addr = A[15] ? {3'b111, A[14:0]} : {rbank, A[12:0]};

// jtframe_sys6809_dma, not jtframe_sys6809: the same CPU and RAM, with the RAM's second
// port brought out (hiscore). jtframe_sys6809 ties that port's clock to 0, and Quartus 17
// then builds the 8 KB RAM from registers.
jtframe_sys6809_dma #(.RAM_AW(13), .RECOVERY(1)) u_cpu (
    .rstn       ( ~rst          ),
    .clk        ( clk           ),
    .cen        ( cen & ~pause  ),
    .cpu_cen    ( cpu_cen       ),
    .nIRQ       ( ~irq_hold     ),
    .nFIRQ      ( 1'b1          ),
    .nNMI       ( 1'b1          ),
    .irq_ack    ( irq_ack       ),
    .bus_busy   ( 1'b0          ),
    .A          ( A             ),
    .RnW        ( RnW           ),
    .VMA        ( VMA           ),
    .ram_cs     ( ram_cs        ),
    .rom_cs     ( rom_cs        ),
    .rom_ok     ( rom_ok        ),
    .ram_dout   ( ram_dout      ),
    .cpu_dout   ( cpu_dout      ),
    .cpu_din    ( cpu_din       ),
    .breq_n     ( 1'b1          ),
    .bg         (               ),
    .dma_clk    ( clk           ),
    .dma_we     ( hs_we         ),
    .dma_addr   ( hs_addr       ),
    .dma_din    ( hs_din        ),
    .dma_dout   ( hs_dout       )
);

wire cen_Q = cpu_cen;                         // jtframe_sys6809's cen_Q: a write is taken there, as its RAM does
wire wr    = VMA && !RnW && cen_Q;
wire rd_go = VMA &&  RnW && cen_Q;            // one pulse per read cycle

// ---------------------------------------------------------------- decode
reg        cbnk;
wire       fixed   = A[15:8] == 8'h40 && A[7:0] < 8'he0;    // 0x4000-0x40df
wire       lowhole = A[15:10] == 6'b0100_00 && !fixed;       // rest of 0x4000-0x43ff
wire       win     = A[15:14] == 2'b01 && !fixed && !lowhole;  // 0x4400-0x7fff
wire [13:0] baddr  = A[13:0];                                // bank4000 offset, CBNK = 0

wire tm_reg_cs  = A[15:6] == 10'b0100_0000_00;              // 4000-403f
wire objreg_cs  = win && !cbnk && baddr[13:4] == 10'h084;   // 4840-484f
wire k54k_cs    = win && !cbnk && baddr[13:5] == 9'h044;    // 4880-489f
wire snd_cs     = win && !cbnk && baddr[13:4] == 10'h08c;   // 48c0-48cf
wire objram_cs  = win && !cbnk && baddr[13:11] == 3'b010;   // 5000-57ff
wire vram_cs    = win && !cbnk && baddr[13] == 1'b1;        // 6000-7fff
wire pal_cs     = win &&  cbnk;

assign tm_reg_addr = A[5:0];
assign vram_we     = vram_cs && wr;
assign vram_rd     = vram_cs && rd_go;
assign vram_addr   = { A[12:11], A[10:0] };
assign objram_we   = objram_cs && wr;
assign objram_addr = A[10:0];
assign objreg_we   = objreg_cs && wr;
assign objreg_addr = A[3:0];
assign pal_we      = pal_cs && wr;
assign pal_addr    = A[13:0];        // the palette share's byte offset, A - 0x4000
assign snd_addr    = A[3:0];
assign snd_we      = snd_cs && wr;
assign snd_on      = (A == 16'h4090) && cen_Q && VMA;

// ---------------------------------------------------------------- registers
reg  [7:0] control2;
reg        irq_en;
always @(posedge clk) begin
    tm_reg_we <= 1'b0;
    if (rst) begin
        rbank <= 5'd0; cbnk <= 1'b0; control2 <= 8'd0; irq_en <= 1'b0;
        pcu1 <= 8'd0; pcu2 <= 8'd0; pcu3 <= 8'd0;
    end else if (wr) begin
        if (tm_reg_cs) begin
            tm_reg_we <= 1'b1;
            if (A[5:0] == 6'h07) irq_en <= cpu_dout[0];      // 054156 word 3 bit 0 (is_irq_enabled)
        end
        case (A)
            16'h40c4: begin control2 <= cpu_dout; cbnk <= cpu_dout[4]; end
            16'h40c8: pcu1  <= cpu_dout;
            16'h40cc: pcu2  <= cpu_dout;
            16'h40d0: pcu3  <= cpu_dout;
            16'h40dc: rbank <= cpu_dout[4:0];
            default: ;
        endcase
    end
end

// vblank IRQ, HOLD_LINE: held until the CPU takes it (lethal.cpp line 477)
always @(posedge clk) begin
    if (rst) irq_hold <= 1'b0;
    else if (vblank_irq && irq_en) irq_hold <= 1'b1;
    else if (irq_ack) irq_hold <= 1'b0;
end

// ---------------------------------------------------------------- EEPROM
wire       ee_do, ee_rdy;
wire [6:0] ee_addr;
wire [7:0] ee_din;
wire       ee_we;
reg  [7:0] ee_ram [0:127];
reg  [7:0] ee_q, nv_q;
always @(posedge clk) begin
    if (ee_we) ee_ram[ee_addr] <= ee_din;
    else if (nv_we) ee_ram[nv_addr] <= nv_din;
    ee_q <= ee_ram[ee_addr];
    nv_q <= ee_ram[nv_addr];
end
assign nv_dout = nv_q;

jt5911 #(.PROG(0)) u_eeprom (
    .rst        ( rst           ),
    .clk        ( clk           ),
    .sclk       ( control2[2]   ),
    .sdi        ( control2[0]   ),
    .sdo        ( ee_do         ),
    .rdy        ( ee_rdy        ),
    .scs        ( control2[1]   ),
    .mem_addr   ( ee_addr       ),
    .mem_din    ( ee_din        ),
    .mem_we     ( ee_we         ),
    .mem_dout   ( ee_q          ),
    .dump_clr   ( nv_clr        ),
    .dump_flag  ( nv_changed    )
);

// ---------------------------------------------------------------- 054000
wire [7:0] k54k_dout;
jtk054000 u_054000 (
    .rst    ( rst           ),
    .clk    ( clk           ),
    .cs     ( k54k_cs       ),
    .addr   ( A[4:0]        ),
    .we     ( wr            ),
    .din    ( cpu_dout      ),
    .dout   ( k54k_dout     )
);

// ---------------------------------------------------------------- read mux
always @* begin
    cpu_din = 8'h00;
    if (ram_cs)                 cpu_din = ram_dout;
    else if (rom_cs)            cpu_din = rom_data;
    else if (fixed) case (A)
        16'h40d4: cpu_din = gun[0];
        16'h40d5: cpu_din = gun[1];
        16'h40d6: cpu_din = gun[2];
        16'h40d7: cpu_din = gun[3];
        16'h40d8: cpu_din = { dsw, 2'b11, ee_rdy, ee_do };
        16'h40d9: cpu_din = inputs;
        16'h40db: cpu_din = { gun_xlsb, 6'd0 };
        default:  cpu_din = 8'h00;
    endcase
    else if (objram_cs)         cpu_din = objram_dout;
    else if (vram_cs)           cpu_din = vram_dout;
    else if (pal_cs)            cpu_din = pal_dout;
    else if (k54k_cs)           cpu_din = k54k_dout;
    else if (snd_cs)            cpu_din = snd_dout;
end

endmodule
