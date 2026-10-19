// SPDX-License-Identifier: GPL-3.0-or-later
//
// The whole board from reset: lethal_main, lethal_sound and lethal_video, with
// ROMs in bench memories and no replay. scripts/check_system.py drives it.
//
//   +prog=<hex>     the 256 KB main program, a byte a line
//   +snd=<hex>      the 64 KB Z80 program
//   +tiles= +sprites=  as sim/video_tb
//   +nv=<hex>       the 128-byte EEPROM image
//   +orient=<0|1|2> as sim/video_tb
//   +trace=<file> +n=<count>   the main CPU's bus accesses, MAME's boot-trace format
//   +frames=<a,b>   log display frames a..b (vblank count), "rrggbb" a pixel, to +out=<file>
//   +romlat=<n>     clocks from a ROM request to data (main program, tiles, sprites)
//   +smp=<hex>      the 054539's 2 MB sample ROM, an 8-byte granule a line, byte 0 lowest
//   +audio=<file>   "left right" at each 48 kHz sample, from reset, while frames are run
//   +until=<frame>  run to this vblank count (with +audio)
//   +coin=<frame>   scripts/mame/audio_play.lua's inputs: two coins from this frame, Start
//                   110 frames after (active low at 0x40d9: coin 1 bit 0, start 1 bit 6)

`timescale 1ns/1ps

module tb_system;

reg clk = 0;
always #10.4167 clk = ~clk;
reg rst = 1;

reg [2:0] c8 = 0;
always @(posedge clk) c8 <= c8 + 3'd1;
wire ce_pix = c8 == 3'd7;
wire ce_2x  = c8[1:0] == 2'd3;
wire cen12  = c8[1:0] == 2'd1;
wire cen6   = c8 == 3'd5;

// ---------------------------------------------------------------- the board
wire [17:0] prog_addr;
wire        prog_cs;
reg         prog_ok;
reg  [7:0]  prog_q;
wire        vblank_irq, tm_reg_we, vram_we, vram_rd, objram_we, objreg_we, pal_we;
wire [5:0]  tm_reg_addr;
wire [7:0]  cpu_dout, vram_dout, objram_dout, pal_dout, pcu1, pcu2, pcu3;
wire [12:0] vram_addr;
wire [10:0] objram_addr;
wire [3:0]  objreg_addr;
wire [13:0] pal_addr;
wire        snd_on, snd_we;
wire [3:0]  snd_addr;
wire [7:0]  snd_dout;
wire [7:0]  gun [4];
// MAME's guns at their default centre (0x80): X 160 >> 1, Y 232 - 121 (lethal.cpp guns_r)
assign gun[0] = 8'h50; assign gun[1] = 8'h6f; assign gun[2] = 8'h50; assign gun[3] = 8'h6f;
reg         nv_we = 0;
integer     coin_at = -1;
integer     frame = 0;
wire signed [31:0] ck = frame - coin_at;
wire [7:0]  inputs = coin_at < 0 ? 8'hff :
                     ~{ 1'b0, ck >= 110 && ck < 116, 5'b0, ck >= 0 && ck < 40 && ck % 20 < 6 };
reg  [6:0]  nv_addr;
reg  [7:0]  nv_din;

lethal_main u_main (
    .rst(rst), .clk(clk), .cen(cen12), .pause(1'b0),
    .rom_addr(prog_addr), .rom_cs(prog_cs), .rom_ok(prog_ok), .rom_data(prog_q),
    .vblank_irq(vblank_irq),
    .tm_reg_we(tm_reg_we), .tm_reg_addr(tm_reg_addr), .cpu_dout(cpu_dout),
    .vram_we(vram_we), .vram_rd(vram_rd), .vram_addr(vram_addr), .vram_dout(vram_dout),
    .objram_we(objram_we), .objram_addr(objram_addr), .objram_dout(objram_dout),
    .objreg_we(objreg_we), .objreg_addr(objreg_addr),
    .pal_we(pal_we), .pal_addr(pal_addr), .pal_dout(pal_dout),
    .pcu1(pcu1), .pcu2(pcu2), .pcu3(pcu3),
    .snd_on(snd_on), .snd_addr(snd_addr), .snd_we(snd_we), .snd_dout(snd_dout),
    .inputs(inputs), .dsw(4'b1101), .gun(gun), .gun_xlsb(2'b00),
    .nv_we(nv_we), .nv_addr(nv_addr), .nv_din(nv_din), .nv_dout(), .nv_changed(), .nv_clr(1'b0),
    .hs_addr(13'd0), .hs_we(1'b0), .hs_din(8'd0), .hs_dout()
);

reg        snd_we_p = 0;
wire signed [15:0] snd_left, snd_right;
wire [17:0] smp_addr;
wire        smp_cs;
reg         smp_ok = 0;
reg  [63:0] smp_data;
reg [15:0] snd_pa;
reg [7:0]  snd_pd;
lethal_sound u_snd (
    .rst(rst), .clk(clk), .cen(cen6),
    .prog_we(snd_we_p), .prog_addr(snd_pa), .prog_din(snd_pd),
    .snd_on(snd_on), .m_addr(snd_addr), .m_we(snd_we), .m_din(cpu_dout), .m_dout(snd_dout),
    .left(snd_left), .right(snd_right),
    .smp_addr(smp_addr), .smp_cs(smp_cs), .smp_ok(smp_ok), .smp_data(smp_data), .ovr()
);

reg  orient_fx = 0, orient_fy = 0;
wire [18:0] tile_addr;
wire [20:2] obj_addr;
wire        tile_cs, obj_cs, hblank, vblank, hsync, vsync, unsup;
reg         tile_ok = 0, obj_ok = 0;
reg  [63:0] tile_data;
reg  [47:0] obj_data;
wire [23:0] rgb;
wire [15:0] lost;

lethal_video u_video (
    .rst(rst), .clk(clk), .ce_pix(ce_pix), .ce_2x(ce_2x),
    .orient_flipx(orient_fx), .orient_flipy(orient_fy), .osd_flip(1'b0), .layer_en(5'h1f),
    .tm_reg_we(tm_reg_we), .tm_reg_addr(tm_reg_addr), .tm_reg_din(cpu_dout),
    .vram_we(vram_we), .vram_rd(vram_rd), .vram_addr(vram_addr), .vram_din(cpu_dout), .vram_dout(vram_dout),
    .objram_we(objram_we), .objram_addr(objram_addr), .objram_din(cpu_dout), .objram_dout(objram_dout),
    .objreg_we(objreg_we), .objreg_addr(objreg_addr), .objreg_din(cpu_dout),
    .pal_we(pal_we), .pal_addr(pal_addr), .pal_din(cpu_dout), .pal_dout(pal_dout),
    .pcu1(pcu1), .pcu2(pcu2), .pcu3(pcu3),
    .tile_addr(tile_addr), .tile_cs(tile_cs), .tile_ok(tile_ok), .tile_data(tile_data),
    .obj_addr(obj_addr), .obj_cs(obj_cs), .obj_ok(obj_ok), .obj_data(obj_data),
    .rgb(rgb), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync),
    .vblank_irq(vblank_irq), .tile_unsupported(unsup), .tile_lost(lost)
);

// ---------------------------------------------------------------- ROMs
reg [7:0]  prom [0:262143];
reg [63:0] srom [0:262143];
integer    slat = 0;
always @(posedge clk) begin
    smp_ok <= 0;
    if (smp_cs && !smp_ok) begin
        if (slat >= romlat + 4) begin smp_data <= srom[smp_addr]; smp_ok <= 1; slat <= 0; end
        else slat <= slat + 1;
    end else slat <= 0;
end
reg [63:0] trom [0:(1<<19)-1];
reg [47:0] orom [0:(1<<19)-1];
integer romlat = 3, plat = 0, tlat = 0, olat = 0;
reg [17:0] plast;
reg [20:2] olast;
always @(posedge clk) begin
    plast <= prog_addr;
    if (!prog_cs || prog_addr != plast) plat <= 0; else if (plat < romlat) plat <= plat + 1;
    prog_q <= prom[prog_addr];
    tile_ok <= 0;
    if (tile_cs && !tile_ok) begin
        if (tlat >= romlat) begin tile_data <= trom[tile_addr]; tile_ok <= 1; tlat <= 0; end
        else tlat <= tlat + 1;
    end else tlat <= 0;
    olast <= obj_addr;
    if (!obj_cs || obj_addr != olast) olat <= 0; else if (olat < romlat) olat <= olat + 1;
    obj_data <= orom[obj_addr];
end
always @* prog_ok = prog_cs && prog_addr == plast && plat >= romlat;
always @* obj_ok  = obj_cs && obj_addr == olast && olat >= romlat;

// ---------------------------------------------------------------- main CPU trace
integer ft = 0, nmax = 0, seq = 0;
reg [15:0] cyc_a;
reg        cyc_rnw, cyc_vma, cyc_live = 0;
wire cen_E = u_main.u_cpu.cen_E;
wire cen_Q = u_main.u_cpu.cen_Q;
always @(posedge clk) if (!rst && ft != 0 && seq < nmax) begin
    if (cen_Q) begin
        cyc_a <= u_main.A; cyc_rnw <= u_main.RnW; cyc_vma <= u_main.VMA; cyc_live <= 1;
    end
    if (cen_E && cyc_live && cyc_vma) begin
        seq = seq + 1;
        $fwrite(ft, "%0d\t%s\t%04X\tFF\t%02X\n", seq, cyc_rnw ? "r" : "w", cyc_a,
                cyc_rnw ? u_main.cpu_din : u_main.cpu_dout);
        if (seq == nmax) begin $fwrite(ft, "# %0d accesses logged\n", seq); $fclose(ft); ft = 0; end
    end
end

// debug: +dpwatch logs every change of the 6809's DP with the access count and PC
reg [7:0] dp_l = 0;
reg       dpwatch = 0;
initial dpwatch = $test$plusargs("dpwatch");
always @(posedge clk) if (dpwatch) begin
    dp_l <= u_main.u_cpu.reg_dp;
    if (u_main.u_cpu.reg_dp != dp_l)
        $display("DP %02x -> %02x at access %0d, PC %04x, frame %0d", dp_l, u_main.u_cpu.reg_dp, seq,
                 u_main.u_cpu.reg_pc, frame);
end

// ---------------------------------------------------------------- frames
integer fa = -1, fb = -2, fo = 0;
always @(posedge clk) if (vblank_irq) begin
    frame <= frame + 1;
    if (frame % 100 == 0) $display("frame %0d, 054539 late samples %0d", frame, u_snd.u_k539.ovr);
end
always @(posedge clk) if (fo != 0 && ce_pix && !hblank && !vblank && frame >= fa && frame <= fb)
    $fwrite(fo, "%06x\n", rgb);

string f_prog, f_snd, f_tiles, f_spr, f_nv, f_trace, f_out, s_frames, f_smp, f_audio;
integer fa_out = 0, until_frame = -1;
// with +audio, the Z80's writes to the 054539 as scripts/mame/k539_writes.lua logs them,
// to <audio file>.k539: "W <sample> <reg> <data>"
integer fk_out = 0, smp_n = 0;
reg [14:0] vol_l = 15'h7fff;
always @(posedge clk) begin
    vol_l <= { u_snd.u_k539.k321_active, u_snd.u_k539.k321_vol };
    if (fk_out != 0 && { u_snd.u_k539.k321_active, u_snd.u_k539.k321_vol } != vol_l)
        $fwrite(fk_out, "V %0d %02x %0d\n", smp_n, u_snd.u_k539.k321_active, u_snd.u_k539.k321_vol);
end
always @(posedge clk) begin
    if (u_snd.u_k539.smp) smp_n <= smp_n + 1;
    if (fk_out != 0 && u_snd.k_start && !u_snd.wr_n)
        $fwrite(fk_out, "W %0d %03x %02x\n", smp_n, u_snd.A[10:0], u_snd.dout);
end
always @(posedge clk) if (fa_out != 0 && u_snd.u_k539.smp) $fwrite(fa_out, "%0d %0d\n", snd_left, snd_right);
integer f, k, v, orient;
initial begin
    if (!$value$plusargs("prog=%s", f_prog) || !$value$plusargs("snd=%s", f_snd) ||
        !$value$plusargs("tiles=%s", f_tiles) || !$value$plusargs("sprites=%s", f_spr) ||
        !$value$plusargs("nv=%s", f_nv)) begin
        $display("missing plusargs"); $finish;
    end
    void'($value$plusargs("romlat=%d", romlat));
    orient = 1; void'($value$plusargs("orient=%d", orient));
    orient_fy = orient == 1; orient_fx = orient == 2;
    $readmemh(f_prog, prom);
    $readmemh(f_tiles, trom);
    $readmemh(f_spr, orom);
    if ($value$plusargs("smp=%s", f_smp)) $readmemh(f_smp, srom);
    void'($value$plusargs("coin=%d", coin_at));
    if ($value$plusargs("audio=%s", f_audio)) begin
        fa_out = $fopen(f_audio, "w");
        fk_out = $fopen({ f_audio, ".k539" }, "w");
        void'($value$plusargs("until=%d", until_frame));
    end
    if ($value$plusargs("trace=%s", f_trace)) begin
        void'($value$plusargs("n=%d", nmax));
        ft = $fopen(f_trace, "w");
        $fwrite(ft, "# tb_system main CPU bus accesses from reset\n# seq\trw\taddr\tmask\tdata\n");
    end
    if ($value$plusargs("frames=%s", s_frames)) begin
        void'($sscanf(s_frames, "%d,%d", fa, fb));
        void'($value$plusargs("out=%s", f_out));
        fo = $fopen(f_out, "w");
    end
    f = $fopen(f_snd, "r");
    for (k = 0; k < 65536; k++) begin
        void'($fscanf(f, "%h\n", v));
        @(posedge clk); snd_we_p <= 1; snd_pa <= 16'(k); snd_pd <= 8'(v);
    end
    @(posedge clk); snd_we_p <= 0; $fclose(f);
    f = $fopen(f_nv, "r");
    for (k = 0; k < 128; k++) begin
        void'($fscanf(f, "%h\n", v));
        @(posedge clk); nv_we <= 1; nv_addr <= 7'(k); nv_din <= 8'(v);
    end
    @(posedge clk); nv_we <= 0; $fclose(f);
    repeat (10) @(posedge clk);
    rst = 0;
    wait ((ft == 0 || nmax == 0 || seq >= nmax) && (fo == 0 || frame > fb) && (fa_out == 0 || frame >= until_frame));
    if (fa_out != 0) $fclose(fa_out);
    if (fk_out != 0) $fclose(fk_out);
    if (fo != 0) $fclose(fo);
    $display("DONE frame %0d, unsupported %0d lost %0d", frame, unsup, lost);
    $finish;
end

endmodule
