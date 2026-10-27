// SPDX-License-Identifier: GPL-3.0-or-later
//
// Lethal Enforcers for MiSTer: the top. The board is lethal_main (6809, I/O, EEPROM),
// lethal_sound (Z80, 054321, 054539) and lethal_video; this file is the MiSTer side --
// clocks, the SDRAM and its download, the .mra's configuration, inputs, the OSD and
// the video output.
//
// Clocks (rtl/pll, NixPirates' settings): clk_sys 48 MHz for everything, SDRAM
// included; SDRAM_CLK the same lagging 5555 ps (lethal_sdram's SHIFTED). The pixel
// (6 MHz), the 6809 wrapper's 12 MHz and the Z80's 6 MHz are clock enables.
//
// ioctl indices: 0 the ROM stream (lethal_sdram's DL_* order; with the .mra's
// address="0x30000000" it arrives in DDR3 and gx_rom_loader replays it), 1 the mod
// byte, 2 the default EEPROM, 4 the saved EEPROM (<nvram>), 254 the DIP switches.
//
// The instrumented revision (LethalEnforcers_stp, DEBUG_ISSP) carries ISSP instance F,
// read by scripts/read_issp.py: its layout is at the instance and in
// scripts/read_issp.tcl.

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign FB_FORCE_BLANK = 0;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

wire signed [15:0] snd_l, snd_r;
assign AUDIO_S   = 1;
assign AUDIO_L   = snd_l;
assign AUDIO_R   = snd_r;
assign AUDIO_MIX = status[107:106];

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign LED_USER  = ioctl_download;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

`include "build_id.v"
localparam CONF_STR = {
	"LethalEnforcers;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[5:3],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer,HV-Integer;",
	"O[46:44],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"O[107:106],Audio mix,Stereo,25%,50%,Mono;",
	// the screen turned 180 degrees, over the set's own orientation (lethal_video)
	"O[65],Flip Screen,Off,On;",
	// HDMI only, for a turned monitor: screen_rotate_two through DDR3; the analog output
	// keeps the native raster
	"O[64:63],Rotation (HDMI),Off,CW,CCW;",
	// 1080p only, unrotated: 216 of the 224 lines at 5x
	"H4O[34],Vertical Crop,Disabled,216p(5x);",
	"H4O[38:35],Crop Offset,0,2,4,8,10,12,-12,-10,-8,-6,-4,-2;",
	// analog 15 kHz (rtl/video/crt); H2: its settings, shown while it is On
	"O[75],CRT Adjust,Off,On;",
	"H2O[82:76],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2O[88:83],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H2O[93:89],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	// the guns (lethal_guns): the crosshair where each points; the left stick per
	// player -- Auto moves a pushed-full axis as the d-pad does, Aim is absolute
	// (light guns), D-pad moves on any deflection; the mouse aims for one player
	"O[68],Crosshair,On,Off;",
	"O[70:69],P1 stick,Auto,Aim,D-pad;",
	"O[72:71],P2 stick,Auto,Aim,D-pad;",
	"O[74:73],Mouse aims,P1,P2,Off;",
	// hiscore.v (rtl/hiscore): shown when the .mra carries a hiscore.dat table
	"H3O[103],Autosave Hiscores,Off,On;",
	"-;",
	"DIP;",
	"-;",
	"R[0],Reset and close OSD;",
	// positional: bit 4 + i, as the .mra's <buttons> (scripts/build_mra.py) and
	// gx_keyboard; button 2 is a reload (a shot off the screen)
	"J1,Trigger,Reload,Button 3,Button 4,Button 5,Button 6,Start,Coin,Pause,Service;",
	"jn,A,B,X,-,-,-,Start,Select,L,R;",
	// the instrumented revision's debug page (H1, hidden in the release build)
	"H1-;",
	"H1O[112],Layer A,On,Off;",
	"H1O[113],Layer B,On,Off;",
	"H1O[114],Layer C,On,Off;",
	"H1O[115],Layer D,On,Off;",
	"H1O[116],Sprites,On,Off;",
	"V,v",`BUILD_DATE
};

`ifdef DEBUG_ISSP
wire debug_hide = 1'b0;
`else
wire debug_hide = 1'b1;
`endif
wire [1:0] rot_sel    = status[64:63];
wire       rotate_en  = rot_sel != 2'd0;
wire       rotate_ccw = rot_sel == 2'd2;

wire forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire  [21:0] gamma_bus;
wire  [10:0] ps2_key;
wire  [24:0] ps2_mouse;
wire  [31:0] joy_pad_0, joy_pad_1, joystick_0, joystick_1;
wire  [15:0] joystick_l_analog_0, joystick_l_analog_1;

wire        ioctl_download, ioctl_wr, ioctl_wait, ioctl_upload;
wire [15:0] ioctl_index;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire  [7:0] nv_dout;
reg         nv_save = 1'b0;
wire        hs_configured, hs_upload_req;
wire  [7:0] hs_to_hps;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	// H1: debug page; H2: CRT Adjust's; H3: hiscores; H4: crop (hidden while rotated)
	.status_menumask({ 11'd0, rotate_en, ~hs_configured, ~status[75], debug_hide, 1'b0 }),

	.joystick_0(joy_pad_0),
	.joystick_1(joy_pad_1),
	.joystick_l_analog_0(joystick_l_analog_0),
	.joystick_l_analog_1(joystick_l_analog_1),
	.ps2_mouse(ps2_mouse),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	// the .mra's <nvram index="4">: the EEPROM's 128 bytes, then hiscore.v's tables;
	// uploaded when either asks
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(nv_save | hs_upload_req),
	.ioctl_upload_index(8'd4),
	.ioctl_din(ioctl_addr >= 27'd128 ? hs_to_hps : nv_dout),
	.ioctl_rd(),

	.ps2_key(ps2_key)
);

wire [31:0] key_0, key_1;
wire  [1:0] svc_coin;
gx_keyboard u_keys (.clk(clk_sys), .ps2_key, .key0(key_0), .key1(key_1), .svc_coin);
assign joystick_0 = joy_pad_0 | key_0;
assign joystick_1 = joy_pad_1 | key_1;

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys, clk_sdram, pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_sdram),
	.locked(pll_locked)
);
assign SDRAM_CLK = clk_sdram;

// eight clocks a pixel: the pixel, the 6809 wrapper's 12 MHz and the Z80's 6 MHz
// (as sim/system_tb)
reg [2:0] c8 = 3'd0;
always @(posedge clk_sys) c8 <= c8 + 3'd1;
wire ce_pix = c8 == 3'd7;
wire ce_2x  = c8[1:0] == 2'd3;
wire cen12  = c8[1:0] == 2'd1;
wire cen6   = c8 == 3'd5;

wire reset = RESET | status[0] | buttons[1] | ~pll_locked;

///////////////////////   ROM LOAD   /////////////////////////////

// The board waits for its ROM: index 0 streamed and the download over, or the fast
// load's copy from DDR3 finished. The copy starts once the downloads are over, after an
// index-0 download that streamed nothing.
wire ldr_busy;
reg  rom_loaded = 1'b0, dl_index0_seen = 1'b0, dl_seen_wr = 1'b0, ldr_busy_d = 1'b0;
reg  dl_active_d = 1'b0, ldr_pending = 1'b0, ldr_start = 1'b0, ldr_done = 1'b0;
wire dl_index0 = ioctl_download && ioctl_index == 16'd0;
always @(posedge clk_sys) begin
	ldr_busy_d  <= ldr_busy;
	dl_active_d <= dl_index0;
	ldr_start   <= 1'b0;
	if (dl_index0) dl_index0_seen <= 1'b1;
	if (dl_index0 && !dl_active_d)  begin dl_seen_wr <= 1'b0; ldr_done <= 1'b0; end
	else if (dl_index0 && ioctl_wr) dl_seen_wr <= 1'b1;          // streamed: no copy
	if (dl_seen_wr && !ioctl_download) rom_loaded <= 1'b1;
	if (ldr_busy_d && !ldr_busy)       rom_loaded <= 1'b1;
	// pending on a download as well as a reset (NixPirates.sv), so no reset is needed after
	// the load
	if (reset || ioctl_download) ldr_pending <= 1'b1;
	else if (ldr_pending && !ldr_busy) begin
		ldr_pending <= 1'b0;
		if (dl_index0_seen && !dl_seen_wr && !ldr_done) begin ldr_start <= 1'b1; ldr_done <= 1'b1; end
	end
end

wire core_reset = reset | ioctl_download | ~rom_loaded | ldr_busy;
reg  [3:0] rst_sr = 4'hf;
always @(posedge clk_sys) rst_sr <= { rst_sr[2:0], core_reset };
wire rst_board = |rst_sr;

// the fast load: DDR3 (0x30000000) replayed as the byte download
wire        ldr_ddr_req, ldr_ddr_busy, ldr_ddr_valid, ldr_wr, dl_wait;
wire [27:0] ldr_ddr_addr;
wire [63:0] ldr_ddr_rdata;
wire [26:0] ldr_addr;
wire  [7:0] ldr_dout;
wire [24:0] dl_end;
// DDR3 has two masters that never overlap: this loader while the board is in reset, the
// HDMI rotator after (the mux at the bottom of this file)
wire  [7:0] ldr_DDRAM_BURSTCNT, ldr_DDRAM_BE;
wire [28:0] ldr_DDRAM_ADDR;
wire [63:0] ldr_DDRAM_DIN;
wire        ldr_DDRAM_RD, ldr_DDRAM_WE;
ddram_phy u_ddram (
	.clk(clk_sys), .reset(reset),
	.DDRAM_BUSY, .DDRAM_BURSTCNT(ldr_DDRAM_BURSTCNT), .DDRAM_ADDR(ldr_DDRAM_ADDR),
	.DDRAM_DOUT, .DDRAM_DOUT_READY, .DDRAM_RD(ldr_DDRAM_RD), .DDRAM_DIN(ldr_DDRAM_DIN),
	.DDRAM_BE(ldr_DDRAM_BE), .DDRAM_WE(ldr_DDRAM_WE),
	.req(ldr_ddr_req), .we(1'b0), .addr(ldr_ddr_addr), .wdata(8'd0),
	.busy(ldr_ddr_busy), .valid(ldr_ddr_valid), .rdata(ldr_ddr_rdata)
);
gx_rom_loader u_ldr (
	.clk(clk_sys), .reset(reset),
	.length({ 3'd0, dl_end }), .start(ldr_start), .busy(ldr_busy),
	.ddr_req(ldr_ddr_req), .ddr_addr(ldr_ddr_addr), .ddr_busy(ldr_ddr_busy),
	.ddr_valid(ldr_ddr_valid), .ddr_rdata(ldr_ddr_rdata),
	.wr(ldr_wr), .addr(ldr_addr), .dout(ldr_dout), .wait_in(dl_wait)
);
wire        m_dl   = ldr_busy || dl_index0;
wire        m_wr   = ldr_busy ? ldr_wr   : dl_index0 && ioctl_wr;
wire [26:0] m_addr = ldr_busy ? ldr_addr : ioctl_addr;
wire  [7:0] m_dout = ldr_busy ? ldr_dout : ioctl_dout;
assign ioctl_wait = dl_wait;

// index 1: the mod byte (scripts/build_mra.py)
reg [7:0] mod_byte = 8'd0;
always @(posedge clk_sys) if (ioctl_wr && ioctl_index == 16'd1) mod_byte <= ioctl_dout;
wire orient_fx = mod_byte[0];          // MAME's ORIENTATION_FLIP_X (else FLIP_Y)
wire gun_rev   = mod_byte[1];          // LIGHT ports PORT_REVERSE

// index 254: DIP bits 0-3 are 0x40d8 bits 4-7
reg [7:0] sw = 8'hff;
always @(posedge clk_sys) if (ioctl_wr && ioctl_index == 16'd254 && !ioctl_addr[24:0]) sw <= ioctl_dout;

// the EEPROM: index 2 (the set's default) then index 4 (the saved one) write its 128
// bytes while the board is in reset; saved back when the OSD opens after the game has
// written it (KonamiGX.sv's shape)
wire       nv_load = ioctl_wr && (ioctl_index == 16'd2 || ioctl_index == 16'd4) && !ioctl_addr[24:7];
wire       nv_changed;
reg        osd_d = 1'b0;
always @(posedge clk_sys) begin
	osd_d   <= OSD_STATUS;
	nv_save <= OSD_STATUS && !osd_d && nv_changed;
end

///////////////////////   MEMORY   ///////////////////////////////

wire        sdram_init, snd_prog_we;
wire [15:0] snd_prog_addr;
wire  [7:0] snd_prog_data;
wire [17:0] prog_addr;
wire        prog_cs, prog_ok;
wire  [7:0] prog_data;
wire [18:0] tile_addr;
wire        tile_cs, tile_ok;
wire [63:0] tile_data;
wire [20:2] obj_addr;
wire        obj_cs, obj_ok;
wire [47:0] obj_data;
wire [17:0] smp_addr;
wire        smp_cs, smp_ok;
wire [63:0] smp_data;
wire [15:0] snd_ovr;

// SDRAM refresh: jtframe_sdram64 refreshes only when rfsh asks (RFSHCNT commands each
// time, meant for a 15 kHz line). A line of this board is 3072 clocks; this counter runs
// from power-on, through the load and the board's reset, as the video does not.
reg [11:0] rfsh_cnt = 12'd0;
always @(posedge clk_sys) rfsh_cnt <= rfsh_cnt == 12'd3071 ? 12'd0 : rfsh_cnt + 12'd1;
wire rfsh = rfsh_cnt < 12'd64;

lethal_sdram #(.SHIFTED(1)) u_sdram (
	.rst(~pll_locked), .clk(clk_sys), .init(sdram_init),
	.dl_active(m_dl), .dl_wr(m_wr), .dl_addr(m_addr[24:0]), .dl_data(m_dout), .dl_wait,
	.dl_end, .snd_we(snd_prog_we), .snd_addr(snd_prog_addr), .snd_data(snd_prog_data),
	.rfsh(rfsh),
	.main_addr(prog_addr), .main_cs(prog_cs), .main_ok(prog_ok), .main_data(prog_data),
	.tile_addr, .tile_cs, .tile_ok, .tile_data,
	.obj_addr, .obj_cs, .obj_ok, .obj_data,
	.smp_addr(smp_addr), .smp_cs(smp_cs), .smp_ok(smp_ok), .smp_data(smp_data),
	.sdram_dq(SDRAM_DQ), .sdram_a(SDRAM_A), .sdram_dqml(SDRAM_DQML), .sdram_dqmh(SDRAM_DQMH),
	.sdram_ba(SDRAM_BA), .sdram_nwe(SDRAM_nWE), .sdram_ncas(SDRAM_nCAS), .sdram_nras(SDRAM_nRAS),
	.sdram_ncs(SDRAM_nCS), .sdram_cke(SDRAM_CKE)
);

///////////////////////   INPUTS   ///////////////////////////////

// Pause: joystick bit 12, either pad, toggles; it holds the 6809; the video runs on
wire pause_btn = joystick_0[12] | joystick_1[12];
reg  pause_btn_d = 1'b0, pause_cpu = 1'b0;
always @(posedge clk_sys) begin
	pause_btn_d <= pause_btn;
	if (reset)                         pause_cpu <= 1'b0;
	else if (pause_btn & ~pause_btn_d) pause_cpu <= ~pause_cpu;
end

wire  [7:0] gun [4];
wire  [1:0] gun_xlsb, gun_trig;
// 0x40d9, active low: coin 1, coin 2, service coin, test, trigger 1, trigger 2, start 1, 2
wire  [7:0] inputs = ~{ joystick_1[10], joystick_0[10], gun_trig[1], gun_trig[0],
                        joystick_0[13] | joystick_1[13], svc_coin[0], joystick_1[11], joystick_0[11] };

///////////////////////   THE BOARD   ////////////////////////////

wire        vblank_irq, tm_reg_we, vram_we, vram_rd, objram_we, objreg_we, pal_we;
wire  [5:0] tm_reg_addr;
wire  [7:0] cpu_dout, vram_dout, objram_dout, pal_dout, pcu1, pcu2, pcu3;
wire [12:0] vram_addr;
wire [10:0] objram_addr;
wire  [3:0] objreg_addr;
wire [13:0] pal_addr;
wire        snd_on, snd_we;
wire  [3:0] snd_addr;
wire  [7:0] snd_dout;

// hiscore.v (rtl/hiscore/PROVENANCE.md): MAME's hiscore.dat entries from the .mra's
// <rom index="3">, restored into work RAM once the game has written its own table, and
// read back when the OSD opens. Its dump shares <nvram index="4"> with the EEPROM, after
// the EEPROM's 128 bytes, so it sees index 4 from byte 128 and addresses from there. It
// reaches the work RAM through the 6809 RAM's second port (a byte the clock after its
// address) and holds the CPU while it does.
wire [12:0] hs_addr;
wire  [7:0] hs_wd, hs_q;
wire        hs_we, hs_pause;
wire        hs_nv = ioctl_index == 16'd4;
hiscore #(
	.HS_ADDRESSWIDTH(13),               // work RAM, 0x2000-0x3fff: the entry's low 13 bits
	.HS_SCOREWIDTH(8),                  // up to 256 bytes (lethalen: 81)
	.CFG_ADDRESSWIDTH(2),               // up to 4 entries (lethalen: 2)
	.CFG_LENGTHWIDTH(2)                 // scripts/build_mra.py's row format, as KonamiGX
) u_hiscore (
	.clk(clk_sys),
	.paused(pause_cpu | hs_pause),
	.reset(rst_board),
	.autosave(status[103]),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(hs_upload_req),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(hs_nv ? ioctl_addr[24:0] - 25'd128 : ioctl_addr[24:0]),
	.ioctl_index(hs_nv && ioctl_addr < 27'd128 ? 8'hfe : ioctl_index[7:0]),
	.OSD_STATUS(OSD_STATUS),
	.data_from_hps(ioctl_dout),
	.data_from_ram(hs_q),
	.ram_address(hs_addr),
	.data_to_hps(hs_to_hps),
	.data_to_ram(hs_wd),
	.ram_write(hs_we),
	.ram_intent_read(),
	.ram_intent_write(),
	.pause_cpu(hs_pause),
	.configured(hs_configured)
);

lethal_main u_main (
	.rst(rst_board), .clk(clk_sys), .cen(cen12), .pause(pause_cpu | hs_pause),
	.rom_addr(prog_addr), .rom_cs(prog_cs), .rom_ok(prog_ok), .rom_data(prog_data),
	.vblank_irq,
	.tm_reg_we, .tm_reg_addr, .cpu_dout,
	.vram_we, .vram_rd, .vram_addr, .vram_dout,
	.objram_we, .objram_addr, .objram_dout,
	.objreg_we, .objreg_addr,
	.pal_we, .pal_addr, .pal_dout,
	.pcu1, .pcu2, .pcu3,
	.snd_on, .snd_addr, .snd_we, .snd_dout,
	.inputs, .dsw(sw[3:0]), .gun, .gun_xlsb,
	.nv_we(nv_load), .nv_addr(ioctl_addr[6:0]), .nv_din(ioctl_dout),
	.nv_dout, .nv_changed, .nv_clr(nv_save),
	.hs_addr, .hs_we, .hs_din(hs_wd), .hs_dout(hs_q)
);

lethal_sound u_snd (
	.rst(rst_board), .clk(clk_sys), .cen(cen6),
	.prog_we(snd_prog_we), .prog_addr(snd_prog_addr), .prog_din(snd_prog_data),
	.snd_on, .m_addr(snd_addr), .m_we(snd_we), .m_din(cpu_dout), .m_dout(snd_dout),
	.left(snd_l), .right(snd_r),
	.smp_addr, .smp_cs, .smp_ok, .smp_data, .ovr(snd_ovr)
);

wire [23:0] rgb;
wire        hblank, vblank, hsync, vsync, tile_unsup;
wire [15:0] tile_lost;
lethal_video u_video (
	.rst(rst_board), .clk(clk_sys), .ce_pix, .ce_2x,
	.orient_flipx(orient_fx), .orient_flipy(~orient_fx), .osd_flip(status[65]), .layer_en(debug_hide ? 5'h1f : ~status[116:112]),
	.tm_reg_we, .tm_reg_addr, .tm_reg_din(cpu_dout),
	.vram_we, .vram_rd, .vram_addr, .vram_din(cpu_dout), .vram_dout,
	.objram_we, .objram_addr, .objram_din(cpu_dout), .objram_dout,
	.objreg_we, .objreg_addr, .objreg_din(cpu_dout),
	.pal_we, .pal_addr, .pal_din(cpu_dout), .pal_dout,
	.pcu1, .pcu2, .pcu3,
	.tile_addr, .tile_cs, .tile_ok, .tile_data,
	.obj_addr, .obj_cs, .obj_ok, .obj_data,
	.rgb, .hblank, .vblank, .hsync, .vsync,
	.vblank_irq, .tile_unsupported(tile_unsup), .tile_lost
);

///////////////////////   VIDEO   ////////////////////////////////

wire [23:0] rgb_x;
lethal_guns u_guns (
	.clk(clk_sys), .rst(rst_board), .joy0(joystick_0), .joy1(joystick_1),
	.ana0(joystick_l_analog_0), .ana1(joystick_l_analog_1), .mouse(ps2_mouse),
	.mode0(status[70:69]), .mode1(status[72:71]), .ms_who(status[74:73]),
	.rev(gun_rev), .gun, .xlsb(gun_xlsb), .trig(gun_trig),
	.show(~status[68]), .pxl_cen(ce_pix), .lhbl(~hblank), .lvbl(~vblank),
	.rgb_in(rgb), .rgb_out(rgb_x)
);

// CRT Adjust (rtl/video/crt): the OSD stores list indices; H-Position has 97 entries
// (0, +1..+48, -48..-1), so its negative half wraps at 97, not 128. H-Size is held
// at 0 while the scandoubler or its effects are on.
wire              crt_on      = status[75];
wire              crt_scale   = ~(forced_scandoubler | |status[46:44]);
wire        [6:0] crt_hpos_ix = status[82:76];
wire signed [8:0] crt_hoffset = crt_hpos_ix <= 7'd48 ? $signed({ 2'b00, crt_hpos_ix })
                                                     : $signed({ 2'b00, crt_hpos_ix }) - 9'sd97;
wire       crt_ce, crt_hs, crt_vs, crt_hb, crt_vb;
wire [7:0] crt_r, crt_g, crt_b;
gx_crt_chain #(.VTOTAL(262)) u_crt (
	.clk(clk_sys), .ce_pix, .pxl_div(4'd8),
	.active(crt_on), .scale_en(crt_scale),
	.hoffset(crt_hoffset), .voffset($signed(status[88:83])), .hsize($signed(status[93:89])),
	.r_in(rgb_x[23:16]), .g_in(rgb_x[15:8]), .b_in(rgb_x[7:0]),
	.hs_in(hsync), .vs_in(vsync), .hb_in(hblank), .vb_in(vblank),
	.ce_out(crt_ce), .r_out(crt_r), .g_out(crt_g), .b_out(crt_b),
	.hs_out(crt_hs), .vs_out(crt_vs), .hb_out(crt_hb), .vb_out(crt_vb)
);

wire vga_de;
arcade_video #(.WIDTH(384), .DW(24), .GAMMA(1)) arcade_video
(
	.clk_video(clk_sys),
	.ce_pix(crt_ce),
	.RGB_in({ crt_r, crt_g, crt_b }),
	.HBlank(crt_hb),
	.VBlank(crt_vb),
	.HSync(crt_hs),
	.VSync(crt_vs),
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS),
	.VGA_DE(vga_de),
	.VGA_SL(VGA_SL),
	.fx(status[46:44]),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus)
);

// 288 x 224 on a 4:3 screen (lethal.cpp's set_raw; the aspect is the monitor's), 3:4
// when the HDMI rotation turns it
wire [1:0] ar = status[122:121];
// vertical crop: the arcade template's, at 1080p with no scandoubler and normal scale
wire       vcrop_en = status[34] && !rotate_en;
wire [3:0] vcopt    = status[38:35];
reg        en216p;
always @(posedge CLK_VIDEO) en216p <= HDMI_WIDTH == 12'd1920 && HDMI_HEIGHT == 12'd1080 && !forced_scandoubler && !status[5:3];
wire [4:0] voff = vcopt < 4'd6 ? { vcopt, 1'b0 } : { vcopt, 1'b0 } - 5'd24;
video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(vga_de),
	.ARX((!ar) ? (rotate_en ? 12'd3 : 12'd4) : (ar - 1'd1)),
	.ARY((!ar) ? (rotate_en ? 12'd4 : 12'd3) : 12'd0),
	.CROP_SIZE((en216p & vcrop_en) ? 12'd216 : 12'd0),
	.CROP_OFF(voff),
	.SCALE(status[5:3])
);

// HDMI rotation: screen_rotate_two taps the video output into DDR3 for the HPS
// framebuffer, which the scaler reads turned; held off DDR3 while the loader has it.
// The game's own flip is Flip Screen above; this one's flip is unused.
wire        rot_DDRAM_CLK, rot_DDRAM_WE, rot_DDRAM_RD;
wire  [7:0] rot_DDRAM_BURSTCNT, rot_DDRAM_BE;
wire [28:0] rot_DDRAM_ADDR;
wire [63:0] rot_DDRAM_DIN;
screen_rotate_two u_rotate (
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B),
	.VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),
	.rotate_ccw(rotate_ccw),
	.no_rotate(~rotate_en),
	.flip(1'b0),
	.two_screen(1'b0),
	.video_rotated(),
	.FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT),
	.FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE),
	.FB_VBL(FB_VBL), .FB_LL(FB_LL),
	.DDRAM_CLK(rot_DDRAM_CLK),
	.DDRAM_BUSY(DDRAM_BUSY | ldr_busy),
	.DDRAM_BURSTCNT(rot_DDRAM_BURSTCNT),
	.DDRAM_ADDR(rot_DDRAM_ADDR),
	.DDRAM_DIN(rot_DDRAM_DIN),
	.DDRAM_BE(rot_DDRAM_BE),
	.DDRAM_WE(rot_DDRAM_WE),
	.DDRAM_RD(rot_DDRAM_RD)
);

// both masters run on clk_sys (CLK_VIDEO)
assign DDRAM_CLK      = clk_sys;
assign DDRAM_BURSTCNT = ldr_busy ? ldr_DDRAM_BURSTCNT : rot_DDRAM_BURSTCNT;
assign DDRAM_ADDR     = ldr_busy ? ldr_DDRAM_ADDR     : rot_DDRAM_ADDR;
assign DDRAM_DIN      = ldr_busy ? ldr_DDRAM_DIN      : rot_DDRAM_DIN;
assign DDRAM_BE       = ldr_busy ? ldr_DDRAM_BE       : rot_DDRAM_BE;
assign DDRAM_WE       = ldr_busy ? ldr_DDRAM_WE       : rot_DDRAM_WE;
assign DDRAM_RD       = ldr_busy ? ldr_DDRAM_RD       : rot_DDRAM_RD;

///////////////////////   DEBUG   ////////////////////////////////

`ifdef DEBUG_ISSP
// Instance F (scripts/read_issp.tcl's fields_F):
//   [15:0]   frames (vblank IRQs since the board left reset)
//   [31:16]  tile_lost (lethal_tilemap's late fetches, saturating)
//   [32]     tile_unsupported (now)
//   [33]     rom_loaded     [34] ldr_busy     [35] pause_cpu     [36] sdram_init
//   [37]     rst_board      [38] nv_changed
//   [47:40]  mod_byte       [55:48] DIP byte
//   [79:56]  clk_sys cycles of the DDR3 copy
//   [95:80]  the 054539's late samples (gx_k054539 ovr)
//   [127]    pll_locked
// source bit 0: clears the frame count
wire [7:0] issp_src;
reg [15:0] frames = 16'd0;
reg [23:0] ldr_cycles = 24'd0;
always @(posedge clk_sys) begin
	if (issp_src[0] || rst_board) frames <= 16'd0;
	else if (vblank_irq) frames <= frames + 16'd1;
	if (ldr_start) ldr_cycles <= 24'd0;
	else if (ldr_busy && ~&ldr_cycles) ldr_cycles <= ldr_cycles + 24'd1;
end
issp_probe #(.INSTANCE_ID("F"), .PROBE_W(128), .SOURCE_W(8)) u_issp_f (
	.clk(clk_sys),
	.probe({ pll_locked, 31'd0, snd_ovr, ldr_cycles, sw, mod_byte, 1'b0, nv_changed, rst_board, sdram_init,
	         pause_cpu, ldr_busy, rom_loaded, tile_unsup, tile_lost, frames }),
	.source(issp_src)
);
`endif

endmodule
