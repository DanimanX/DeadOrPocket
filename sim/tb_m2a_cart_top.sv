// tb_m2a_cart_top: REAL Sega Model 2A-CRX Compute Cartridge (i960_top + m2_cpu_bridge)
//                  <-- 30-Pin Virtual Analogue Pocket Cartridge Bus -->
//                  Analogue Pocket Render Side (m2_cart_bus + m2_video + u_tram/u_pal)
//
// Boots REAL Model 2A-CRX ROMs (Dead or Alive `doaab.rom`, Virtua Fighter 2 `vf2.rom`)
// on the real Intel i960KB + m2_cpu_bridge and streams real CPU video writes (Tile RAM,
// Palette, Xlat, Char RAM, Texture Sheets, 3D LUTs) across the 30-pin bus into Pocket!
`default_nettype none

module tb_m2a_cart_top (
	input  wire        clk_mem,        // 95.91 MHz Pocket video/mem clock
	input  wire        clk_sys,        // 73.77 MHz Pocket sys clock
	input  wire        clk_cart,       // 31.97 MHz 30-pin Cartridge Slot Bus clock
	input  wire        clk_cpu,        // 25.00 MHz Cartridge i960 CPU clock
	input  wire        rst_n,
	input  wire        cpu_rst_n,

	// ---- Cartridge 128 MB SDRAM behavioral port (backed in C++ for instant ROM load) ----
	output wire        csd_req_o,
	output wire        csd_we_o,
	output wire [26:1] csd_addr_o,
	output wire [15:0] csd_din_o,
	output wire  [1:0] csd_be_o,
	input  wire [63:0] csd_dout_i,
	input  wire        csd_ack_i,

	// ---- Cartridge i960 I/O peripheral port (handled in C++ model) ---------
	output wire        io_sel_o,
	output wire        io_we_o,
	output wire [31:0] io_addr_o,
	output wire [31:0] io_wdata_o,
	output wire  [3:0] io_be_o,
	input  wire [31:0] io_rdata_i,
	input  wire        io_stall_i,
	input  wire  [3:0] irq_i,
	input  wire        prog_ext_i,

	// ---- Pocket Controller Inputs (sent over CH3 to Cartridge) -------------
	input  wire [31:0] p_pad_key,
	input  wire [31:0] p_pad_joy,
	input  wire [15:0] p_pad_trig,

	// ---- Cartridge CPU & Bus Telemetry -------------------------------------
	output wire [31:0] dbg_pc_o,
	output wire [31:0] dbg_ip_o,
	output wire [31:0] dbg_acc_cnt_o,
	output wire        trap_o,
	output wire        halted_o,
	output wire [31:0] dbg_tram_wr_o,
	output wire [31:0] dbg_pal_wr_o,
	output wire        c_vsync_o,
	output wire [31:0] c_pad_key_o,
	output wire        c_pad_valid_o,

	// ---- Pocket Video & Bus Verification Outputs ---------------------------
	output wire        ce_pix_o,
	output wire  [9:0] vid_x_o,
	output wire  [9:0] vid_y_o,
	output wire        vid_de_o,
	output wire        vid_vs_o,
	output wire [23:0] vid_rgb_o,
	output wire        cart_detected_o,
	output wire [31:0] dbg_tx_words_o,
	output wire [31:0] dbg_rx_words_o,
	output wire [31:0] dbg_tx_ch1_o,
	output wire [31:0] dbg_rx_ch3_o,
	output reg  [31:0] bus_contention_cnt = 32'd0,
	output reg  [31:0] pocket_tram_writes = 32'd0,
	output reg  [31:0] pocket_pal_writes  = 32'd0,
	output reg  [31:0] pocket_sd_writes   = 32'd0
);

	// -------------------------------------------------------------------------
	// 1. REAL Model 2A-CRX Compute Cartridge: i960_top + m2_cpu_bridge
	// -------------------------------------------------------------------------
	wire        bus_req, bus_ifetch, bus_we, bus_ack;
	wire [31:0] bus_addr, bus_wdata, bus_rdata;
	wire  [3:0] bus_be;

	i960_top #(
		.FP_SUBN ( 2 ),
		.RC_RING ( 1 ),
		.FR      ( 1'b1 ),
		.F2A     ( 1'b1 ),
		.IC_HUF  ( 1'b1 ),
		.IC_ER   ( 1'b1 ),
		.PF2W    ( 1'b1 )
	) u_cpu (
		.clk(clk_cpu), .rst_n(cpu_rst_n), .vc_en(1'b1),
		.bus_req(bus_req), .bus_ifetch(bus_ifetch), .bus_we(bus_we),
		.bus_addr(bus_addr), .bus_be(bus_be),
		.bus_wdata(bus_wdata), .bus_rdata(bus_rdata), .bus_ack(bus_ack),
		.irq(irq_i),
		.dbg_pc(dbg_pc_o), .dbg_ip(dbg_ip_o), .dbg_acc_cnt(dbg_acc_cnt_o),
		.trap(trap_o), .halted(halted_o),
		.dbg_sat(), .dbg_prcb(), .dbg_icr(), .dbg_intr_cnt(), .dbg_intr_work(),
		.dbg_insn(), .trap_op(), .dbg_rip(), .dbg_pfp(), .dbg_ts(), .dbg_rcache_pos(),
		.dbg_to_memory(), .dbg_rf_req(), .dbg_rf_ack(), .dbg_rf_addr(),
		.dbg_rf_we(), .dbg_rf_wdata()
	);

	// Local Cartridge 2D shadow RAMs so i960 readbacks of TRAM/PAL stay 0-latency!
	wire        oc_tram_we, oc_pal_we, oc_xlat_we, char_wr, tex_inval;
	wire [14:0] oc_addr;
	wire [15:0] oc_din, oc_tram_q, oc_pal_q;
	wire [17:0] char_wr_addr;
	wire  [6:0] oc_xlat_addr;
	wire  [7:0] oc_xlat_din;

	m2_tdp_ram2c #(.DW(16), .AW(15)) u_cart_tram (
		.a_clk(clk_mem), .a_addr(oc_addr), .a_din(oc_din), .a_we(oc_tram_we), .a_q(oc_tram_q),
		.b_clk(clk_mem), .b_addr(15'd0), .b_q()
	);
	m2_tdp_ram2c #(.DW(16), .AW(12)) u_cart_pal (
		.a_clk(clk_mem), .a_addr(oc_addr[11:0]), .a_din(oc_din), .a_we(oc_pal_we), .a_q(oc_pal_q),
		.b_clk(clk_mem), .b_addr(12'd0), .b_q()
	);

	// Model 2A-CRX SDRAM word-address map (128 MB, AW=26, matching Model2.sv M2A layout)
	localparam [26:1] GAME_PROG   = 26'h000_0000;
	localparam [26:1] GAME_DATA   = 26'h004_0000; // byte 0x0080000
	localparam [26:1] GAME_PROGXB = 26'h12C_0000; // byte 0x2580000 (extension - 0x40000 words -> 0x2600000)
	localparam [26:1] GAME_WORK   = 26'h180_0000; // byte 0x3000000 (1 MB work RAM)
	localparam [26:1] GAME_BOARD  = 26'h188_0000; // byte 0x3100000 (256 KB board RAM)
	localparam [26:1] GAME_CHAR   = 26'h190_0000; // byte 0x3200000 (1 MB char RAM)
	localparam [26:1] GAME_BUFFER = 26'h198_0000; // byte 0x3300000 (128 KB buffer RAM)
	localparam [26:1] GAME_PAL3D  = 26'h19C_0000;
	localparam [26:1] GAME_XLAT3D = 26'h19D_0000;
	localparam [26:1] GAME_TEXS0  = 26'h1A0_0000; // 1 MB TEXS0
	localparam [26:1] GAME_TEXS1  = 26'h1A8_0000; // 1 MB TEXS1
	localparam [26:1] GAME_LUMA   = 26'h1B0_0000; // 32K words luma

	m2_cpu_bridge #(
		.DCACHE_EN ( 1'b1 ),
		.BUFFERRAM ( 1'b1 ),
		.AW        ( 26 ),
		.BOARD_2A  ( 1'b1 ),
		.ASYNC     ( 1'b1 )
	) u_bridge (
		.clk_cpu(clk_cpu), .rst_n_cpu(cpu_rst_n),
		.bus_req(bus_req), .bus_ifetch(bus_ifetch), .bus_we(bus_we),
		.bus_addr(bus_addr), .bus_be(bus_be), .bus_wdata(bus_wdata),
		.bus_rdata(bus_rdata), .bus_ack(bus_ack),
		.clk_mem(clk_mem), .rst_n_mem(rst_n),
		.base_prog(GAME_PROG), .prog_ext(prog_ext_i), .base_progx(GAME_PROGXB),
		.base_data(GAME_DATA), .base_work(GAME_WORK), .base_board(GAME_BOARD),
		.base_char(GAME_CHAR), .base_buffer(GAME_BUFFER),
		.base_pal3d(GAME_PAL3D), .base_xlat3d(GAME_XLAT3D),
		.base_texs0(GAME_TEXS0), .base_texs1(GAME_TEXS1), .base_luma(GAME_LUMA),
		.sd_req(csd_req_o), .sd_we(csd_we_o), .sd_addr(csd_addr_o),
		.sd_din(csd_din_o), .sd_be(csd_be_o), .sd_dout(csd_dout_i), .sd_ack(csd_ack_i),
		.oc_tram_we(oc_tram_we), .oc_pal_we(oc_pal_we), .oc_addr(oc_addr),
		.oc_din(oc_din), .oc_tram_q(oc_tram_q), .oc_pal_q(oc_pal_q),
		.char_wr(char_wr), .char_wr_addr(char_wr_addr),
		.oc_xlat_we(oc_xlat_we), .oc_xlat_addr(oc_xlat_addr), .oc_xlat_din(oc_xlat_din),
		.col_inval(), .buf_inval(), .tex_inval(tex_inval),
		.io_rdata(io_rdata_i), .io_stall(io_stall_i), .buf_wr_stall(1'b0),
		.io_sel(io_sel_o), .io_we(io_we_o), .io_addr(io_addr_o),
		.io_wdata(io_wdata_o), .io_be(io_be_o),
		.dbg_cpu_reads(), .dbg_cpu_writes(), .dbg_unmapped(),
		.dbg_last_addr(), .dbg_last_dout(), .dbg_probe6(), .dbg_probe2(),
		.dbg_tram_wr(dbg_tram_wr_o), .dbg_pal_wr(dbg_pal_wr_o)
	);

	// -------------------------------------------------------------------------
	// 2. Live Cartridge Video-Write Snooper -> m2_cart_host CH1 (clk_mem)
	//    Captures real i960 writes to TRAM, PAL, XLAT, CHAR_RAM, TEXS0/1
	//    into a 1024-deep FIFO so the CPU never stalls on bus bursts.
	// -------------------------------------------------------------------------
	wire is_sd_wr_fire = csd_req_o && csd_we_o && csd_ack_i;
	wire is_char_sd = is_sd_wr_fire && (csd_addr_o >= GAME_CHAR)  && (csd_addr_o < GAME_CHAR  + 26'h08_0000);
	wire is_tex0_sd = is_sd_wr_fire && (csd_addr_o >= GAME_TEXS0) && (csd_addr_o < GAME_TEXS0 + 26'h08_0000);
	wire is_tex1_sd = is_sd_wr_fire && (csd_addr_o >= GAME_TEXS1) && (csd_addr_o < GAME_TEXS1 + 26'h08_0000);

	wire        snoop_wr = oc_tram_we || oc_pal_we || oc_xlat_we || is_char_sd || is_tex0_sd || is_tex1_sd;
	reg   [3:0] snoop_kind;
	reg  [24:0] snoop_addr;
	reg  [15:0] snoop_data;
	always @(*) begin
		if (oc_tram_we) begin
			snoop_kind = 4'd0; snoop_addr = {10'd0, oc_addr}; snoop_data = oc_din;
		end else if (oc_pal_we) begin
			snoop_kind = 4'd1; snoop_addr = {13'd0, oc_addr[11:0]}; snoop_data = oc_din;
		end else if (oc_xlat_we) begin
			snoop_kind = 4'd2; snoop_addr = {18'd0, oc_xlat_addr}; snoop_data = {8'd0, oc_xlat_din};
		end else if (is_char_sd) begin
			snoop_kind = 4'd5; snoop_addr = 25'h080_0000 + (csd_addr_o[24:1] - GAME_CHAR[24:1]); snoop_data = csd_din_o;
		end else if (is_tex0_sd) begin
			snoop_kind = 4'd5; snoop_addr = 25'h000_0000 + (csd_addr_o[24:1] - GAME_TEXS0[24:1]); snoop_data = csd_din_o;
		end else begin
			snoop_kind = 4'd5; snoop_addr = 25'h020_0000 + (csd_addr_o[24:1] - GAME_TEXS1[24:1]); snoop_data = csd_din_o;
		end
	end

	wire [44:0] sf_dout;
	wire        sf_empty, sf_full;
	wire        host_w_ready;
	dcfifo #(
		.lpm_numwords(1024), .lpm_showahead("ON"), .lpm_width(45), .lpm_widthu(10)
	) u_snoop_fifo (
		.data({snoop_kind, snoop_addr, snoop_data}), .wrclk(clk_mem), .wrreq(snoop_wr && !sf_full),
		.rdclk(clk_mem), .rdreq(!sf_empty && host_w_ready), .q(sf_dout),
		.rdempty(sf_empty), .wrfull(sf_full), .aclr(!rst_n),
		.eccstatus(), .rdfull(), .rdusedw(), .wrempty(), .wrusedw()
	);

	// -------------------------------------------------------------------------
	// 3. Virtual 30-Pin Analogue Pocket Cartridge Bus + Contention Checker
	// -------------------------------------------------------------------------
	wire [7:4] cart_tran_bank0;
	wire       cart_tran_bank0_dir, cart_tran_bank1_dir, cart_tran_bank2_dir, cart_tran_bank3_dir;
	wire [7:0] cart_tran_bank1, cart_tran_bank2, cart_tran_bank3;
	wire       cart_tran_pin30, cart_tran_pin30_dir, cart_pin30_pwroff_reset;
	wire       cart_tran_pin31, cart_tran_pin31_dir;
	wire       host_pin31_o, host_b1_oe, host_b2_oe, host_b3_oe;
	wire [7:0] host_b1_o, host_b2_o, host_b3_o;

	assign cart_tran_pin31 = host_pin31_o;
	assign cart_tran_bank1 = host_b1_oe ? host_b1_o : 8'hzz;
	assign cart_tran_bank2 = host_b2_oe ? host_b2_o : 8'hzz;
	assign cart_tran_bank3 = host_b3_oe ? host_b3_o : 8'hzz;

	always @(posedge clk_cart or negedge rst_n) begin
		if (!rst_n) bus_contention_cnt <= 32'd0;
		else if ((cart_tran_bank1_dir && host_b1_oe) ||
		         (cart_tran_bank2_dir && host_b2_oe) ||
		         (cart_tran_bank3_dir && host_b3_oe))
			bus_contention_cnt <= bus_contention_cnt + 32'd1;
	end

	m2_cart_host u_cart_host (
		.clk_core(clk_mem), .rst_n(rst_n),
		.cart_bank0_i(cart_tran_bank0), .cart_pin30_i(cart_tran_pin30), .cart_pin31_o(host_pin31_o),
		.cart_bank1_i(cart_tran_bank1), .cart_bank1_o(host_b1_o), .cart_bank1_oe(host_b1_oe),
		.cart_bank2_i(cart_tran_bank2), .cart_bank2_o(host_b2_o), .cart_bank2_oe(host_b2_oe),
		.cart_bank3_i(cart_tran_bank3), .cart_bank3_o(host_b3_o), .cart_bank3_oe(host_b3_oe),
		.frame_start(1'b0), .frame_tag(4'd0),
		.q_valid(1'b0), .q_ready(),
		.q_x0(16'sd0), .q_y0(16'sd0), .q_x1(16'sd0), .q_y1(16'sd0),
		.q_x2(16'sd0), .q_y2(16'sd0), .q_x3(16'sd0), .q_y3(16'sd0),
		.q_col(24'd0), .q_z(32'd0), .q_moire(1'b0),
		.q_oz0(16'd0), .q_oz1(16'd0), .q_oz2(16'd0), .q_oz3(16'd0), .q_frac(16'd0),
		.q_u0(13'd0), .q_v0(13'd0), .q_u1(13'd0), .q_v1(13'd0),
		.q_u2(13'd0), .q_v2(13'd0), .q_u3(13'd0), .q_v3(13'd0),
		.q_tex(27'd0), .q_uvs(2'd0), .q_mipz(1'b0), .q_end(1'b0),
		.w_valid(!sf_empty), .w_ready(host_w_ready),
		.w_kind(sf_dout[44:41]), .w_addr(sf_dout[40:16]), .w_data(sf_dout[15:0]),
		.audio_stb(1'b0), .audio_l(16'd0), .audio_r(16'd0),
		.vsync_o(c_vsync_o), .pad_key_o(c_pad_key_o), .pad_joy_o(), .pad_trig_o(), .pad_valid_o(c_pad_valid_o),
		.dbg_tx_words(dbg_tx_words_o), .dbg_tx_quads(), .dbg_tx_ch1(dbg_tx_ch1_o),
		.dbg_tx_audio(), .dbg_rx_ch3(dbg_rx_ch3_o)
	);

	// -------------------------------------------------------------------------
	// 4. Pocket Side: m2_cart_bus + u_tram + u_pal + m2_video (496x384)
	// -------------------------------------------------------------------------
	wire vid_vblank_irq;
	reg  vb_tog_m = 1'b0;
	always @(posedge clk_mem or negedge rst_n) begin
		if (!rst_n)              vb_tog_m <= 1'b0;
		else if (vid_vblank_irq) vb_tog_m <= ~vb_tog_m;
	end
	reg [2:0] vb_sync_s = 3'd0;
	always @(posedge clk_sys or negedge rst_n) begin
		if (!rst_n) vb_sync_s <= 3'd0;
		else        vb_sync_s <= {vb_sync_s[1:0], vb_tog_m};
	end
	wire vblank_pulse_sys = vb_sync_s[2] ^ vb_sync_s[1];

	wire        p_tram_we, p_pal_we, p_xlat_we, p_sd_wreq;
	wire [14:0] p_tram_waddr;
	wire [15:0] p_tram_wdin, p_pal_wdin, p_sd_wdin;
	wire [11:0] p_pal_waddr;
	wire  [6:0] p_xlat_waddr;
	wire  [7:0] p_xlat_wdin;
	wire [25:1] p_sd_waddr;

	m2_cart_bus u_cart_bus (
		.clk_cart(clk_cart), .clk_sys(clk_sys), .clk_mem(clk_mem), .rst_n(rst_n),
		.cart_tran_bank0(cart_tran_bank0), .cart_tran_bank0_dir(cart_tran_bank0_dir),
		.cart_tran_bank1(cart_tran_bank1), .cart_tran_bank1_dir(cart_tran_bank1_dir),
		.cart_tran_bank2(cart_tran_bank2), .cart_tran_bank2_dir(cart_tran_bank2_dir),
		.cart_tran_bank3(cart_tran_bank3), .cart_tran_bank3_dir(cart_tran_bank3_dir),
		.cart_tran_pin30(cart_tran_pin30), .cart_tran_pin30_dir(cart_tran_pin30_dir),
		.cart_pin30_pwroff_reset(cart_pin30_pwroff_reset),
		.cart_tran_pin31(cart_tran_pin31), .cart_tran_pin31_dir(cart_tran_pin31_dir),
		.vsync_pulse_sys(vblank_pulse_sys),
		.pad_key_sys(p_pad_key), .pad_joy_sys(p_pad_joy), .pad_trig_sys(p_pad_trig),
		.cart_detected(cart_detected_o), .dbg_rx_words(dbg_rx_words_o),
		.q_valid(), .q_ready(1'b1),
		.q_x0(), .q_y0(), .q_x1(), .q_y1(), .q_x2(), .q_y2(), .q_x3(), .q_y3(),
		.q_col(), .q_z(), .q_moire(), .q_oz0(), .q_oz1(), .q_oz2(), .q_oz3(), .q_frac(),
		.q_u0(), .q_v0(), .q_u1(), .q_v1(), .q_u2(), .q_v2(), .q_u3(), .q_v3(),
		.q_tex(), .q_uvs(), .q_mipz(), .q_end(), .q_tag(), .frame_start_cart(),
		.tram_we(p_tram_we), .tram_addr(p_tram_waddr), .tram_din(p_tram_wdin),
		.pal_we(p_pal_we), .pal_addr(p_pal_waddr), .pal_din(p_pal_wdin),
		.xlat_we(p_xlat_we), .xlat_addr(p_xlat_waddr), .xlat_din(p_xlat_wdin),
		.lut_we(), .lut_sel(), .lut_addr(), .lut_data(),
		.sd_wreq(p_sd_wreq), .sd_waddr(p_sd_waddr), .sd_wdin(p_sd_wdin),
		.sd_wack(1'b1), .tex_inval_cart(), .char_inval_cart(),
		.audio_l(), .audio_r(), .audio_stb()
	);

	// Pocket-side Char RAM backing array (1 MB = 512K x 16-bit) receiving CH1 SDRAM writes
	reg [15:0] pocket_char_ram [0:524287];
	always @(posedge clk_sys or negedge rst_n) begin
		if (!rst_n) begin
			pocket_tram_writes <= 32'd0;
			pocket_pal_writes  <= 32'd0;
			pocket_sd_writes   <= 32'd0;
		end else begin
			if (p_tram_we) pocket_tram_writes <= pocket_tram_writes + 32'd1;
			if (p_pal_we)  pocket_pal_writes  <= pocket_pal_writes  + 32'd1;
			if (p_sd_wreq) begin
				pocket_sd_writes <= pocket_sd_writes + 32'd1;
				if (p_sd_waddr[25:20] == 6'b001000)
					pocket_char_ram[p_sd_waddr[19:1]] <= p_sd_wdin;
			end
		end
	end

	// Pocket 2D Tilemap Pipeline (m2_video)
	reg [2:0] ce_div = 3'd0;
	always @(posedge clk_mem or negedge rst_n) begin
		if (!rst_n)              ce_div <= 3'd0;
		else if (ce_div == 3'd5) ce_div <= 3'd0;
		else                     ce_div <= ce_div + 3'd1;
	end
	assign ce_pix_o = (ce_div == 3'd0);

	wire [14:0] tram_raddr;
	wire [15:0] tram_rdata;
	wire [11:0] pal_raddr;
	wire [15:0] pal_rdata;
	m2_tdp_ram2c #(.DW(16), .AW(15)) u_p_tram (
		.a_clk(clk_sys), .a_addr(p_tram_waddr), .a_din(p_tram_wdin), .a_we(p_tram_we), .a_q(),
		.b_clk(clk_mem), .b_addr(tram_raddr), .b_q(tram_rdata)
	);
	m2_tdp_ram2c #(.DW(16), .AW(12)) u_p_pal (
		.a_clk(clk_sys), .a_addr(p_pal_waddr), .a_din(p_pal_wdin), .a_we(p_pal_we), .a_q(),
		.b_clk(clk_mem), .b_addr(pal_raddr), .b_q(pal_rdata)
	);

	wire        char_req;
	wire [17:0] char_addr;
	reg         char_ack = 1'b0;
	reg  [31:0] char_data = 32'd0;
	always @(posedge clk_mem) begin
		char_ack <= char_req;
		if (char_req) begin
			char_data <= {pocket_char_ram[{char_addr, 1'b1}], pocket_char_ram[{char_addr, 1'b0}]};
		end
	end

	wire       vid_hb_m, vid_vb_m, vid_hs_m;
	wire [7:0] vid_r_m, vid_g_m, vid_b_m;

	m2_video #(
		.COLUMNS(62), .LB_RING(1'b1), .HSCR_FIX(1'b1),
		.SCR_SYNC(1'b1), .SCR_STEP(1'b1), .SCR_DEPTH(2), .MASK_SKIP(1'b1)
	) u_tilemap (
		.clk(clk_mem), .ce_pix(ce_pix_o), .rst_n(rst_n),
		.tile_mask(14'h3FFF), .gamma_sel(2'd0),
		.xlat_clk(clk_sys), .xlat_we(p_xlat_we), .xlat_addr(p_xlat_waddr), .xlat_din(p_xlat_wdin),
		.tram_addr(tram_raddr), .tram_data(tram_rdata),
		.char_req(char_req), .char_addr(char_addr), .char_data(char_data), .char_ack(char_ack),
		.pal_addr(pal_raddr), .pal_data(pal_rdata),
		.vid_cat1(), .vid_r(vid_r_m), .vid_g(vid_g_m), .vid_b(vid_b_m),
		.vid_hs(vid_hs_m), .vid_vs(vid_vs_o), .vid_hb(vid_hb_m), .vid_vb(vid_vb_m),
		.vblank_irq(vid_vblank_irq),
		.dbg_fetches(), .dbg_overruns(), .dbg_ovr_frame(), .dbg_layer_px(),
		.dbg_hscr(), .dbg_vscr(), .dbg_layer_have(),
		.vid_x(vid_x_o), .vid_y(vid_y_o),
		.interlace(1'b0), .scr_flip(1'b0), .scr_tag(4'd0), .scr_vtgl(1'b0), .scr_ttag(4'd0),
		.ntsc_lines(1'b0), .mid_lines(1'b0), .narrow(1'b0), .vid_field()
	);

	assign vid_de_o  = ~(vid_hb_m | vid_vb_m);
	assign vid_rgb_o = {vid_r_m, vid_g_m, vid_b_m};

endmodule
`default_nettype wire
