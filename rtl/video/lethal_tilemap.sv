// SPDX-License-Identifier: GPL-3.0-or-later
//
// Lethal Enforcers' tilemaps: the 054156 register file and the 054157 pair's
// tile fetch, as a line renderer. Four layers, 8 bpp (MAME's K056832_BPP_8LE).
//
// Derived from gx_tilemap.sv in Arcade-KonamiGX_MiSTer (89124d4), itself written
// from MAME's k054156_k054157_k056832.cpp. Changed for this core (GPLv3 5(a)):
// five VRAM pages instead of sixteen, line scroll from the external page,
// screen flip in both axes as MAME draws it, the 8LE pixel decode, and Lethal's
// layer offsets. The specification is scripts/render_model.py draw_layer(),
// pixel-identical to MAME; scripts/check_tilemap.py is the test.
//
// VRAM: the game writes pages 0, 1, 4 and 5 and the line-scroll page 16 and no
// others (docs/HARDWARE_NOTES.md, measured on all nine sets). They are stored
// as physical pages 0-4; a CPU write to any other page is dropped and counted
// on dbg_lost.
//
// COORDINATES are MAME's bitmap's (lethal.cpp line 695): line_y is a bitmap
// line, 16..239 visible, and the line buffer holds bitmap columns 24..311 at
// 0..287 -- or 311..24 when lb_rev is set. Screen flip (register 0 bits 4, 5)
// follows MAME's tilemap_t: about the visible window's centre, so the flipped
// map column at bitmap x is (335 - x + scroll) and row (255 - y + scroll). The
// cabinet orientation (MAME's ORIENTATION_FLIP_Y / FLIP_X) is the caller's:
// it chooses which bitmap line to render and the read direction.
//
// NOT HANDLED, flagged on `unsupported` for the line being rendered: a layer more than one page wide or
// tall (never seen in Lethal; MAME's multi-page flip has its own clipping),
// line-map pages (register 4), and layer association turned off.
//
// OUTPUT per layer per pixel: { colour[3:0], pixel[7:0] }, pixel 0 transparent.
// The pen is 1024 * PCU bank + 64 * { colour, 2'b00 } + pixel (lethal.cpp
// tile_callback with the gfx element's granularity of 16).

module lethal_tilemap (
    input               clk,
    input               rst,

    // 054156 registers, byte writes as lethal.cpp maps them (main 0x4000-0x403f):
    // reg_addr[5:1] the word, reg_addr[0] the byte (0 = high)
    input               reg_we,
    input        [5:0]  reg_addr,
    input        [7:0]  reg_din,

    // VRAM through the CPU window (bank4000 0x2000-0x3fff): plane 0 code low,
    // 1 code high, 2 attribute low, 3 attribute high, 2 KB each
    input               vram_we,
    input               vram_rd,
    input       [12:0]  vram_addr,          // { plane[1:0], tile[10:0] }
    input        [7:0]  vram_din,
    output reg   [7:0]  vram_dout,

    // render
    input               line_start,
    input        [8:0]  line_y,             // a bitmap line
    input               lb_rev,             // write the line buffer right to left
    output              busy,
    output reg          unsupported,
    output reg  [15:0]  dbg_lost,           // CPU writes to pages the game never uses

    // tile ROM, one pixel row per address: { code[15:0], y[2:0] }. rom_data[63:32] is
    // the row's four bytes from the region's first 2 MB, [31:0] from the second.
    output reg  [18:0]  rom_addr,
    output reg          rom_cs,
    input               rom_ok,
    input       [63:0]  rom_data,

    // line buffer read: column rd_x of the line rendered before, one cycle latency
    input        [8:0]  rd_x,
    output      [11:0]  rd_pix [4]
);

localparam [9:0] VIS_X0 = 10'd24, VIS_W = 10'd288;

// ------------------------------------------------------------ registers ---
reg [15:0] regs [32];

always @(posedge clk) begin
    if (reg_we) begin
        if (reg_addr[0]) regs[reg_addr[5:1]][ 7:0] <= reg_din;
        else             regs[reg_addr[5:1]][15:8] <= reg_din;
    end
end

wire [15:0] r_ctrl   = regs[0];
wire [15:0] r_flipen = regs[1];
wire [15:0] r_attr   = regs[3];
wire [15:0] r_scroll = regs[5];           // 0x0a: two bits a layer
wire        flipx    = r_ctrl[4];
wire        flipy    = r_ctrl[5];

// CPU page select (change_rambank): register 0x19, or the line-scroll page
// while register 0 bit 1 is set
wire [3:0] cpu_lpage = { regs[25][4:3], regs[25][1:0] };
reg  [2:0] cpu_ppage;
reg        cpu_ok;
always @* begin
    cpu_ok = 1'b1;
    if (r_ctrl[1]) cpu_ppage = 3'd4;
    else case (cpu_lpage)
        4'd0:    cpu_ppage = 3'd0;
        4'd1:    cpu_ppage = 3'd1;
        4'd4:    cpu_ppage = 3'd2;
        4'd5:    cpu_ppage = 3'd3;
        default: begin cpu_ppage = 3'd0; cpu_ok = 1'b0; end
    endcase
end

// a logical page's physical page, for the renderer
function automatic [3:0] ppage_of( input [3:0] lp );   // { valid, page[2:0] }
    case (lp)
        4'd0: ppage_of = 4'b1000;
        4'd1: ppage_of = 4'b1001;
        4'd4: ppage_of = 4'b1010;
        4'd5: ppage_of = 4'b1011;
        default: ppage_of = 4'b0000;
    endcase
endfunction

// -------------------------------------------------------------- render ---
typedef enum logic [3:0] { IDLE, SETUP, MOD_Y, FIX_Y, LS_RD, LS_Q, PREP, RUN } state_t;
typedef enum logic [2:0] { F_IDLE, F_VWAIT, F_VDATA, F_RWAIT, F_HOLD } fstate_t;
state_t  st;
fstate_t fst;

reg  [ 1:0] layer;
reg  [ 8:0] y;
reg  [11:0] height;          // rowspan * 256
reg  [11:0] width;           // colspan * 512
reg  [ 1:0] rowstart, colstart;
reg  [19:0] modv;
reg         modneg;
reg  [ 2:0] modk;
reg  [11:0] ay, my;
reg  [15:0] ls_x;
reg  [31:0] scan_q;
reg         lb_rev_l;

wire [15:0] l_ysc  = regs[16 + layer];
wire [15:0] l_xsc  = regs[20 + layer];
wire [15:0] l_rows = regs[8 + layer];
wire [15:0] l_cols = regs[12 + layer];

// Line scroll (tilemap_draw_common): mode 0 a word pair a line, 2 a pair per
// eight lines, 1 and 3 none. Lethal's pairs live in page 16 at layer * 0x400
// words (m_lsram_page's default), the X scroll in the pair's second word. The
// first line's pair is dy + corr_y, or 255 under flip Y, rounded down to eight for mode
// 2; the walk goes down under flip Y. Mode 2 under flip Y reads 0x1e0 + 14
// words further (K056832_DRAW_FLAG_MIRROR, which lethal.cpp passes).
wire [ 1:0] ls_mode  = r_scroll[{layer, 1'b0} +: 2];
wire        ls_on    = ls_mode == 2'd0 || ls_mode == 2'd2;
wire [ 8:0] ls_start0 = flipy ? 9'd255 : 9'(ydiff);
wire [ 8:0] ls_start  = ls_mode == 2'd2 ? { ls_start0[8:3], 3'd0 } : ls_start0;
wire [ 8:0] ls_grp    = ls_mode == 2'd2 ? 9'((10'(y) + 10'(ydiff[2:0])) >> 3) : y;
// word index of the pair, & 0x3ff; mode 0 steps 2 words a group, mode 2 sixteen
wire [ 9:0] ls_step   = ls_mode == 2'd2 ? { ls_grp[5:0], 4'd0 } : { ls_grp[8:0], 1'b0 };
wire [ 9:0] ls_widx   = flipy ? { ls_start, 1'b0 } - ls_step : { ls_start, 1'b0 } + ls_step;
wire [11:0] ls_word   = 12'(ls_widx) + ((ls_mode == 2'd2 && flipy) ? 12'h1ee : 12'h000) + 12'd1;
// the pair's second word, as an entry of page 16: { layer, word } / 2, low half
wire [11:0] ls_entry  = { layer, 10'd0 } + ls_word;    // a word of the page
wire [10:0] ls_tile   = ls_entry[11:1];

// Lethal's per-layer X offsets (lethal.cpp screen_update): -4, -2, 0, 2, and
// 167 less under flip X. The Y offsets are 0.
wire signed [9:0] offs_x = $signed({7'd0, layer, 1'b0}) - 10'sd4 - (flipx ? 10'sd167 : 10'sd0);

// MAME: ay = (dy + corr_y - offs_y) % height, corr_y the sign-extended 11-bit
// register 0x3c under flip Y; the X scroll gets corr_x, register 0x3a's 12 bits,
// under flip X, less the layer offset.
wire signed [16:0] corr_y = flipy ? $signed({{6{regs[30][10]}}, regs[30][10:0]}) : 17'sd0;
wire signed [16:0] ydiff  = $signed({l_ysc[15], l_ysc}) + corr_y;
wire signed [12:0] corr_x = flipx ? $signed({regs[29][11], regs[29][11:0]}) : 13'sd0;
wire        [15:0] xdiff  = (ls_on ? ls_x : l_xsc) + 16'($signed(corr_x)) - 16'($signed(offs_x));
wire        [11:0] sx     = xdiff[11:0] & (width - 12'd1);
// the map row: (y + ay), or (255 - y + ay) under flip Y, mod height
wire        [11:0] yb     = flipy ? 12'd255 - 12'(y) : 12'(y);
wire        [11:0] ysum   = yb + ay;
// one page tall (anything else is flagged): the row wraps at 256 either way
wire        [11:0] ly     = ysum & (height - 12'd1);
// the map column of the first pixel written: bitmap column 24 unflipped,
// 311 under flip X, which both give 24 + sx
wire        [11:0] xsum   = 12'(VIS_X0) + sx;
wire        [11:0] mx0    = xsum >= width ? xsum - width : xsum;

// Attribute decode, selected by register 3 bits 6-7
reg  [3:0] flips;
reg  [5:0] palm1, palm2;
reg  [1:0] pals2;
always @* begin
    case (r_attr[7:6])
        2'd0:    begin flips = 4'd6; palm1 = 6'h3f; pals2 = 2'd0; palm2 = 6'h00; end
        2'd1:    begin flips = 4'd4; palm1 = 6'h0f; pals2 = 2'd2; palm2 = 6'h30; end
        2'd2:    begin flips = 4'd2; palm1 = 6'h03; pals2 = 2'd2; palm2 = 6'h3c; end
        default: begin flips = 4'd0; palm1 = 6'h00; pals2 = 2'd2; palm2 = 6'h3f; end
    endcase
end

wire [15:0] attr    = scan_q[31:16];
wire [15:0] code    = scan_q[15:0];
wire [15:0] attr_sh = attr >> pals2;
wire [ 1:0] t_flip  = attr[flips +: 2] & r_flipen[{layer, 1'b0} +: 2];
wire [ 5:0] t_col   = (attr[5:0] & palm1) | (attr_sh[5:0] & palm2);
// my and the fetcher's columns are map coordinates, screen flip already applied
// in getting there, so only the tile's own flip reverses a row
wire [ 2:0] t_y     = t_flip[1] ? ~my[2:0] : my[2:0];

// fetcher
reg  [11:0] fmx;
reg  [ 6:0] fleft;
reg  [ 2:0] ftx;
reg  [ 3:0] fcol;
reg  [ 1:0] fflip;
reg  [63:0] frow;
wire [11:0] fnext = {fmx[11:3], 3'd0} + 12'd8;

reg         nb_valid;
reg  [63:0] nb_row;
reg  [ 3:0] nb_col;
reg  [ 1:0] nb_flip;
reg  [ 2:0] nb_tx;

reg         e_valid;
reg  [ 9:0] px;
reg  [ 2:0] tx;
reg  [ 1:0] flip;
reg  [ 3:0] colour;
reg  [63:0] row;

// charlayout8le: pixel = { second half's nibble, first half's nibble }; x 0..7
// take bytes 1, 1, 0, 0, 3, 3, 2, 2, high nibble first (x offsets 8, 12, 0, 4,
// 24, 28, 16, 20 bits, MSB-first numbering)
wire [2:0] pxi = flip[0] ? ~tx : tx;
function automatic [3:0] nib8le( input [31:0] r, input [2:0] x );
    reg [7:0] b;
    case (x[2:1])
        2'd0: b = r[23:16];        // byte 1
        2'd1: b = r[31:24];        // byte 0
        2'd2: b = r[ 7: 0];        // byte 3
        default: b = r[15:8];      // byte 2
    endcase
    nib8le = x[0] ? b[3:0] : b[7:4];
endfunction
wire [7:0] pixel = { nib8le(row[31:0], pxi), nib8le(row[63:32], pxi) };

wire last_px  = e_valid && px == VIS_W - 10'd1;
wire tile_end = e_valid && tx == 3'd7 && !last_px;
wire nb_take  = nb_valid && (!e_valid || tile_end);
wire nb_free  = !nb_valid || nb_take;

// ------------------------------------------------------ VRAM, line buffers ---
// 5 pages x 2048 entries x { attr, code }, as four byte-lane RAMs of 16K x 8
// (10K entries used). One read port shared by the CPU and the renderer.
// The renderer's map page is ((rowstart + my / 256) & 3) * 4 + ((colstart + mx / 512) & 3).
wire [ 3:0] map_page  = { 2'(rowstart + my[9:8]), 2'(colstart + fmx[10:9]) };
wire [ 3:0] map_pp    = ppage_of(map_page);
wire [13:0] tile_addr = { map_pp[2:0], my[7:3], fmx[8:3] };
wire        scan_rd   = st == RUN && fst == F_IDLE && fleft != 7'd0 && !vram_rd;
wire [13:0] ls_addr   = { 3'd4, ls_tile };
wire        ls_rd     = st == LS_RD && !vram_rd;
wire [13:0] cpu_addr  = { cpu_ppage, vram_addr[10:0] };
wire [13:0] rd_addr   = vram_rd ? cpu_addr : ls_rd ? ls_addr : tile_addr;
wire [31:0] ram_q;
reg         cpu_rd_l;
reg  [ 1:0] cpu_plane;

genvar b;
generate for (b = 0; b < 4; b++) begin : g_vram
    // lane b holds bits 8b+7..8b of { attr, code }: plane 0 -> lane 0, 1 -> 1, 2 -> 2, 3 -> 3
    lethal_sdpram #(.AW(14), .DW(8)) u_lane (
        .clk ( clk ),
        .we  ( vram_we && cpu_ok && vram_addr[12:11] == 2'(b) ),
        .wa  ( cpu_addr ),
        .d   ( vram_din ),
        .ra  ( rd_addr ),
        .q   ( ram_q[b*8 +: 8] )
    );
end endgenerate

always @(posedge clk) begin
    cpu_rd_l  <= vram_rd;
    cpu_plane <= vram_addr[12:11];
    if (cpu_rd_l) vram_dout <= ram_q[cpu_plane*8 +: 8];
    if (rst) dbg_lost <= 16'd0;
    else if (vram_we && !cpu_ok && dbg_lost != 16'hffff) dbg_lost <= dbg_lost + 16'd1;
end

reg        wr_half;
reg        lb_we;
reg [ 1:0] lb_layer;
reg [ 8:0] lb_px;
reg [11:0] lb_din;

genvar l;
generate for (l = 0; l < 4; l++) begin : g_lbuf
    lethal_sdpram #(.AW(10), .DW(12)) u_lbuf (
        .clk ( clk ),
        .we  ( lb_we && lb_layer == l ),
        .wa  ( {wr_half, lb_px} ),
        .d   ( lb_din ),
        .ra  ( {~wr_half, rd_x} ),
        .q   ( rd_pix[l] )
    );
end endgenerate

assign busy = st != IDLE;

always @(posedge clk) begin
    lb_we <= 1'b0;
    if (rst) begin
        st          <= IDLE;
        fst         <= F_IDLE;
        wr_half     <= 1'b0;
        rom_cs      <= 1'b0;
        nb_valid    <= 1'b0;
        e_valid     <= 1'b0;
        fleft       <= 7'd0;
        unsupported <= 1'b0;
    end else case (st)
        IDLE: if (line_start) begin
            unsupported <= 1'b0;      // reports the line being rendered
            wr_half  <= ~wr_half;
            y        <= line_y;
            lb_rev_l <= lb_rev;
            layer    <= 2'd0;
            st       <= SETUP;
        end
        SETUP: begin
            rowstart <= l_rows[4:3];
            colstart <= l_cols[4:3];
            height   <= { 1'b0, {1'b0, l_rows[1:0]} + 3'd1, 8'd0 };
            width    <= { {1'b0, l_cols[1:0]} + 3'd1, 9'd0 };
            modneg   <= ydiff < 0;
            modv     <= ydiff < 0 ? 20'(-ydiff) : 20'(ydiff);
            modk     <= 3'd7;
            if (l_rows[1:0] != 2'd0 || l_cols[1:0] != 2'd0 || regs[4][layer] == 1'b0)
                unsupported <= 1'b1;
            st       <= MOD_Y;
        end
        // |ydiff| mod height by repeated subtraction, height << 7 down to height
        MOD_Y: begin
            if (modv >= (20'(height) << modk)) modv <= modv - (20'(height) << modk);
            modk <= modk - 3'd1;
            if (modk == 3'd0) st <= FIX_Y;
        end
        FIX_Y: begin
            ay <= (modneg && modv != 0) ? height - modv[11:0] : modv[11:0];
            st <= LS_RD;
        end
        LS_RD: begin
            if (!ls_on) st <= PREP;
            else if (ls_rd) st <= LS_Q;
        end
        LS_Q: begin
            // the entry is { attr = word 2t, code = word 2t+1 }
            ls_x <= ls_word[0] ? ram_q[15:0] : ram_q[31:16];
            st   <= PREP;
        end
        PREP: begin
            my    <= ly;
            fmx   <= mx0;
            fleft <= 7'((11'(mx0[2:0]) + 11'(VIS_W) + 11'd7) >> 3);
            px    <= 10'd0;
            st    <= RUN;
        end
        RUN: begin
            case (fst)
                F_IDLE: if (scan_rd) fst <= F_VWAIT;
                F_VWAIT: begin
                    scan_q <= map_pp[3] ? ram_q : 32'd0;
                    fst    <= F_VDATA;
                end
                F_VDATA: begin
                    fflip    <= t_flip;
                    fcol     <= t_col[5:2];
                    ftx      <= fmx[2:0];
                    rom_addr <= { code, t_y };
                    fmx      <= fnext == width ? 12'd0 : fnext;
                    fleft    <= fleft - 7'd1;
                    rom_cs   <= 1'b1;
                    fst      <= F_RWAIT;
                end
                F_RWAIT: if (rom_ok) begin
                    frow   <= rom_data;
                    rom_cs <= 1'b0;
                    fst    <= F_HOLD;
                end
                F_HOLD: if (nb_free) fst <= F_IDLE;
                default: fst <= F_IDLE;
            endcase

            if (fst == F_HOLD && nb_free) begin
                nb_valid <= 1'b1;
                nb_row   <= frow;
                nb_col   <= fcol;
                nb_flip  <= fflip;
                nb_tx    <= ftx;
            end else if (nb_take) nb_valid <= 1'b0;

            if (e_valid) begin
                lb_we    <= 1'b1;
                lb_layer <= layer;
                lb_px    <= (flipx ^ lb_rev_l) ? 9'(VIS_W - 10'd1 - px) : px[8:0];
                lb_din   <= { colour, pixel };
                px       <= px + 10'd1;
                tx       <= tx + 3'd1;
            end
            if (nb_take) begin
                e_valid <= 1'b1;
                row     <= nb_row;
                colour  <= nb_col;
                flip    <= nb_flip;
                tx      <= nb_tx;
            end else if (tile_end) e_valid <= 1'b0;

            if (last_px) begin
                e_valid <= 1'b0;
                layer   <= layer + 2'd1;
                st      <= layer == 2'd3 ? IDLE : SETUP;
            end
        end
        default: st <= IDLE;
    endcase
end

endmodule

// Simple dual-port RAM: one write port, one registered read port.
module lethal_sdpram #(parameter AW = 10, DW = 8) (
    input               clk,
    input               we,
    input      [AW-1:0] wa,
    input      [DW-1:0] d,
    input      [AW-1:0] ra,
    output reg [DW-1:0] q
);
    reg [DW-1:0] mem [0:(1<<AW)-1];
    always @(posedge clk) begin
        if (we) mem[wa] <= d;
        q <= mem[ra];
    end
endmodule
