// SPDX-License-Identifier: GPL-3.0-or-later
//
// Lethal Enforcers' 054539 with what the board puts around it: its 32 KB RAM, its sample
// ROM in SDRAM, the 054321's volume, and the routing to the two speakers (lethal.cpp
// lines 718-725). lethal_sound connects it to the Z80; sim/k539_tb drives it from MAME's
// register writes.

module lethal_k539 (
    input               clk,                // 48 MHz
    input               rst,

    // the Z80 side: cs a one-clock pulse per access, ack when it is done
    input               cs,
    input               we,
    input        [10:0] addr,               // f800-fa2f -> 000-22f
    input         [7:0] din,
    output        [7:0] dout,
    output              ack,
    output              timer_out,

    // the 054321's main side, for its volume and enables
    input               vol_we,
    input         [3:0] vol_addr,
    input         [7:0] vol_din,

    // the sample ROM, SDRAM bank 3 (lethal_sdram's samples port)
    output       [17:0] smp_addr,
    output              smp_cs,
    input               smp_ok,
    input        [63:0] smp_data,

    output              smp,                // the 48 kHz sample strobe
    output reg signed [15:0] left,
    output reg signed [15:0] right,
    output       [15:0] ovr                 // the chip's late samples
);

// The chip's memories. Its 32 KB RAM is here in block RAM; its sample ROM is SDRAM bank 3
// (smp_*), a granule of 8 bytes at a time, byte k in bits 8k+7..8k.
//   m_*  the 0x22d port: a RAM byte, or a ROM byte (the granule fetched, then the byte)
//   p_*  the voices' and the reverb's granule reads: below ram_g0 (0x40000 for a 2 MB
//        region) the samples, from SDRAM; from ram_g0 up the RAM's words, 4 a granule
//   r_*  the reverb's word writes
reg        km_ack, r_ack;
reg        p_ok;
reg [63:0] p_data;
wire       km_req, km_we, km_ram, p_cs, r_req;
wire [21:0] km_addr;
wire [7:0]  km_wdata;
wire [20:0] p_addr;
wire [12:0] r_word;
wire [15:0] r_data;
// two byte lanes: byte address a is lane a[0] (even = low, MAME's little-endian
// int16_t view of the reverb words) at word a[14:1]. One write port, the chip's access
// first and a reverb write on a clock without one, so Quartus maps it to block RAM; one
// read port, the 0x22d access first and the reverb's granule reads on the other clocks.
reg  [7:0]  kram_lo [0:16383];
reg  [7:0]  kram_hi [0:16383];
reg  [7:0]  kq_lo, kq_hi;
reg  [1:0]  ksel;
reg         r_pend;
reg  [12:0] r_w;
reg  [15:0] r_d;
wire        km_rom = km_req && !km_ram && !km_we;    // a ROM byte: through SDRAM, below
wire        km_go  = km_req && !km_ack && !km_rom;
wire        kw_cpu = km_go && km_ram && km_we;
wire        kw_rv  = !km_go && r_pend;
wire [13:0] kw_a   = kw_cpu ? km_addr[14:1] : { 1'b0, r_w };
wire        kw_lo  = kw_cpu ? !km_addr[0] : kw_rv;
wire        kw_hi  = kw_cpu ?  km_addr[0] : kw_rv;
wire [7:0]  kw_dlo = kw_cpu ? km_wdata : r_d[7:0];
wire [7:0]  kw_dhi = kw_cpu ? km_wdata : r_d[15:8];
// the reverb's granule read: four words, one on each clock the 0x22d port leaves free
wire        p_ram  = p_addr >= 21'h40000;
reg         pr_busy, pr_rd, pr_done;
reg  [1:0]  pr_i, pr_il;
wire [13:0] k_ra   = km_go ? km_addr[14:1] : { 1'b0, p_addr[10:0], pr_i };
always @(posedge clk) begin
    if (kw_lo) kram_lo[kw_a] <= kw_dlo;
    if (kw_hi) kram_hi[kw_a] <= kw_dhi;
    kq_lo <= kram_lo[k_ra];
    kq_hi <= kram_hi[k_ra];
end

// one SDRAM client for the voices' samples and the 0x22d port's ROM byte
reg         kr_busy;
reg  [7:0]  kr_byte;
reg         s_cs, s_who;               // s_who: 1 the 0x22d port
reg  [17:0] s_addr;
wire [7:0]  km_rdata = kr_busy ? kr_byte : !ksel[1] ? 8'd0 : ksel[0] ? kq_hi : kq_lo;
always @(posedge clk) begin
    km_ack  <= 1'b0;
    r_ack   <= 1'b0;
    p_ok    <= 1'b0;
    ksel    <= { km_ram, km_addr[0] };
    if (r_req) begin r_pend <= 1'b1; r_w <= r_word; r_d <= r_data; end
    if (km_go) km_ack <= 1'b1;
    else if (r_pend) begin r_pend <= 1'b0; r_ack <= 1'b1; end

    // the reverb's granule
    pr_rd <= pr_busy && !km_go;
    pr_il <= pr_i;
    // not while the last word is still on its way (pr_rd): a second read would answer the
    // chip's next request with this one's words
    if (p_cs && p_ram && !pr_busy && !pr_rd && !pr_done && !p_ok) begin pr_busy <= 1'b1; pr_i <= 2'd0; end
    else if (pr_busy && !km_go) begin
        pr_i <= pr_i + 2'd1;
        if (pr_i == 2'd3) pr_busy <= 1'b0;
    end
    if (pr_rd) begin
        p_data[16 * pr_il +: 16] <= { kq_hi, kq_lo };
        if (pr_il == 2'd3) pr_done <= 1'b1;
    end
    if (pr_done) begin pr_done <= 1'b0; p_ok <= 1'b1; end

    // samples and the ROM byte through SDRAM
    if (!s_cs) begin
        if (km_rom && !kr_busy && !km_ack) begin
            s_cs <= 1'b1; s_who <= 1'b1; s_addr <= km_addr[20:3]; kr_busy <= 1'b1;
        end else if (p_cs && !p_ram && !p_ok) begin
            s_cs <= 1'b1; s_who <= 1'b0; s_addr <= p_addr[17:0];
        end
    end else if (smp_ok) begin
        s_cs <= 1'b0;
        if (s_who) begin kr_byte <= smp_data[8 * km_addr[2:0] +: 8]; km_ack <= 1'b1; end
        else       begin p_data <= smp_data; p_ok <= 1'b1; end
    end
    if (km_ack && kr_busy) kr_busy <= 1'b0;

    if (rst) begin
        r_pend <= 1'b0; pr_busy <= 1'b0; pr_done <= 1'b0; s_cs <= 1'b0; kr_busy <= 1'b0;
    end
end
assign smp_cs   = s_cs;
assign smp_addr = s_addr;

// 48 kHz sample strobe: 18.432 MHz / 384 in MAME, 48 MHz / 1000 here
reg [9:0] smp_cnt;
assign    smp = smp_cnt == 10'd999;
always @(posedge clk) smp_cnt <= smp ? 10'd0 : smp_cnt + 10'd1;

wire signed [25:0] out_l, out_r;
wire              out_v;
gx_k054539 u_539 (
    .clk        ( clk           ),
    .rst        ( rst           ),
    .cs         ( cs            ),
    .we         ( we            ),
    .addr       ( addr          ),
    .din        ( din           ),
    .dout       ( dout          ),
    .ack        ( ack           ),
    .timer_out  ( timer_out     ),
    .m_req      ( km_req         ),
    .m_we       ( km_we          ),
    .m_ram      ( km_ram         ),
    .m_addr     ( km_addr        ),
    .m_wdata    ( km_wdata       ),
    .m_ack      ( km_ack         ),
    .m_rdata    ( km_rdata       ),
    .smp        ( smp           ),
    .pcm_mask   ( 24'h1fffff    ),
    .p_cs       ( p_cs          ),
    .p_addr     ( p_addr        ),
    .p_ok       ( p_ok          ),
    .p_data     ( p_data        ),
    .out_l      ( out_l         ),
    .out_r      ( out_r         ),
    .out_v      ( out_v         ),
    .ovr        ( ovr           ),
    .r_req      ( r_req         ),
    .r_word     ( r_word        ),
    .r_data     ( r_data        ),
    .r_ack      ( r_ack         ),
    .ss_freeze  ( 1'b0          ),
    .ss_step    ( 1'b0          ),
    .ss_sel     ( 1'b0          ),
    .ss_addr    ( 12'd0         ),
    .ss_we      ( 1'b0          ),
    .ss_wd      ( 16'd0         ),
    .ss_rd      (               )
);

// ---------------------------------------------------------------- output
// The 054321's volume and enables, from the main CPU's writes (MAME's k054321.cpp;
// jt054321 keeps its own count and no enables): 0 active, 2 volume to 0, 3 volume + 1
// (data non-zero, up to 64). Gain 2^((v - 40) / 10), MAME's float, as a Q16 table.
// lethal.cpp routes the chip's output 0 to the right speaker and 1 to the left, each
// gated by an active bit (bit 1 left, bit 0 right).
reg [7:0] k321_active;
reg [6:0] k321_vol;
always @(posedge clk) begin
    if (vol_we && vol_addr == 4'd0) k321_active <= vol_din;
    if (vol_we && vol_addr == 4'd2) k321_vol <= 7'd0;
    if (vol_we && vol_addr == 4'd3 && vol_din != 8'd0 && k321_vol < 7'd64) k321_vol <= k321_vol + 7'd1;
    if (rst) begin k321_active <= 8'd0; k321_vol <= 7'd0; end
end

function [19:0] vgain( input [6:0] v );
    case (v)
        7'd0: vgain = 20'd4096;  7'd1: vgain = 20'd4390;  7'd2: vgain = 20'd4705;  7'd3: vgain = 20'd5043;
        7'd4: vgain = 20'd5405;  7'd5: vgain = 20'd5793;  7'd6: vgain = 20'd6208;  7'd7: vgain = 20'd6654;
        7'd8: vgain = 20'd7132;  7'd9: vgain = 20'd7643;  7'd10: vgain = 20'd8192;  7'd11: vgain = 20'd8780;
        7'd12: vgain = 20'd9410;  7'd13: vgain = 20'd10086;  7'd14: vgain = 20'd10809;  7'd15: vgain = 20'd11585;
        7'd16: vgain = 20'd12417;  7'd17: vgain = 20'd13308;  7'd18: vgain = 20'd14263;  7'd19: vgain = 20'd15287;
        7'd20: vgain = 20'd16384;  7'd21: vgain = 20'd17560;  7'd22: vgain = 20'd18820;  7'd23: vgain = 20'd20171;
        7'd24: vgain = 20'd21619;  7'd25: vgain = 20'd23170;  7'd26: vgain = 20'd24834;  7'd27: vgain = 20'd26616;
        7'd28: vgain = 20'd28526;  7'd29: vgain = 20'd30574;  7'd30: vgain = 20'd32768;  7'd31: vgain = 20'd35120;
        7'd32: vgain = 20'd37641;  7'd33: vgain = 20'd40342;  7'd34: vgain = 20'd43238;  7'd35: vgain = 20'd46341;
        7'd36: vgain = 20'd49667;  7'd37: vgain = 20'd53232;  7'd38: vgain = 20'd57052;  7'd39: vgain = 20'd61147;
        7'd40: vgain = 20'd65536;  7'd41: vgain = 20'd70240;  7'd42: vgain = 20'd75281;  7'd43: vgain = 20'd80684;
        7'd44: vgain = 20'd86475;  7'd45: vgain = 20'd92682;  7'd46: vgain = 20'd99334;  7'd47: vgain = 20'd106464;
        7'd48: vgain = 20'd114105;  7'd49: vgain = 20'd122294;  7'd50: vgain = 20'd131072;  7'd51: vgain = 20'd140480;
        7'd52: vgain = 20'd150562;  7'd53: vgain = 20'd161369;  7'd54: vgain = 20'd172951;  7'd55: vgain = 20'd185364;
        7'd56: vgain = 20'd198668;  7'd57: vgain = 20'd212927;  7'd58: vgain = 20'd228210;  7'd59: vgain = 20'd244589;
        7'd60: vgain = 20'd262144;  7'd61: vgain = 20'd280959;  7'd62: vgain = 20'd301124;  7'd63: vgain = 20'd322737;
        7'd64: vgain = 20'd345901;
        default: vgain = 20'd0;
    endcase
endfunction

// MAME's sample is the chip's accumulator / 32768 (out_* carries 8 fraction bits), times the
// gain; sound.cpp writes int(x * 32768), truncated toward zero, clamped to 16 bits
reg  [19:0]        g;
reg  signed [46:0] ml, mr;
reg                mv;
wire signed [46:0] g_s = $signed({ 27'd0, g });
function signed [15:0] clamp16( input signed [46:0] x );    // x has 24 fraction bits
    reg signed [46:0] t;
    reg signed [22:0] y;
    begin
        t = x < 0 ? x + 47'sh0ffffff : x;                   // toward zero
        y = 23'(t >>> 24);
        clamp16 = y > 23'sd32767 ? 16'sd32767 : y < -23'sd32768 ? -16'sd32768 : 16'(y);
    end
endfunction
always @(posedge clk) begin
    g  <= vgain(k321_vol);
    mv <= out_v;
    if (out_v) begin
        ml <= k321_active[1] ? 47'(out_r) * g_s : 47'sd0;
        mr <= k321_active[0] ? 47'(out_l) * g_s : 47'sd0;
    end
    if (mv) begin
        left  <= clamp16(ml);
        right <= clamp16(mr);
    end
    if (rst) begin left <= 16'sd0; right <= 16'sd0; end
end

endmodule
