// m2_pocket_top: DeadOrPocket (Sega Model 2 & Model 2A-CRX Hybrid Render Core)
//
// Phase 1 Analogue Pocket top-level (5CEBA4F23C8), based on SpaceFish's proven
// openFPGA infrastructure:
//   - Full unmodified m2_raster3d (bilinear, mip-mapping, FTB, 4 texel ports, 57.52 Hz)
//   - Full pixel-exact m2_video (2D tilemaps, 4-line ring, char cache, palette)
//   - 64 MB SDR SDRAM (dram_*) via m2_sdram (8 ports) for textures & 2D char RAM
//   - Dual 16 MB Cellular PSRAM (cram0_*, cram1_*) via 2x psram_phy + m2_fb_psram
//     for zero-contention ping-pong 3D double-buffered framebuffer (replaces DDR3)
//   - 30-pin Analogue Pocket Cartridge Slot synchronous 16-bit bus (m2_cart_bus)
//     connecting to the external Compute Cartridge (i960 + TGP + Geometry + Sound)
//   - Built-in 57.52 Hz 3D Self-Test Demo (m2_demo_gen) for standalone Pocket testing
//
`default_nettype none

module m2_pocket_top (
	input  wire        clk_74a,
	input  wire        apf_reset_n,

	// APF bridge bus
	input  wire [31:0] bridge_addr,
	input  wire        bridge_wr,
	input  wire [31:0] bridge_wr_data,

	// APF controllers & dataslot
	input  wire [31:0] pad_key,
	input  wire [31:0] pad_joy,
	input  wire [15:0] pad_trig,
	input  wire        apf_dataslot_complete,

	// Video out to APF scaler (496x384 @ 57.47 Hz RGB24)
	output reg  [23:0] video_rgb = 24'd0,
	output wire        video_rgb_clock,
	output wire        video_rgb_clock_90,
	output reg         video_de = 1'b0,
	output wire        video_skip,
	output reg         video_vs = 1'b0,
	output reg         video_hs = 1'b0,

	// Audio out to APF I2S DAC (48 kHz Stereo)
	output wire        audio_mclk,
	output wire        audio_lrck,
	output wire        audio_dac,

	// SDR SDRAM (64 MB / 512 Mbit, 16-bit)
	output wire [12:0] dram_a,
	output wire  [1:0] dram_ba,
	inout  wire [15:0] dram_dq,
	output wire  [1:0] dram_dqm,
	output wire        dram_clk,
	output wire        dram_cke,
	output wire        dram_ras_n,
	output wire        dram_cas_n,
	output wire        dram_we_n,

	// Cellular PSRAM 0 (16 MB, 3D FB Bank A)
	output wire [21:16] cram0_a,
	inout  wire [15:0]  cram0_dq,
	input  wire         cram0_wait,
	output wire         cram0_clk,
	output wire         cram0_adv_n,
	output wire         cram0_cre,
	output wire         cram0_ce0_n,
	output wire         cram0_ce1_n,
	output wire         cram0_oe_n,
	output wire         cram0_we_n,
	output wire         cram0_ub_n,
	output wire         cram0_lb_n,

	// Cellular PSRAM 1 (16 MB, 3D FB Bank B)
	output wire [21:16] cram1_a,
	inout  wire [15:0]  cram1_dq,
	input  wire         cram1_wait,
	output wire         cram1_clk,
	output wire         cram1_adv_n,
	output wire         cram1_cre,
	output wire         cram1_ce0_n,
	output wire         cram1_ce1_n,
	output wire         cram1_oe_n,
	output wire         cram1_we_n,
	output wire         cram1_ub_n,
	output wire         cram1_lb_n,

	// Asynchronous SRAM (256 KB, reserved for Phase 2 quad spill / NVRAM)
	output wire [16:0]  sram_a,
	inout  wire [15:0]  sram_dq,
	output wire         sram_oe_n,
	output wire         sram_we_n,
	output wire         sram_ub_n,
	output wire         sram_lb_n,

	// Cartridge Slot (30 pins, 16-bit sync bus to Compute Cartridge)
	inout  wire  [7:4]  cart_tran_bank0,
	output wire         cart_tran_bank0_dir,
	inout  wire  [7:0]  cart_tran_bank1,
	output wire         cart_tran_bank1_dir,
	inout  wire  [7:0]  cart_tran_bank2,
	output wire         cart_tran_bank2_dir,
	inout  wire  [7:0]  cart_tran_bank3,
	output wire         cart_tran_bank3_dir,
	inout  wire         cart_tran_pin30,
	output wire         cart_tran_pin30_dir,
	output wire         cart_pin30_pwroff_reset,
	inout  wire         cart_tran_pin31,
	output wire         cart_tran_pin31_dir,

	output wire         pll_locked_o
);

	assign video_skip = 1'b0;

	// Tie off Async SRAM cleanly in idle state for Phase 1
	assign sram_a    = 17'd0;
	assign sram_dq   = 16'hzzzz;
	assign sram_oe_n = 1'b1;
	assign sram_we_n = 1'b1;
	assign sram_ub_n = 1'b1;
	assign sram_lb_n = 1'b1;

	// -------------------------------------------------------------------------
	// 1. Clocks (2 PLLs: Core + Audio)
	// -------------------------------------------------------------------------
	wire clk_mem;        // 95.91 MHz
	wire clk_sdram_pin;  // 95.91 MHz (+180 deg)
	wire clk_sys;        // 73.77 MHz (C2 = 13, full C8 PVT timing closure)
	wire clk_cart;       // 31.97 MHz
	wire clk_pix;        // 15.98 MHz
	wire clk_pix_90;     // 15.98 MHz (+90 deg)
	wire pll_locked;
	wire clk_audio_mclk; // 12.288 MHz

	m2_pll u_pll (
		.refclk        ( clk_74a ),
		.rst           ( 1'b0 ),
		.clk_mem       ( clk_mem ),
		.clk_sdram_pin ( clk_sdram_pin ),
		.clk_sys       ( clk_sys ),
		.clk_cart      ( clk_cart ),
		.clk_pix       ( clk_pix ),
		.clk_pix_90    ( clk_pix_90 ),
		.locked        ( pll_locked )
	);

	m2_audio_pll u_audio_pll (
		.refclk     ( clk_74a ),
		.rst        ( 1'b0 ),
		.audio_mclk ( clk_audio_mclk ),
		.locked     ( )
	);

	assign video_rgb_clock    = clk_pix;
	assign video_rgb_clock_90 = clk_pix_90;
	assign pll_locked_o       = pll_locked;
	assign dram_clk           = clk_sdram_pin;

	// -------------------------------------------------------------------------
	// 2. APF I/O, Settings & ROM Loader (m2_pk_io)
	// -------------------------------------------------------------------------
	wire        core_reset_btn;
	wire        demo_mode;
	wire        tex_bilinear;
	wire        dbg_overlay;
	wire  [1:0] tex_mip_mode;
	wire [31:0] game_cfg;
	wire [31:0] pad_key_sys, pad_joy_sys;
	wire [15:0] pad_trig_sys;

	wire        dl_active, dl_wr, dl_ack;
	wire [25:1] dl_addr;
	wire [15:0] dl_din;
	wire        boot_done, fifo_ovf;

	m2_pk_io u_pk_io (
		.clk_74a               ( clk_74a ),
		.apf_reset_n           ( apf_reset_n ),
		.bridge_addr           ( bridge_addr ),
		.bridge_wr             ( bridge_wr ),
		.bridge_wr_data        ( bridge_wr_data ),
		.pad_key               ( pad_key ),
		.pad_joy               ( pad_joy ),
		.pad_trig              ( pad_trig ),
		.apf_dataslot_complete ( apf_dataslot_complete ),
		.clk_sys               ( clk_sys ),
		.clk_mem               ( clk_mem ),
		.pll_locked            ( pll_locked ),
		.core_reset_btn        ( core_reset_btn ),
		.demo_mode             ( demo_mode ),
		.tex_bilinear          ( tex_bilinear ),
		.dbg_overlay           ( dbg_overlay ),
		.tex_mip_mode          ( tex_mip_mode ),
		.game_cfg              ( game_cfg ),
		.pad_key_sys           ( pad_key_sys ),
		.pad_joy_sys           ( pad_joy_sys ),
		.pad_trig_sys          ( pad_trig_sys ),
		.dl_active             ( dl_active ),
		.dl_wr                 ( dl_wr ),
		.dl_addr               ( dl_addr ),
		.dl_din                ( dl_din ),
		.dl_ack                ( dl_ack ),
		.boot_done             ( boot_done ),
		.fifo_ovf              ( fifo_ovf )
	);

	// Synchronize resets cleanly per clock domain
	wire mem_rst_n = pll_locked;
	reg [1:0] rst_sys_s = 2'b00;
	always @(posedge clk_sys or negedge pll_locked) begin
		if (!pll_locked) rst_sys_s <= 2'b00;
		else             rst_sys_s <= {rst_sys_s[0], ~core_reset_btn};
	end
	wire core_rst_n = rst_sys_s[1];

	reg [1:0] rst_mem_s = 2'b00;
	always @(posedge clk_mem or negedge pll_locked) begin
		if (!pll_locked) rst_mem_s <= 2'b00;
		else             rst_mem_s <= {rst_mem_s[0], core_rst_n};
	end
	wire vid_rst_n = rst_mem_s[1];

	// -------------------------------------------------------------------------
	// 3. 64 MB SDR SDRAM Controller (m2_sdram, 8 ports @ 95.91 MHz)
	//    Port 0: 2D Char Cache miss
	//    Port 1: Texel miss 0 (8-word burst)
	//    Port 2: Texel miss 1 (8-word burst)
	//    Port 3: Texel miss 2 (8-word burst)
	//    Port 4: Texel miss 3 (8-word burst)
	//    Ports 5..7: Reserved (Cartridge 2D Char RAM writes / future expansion)
	// -------------------------------------------------------------------------
	localparam int unsigned SDR_AW = 25; // 64 MB = 32M x 16-bit words (A[25:1])
	localparam int unsigned NPORTS = 8;

	wire [15:0] sd_dq_o;
	wire        sd_dq_oe;
	assign dram_dq = sd_dq_oe ? sd_dq_o : 16'hzzzz;

	wire [NPORTS-1:0]            p_req;
	wire [NPORTS-1:0]            p_we;
	wire [NPORTS-1:0][SDR_AW:1]  p_addr;
	wire [NPORTS-1:0][15:0]      p_din;
	wire [NPORTS-1:0][1:0]       p_be;
	wire [NPORTS-1:0][63:0]      p_dout;
	wire [NPORTS-1:0]            p_ack;
	wire [NPORTS-1:0]            p_long;
	wire [NPORTS-1:0]            p_lo;
	wire                         sdram_ready;

	m2_sdram #(
		.COL_BITS ( 10 ),
		.ROW_BITS ( 13 ),
		.BA_BITS  ( 2 ),
		.NP       ( NPORTS ),
		.T_REFI   ( 748 ), // 7.8 us @ 95.91 MHz
		.PRI      ( 8'b0001_1111 ),
		.PRI_TOP  ( 8'b0000_0001 )
	) u_sdram (
		.clk        ( clk_mem ),
		.rst_n      ( mem_rst_n ),
		.ready      ( sdram_ready ),
		.rd_lat_sel ( 3'd1 ), // CL+2 (SDRAM clocked at 180 deg)
		.sd_cke     ( dram_cke ),
		.sd_cs_n    ( ),
		.sd_ras_n   ( dram_ras_n ),
		.sd_cas_n   ( dram_cas_n ),
		.sd_we_n    ( dram_we_n ),
		.sd_ba      ( dram_ba ),
		.sd_a       ( dram_a ),
		.sd_dqm     ( dram_dqm ),
		.sd_dq_o    ( sd_dq_o ),
		.sd_dq_oe   ( sd_dq_oe ),
		.sd_dq_i    ( dram_dq ),
		.wr_req     ( dl_wr ),
		.wr_addr    ( dl_addr ),
		.wr_din     ( dl_din ),
		.wr_be      ( 2'b11 ),
		.wr_ack     ( dl_ack ),
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

	// -------------------------------------------------------------------------
	// 4. Dual Cellular PSRAM PHYs (CRAM0 = FB Bank 0, CRAM1 = FB Bank 1)
	// -------------------------------------------------------------------------
	wire [15:0] c0_dq_out, c1_dq_out;
	wire        c0_dq_oe,  c1_dq_oe;
	assign cram0_dq = c0_dq_oe ? c0_dq_out : 16'hzzzz;
	assign cram1_dq = c1_dq_oe ? c1_dq_out : 16'hzzzz;

	wire        c0_cfg_done, c0_cmd_valid, c0_cmd_ready, c0_cmd_we, c0_wd_pop, c0_rd_valid, c0_rd_last;
	wire [22:0] c0_cmd_addr;
	wire  [4:0] c0_cmd_len;
	wire [15:0] c0_wd_data, c0_rd_data;
	wire  [1:0] c0_wd_be;

	wire        c1_cfg_done, c1_cmd_valid, c1_cmd_ready, c1_cmd_we, c1_wd_pop, c1_rd_valid, c1_rd_last;
	wire [22:0] c1_cmd_addr;
	wire  [4:0] c1_cmd_len;
	wire [15:0] c1_wd_data, c1_rd_data;
	wire  [1:0] c1_wd_be;

	psram_phy #(.LC(2), .CLKDIV(2), .RDLAT(2)) u_cram0_phy (
		.clk       ( clk_mem ),
		.rst       ( !mem_rst_n ),
		.cmd_valid ( c0_cmd_valid ),
		.cmd_ready ( c0_cmd_ready ),
		.cmd_we    ( c0_cmd_we ),
		.cmd_addr  ( c0_cmd_addr ),
		.cmd_len   ( c0_cmd_len ),
		.wd_pop    ( c0_wd_pop ),
		.wd_data   ( c0_wd_data ),
		.wd_be     ( c0_wd_be ),
		.rd_valid  ( c0_rd_valid ),
		.rd_data   ( c0_rd_data ),
		.rd_last   ( c0_rd_last ),
		.cfg_done  ( c0_cfg_done ),
		.p_a       ( cram0_a ),
		.p_dq_out  ( c0_dq_out ),
		.p_dq_oe   ( c0_dq_oe ),
		.p_dq_in   ( cram0_dq ),
		.p_clk     ( cram0_clk ),
		.p_adv_n   ( cram0_adv_n ),
		.p_cre     ( cram0_cre ),
		.p_ce0_n   ( cram0_ce0_n ),
		.p_ce1_n   ( cram0_ce1_n ),
		.p_oe_n    ( cram0_oe_n ),
		.p_we_n    ( cram0_we_n ),
		.p_ub_n    ( cram0_ub_n ),
		.p_lb_n    ( cram0_lb_n ),
		.p_wait    ( cram0_wait )
	);

	psram_phy #(.LC(2), .CLKDIV(2), .RDLAT(2)) u_cram1_phy (
		.clk       ( clk_mem ),
		.rst       ( !mem_rst_n ),
		.cmd_valid ( c1_cmd_valid ),
		.cmd_ready ( c1_cmd_ready ),
		.cmd_we    ( c1_cmd_we ),
		.cmd_addr  ( c1_cmd_addr ),
		.cmd_len   ( c1_cmd_len ),
		.wd_pop    ( c1_wd_pop ),
		.wd_data   ( c1_wd_data ),
		.wd_be     ( c1_wd_be ),
		.rd_valid  ( c1_rd_valid ),
		.rd_data   ( c1_rd_data ),
		.rd_last   ( c1_rd_last ),
		.cfg_done  ( c1_cfg_done ),
		.p_a       ( cram1_a ),
		.p_dq_out  ( c1_dq_out ),
		.p_dq_oe   ( c1_dq_oe ),
		.p_dq_in   ( cram1_dq ),
		.p_clk     ( cram1_clk ),
		.p_adv_n   ( cram1_adv_n ),
		.p_cre     ( cram1_cre ),
		.p_ce0_n   ( cram1_ce0_n ),
		.p_ce1_n   ( cram1_ce1_n ),
		.p_oe_n    ( cram1_oe_n ),
		.p_we_n    ( cram1_we_n ),
		.p_ub_n    ( cram1_ub_n ),
		.p_lb_n    ( cram1_lb_n ),
		.p_wait    ( cram1_wait )
	);

	// -------------------------------------------------------------------------
	// 5. Cartridge Slot 16-bit Bus PHY + Built-in 3D Demo Generator
	// -------------------------------------------------------------------------
	wire        vid_vblank_irq;
	reg         vb_tog_m = 1'b0;
	always @(posedge clk_mem or negedge vid_rst_n) begin
		if (!vid_rst_n)          vb_tog_m <= 1'b0;
		else if (vid_vblank_irq) vb_tog_m <= ~vb_tog_m;
	end
	reg [2:0] vb_sync_s = 3'd0;
	always @(posedge clk_sys or negedge core_rst_n) begin
		if (!core_rst_n) vb_sync_s <= 3'd0;
		else             vb_sync_s <= {vb_sync_s[1:0], vb_tog_m};
	end
	wire vblank_pulse_sys = vb_sync_s[2] ^ vb_sync_s[1];

	wire        cart_detected;
	wire        cq_valid, cq_moire, cq_mipz, cq_end, c_frame_start;
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
	wire [15:0] cart_audio_l, cart_audio_r;
	wire        cart_audio_stb;
	wire        cart_sd_wreq, cart_tex_inval, cart_char_inval;
	wire [25:1] cart_sd_waddr;
	wire [15:0] cart_sd_wdin;
	wire        cart_sd_wack;

	wire        r3d_q_ready;

	m2_cart_bus u_cart_bus (
		.clk_cart                ( clk_cart ),
		.clk_sys                 ( clk_sys ),
		.clk_mem                 ( clk_mem ),
		.rst_n                   ( core_rst_n ),
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
		.pad_key_sys             ( pad_key_sys ),
		.pad_joy_sys             ( pad_joy_sys ),
		.pad_trig_sys            ( pad_trig_sys ),
		.cart_detected           ( cart_detected ),
		.dbg_rx_words            ( ),
		.q_valid                 ( cq_valid ),
		.q_ready                 ( use_demo ? 1'b1 : r3d_q_ready ),
		.q_x0(cq_x0), .q_y0(cq_y0), .q_x1(cq_x1), .q_y1(cq_y1),
		.q_x2(cq_x2), .q_y2(cq_y2), .q_x3(cq_x3), .q_y3(cq_y3),
		.q_col(cq_col), .q_z(cq_z), .q_moire(cq_moire),
		.q_oz0(cq_oz0), .q_oz1(cq_oz1), .q_oz2(cq_oz2), .q_oz3(cq_oz3),
		.q_frac(cq_frac),
		.q_u0(cq_u0), .q_v0(cq_v0), .q_u1(cq_u1), .q_v1(cq_v1),
		.q_u2(cq_u2), .q_v2(cq_v2), .q_u3(cq_u3), .q_v3(cq_v3),
		.q_tex(cq_tex), .q_uvs(cq_uvs), .q_mipz(cq_mipz), .q_end(cq_end),
		.q_tag(cq_tag), .frame_start_cart(c_frame_start),
		.tram_we(tram_we), .tram_addr(tram_waddr), .tram_din(tram_wdin),
		.pal_we(pal_we), .pal_addr(pal_waddr), .pal_din(pal_wdin),
		.xlat_we(xlat_we), .xlat_addr(xlat_waddr), .xlat_din(xlat_wdin),
		.lut_we(lut_we), .lut_sel(lut_sel), .lut_addr(lut_addr), .lut_data(lut_data),
		.sd_wreq(cart_sd_wreq), .sd_waddr(cart_sd_waddr), .sd_wdin(cart_sd_wdin),
		.sd_wack(cart_sd_wack), .tex_inval_cart(cart_tex_inval), .char_inval_cart(cart_char_inval),
		.audio_l(cart_audio_l), .audio_r(cart_audio_r), .audio_stb(cart_audio_stb)
	);

	// Zero-M10K CDC bridge: Cartridge live Texture/Char writes (clk_sys -> clk_mem SDRAM Port 5)
	reg        csdw_tog_s = 1'b0, csdw_pend_s = 1'b0;
	reg [25:1] csdw_addr_s = 25'd0;
	reg [15:0] csdw_din_s  = 16'd0;
	reg        csdw_ack_m  = 1'b0;
	reg [2:0]  csdw_ack_s  = 3'd0;
	assign cart_sd_wack = csdw_pend_s && (csdw_ack_s[2] ^ csdw_ack_s[1]);
	always @(posedge clk_sys or negedge core_rst_n) begin
		if (!core_rst_n) begin
			csdw_tog_s  <= 1'b0;
			csdw_pend_s <= 1'b0;
			csdw_addr_s <= 25'd0;
			csdw_din_s  <= 16'd0;
			csdw_ack_s  <= 3'd0;
		end else begin
			csdw_ack_s <= {csdw_ack_s[1:0], csdw_ack_m};
			if (cart_sd_wack) begin
				csdw_pend_s <= 1'b0;
			end else if (cart_sd_wreq && !csdw_pend_s) begin
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
	always @(posedge clk_mem or negedge vid_rst_n) begin
		if (!vid_rst_n) begin
			csdw_req_m <= 3'd0;
			p5_req_r   <= 1'b0;
			p5_addr_r  <= 25'd0;
			p5_din_r   <= 16'd0;
			csdw_ack_m <= 1'b0;
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

	wire use_demo = demo_mode && !cart_detected;

	wire        dq_valid, dq_end, d_frame_start;
	wire signed [15:0] dq_x0, dq_y0, dq_x1, dq_y1, dq_x2, dq_y2, dq_x3, dq_y3;
	wire [23:0] dq_col;
	wire [31:0] dq_z;
	wire  [3:0] dq_tag;

	m2_demo_gen u_demo_gen (
		.clk          ( clk_sys ),
		.rst_n        ( core_rst_n ),
		.enable       ( use_demo ),
		.vblank_pulse ( vblank_pulse_sys ),
		.frame_start  ( d_frame_start ),
		.q_valid      ( dq_valid ),
		.q_ready      ( use_demo ? r3d_q_ready : 1'b0 ),
		.q_x0(dq_x0), .q_y0(dq_y0), .q_x1(dq_x1), .q_y1(dq_y1),
		.q_x2(dq_x2), .q_y2(dq_y2), .q_x3(dq_x3), .q_y3(dq_y3),
		.q_col(dq_col), .q_z(dq_z), .q_end(dq_end), .q_tag(dq_tag)
	);

	// -------------------------------------------------------------------------
	// 6. Full Unmodified Sega Model 2A 3D Rasterizer (m2_raster3d) + Dual PSRAM FB
	// -------------------------------------------------------------------------
	wire        fb_req, fb_we, fb_wnext, fb_wacc, fb_rvalid, fb_ack;
	wire [24:0] fb_addr;
	wire  [7:0] fb_blen, fb_be;
	wire [63:0] fb_din, fb_dout;
	wire        fb_ready;

	m2_fb_psram u_fb_psram (
		.clk_sys      ( clk_sys ),
		.clk_mem      ( clk_mem ),
		.rst_n        ( mem_rst_n ),
		.fb_req       ( fb_req ),
		.fb_we        ( fb_we ),
		.fb_addr      ( fb_addr ),
		.fb_blen      ( fb_blen ),
		.fb_din       ( fb_din ),
		.fb_be        ( fb_be ),
		.fb_wnext     ( fb_wnext ),
		.fb_wacc      ( fb_wacc ),
		.fb_rvalid    ( fb_rvalid ),
		.fb_ack       ( fb_ack ),
		.fb_dout      ( fb_dout ),
		.c0_cfg_done  ( c0_cfg_done ),
		.c0_cmd_valid ( c0_cmd_valid ),
		.c0_cmd_ready ( c0_cmd_ready ),
		.c0_cmd_we    ( c0_cmd_we ),
		.c0_cmd_addr  ( c0_cmd_addr ),
		.c0_cmd_len   ( c0_cmd_len ),
		.c0_wd_pop    ( c0_wd_pop ),
		.c0_wd_data   ( c0_wd_data ),
		.c0_wd_be     ( c0_wd_be ),
		.c0_rd_valid  ( c0_rd_valid ),
		.c0_rd_data   ( c0_rd_data ),
		.c0_rd_last   ( c0_rd_last ),
		.c1_cfg_done  ( c1_cfg_done ),
		.c1_cmd_valid ( c1_cmd_valid ),
		.c1_cmd_ready ( c1_cmd_ready ),
		.c1_cmd_we    ( c1_cmd_we ),
		.c1_cmd_addr  ( c1_cmd_addr ),
		.c1_cmd_len   ( c1_cmd_len ),
		.c1_wd_pop    ( c1_wd_pop ),
		.c1_wd_data   ( c1_wd_data ),
		.c1_wd_be     ( c1_wd_be ),
		.c1_rd_valid  ( c1_rd_valid ),
		.c1_rd_data   ( c1_rd_data ),
		.c1_rd_last   ( c1_rd_last ),
		.ready_o      ( fb_ready )
	);

	wire  [9:0] vid_x, vid_y;
	wire [15:0] scan_col;
	wire        scan_hit;
	wire  [3:0] show_tag;

	wire        tex_m_req, tex_m2_req, tex_m3_req, tex_m4_req;
	wire [SDR_AW:1] tex_m_addr, tex_m2_addr, tex_m3_addr, tex_m4_addr;

	m2_raster3d #(
		.SCR_W      ( 496 ),
		.SCR_H      ( 384 ),
		.BAND_H     ( 8 ),
		.NBUF       ( 6 ),
		.FTB        ( 1'b1 ),
		.FB_DDR3    ( 1'b1 ),
		.FB_WCOMB   ( 1'b1 ),
		.SPLIT_TRI  ( 1'b1 ),
		.PXC        ( 1'b1 ),
		.PIXSTEP    ( 4 ),
		.FRB        ( 2 ),
		.M2COV      ( 1'b1 ),
		.DIL        ( 1'b1 ),
		.UVCL       ( 1'b1 ),
		.NEGZ       ( 1'b1 ),
		.TXLATE     ( 3 ),
		.TXNS       ( 4 ),
		.TXRSP      ( 4 ),
		.TXK        ( 16 ),
		.TXLW8      ( 1'b1 ),
		.TXREUSE    ( 1'b0 ),
		.SPCULL     ( 1'b1 ),
		.MIP        ( 1'b1 ),
		.TWO_CLOCKS ( 1'b1 ),
		.TEX_AW     ( SDR_AW ),
		.TEXLUT     ( 1'b1 ),
		.KW         ( 20 ),
		.UVSH       ( 1'b1 ),
		.QNX        ( 0 )
	) u_raster3d (
		.clk          ( clk_sys ),
		.clk_mem      ( clk_mem ),
		.rst_n        ( core_rst_n ),
		.frame_start  ( use_demo ? d_frame_start : vblank_pulse_sys ),
		.q_valid      ( use_demo ? dq_valid : cq_valid ),
		.q_ready      ( r3d_q_ready ),
		.q_x0         ( use_demo ? dq_x0 : cq_x0 ),
		.q_y0         ( use_demo ? dq_y0 : cq_y0 ),
		.q_x1         ( use_demo ? dq_x1 : cq_x1 ),
		.q_y1         ( use_demo ? dq_y1 : cq_y1 ),
		.q_x2         ( use_demo ? dq_x2 : cq_x2 ),
		.q_y2         ( use_demo ? dq_y2 : cq_y2 ),
		.q_x3         ( use_demo ? dq_x3 : cq_x3 ),
		.q_y3         ( use_demo ? dq_y3 : cq_y3 ),
		.q_col        ( use_demo ? dq_col : cq_col ),
		.q_z          ( use_demo ? dq_z   : cq_z ),
		.q_moire      ( use_demo ? 1'b0   : cq_moire ),
		.q_oz0        ( use_demo ? 16'h3C00 : cq_oz0 ),
		.q_oz1        ( use_demo ? 16'h3C00 : cq_oz1 ),
		.q_oz2        ( use_demo ? 16'h3C00 : cq_oz2 ),
		.q_oz3        ( use_demo ? 16'h3C00 : cq_oz3 ),
		.q_frac       ( use_demo ? 16'd0 : cq_frac ),
		.q_u0         ( use_demo ? 13'd0 : cq_u0 ),
		.q_v0         ( use_demo ? 13'd0 : cq_v0 ),
		.q_u1         ( use_demo ? 13'd0 : cq_u1 ),
		.q_v1         ( use_demo ? 13'd0 : cq_v1 ),
		.q_u2         ( use_demo ? 13'd0 : cq_u2 ),
		.q_v2         ( use_demo ? 13'd0 : cq_v2 ),
		.q_u3         ( use_demo ? 13'd0 : cq_u3 ),
		.q_v3         ( use_demo ? 13'd0 : cq_v3 ),
		.q_tex        ( use_demo ? 27'd0 : cq_tex ),
		.q_uvs        ( use_demo ? 2'd0  : cq_uvs ),
		.q_mipz       ( use_demo ? 1'b1  : cq_mipz ),
		.q_end        ( use_demo ? dq_end : cq_end ),
		.q_tag        ( use_demo ? dq_tag : cq_tag ),
		.show_tag     ( show_tag ),
		.scan_clk     ( clk_mem ),
		.scan_x       ( vid_x ),
		.scan_y       ( vid_y ),
		.scan_il      ( 1'b0 ),
		.scan_field   ( 1'b0 ),
		.scan_col     ( scan_col ),
		.scan_hit     ( scan_hit ),
		.tex_base0    ( 25'h000_0000 ),
		.tex_base1    ( 25'h020_0000 ),
		.tex_inval    ( cart_tex_inval ),
		.tex_bilinear ( tex_bilinear ),
		.tex_pxk      ( 2'd2 ),
		.tex_mip_mode ( tex_mip_mode ),
		.dil_on       ( 2'd1 ),
		.tex_gamma    ( 2'd0 ),
		.lut_we       ( lut_we ),
		.lut_sel      ( lut_sel ),
		.lut_addr     ( lut_addr ),
		.lut_data     ( lut_data ),
		.list_hold    ( ),
		.fb_test      ( 1'b0 ),
		.fb_pace      ( 3'd0 ),
		.tex_m_req    ( tex_m_req ),
		.tex_m_addr   ( tex_m_addr ),
		.tex_m_ack    ( p_ack[1] ),
		.tex_m_lo     ( p_lo[1] ),
		.tex_m_data   ( p_dout[1] ),
		.tex_m2_en    ( 1'b1 ),
		.tex_m2_req   ( tex_m2_req ),
		.tex_m2_addr  ( tex_m2_addr ),
		.tex_m2_ack   ( p_ack[2] ),
		.tex_m2_lo    ( p_lo[2] ),
		.tex_m2_data  ( p_dout[2] ),
		.tex_m3_en    ( 1'b1 ),
		.tex_m3_req   ( tex_m3_req ),
		.tex_m3_addr  ( tex_m3_addr ),
		.tex_m3_ack   ( p_ack[3] ),
		.tex_m3_lo    ( p_lo[3] ),
		.tex_m3_data  ( p_dout[3] ),
		.tex_m4_en    ( 1'b1 ),
		.tex_m4_req   ( tex_m4_req ),
		.tex_m4_addr  ( tex_m4_addr ),
		.tex_m4_ack   ( p_ack[4] ),
		.tex_m4_lo    ( p_lo[4] ),
		.tex_m4_data  ( p_dout[4] ),
		.fb_req       ( fb_req ),
		.fb_we        ( fb_we ),
		.fb_addr      ( fb_addr ),
		.fb_blen      ( fb_blen ),
		.fb_din       ( fb_din ),
		.fb_be        ( fb_be ),
		.fb_wnext     ( fb_wnext ),
		.fb_wacc      ( fb_wacc ),
		.fb_rvalid    ( fb_rvalid ),
		.fb_ack       ( fb_ack ),
		.fb_dout      ( fb_dout )
	);

	// -------------------------------------------------------------------------
	// 7. Pixel-Exact 2D Tilemap Pipeline (m2_video + m2_char_cache + Tile/Pal RAM)
	// -------------------------------------------------------------------------
	// Exact /6 pixel clock enable on clk_mem (95.90625 / 6 = 15.984375 MHz)
	reg [2:0] ce_div = 3'd0;
	always @(posedge clk_mem or negedge vid_rst_n) begin
		if (!vid_rst_n)          ce_div <= 3'd0;
		else if (ce_div == 3'd5) ce_div <= 3'd0;
		else                     ce_div <= ce_div + 3'd1;
	end
	wire ce_pix = (ce_div == 3'd0);

	wire [14:0] tram_raddr;
	wire [15:0] tram_rdata;
	wire [11:0] pal_raddr;
	wire [15:0] pal_rdata;

	m2_tdp_ram2c #(.DW(16), .AW(15)) u_tram (
		.a_clk  ( clk_sys ),
		.a_addr ( tram_waddr ),
		.a_din  ( tram_wdin ),
		.a_we   ( tram_we ),
		.a_q    ( ),
		.b_clk  ( clk_mem ),
		.b_addr ( tram_raddr ),
		.b_q    ( tram_rdata )
	);

	m2_tdp_ram2c #(.DW(16), .AW(12)) u_pal (
		.a_clk  ( clk_sys ),
		.a_addr ( pal_waddr ),
		.a_din  ( pal_wdin ),
		.a_we   ( pal_we ),
		.a_q    ( ),
		.b_clk  ( clk_mem ),
		.b_addr ( pal_raddr ),
		.b_q    ( pal_rdata )
	);

	wire        char_req, char_ack;
	wire [17:0] char_addr;
	wire [31:0] char_data;
	wire        cc_m_req;
	wire [17:0] cc_m_addr;

	// Auto-invalidate char_cache line when Cartridge streams a write into CHAR_BASE (0x080_0000..0x08F_FFFF)
	wire p5_char_hit = p5_req_r && p_ack[5] && (p5_addr_r[25:20] == 6'b001000);

	m2_char_cache #(.IDX_BITS(10), .ADDR_BITS(18), .SIBLING(1'b0)) u_char_cache (
		.clk        ( clk_mem ),
		.rst_n      ( vid_rst_n ),
		.v_req      ( char_req ),
		.v_addr     ( char_addr ),
		.v_data     ( char_data ),
		.v_ack      ( char_ack ),
		.inval      ( p5_char_hit ),
		.inval_idx  ( p5_addr_r[11:2] ),
		.m_req      ( cc_m_req ),
		.m_addr     ( cc_m_addr ),
		.m_data     ( p_dout[0] ),
		.m_ack      ( p_ack[0] ),
		.dbg_hits   ( ),
		.dbg_misses ( ),
		.dbg_fills  ( )
	);

	// Wire SDRAM ports 0..7
	localparam [SDR_AW:1] CHAR_BASE = 25'h080_0000; // 16 MB offset in Pocket SDRAM
	assign p_req[0]  = cc_m_req;  assign p_we[0] = 1'b0; assign p_addr[0] = CHAR_BASE + {6'd0, cc_m_addr, 1'b0}; assign p_din[0] = 16'd0; assign p_be[0] = 2'b11; assign p_long[0] = 1'b0;
	assign p_req[1]  = tex_m_req;  assign p_we[1] = 1'b0; assign p_addr[1] = tex_m_addr;  assign p_din[1] = 16'd0; assign p_be[1] = 2'b11; assign p_long[1] = 1'b1;
	assign p_req[2]  = tex_m2_req; assign p_we[2] = 1'b0; assign p_addr[2] = tex_m2_addr; assign p_din[2] = 16'd0; assign p_be[2] = 2'b11; assign p_long[2] = 1'b1;
	assign p_req[3]  = tex_m3_req; assign p_we[3] = 1'b0; assign p_addr[3] = tex_m3_addr; assign p_din[3] = 16'd0; assign p_be[3] = 2'b11; assign p_long[3] = 1'b1;
	assign p_req[4]  = tex_m4_req; assign p_we[4] = 1'b0; assign p_addr[4] = tex_m4_addr; assign p_din[4] = 16'd0; assign p_be[4] = 2'b11; assign p_long[4] = 1'b1;
	assign p_req[5]  = p5_req_r;   assign p_we[5] = 1'b1; assign p_addr[5] = p5_addr_r;   assign p_din[5] = p5_din_r; assign p_be[5] = 2'b11; assign p_long[5] = 1'b0;
	assign p_req[6]  = 1'b0; assign p_we[6] = 1'b0; assign p_addr[6] = 25'd0; assign p_din[6] = 16'd0; assign p_be[6] = 2'b00; assign p_long[6] = 1'b0;
	assign p_req[7]  = 1'b0; assign p_we[7] = 1'b0; assign p_addr[7] = 25'd0; assign p_din[7] = 16'd0; assign p_be[7] = 2'b00; assign p_long[7] = 1'b0;

	wire       vid_cat1, vid_hs_m, vid_vs_m, vid_hb_m, vid_vb_m;
	wire [7:0] vid_r_m, vid_g_m, vid_b_m;

	m2_video #(
		.COLUMNS   ( 62 ),
		.LB_RING   ( 1'b1 ),
		.HSCR_FIX  ( 1'b1 ),
		.SCR_SYNC  ( 1'b1 ),
		.SCR_STEP  ( 1'b1 ),
		.SCR_DEPTH ( 2 ),
		.MASK_SKIP ( 1'b1 )
	) u_tilemap (
		.clk            ( clk_mem ),
		.ce_pix         ( ce_pix ),
		.rst_n          ( vid_rst_n ),
		.tile_mask      ( 14'h3FFF ),
		.gamma_sel      ( 2'd0 ),
		.xlat_clk       ( clk_sys ),
		.xlat_we        ( xlat_we ),
		.xlat_addr      ( xlat_waddr ),
		.xlat_din       ( xlat_wdin ),
		.tram_addr      ( tram_raddr ),
		.tram_data      ( tram_rdata ),
		.char_req       ( char_req ),
		.char_addr      ( char_addr ),
		.char_data      ( char_data ),
		.char_ack       ( char_ack ),
		.pal_addr       ( pal_raddr ),
		.pal_data       ( pal_rdata ),
		.vid_cat1       ( vid_cat1 ),
		.vid_r          ( vid_r_m ),
		.vid_g          ( vid_g_m ),
		.vid_b          ( vid_b_m ),
		.vid_hs         ( vid_hs_m ),
		.vid_vs         ( vid_vs_m ),
		.vid_hb         ( vid_hb_m ),
		.vid_vb         ( vid_vb_m ),
		.vblank_irq     ( vid_vblank_irq ),
		.dbg_fetches    ( ),
		.dbg_overruns   ( ),
		.dbg_ovr_frame  ( ),
		.dbg_layer_px   ( ),
		.dbg_hscr       ( ),
		.dbg_vscr       ( ),
		.dbg_layer_have ( ),
		.vid_x          ( vid_x ),
		.vid_y          ( vid_y ),
		.interlace      ( 1'b0 ),
		.scr_flip       ( 1'b0 ),
		.scr_tag        ( show_tag ),
		.scr_vtgl       ( 1'b0 ),
		.scr_ttag       ( 4'd0 ),
		.ntsc_lines     ( 1'b0 ),
		.mid_lines      ( 1'b0 ),
		.narrow         ( 1'b0 ),
		.vid_field      ( )
	);

	// -------------------------------------------------------------------------
	// 8. 2D + 3D Compositor & APF Video Output (496x384 @ 15.984 MHz)
	//    Priority: 2D cat1 > 3D polygon (scan_hit) > 2D cat0
	// -------------------------------------------------------------------------
	wire [7:0] r3d_r = {scan_col[15:11], scan_col[15:13]};
	wire [7:0] r3d_g = {scan_col[10:5],  scan_col[10:9]};
	wire [7:0] r3d_b = {scan_col[4:0],   scan_col[4:2]};

	wire use_3d = scan_hit && !vid_cat1;
	wire [23:0] comp_rgb_m = use_3d ? {r3d_r, r3d_g, r3d_b} : {vid_r_m, vid_g_m, vid_b_m};
	wire        comp_de_m  = ~(vid_hb_m | vid_vb_m);

	// Latch on clk_mem at ce_pix, then register cleanly onto clk_pix (exact /6 phase)
	reg [23:0] pix_rgb_m = 24'd0;
	reg        pix_de_m  = 1'b0, pix_hs_m = 1'b0, pix_vs_m = 1'b0;
	always @(posedge clk_mem) begin
		if (ce_pix) begin
			pix_rgb_m <= comp_rgb_m;
			pix_de_m  <= comp_de_m;
			pix_hs_m  <= vid_hs_m;
			pix_vs_m  <= vid_vs_m;
		end
	end

	always @(posedge clk_pix) begin
		video_rgb <= pix_de_m ? pix_rgb_m : 24'd0;
		video_de  <= pix_de_m;
		video_hs  <= pix_hs_m;
		video_vs  <= pix_vs_m;
	end

	// -------------------------------------------------------------------------
	// 9. APF 48 kHz Stereo I2S Audio Output (sound_i2s from SpaceFish)
	// -------------------------------------------------------------------------
	sound_i2s #(
		.CHANNEL_WIDTH ( 16 ),
		.SIGNED_INPUT  ( 1 )
	) u_i2s (
		.clk_74a    ( clk_74a ),
		.clk_audio  ( clk_sys ),
		.ext_mclk   ( clk_audio_mclk ),
		.audio_l    ( cart_audio_l ),
		.audio_r    ( cart_audio_r ),
		.audio_stb  ( cart_audio_stb ),
		.audio_mclk ( audio_mclk ),
		.audio_lrck ( audio_lrck ),
		.audio_dac  ( audio_dac )
	);

endmodule
`default_nettype wire
