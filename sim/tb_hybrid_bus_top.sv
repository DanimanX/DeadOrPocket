// tb_hybrid_bus_top: Full Cycle-Accurate Co-Simulation Harness for DeadOrPocket Phase 2
//
// Connects:
//   [Compute Cartridge Side: m2_cart_host]
//        <-- Virtual 30-Pin Analogue Pocket Cartridge Bus (with live contention checker) -->
//   [Analogue Pocket Render Side: m2_cart_bus + m2_raster3d + m2_fb_psram +
//    2x psram_phy + 2x psram_cell_model + m2_video + m2_char_cache +
//    m2_tdp_ram2c (tram/pal) + m2_sdram (8p) + sdram_model (JEDEC checker)]
//
`default_nettype none

module tb_hybrid_bus_top (
	input  wire        clk_mem,        // 95.91 MHz (SDRAM + PSRAM PHY + 2D video)
	input  wire        clk_sys,        // 73.77 MHz (m2_raster3d + FB + Cart Bus demux)
	input  wire        clk_cart,       // 31.97 MHz (30-pin Cartridge Slot Bus)
	input  wire        clk_core,       // 80.00 MHz (Compute Cartridge CPU/Geometry)
	input  wire        rst_n,

	// ---- Compute Cartridge Producer Inputs (clk_core) ----------------------
	input  wire        c_frame_start,
	input  wire  [3:0] c_frame_tag,
	input  wire        c_q_valid,
	output wire        c_q_ready,
	input  wire signed [15:0] c_q_x0, c_q_y0, c_q_x1, c_q_y1,
	input  wire signed [15:0] c_q_x2, c_q_y2, c_q_x3, c_q_y3,
	input  wire [23:0] c_q_col,
	input  wire [31:0] c_q_z,
	input  wire        c_q_moire,
	input  wire [15:0] c_q_oz0, c_q_oz1, c_q_oz2, c_q_oz3, c_q_frac,
	input  wire [12:0] c_q_u0, c_q_v0, c_q_u1, c_q_v1,
	input  wire [12:0] c_q_u2, c_q_v2, c_q_u3, c_q_v3,
	input  wire [26:0] c_q_tex,
	input  wire  [1:0] c_q_uvs,
	input  wire        c_q_mipz,
	input  wire        c_q_end,

	input  wire        c_w_valid,
	output wire        c_w_ready,
	input  wire  [3:0] c_w_kind,
	input  wire [24:0] c_w_addr,
	input  wire [15:0] c_w_data,

	input  wire        c_audio_stb,
	input  wire [15:0] c_audio_l,
	input  wire [15:0] c_audio_r,

	// ---- Compute Cartridge CH3 Outputs (received from Pocket) --------------
	output wire        c_vsync_o,
	output wire [31:0] c_pad_key_o,
	output wire [31:0] c_pad_joy_o,
	output wire [15:0] c_pad_trig_o,
	output wire        c_pad_valid_o,

	// ---- Pocket Controller Inputs (sent over CH3 to Cartridge) -------------
	input  wire [31:0] p_pad_key,
	input  wire [31:0] p_pad_joy,
	input  wire [15:0] p_pad_trig,

	// ---- Pocket Video & Audio Outputs --------------------------------------
	output wire        ce_pix_o,
	output wire  [9:0] vid_x_o,
	output wire  [9:0] vid_y_o,
	output wire        vid_de_o,
	output wire        vid_vs_o,
	output wire        vid_hs_o,
	output wire [23:0] vid_rgb_o,
	output wire        scan_hit_o,
	output wire        vid_cat1_o,
	output wire [15:0] p_audio_l_o,
	output wire [15:0] p_audio_r_o,
	output wire        p_audio_stb_o,

	// ---- Status, Telemetry & Protocol Checkers -----------------------------
	output wire        sdram_ready_o,
	output wire        fb_ready_o,
	output wire        cart_detected_o,
	output wire [31:0] dbg_tx_words_o,
	output wire [31:0] dbg_rx_words_o,
	output wire [31:0] dbg_tx_quads_o,
	output wire [31:0] dbg_tx_ch1_o,
	output wire [31:0] dbg_tx_audio_o,
	output wire [31:0] dbg_rx_ch3_o,
	output reg  [31:0] bus_contention_cnt = 32'd0,
	output wire [31:0] sdram_violations_o,
	output wire [31:0] sdram_reads_o,
	output wire [31:0] sdram_writes_o,
	output wire [31:0] dbg_state_o,
	output wire [31:0] dbg_r3d_0_o,
	output wire [31:0] dbg_r3d_1_o
);

	// -------------------------------------------------------------------------
	// 1. Virtual 30-Pin Analogue Pocket Cartridge Slot Wires + Contention Monitor
	// -------------------------------------------------------------------------
	wire [7:4] cart_tran_bank0;
	wire       cart_tran_bank0_dir;
	wire [7:0] cart_tran_bank1;
	wire       cart_tran_bank1_dir;
	wire [7:0] cart_tran_bank2;
	wire       cart_tran_bank2_dir;
	wire [7:0] cart_tran_bank3;
	wire       cart_tran_bank3_dir;
	wire       cart_tran_pin30, cart_tran_pin30_dir, cart_pin30_pwroff_reset;
	wire       cart_tran_pin31, cart_tran_pin31_dir;

	wire       host_pin31_o;
	wire [7:0] host_b1_o, host_b2_o, host_b3_o;
	wire       host_b1_oe, host_b2_oe, host_b3_oe;

	assign cart_tran_pin31 = host_pin31_o;
	assign cart_tran_bank1 = host_b1_oe ? host_b1_o : 8'hzz;
	assign cart_tran_bank2 = host_b2_oe ? host_b2_o : 8'hzz;
	assign cart_tran_bank3 = host_b3_oe ? host_b3_o : 8'hzz;

	// Live electrical contention detector on bidirectional level-translated banks
	// Note: Pocket drives only when cart_tran_bank1_dir==1 (actually 1 cycle later),
	// Cart drives only when host_b1_oe==1 (!bus_dir). Both high simultaneously = contention!
	always @(posedge clk_cart or negedge rst_n) begin
		if (!rst_n) begin
			bus_contention_cnt <= 32'd0;
		end else begin
			if ((cart_tran_bank1_dir && host_b1_oe) ||
			    (cart_tran_bank2_dir && host_b2_oe) ||
			    (cart_tran_bank3_dir && host_b3_oe)) begin
				bus_contention_cnt <= bus_contention_cnt + 32'd1;
			end
		end
	end

	// -------------------------------------------------------------------------
	// 2. Compute Cartridge Side: m2_cart_host
	// -------------------------------------------------------------------------
	m2_cart_host u_cart_host (
		.clk_core      ( clk_core ),
		.rst_n         ( rst_n ),
		.cart_bank0_i  ( cart_tran_bank0 ),
		.cart_pin30_i  ( cart_tran_pin30 ),
		.cart_pin31_o  ( host_pin31_o ),
		.cart_bank1_i  ( cart_tran_bank1 ),
		.cart_bank1_o  ( host_b1_o ),
		.cart_bank1_oe ( host_b1_oe ),
		.cart_bank2_i  ( cart_tran_bank2 ),
		.cart_bank2_o  ( host_b2_o ),
		.cart_bank2_oe ( host_b2_oe ),
		.cart_bank3_i  ( cart_tran_bank3 ),
		.cart_bank3_o  ( host_b3_o ),
		.cart_bank3_oe ( host_b3_oe ),
		.frame_start   ( c_frame_start ),
		.frame_tag     ( c_frame_tag ),
		.q_valid       ( c_q_valid ),
		.q_ready       ( c_q_ready ),
		.q_x0(c_q_x0), .q_y0(c_q_y0), .q_x1(c_q_x1), .q_y1(c_q_y1),
		.q_x2(c_q_x2), .q_y2(c_q_y2), .q_x3(c_q_x3), .q_y3(c_q_y3),
		.q_col(c_q_col), .q_z(c_q_z), .q_moire(c_q_moire),
		.q_oz0(c_q_oz0), .q_oz1(c_q_oz1), .q_oz2(c_q_oz2), .q_oz3(c_q_oz3),
		.q_frac(c_q_frac),
		.q_u0(c_q_u0), .q_v0(c_q_v0), .q_u1(c_q_u1), .q_v1(c_q_v1),
		.q_u2(c_q_u2), .q_v2(c_q_v2), .q_u3(c_q_u3), .q_v3(c_q_v3),
		.q_tex(c_q_tex), .q_uvs(c_q_uvs), .q_mipz(c_q_mipz), .q_end(c_q_end),
		.w_valid       ( c_w_valid ),
		.w_ready       ( c_w_ready ),
		.w_kind        ( c_w_kind ),
		.w_addr        ( c_w_addr ),
		.w_data        ( c_w_data ),
		.audio_stb     ( c_audio_stb ),
		.audio_l       ( c_audio_l ),
		.audio_r       ( c_audio_r ),
		.vsync_o       ( c_vsync_o ),
		.pad_key_o     ( c_pad_key_o ),
		.pad_joy_o     ( c_pad_joy_o ),
		.pad_trig_o    ( c_pad_trig_o ),
		.pad_valid_o   ( c_pad_valid_o ),
		.dbg_tx_words  ( dbg_tx_words_o ),
		.dbg_tx_quads  ( dbg_tx_quads_o ),
		.dbg_tx_ch1    ( dbg_tx_ch1_o ),
		.dbg_tx_audio  ( dbg_tx_audio_o ),
		.dbg_rx_ch3    ( dbg_rx_ch3_o )
	);

	// -------------------------------------------------------------------------
	// 3. Pocket Side: m2_cart_bus + m2_raster3d + m2_fb_psram + 2x psram_phy
	//    + m2_video + m2_char_cache + m2_sdram + JEDEC sdram_model
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

	wire        cq_valid, cq_moire, cq_mipz, cq_end, c_fs_rx;
	wire signed [15:0] cq_x0, cq_y0, cq_x1, cq_y1, cq_x2, cq_y2, cq_x3, cq_y3;
	wire [23:0] cq_col;
	wire [31:0] cq_z;
	wire [15:0] cq_oz0, cq_oz1, cq_oz2, cq_oz3, cq_frac;
	wire [12:0] cq_u0, cq_v0, cq_u1, cq_v1, cq_u2, cq_v2, cq_u3, cq_v3;
	wire [26:0] cq_tex;
	wire  [1:0] cq_uvs;
	wire  [3:0] cq_tag;

	wire        tram_we, pal_we, xlat_we, lut_we;
	wire [14:0] tram_waddr;
	wire [15:0] tram_wdin;
	wire [11:0] pal_waddr;
	wire [15:0] pal_wdin;
	wire  [6:0] xlat_waddr;
	wire  [7:0] xlat_wdin;
	wire  [1:0] lut_sel;
	wire [12:0] lut_addr;
	wire [15:0] lut_data;

	wire        cart_sd_wreq, cart_tex_inval, cart_char_inval, cart_sd_wack;
	wire [25:1] cart_sd_waddr;
	wire [15:0] cart_sd_wdin;
	wire        r3d_q_ready;

	m2_cart_bus u_cart_bus (
		.clk_cart                ( clk_cart ),
		.clk_sys                 ( clk_sys ),
		.clk_mem                 ( clk_mem ),
		.rst_n                   ( rst_n ),
		.cart_tran_bank0         ( cart_tran_bank0 ),
		.cart_tran_bank0_dir     ( cart_tran_bank0_dir ),
		.cart_tran_bank1         ( cart_tran_bank1 ),
		.cart_tran_bank1_dir     ( cart_tran_bank1_dir ),
		.cart_tran_bank2         ( cart_tran_bank2 ),
		.cart_tran_bank2_dir     ( cart_tran_bank2_dir ),
		.cart_tran_bank3         ( cart_tran_bank3 ),
		.cart_tran_bank3_dir     ( cart_tran_bank3_dir ),
		.cart_tran_pin30         ( cart_tran_pin30 ),
		.cart_tran_pin30_dir     ( cart_tran_pin30_dir ),
		.cart_pin30_pwroff_reset ( cart_pin30_pwroff_reset ),
		.cart_tran_pin31         ( cart_tran_pin31 ),
		.cart_tran_pin31_dir     ( cart_tran_pin31_dir ),
		.vsync_pulse_sys         ( vblank_pulse_sys ),
		.pad_key_sys             ( p_pad_key ),
		.pad_joy_sys             ( p_pad_joy ),
		.pad_trig_sys            ( p_pad_trig ),
		.cart_detected           ( cart_detected_o ),
		.dbg_rx_words            ( dbg_rx_words_o ),
		.q_valid                 ( cq_valid ),
		.q_ready                 ( r3d_q_ready ),
		.q_x0(cq_x0), .q_y0(cq_y0), .q_x1(cq_x1), .q_y1(cq_y1),
		.q_x2(cq_x2), .q_y2(cq_y2), .q_x3(cq_x3), .q_y3(cq_y3),
		.q_col(cq_col), .q_z(cq_z), .q_moire(cq_moire),
		.q_oz0(cq_oz0), .q_oz1(cq_oz1), .q_oz2(cq_oz2), .q_oz3(cq_oz3),
		.q_frac(cq_frac),
		.q_u0(cq_u0), .q_v0(cq_v0), .q_u1(cq_u1), .q_v1(cq_v1),
		.q_u2(cq_u2), .q_v2(cq_v2), .q_u3(cq_u3), .q_v3(cq_v3),
		.q_tex(cq_tex), .q_uvs(cq_uvs), .q_mipz(cq_mipz), .q_end(cq_end),
		.q_tag(cq_tag), .frame_start_cart(c_fs_rx),
		.tram_we(tram_we), .tram_addr(tram_waddr), .tram_din(tram_wdin),
		.pal_we(pal_we), .pal_addr(pal_waddr), .pal_din(pal_wdin),
		.xlat_we(xlat_we), .xlat_addr(xlat_waddr), .xlat_din(xlat_wdin),
		.lut_we(lut_we), .lut_sel(lut_sel), .lut_addr(lut_addr), .lut_data(lut_data),
		.sd_wreq(cart_sd_wreq), .sd_waddr(cart_sd_waddr), .sd_wdin(cart_sd_wdin),
		.sd_wack(cart_sd_wack), .tex_inval_cart(cart_tex_inval), .char_inval_cart(cart_char_inval),
		.audio_l(p_audio_l_o), .audio_r(p_audio_r_o), .audio_stb(p_audio_stb_o)
	);

	// Port 5 SDRAM CDC bridge (exact same logic as m2_pocket_top.sv)
	reg        csdw_tog_s = 1'b0, csdw_pend_s = 1'b0;
	reg [25:1] csdw_addr_s = 25'd0;
	reg [15:0] csdw_din_s  = 16'd0;
	reg        csdw_ack_m  = 1'b0;
	reg [2:0]  csdw_ack_s  = 3'd0;
	assign cart_sd_wack = csdw_pend_s && (csdw_ack_s[2] ^ csdw_ack_s[1]);
	always @(posedge clk_sys or negedge rst_n) begin
		if (!rst_n) begin
			csdw_tog_s <= 1'b0; csdw_pend_s <= 1'b0; csdw_ack_s <= 3'd0;
		end else begin
			csdw_ack_s <= {csdw_ack_s[1:0], csdw_ack_m};
			if (cart_sd_wack) csdw_pend_s <= 1'b0;
			else if (cart_sd_wreq && !csdw_pend_s) begin
				csdw_addr_s <= cart_sd_waddr;
				csdw_din_s  <= cart_sd_wdin;
				csdw_tog_s  <= ~csdw_tog_s;
				csdw_pend_s <= 1'b1;
			end
		end
	end

	reg [2:0]  csdw_req_m = 3'd0;
	reg        p5_req_r   = 1'b0;
	reg [25:1] p5_addr_r  = 25'd0;
	reg [15:0] p5_din_r   = 16'd0;
	always @(posedge clk_mem or negedge rst_n) begin
		if (!rst_n) begin
			csdw_req_m <= 3'd0; p5_req_r <= 1'b0; csdw_ack_m <= 1'b0;
		end else begin
			csdw_req_m <= {csdw_req_m[1:0], csdw_tog_s};
			if (p5_req_r && p_ack[5]) begin
				p5_req_r   <= 1'b0;
				csdw_ack_m <= ~csdw_ack_m;
			end else if (!p5_req_r && (csdw_req_m[2] ^ csdw_req_m[1])) begin
				p5_addr_r <= csdw_addr_s;
				p5_din_r  <= csdw_din_s;
				p5_req_r  <= 1'b1;
			end
		end
	end

	// -------------------------------------------------------------------------
	// 4. 64 MB SDR SDRAM Controller (m2_sdram) + JEDEC Protocol Checker Model
	// -------------------------------------------------------------------------
	localparam int unsigned SDR_AW = 25;
	localparam int unsigned NPORTS = 8;

	wire        sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
	wire  [1:0] sd_ba, sd_dqm;
	wire [12:0] sd_a;
	wire [15:0] sd_dq_o, sd_dq_i;
	wire        sd_dq_oe, sd_dq_oe_dev;

	wire [NPORTS-1:0]            p_req, p_we, p_ack, p_long, p_lo;
	wire [NPORTS-1:0][SDR_AW:1]  p_addr;
	wire [NPORTS-1:0][15:0]      p_din;
	wire [NPORTS-1:0][1:0]       p_be;
	wire [NPORTS-1:0][63:0]      p_dout;

	m2_sdram #(
		.COL_BITS ( 10 ),
		.ROW_BITS ( 13 ),
		.BA_BITS  ( 2 ),
		.NP       ( NPORTS ),
		.T_REFI   ( 748 ),
		.INIT_NOP ( 64 ), // Fast sim power-up
		.PRI      ( 8'b0001_1111 ),
		.PRI_TOP  ( 8'b0000_0001 )
	) u_sdram (
		.clk        ( clk_mem ),
		.rst_n      ( rst_n ),
		.ready      ( sdram_ready_o ),
		.rd_lat_sel ( 3'd0 ), // CL+1 matches synchronous behavioral sdram_model
		.sd_cke     ( sd_cke ),
		.sd_cs_n    ( sd_cs_n ),
		.sd_ras_n   ( sd_ras_n ),
		.sd_cas_n   ( sd_cas_n ),
		.sd_we_n    ( sd_we_n ),
		.sd_ba      ( sd_ba ),
		.sd_a       ( sd_a ),
		.sd_dqm     ( sd_dqm ),
		.sd_dq_o    ( sd_dq_o ),
		.sd_dq_oe   ( sd_dq_oe ),
		.sd_dq_i    ( sd_dq_i ),
		.wr_req     ( 1'b0 ),
		.wr_addr    ( 25'd0 ),
		.wr_din     ( 16'd0 ),
		.wr_be      ( 2'b00 ),
		.wr_ack     ( ),
		.p_req      ( p_req ),
		.p_we       ( p_we ),
		.p_addr     ( p_addr ),
		.p_din      ( p_din ),
		.p_be       ( p_be ),
		.p_dout     ( p_dout ),
		.p_ack      ( p_ack ),
		.p_long     ( p_long ),
		.p_lo       ( p_lo ),
		.dbg_req    ( ),
		.dbg_grant  ( )
	);

	sdram_model #(
		.ROW_BITS      ( 13 ),
		.COL_BITS      ( 10 ),
		.BA_BITS       ( 2 ),
		.T_REFI        ( 781 ),
		.CHECK_REFRESH ( 1'b1 ),
		.NAME          ( "POCKET_SDRAM" )
	) u_sdram_dev (
		.clk           ( clk_mem ),
		.cke           ( sd_cke ),
		.cs_n          ( sd_cs_n ),
		.ras_n         ( sd_ras_n ),
		.cas_n         ( sd_cas_n ),
		.we_n          ( sd_we_n ),
		.ba            ( sd_ba ),
		.a             ( sd_a ),
		.dqm           ( sd_dqm ),
		.dq_i          ( sd_dq_o ),
		.dq_oe_i       ( sd_dq_oe ),
		.dq_o          ( sd_dq_i ),
		.dq_oe_o       ( sd_dq_oe_dev ),
		.violations    ( sdram_violations_o ),
		.v_flags       ( ),
		.reads_served  ( sdram_reads_o ),
		.writes_served ( sdram_writes_o )
	);

	// -------------------------------------------------------------------------
	// 5. Dual Cellular PSRAM PHYs + Models + m2_fb_psram
	// -------------------------------------------------------------------------
	wire        c0_cfg_done, c0_cmd_valid, c0_cmd_ready, c0_cmd_we, c0_wd_pop, c0_rd_valid, c0_rd_last;
	wire [22:0] c0_cmd_addr;
	wire  [4:0] c0_cmd_len;
	wire [15:0] c0_wd_data, c0_rd_data;
	wire  [1:0] c0_wd_be;
	wire [21:16] c0_a;
	wire [15:0] c0_dqo, c0_dqi;
	wire        c0_dqoe, c0_clk, c0_adv, c0_cre, c0_ce0, c0_ce1, c0_oe, c0_we, c0_ub, c0_lb, c0_wait;

	wire        c1_cfg_done, c1_cmd_valid, c1_cmd_ready, c1_cmd_we, c1_wd_pop, c1_rd_valid, c1_rd_last;
	wire [22:0] c1_cmd_addr;
	wire  [4:0] c1_cmd_len;
	wire [15:0] c1_wd_data, c1_rd_data;
	wire  [1:0] c1_wd_be;
	wire [21:16] c1_a;
	wire [15:0] c1_dqo, c1_dqi;
	wire        c1_dqoe, c1_clk, c1_adv, c1_cre, c1_ce0, c1_ce1, c1_oe, c1_we, c1_ub, c1_lb, c1_wait;

	psram_phy #(.LC(2), .CLKDIV(2), .RDLAT(2), .INIT_CYC(16), .WAKE_LOG2(2)) u_cram0_phy (
		.clk(clk_mem), .rst(!rst_n),
		.cmd_valid(c0_cmd_valid), .cmd_ready(c0_cmd_ready), .cmd_we(c0_cmd_we),
		.cmd_addr(c0_cmd_addr), .cmd_len(c0_cmd_len),
		.wd_pop(c0_wd_pop), .wd_data(c0_wd_data), .wd_be(c0_wd_be),
		.rd_valid(c0_rd_valid), .rd_data(c0_rd_data), .rd_last(c0_rd_last), .cfg_done(c0_cfg_done),
		.p_a(c0_a), .p_dq_out(c0_dqo), .p_dq_oe(c0_dqoe), .p_dq_in(c0_dqi),
		.p_clk(c0_clk), .p_adv_n(c0_adv), .p_cre(c0_cre), .p_ce0_n(c0_ce0), .p_ce1_n(c0_ce1),
		.p_oe_n(c0_oe), .p_we_n(c0_we), .p_ub_n(c0_ub), .p_lb_n(c0_lb), .p_wait(c0_wait)
	);
	psram_cell_model #(.LC(2)) u_cram0_dev (
		.p_a(c0_a), .p_dq_out(c0_dqo), .p_dq_oe(c0_dqoe), .p_dq_in(c0_dqi),
		.p_clk(c0_clk), .p_adv_n(c0_adv), .p_cre(c0_cre), .p_ce0_n(c0_ce0), .p_ce1_n(c0_ce1),
		.p_oe_n(c0_oe), .p_we_n(c0_we), .p_ub_n(c0_ub), .p_lb_n(c0_lb), .p_wait(c0_wait)
	);

	psram_phy #(.LC(2), .CLKDIV(2), .RDLAT(2), .INIT_CYC(16), .WAKE_LOG2(2)) u_cram1_phy (
		.clk(clk_mem), .rst(!rst_n),
		.cmd_valid(c1_cmd_valid), .cmd_ready(c1_cmd_ready), .cmd_we(c1_cmd_we),
		.cmd_addr(c1_cmd_addr), .cmd_len(c1_cmd_len),
		.wd_pop(c1_wd_pop), .wd_data(c1_wd_data), .wd_be(c1_wd_be),
		.rd_valid(c1_rd_valid), .rd_data(c1_rd_data), .rd_last(c1_rd_last), .cfg_done(c1_cfg_done),
		.p_a(c1_a), .p_dq_out(c1_dqo), .p_dq_oe(c1_dqoe), .p_dq_in(c1_dqi),
		.p_clk(c1_clk), .p_adv_n(c1_adv), .p_cre(c1_cre), .p_ce0_n(c1_ce0), .p_ce1_n(c1_ce1),
		.p_oe_n(c1_oe), .p_we_n(c1_we), .p_ub_n(c1_ub), .p_lb_n(c1_lb), .p_wait(c1_wait)
	);
	psram_cell_model #(.LC(2)) u_cram1_dev (
		.p_a(c1_a), .p_dq_out(c1_dqo), .p_dq_oe(c1_dqoe), .p_dq_in(c1_dqi),
		.p_clk(c1_clk), .p_adv_n(c1_adv), .p_cre(c1_cre), .p_ce0_n(c1_ce0), .p_ce1_n(c1_ce1),
		.p_oe_n(c1_oe), .p_we_n(c1_we), .p_ub_n(c1_ub), .p_lb_n(c1_lb), .p_wait(c1_wait)
	);

	wire        fb_req, fb_we, fb_wnext, fb_wacc, fb_rvalid, fb_ack;
	wire [24:0] fb_addr;
	wire  [7:0] fb_blen, fb_be;
	wire [63:0] fb_din, fb_dout;

	m2_fb_psram u_fb_psram (
		.clk_sys(clk_sys), .clk_mem(clk_mem), .rst_n(rst_n),
		.fb_req(fb_req), .fb_we(fb_we), .fb_addr(fb_addr), .fb_blen(fb_blen),
		.fb_din(fb_din), .fb_be(fb_be), .fb_wnext(fb_wnext), .fb_wacc(fb_wacc),
		.fb_rvalid(fb_rvalid), .fb_ack(fb_ack), .fb_dout(fb_dout),
		.c0_cfg_done(c0_cfg_done), .c0_cmd_valid(c0_cmd_valid), .c0_cmd_ready(c0_cmd_ready),
		.c0_cmd_we(c0_cmd_we), .c0_cmd_addr(c0_cmd_addr), .c0_cmd_len(c0_cmd_len),
		.c0_wd_pop(c0_wd_pop), .c0_wd_data(c0_wd_data), .c0_wd_be(c0_wd_be),
		.c0_rd_valid(c0_rd_valid), .c0_rd_data(c0_rd_data), .c0_rd_last(c0_rd_last),
		.c1_cfg_done(c1_cfg_done), .c1_cmd_valid(c1_cmd_valid), .c1_cmd_ready(c1_cmd_ready),
		.c1_cmd_we(c1_cmd_we), .c1_cmd_addr(c1_cmd_addr), .c1_cmd_len(c1_cmd_len),
		.c1_wd_pop(c1_wd_pop), .c1_wd_data(c1_wd_data), .c1_wd_be(c1_wd_be),
		.c1_rd_valid(c1_rd_valid), .c1_rd_data(c1_rd_data), .c1_rd_last(c1_rd_last),
		.ready_o(fb_ready_o)
	);

	// -------------------------------------------------------------------------
	// 6. Real Unmodified m2_raster3d + m2_video + m2_char_cache
	// -------------------------------------------------------------------------
	wire [15:0] scan_col;
	wire        scan_hit;
	wire  [3:0] show_tag;
	wire        tex_m_req, tex_m2_req, tex_m3_req, tex_m4_req;
	wire [SDR_AW:1] tex_m_addr, tex_m2_addr, tex_m3_addr, tex_m4_addr;

	m2_raster3d #(
		.SCR_W(496), .SCR_H(384), .BAND_H(8), .NBUF(6), .FTB(1'b1),
		.FB_DDR3(1'b1), .FB_WCOMB(1'b1), .SPLIT_TRI(1'b1), .PXC(1'b1),
		.PIXSTEP(4), .FRB(2), .M2COV(1'b1), .DIL(1'b1), .UVCL(1'b1),
		.NEGZ(1'b1), .TXLATE(3), .TXNS(4), .TXRSP(4), .TXK(16),
		.TXLW8(1'b1), .TXREUSE(1'b0), .SPCULL(1'b1), .MIP(1'b1),
		.TWO_CLOCKS(1'b1), .TEX_AW(SDR_AW), .TEXLUT(1'b1), .KW(20),
		.UVSH(1'b1), .QNX(0)
	) u_raster3d (
		.clk(clk_sys), .clk_mem(clk_mem), .rst_n(rst_n),
		.frame_start(vblank_pulse_sys),
		.q_valid(cq_valid), .q_ready(r3d_q_ready),
		.q_x0(cq_x0), .q_y0(cq_y0), .q_x1(cq_x1), .q_y1(cq_y1),
		.q_x2(cq_x2), .q_y2(cq_y2), .q_x3(cq_x3), .q_y3(cq_y3),
		.q_col(cq_col), .q_z(cq_z), .q_moire(cq_moire),
		.q_oz0(cq_oz0), .q_oz1(cq_oz1), .q_oz2(cq_oz2), .q_oz3(cq_oz3),
		.q_frac(cq_frac),
		.q_u0(cq_u0), .q_v0(cq_v0), .q_u1(cq_u1), .q_v1(cq_v1),
		.q_u2(cq_u2), .q_v2(cq_v2), .q_u3(cq_u3), .q_v3(cq_v3),
		.q_tex(cq_tex), .q_uvs(cq_uvs), .q_mipz(cq_mipz), .q_end(cq_end),
		.q_tag(cq_tag), .show_tag(show_tag),
		.scan_clk(clk_mem), .scan_x(vid_x_o), .scan_y(vid_y_o),
		.scan_il(1'b0), .scan_field(1'b0), .scan_col(scan_col), .scan_hit(scan_hit),
		.tex_base0(25'h000_0000), .tex_base1(25'h020_0000), .tex_inval(cart_tex_inval),
		.tex_bilinear(1'b1), .tex_pxk(2'd2), .tex_mip_mode(2'd0), .dil_on(2'd1), .tex_gamma(2'd0),
		.lut_we(lut_we), .lut_sel(lut_sel), .lut_addr(lut_addr), .lut_data(lut_data),
		.list_hold(), .fb_test(1'b0), .fb_pace(3'd0),
		.tex_m_req(tex_m_req), .tex_m_addr(tex_m_addr), .tex_m_ack(p_ack[1]), .tex_m_lo(p_lo[1]), .tex_m_data(p_dout[1]),
		.tex_m2_en(1'b1), .tex_m2_req(tex_m2_req), .tex_m2_addr(tex_m2_addr), .tex_m2_ack(p_ack[2]), .tex_m2_lo(p_lo[2]), .tex_m2_data(p_dout[2]),
		.tex_m3_en(1'b1), .tex_m3_req(tex_m3_req), .tex_m3_addr(tex_m3_addr), .tex_m3_ack(p_ack[3]), .tex_m3_lo(p_lo[3]), .tex_m3_data(p_dout[3]),
		.tex_m4_en(1'b1), .tex_m4_req(tex_m4_req), .tex_m4_addr(tex_m4_addr), .tex_m4_ack(p_ack[4]), .tex_m4_lo(p_lo[4]), .tex_m4_data(p_dout[4]),
		.fb_req(fb_req), .fb_we(fb_we), .fb_addr(fb_addr), .fb_blen(fb_blen),
		.fb_din(fb_din), .fb_be(fb_be), .fb_wnext(fb_wnext), .fb_wacc(fb_wacc),
		.fb_rvalid(fb_rvalid), .fb_ack(fb_ack), .fb_dout(fb_dout)
	);

	// /6 pixel clock enable on clk_mem
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

	m2_tdp_ram2c #(.DW(16), .AW(15)) u_tram (
		.a_clk(clk_sys), .a_addr(tram_waddr), .a_din(tram_wdin), .a_we(tram_we), .a_q(),
		.b_clk(clk_mem), .b_addr(tram_raddr), .b_q(tram_rdata)
	);
	m2_tdp_ram2c #(.DW(16), .AW(12)) u_pal (
		.a_clk(clk_sys), .a_addr(pal_waddr), .a_din(pal_wdin), .a_we(pal_we), .a_q(),
		.b_clk(clk_mem), .b_addr(pal_raddr), .b_q(pal_rdata)
	);

	wire        char_req, char_ack, cc_m_req;
	wire [17:0] char_addr, cc_m_addr;
	wire [31:0] char_data;
	wire        p5_char_hit = p5_req_r && p_ack[5] && (p5_addr_r[25:20] == 6'b001000);

	m2_char_cache #(.IDX_BITS(10), .ADDR_BITS(18), .SIBLING(1'b0)) u_char_cache (
		.clk(clk_mem), .rst_n(rst_n),
		.v_req(char_req), .v_addr(char_addr), .v_data(char_data), .v_ack(char_ack),
		.inval(p5_char_hit), .inval_idx(p5_addr_r[11:2]),
		.m_req(cc_m_req), .m_addr(cc_m_addr), .m_data(p_dout[0]), .m_ack(p_ack[0]),
		.dbg_hits(), .dbg_misses(), .dbg_fills()
	);

	localparam [SDR_AW:1] CHAR_BASE = 25'h080_0000;
	assign p_req[0] = cc_m_req;   assign p_we[0] = 1'b0; assign p_addr[0] = CHAR_BASE + {6'd0, cc_m_addr, 1'b0}; assign p_din[0] = 16'd0;    assign p_be[0] = 2'b11; assign p_long[0] = 1'b0;
	assign p_req[1] = tex_m_req;  assign p_we[1] = 1'b0; assign p_addr[1] = tex_m_addr;  assign p_din[1] = 16'd0;    assign p_be[1] = 2'b11; assign p_long[1] = 1'b1;
	assign p_req[2] = tex_m2_req; assign p_we[2] = 1'b0; assign p_addr[2] = tex_m2_addr; assign p_din[2] = 16'd0;    assign p_be[2] = 2'b11; assign p_long[2] = 1'b1;
	assign p_req[3] = tex_m3_req; assign p_we[3] = 1'b0; assign p_addr[3] = tex_m3_addr; assign p_din[3] = 16'd0;    assign p_be[3] = 2'b11; assign p_long[3] = 1'b1;
	assign p_req[4] = tex_m4_req; assign p_we[4] = 1'b0; assign p_addr[4] = tex_m4_addr; assign p_din[4] = 16'd0;    assign p_be[4] = 2'b11; assign p_long[4] = 1'b1;
	assign p_req[5] = p5_req_r;   assign p_we[5] = 1'b1; assign p_addr[5] = p5_addr_r;   assign p_din[5] = p5_din_r; assign p_be[5] = 2'b11; assign p_long[5] = 1'b0;
	assign p_req[6] = 1'b0; assign p_we[6] = 1'b0; assign p_addr[6] = 25'd0; assign p_din[6] = 16'd0; assign p_be[6] = 2'b00; assign p_long[6] = 1'b0;
	assign p_req[7] = 1'b0; assign p_we[7] = 1'b0; assign p_addr[7] = 25'd0; assign p_din[7] = 16'd0; assign p_be[7] = 2'b00; assign p_long[7] = 1'b0;

	wire       vid_hb_m, vid_vb_m;
	wire [7:0] vid_r_m, vid_g_m, vid_b_m;

	m2_video #(
		.COLUMNS(62), .LB_RING(1'b1), .HSCR_FIX(1'b1),
		.SCR_SYNC(1'b1), .SCR_STEP(1'b1), .SCR_DEPTH(2), .MASK_SKIP(1'b1)
	) u_tilemap (
		.clk(clk_mem), .ce_pix(ce_pix_o), .rst_n(rst_n),
		.tile_mask(14'h3FFF), .gamma_sel(2'd0),
		.xlat_clk(clk_sys), .xlat_we(xlat_we), .xlat_addr(xlat_waddr), .xlat_din(xlat_wdin),
		.tram_addr(tram_raddr), .tram_data(tram_rdata),
		.char_req(char_req), .char_addr(char_addr), .char_data(char_data), .char_ack(char_ack),
		.pal_addr(pal_raddr), .pal_data(pal_rdata),
		.vid_cat1(vid_cat1_o), .vid_r(vid_r_m), .vid_g(vid_g_m), .vid_b(vid_b_m),
		.vid_hs(vid_hs_o), .vid_vs(vid_vs_o), .vid_hb(vid_hb_m), .vid_vb(vid_vb_m),
		.vblank_irq(vid_vblank_irq),
		.dbg_fetches(), .dbg_overruns(), .dbg_ovr_frame(), .dbg_layer_px(),
		.dbg_hscr(), .dbg_vscr(), .dbg_layer_have(),
		.vid_x(vid_x_o), .vid_y(vid_y_o),
		.interlace(1'b0), .scr_flip(1'b0), .scr_tag(show_tag), .scr_vtgl(1'b0), .scr_ttag(4'd0),
		.ntsc_lines(1'b0), .mid_lines(1'b0), .narrow(1'b0), .vid_field()
	);

	wire [7:0] r3d_r = {scan_col[15:11], scan_col[15:13]};
	wire [7:0] r3d_g = {scan_col[10:5],  scan_col[10:9]};
	wire [7:0] r3d_b = {scan_col[4:0],   scan_col[4:2]};

	assign scan_hit_o = scan_hit;
	assign vid_de_o   = ~(vid_hb_m | vid_vb_m);
	assign vid_rgb_o  = (scan_hit && !vid_cat1_o) ? {r3d_r, r3d_g, r3d_b} : {vid_r_m, vid_g_m, vid_b_m};

	assign dbg_state_o = {
		u_cart_bus.q_valid,        // [31]
		r3d_q_ready,               // [30]
		u_cart_bus.sd_wreq,        // [29]
		cart_sd_wack,              // [28]
		u_cart_bus.b_st,           // [27:25]
		u_cart_bus.rx_empty,       // [24]
		u_cart_bus.rx_full,        // [23]
		u_fb_psram.cs_st,          // [22:21]
		u_fb_psram.ms_st,          // [20:18]
		fb_req,                    // [17]
		fb_we,                     // [16]
		u_fb_psram.wf_empty,       // [15]
		u_fb_psram.rf_empty,       // [14]
		u_cram0_phy.st,            // [13:11]
		u_cram1_phy.st,            // [10:8]
		u_cart_bus.rx_wrusedw      // [7:0]
	};

	assign dbg_r3d_0_o = {
		u_raster3d.dbg_quads[15:0],      // [31:16]
		u_raster3d.dbg_qend_frames[7:0], // [15:8]
		u_raster3d.dbg_bands_done[7:0]   // [7:0]
	};
	assign dbg_r3d_1_o = {
		u_raster3d.dbg_fb_pub[7:0],      // [31:24]
		u_raster3d.dbg_fb_lines[11:0],   // [23:12]
		u_raster3d.dbg_fb_pixels[11:0]   // [11:0]
	};

endmodule
`default_nettype wire
