// m2_cart_top: DeadOrPocket Compute Cartridge Top-Level (Sega Model 2A-CRX)
// Target FPGA: Intel Cyclone V 5CEBA5F23C8 (pin-compatible with 5CEBA7F23C8, FBGA-484)
//
// Integrates the complete Sega Model 2A-CRX compute & audio stack:
//   - Intel i960KB + FPU (i960_top: FP_SUBN=2, RC_RING=1, FR=1, F2A=1 @ 25.0 MHz)
//   - Fujitsu MB86233 TGP Coprocessor (m2_copro: 4K prog, subnormal FPU @ 50.0 MHz)
//   - Full 3D Geometry Pipeline (m2_geo + m2_geo_view + m2_geometry @ 50.0 MHz)
//   - Sega Model 2A Sound Board (m2_2a_sound: 68000 fx68k + SCSP + SCSP DSP @ 50.0 MHz)
//   - Model 2A I/O & Peripherals (m2_cpu_bridge, m2_timers, m2_backup, m2_2a_inputs, m2_315_5649, m2_i8251)
//   - 128 MB Dual-Chip SDR SDRAM Controller (m2_sdram, 8 ports, DUAL=1 @ 100.0 MHz)
//   - 30-Pin Analogue Pocket Cartridge Slot PHY (m2_cart_host @ 31.97 MHz = 63.9 MB/s)
//
`default_nettype none

module m2_cart_top (
	input  wire        clk_50m,        // Onboard 50.000 MHz TCXO
	input  wire        ext_rst_n,      // Pushbutton / supervisor reset (active low)
	output wire  [3:0] led_status,     // Diagnostic LEDs [0]=PLL, [1]=SDRAM, [2]=CPU, [3]=BUS_TX

	// ---- 30-Pin Analogue Pocket Cartridge Edge Connector (strictly 3.3V) ---
	input  wire  [7:4] cart_bank0,     // [7]=BUS_CLK(31.97M), [6]=BUS_DIR, [5]=VSYNC, [4]=SOFT_RST_N
	input  wire        cart_pin30,     // POCKET_READY
	output wire        cart_pin31,     // CART_VALID
	inout  wire  [7:0] cart_bank1,     // PKT_HDR[7:0]
	inout  wire  [7:0] cart_bank2,     // BUS_DATA[15:8]
	inout  wire  [7:0] cart_bank3,     // BUS_DATA[7:0]

	// ---- 128 MB Dual-Chip SDR SDRAM (2 x 64 MB 16-bit, DQM on A[12:11]) ----
	output wire        sdram_clk,
	output wire        sdram_cke,
	output wire        sdram_cs_n,
	output wire        sdram_ras_n,
	output wire        sdram_cas_n,
	output wire        sdram_we_n,
	output wire  [1:0] sdram_ba,
	output wire [12:0] sdram_a,
	inout  wire [15:0] sdram_dq,

	// ---- Onboard MicroSD SPI Boot Slot (direct 128 MB ROM loading) ---------
	output wire        sd_sck,
	output wire        sd_cs_n,
	output wire        sd_mosi,
	input  wire        sd_miso
);

	// -------------------------------------------------------------------------
	// 1. Clocks & Reset (50 MHz -> 100 MHz mem, 50 MHz sys, 25 MHz i960 CPU)
	// -------------------------------------------------------------------------
	wire clk_mem, clk_sdram_pin, clk_sys, clk_cpu, pll_locked;

	m2_cart_pll u_pll (
		.refclk        ( clk_50m ),
		.rst           ( !ext_rst_n ),
		.clk_mem       ( clk_mem ),
		.clk_sdram_pin ( clk_sdram_pin ),
		.clk_sys       ( clk_sys ),
		.clk_cpu       ( clk_cpu ),
		.locked        ( pll_locked )
	);

	assign sdram_clk = clk_sdram_pin;

	// Synchronized resets per clock domain
	reg [1:0] rst_mem_s = 2'b00, rst_sys_s = 2'b00, rst_cpu_s = 2'b00;
	wire por_n = ext_rst_n && pll_locked;
	always @(posedge clk_mem or negedge por_n) begin
		if (!por_n) rst_mem_s <= 2'b00;
		else        rst_mem_s <= {rst_mem_s[0], 1'b1};
	end
	wire mem_rst_n = rst_mem_s[1];

	wire pocket_rst_n = cart_bank0[4];
	always @(posedge clk_sys or negedge por_n) begin
		if (!por_n) rst_sys_s <= 2'b00;
		else        rst_sys_s <= {rst_sys_s[0], mem_rst_n & pocket_rst_n};
	end
	wire sys_rst_n = rst_sys_s[1];

	wire sdram_ready;
	wire boot_done, boot_err, boot_prog_ext;
	wire [6:0] boot_game_id;
	always @(posedge clk_cpu or negedge por_n) begin
		if (!por_n) rst_cpu_s <= 2'b00;
		else        rst_cpu_s <= {rst_cpu_s[0], sys_rst_n & sdram_ready & boot_done};
	end
	wire cpu_rst_n = rst_cpu_s[1];

	// -------------------------------------------------------------------------
	// 2. Real SD/SDHC MicroSD SPI Boot Loader (CMD0/8/41/58/17/18/12 -> 128 MB SDRAM)
	// -------------------------------------------------------------------------
	wire        boot_wr_req;
	wire [26:1] boot_wr_addr;
	wire [15:0] boot_wr_din;
	wire        boot_wr_ack;

	m2_sd_loader #(
		.INIT_DIV ( 128 ), // 390 kHz SD init clock
		.FAST_DIV ( 2 )    // 25.0 MHz SDHC multi-block data clock
	) u_sd_loader (
		.clk               ( clk_mem ),
		.rst_n             ( mem_rst_n ),
		.sdram_ready       ( sdram_ready ),
		.sd_sck            ( sd_sck ),
		.sd_cs_n           ( sd_cs_n ),
		.sd_mosi           ( sd_mosi ),
		.sd_miso           ( sd_miso ),
		.wr_req            ( boot_wr_req ),
		.wr_addr           ( boot_wr_addr ),
		.wr_din            ( boot_wr_din ),
		.wr_ack            ( boot_wr_ack ),
		.boot_done         ( boot_done ),
		.boot_err          ( boot_err ),
		.boot_game_id      ( boot_game_id ),
		.boot_prog_ext     ( boot_prog_ext ),
		.boot_words_loaded ( )
	);

	// Synchronize MicroSD boot metadata (clk_mem -> clk_sys)
	reg [6:0] game_id_s1 = 7'h16, game_id_sys = 7'h16;
	reg       prog_ext_s1 = 1'b1, prog_ext_sys = 1'b1;
	always @(posedge clk_sys or negedge sys_rst_n) begin
		if (!sys_rst_n) begin
			game_id_s1   <= 7'h16; game_id_sys  <= 7'h16;
			prog_ext_s1  <= 1'b1;  prog_ext_sys <= 1'b1;
		end else begin
			game_id_s1   <= boot_game_id;  game_id_sys  <= game_id_s1;
			prog_ext_s1  <= boot_prog_ext; prog_ext_sys <= prog_ext_s1;
		end
	end

	// -------------------------------------------------------------------------
	// 3. 128 MB Dual-Chip SDR SDRAM Controller (m2_sdram, 8 ports @ 100 MHz)
	// -------------------------------------------------------------------------
	localparam int unsigned SDR_AW = 26; // 128 MB = 64M x 16-bit words (DUAL=1)
	localparam int unsigned NPORTS = 8;

	// Model 2A-CRX 128 MB SDRAM word-address map (matching Model2.sv)
	localparam [SDR_AW:1] GAME_PROG      = 26'h000_0000;
	localparam [SDR_AW:1] GAME_DATA      = 26'h004_0000;
	localparam [SDR_AW:1] GAME_TEX       = 26'h200_0000; // byte 0x400_0000 (16 MB tex ROM)
	localparam [SDR_AW:1] GAME_POLY      = 26'h280_0000; // byte 0x500_0000 (24 MB polygons)
	localparam [SDR_AW:1] GAME_TBL       = 26'h124_0000; // byte 0x248_0000 (256 KB TGP tables)
	localparam [SDR_AW:1] GAME_SND_2A    = 26'h126_0000; // byte 0x24C_0000 (512 KB 68k prog)
	localparam [SDR_AW:1] GAME_SMP_2A    = 26'h1A0_0000; // byte 0x340_0000 (8 MB SCSP samples)
	localparam [SDR_AW:1] GAME_PROGXB_2A = 26'h12C_0000; // byte 0x258_0000 (+0x40000 -> 0x260_0000)
	localparam [SDR_AW:1] GAME_COPRO     = 26'h13C_0000; // byte 0x278_0000 (4 MB copro data)
	localparam [SDR_AW:1] GAME_WORK      = 26'h162_0000; // 1 MB work RAM
	localparam [SDR_AW:1] GAME_BOARD     = 26'h12A_0000; // 256 KB board RAM
	localparam [SDR_AW:1] GAME_CHAR      = 26'h16A_0000; // 1 MB char RAM
	localparam [SDR_AW:1] GAME_BUFFER    = 26'h172_0000; // 128 KB display list buffer RAM
	localparam [SDR_AW:1] GAME_PAL3D     = 26'h174_0000;
	localparam [SDR_AW:1] GAME_XLAT3D    = 26'h174_8000;
	localparam [SDR_AW:1] GAME_TEXS0     = 26'h176_0000; // 1 MB TEXS0
	localparam [SDR_AW:1] GAME_TEXS1     = 26'h17E_0000; // 1 MB TEXS1
	localparam [SDR_AW:1] GAME_LUMA      = 26'h186_0000;
	localparam [SDR_AW:1] GAME_PRAM0     = 26'h188_0000;
	localparam [SDR_AW:1] GAME_PRAM1     = 26'h190_0000;
	localparam [SDR_AW:1] GAME_TEXRAM    = 26'h198_0000;
	localparam [SDR_AW:1] GAME_SNDRAM_2A = 26'h19A_0000; // 512 KB SCSP/68k sound RAM

	wire [15:0] sd_dq_o;
	wire        sd_dq_oe;
	assign sdram_dq = sd_dq_oe ? sd_dq_o : 16'hzzzz;

	wire [NPORTS-1:0]            p_req, p_we, p_ack, p_long, p_lo;
	wire [NPORTS-1:0][SDR_AW:1]  p_addr;
	wire [NPORTS-1:0][15:0]      p_din;
	wire [NPORTS-1:0][1:0]       p_be;
	wire [NPORTS-1:0][63:0]      p_dout;

	// Slow-domain (clk_sys = 50 MHz) SDRAM port arrays bridged to clk_mem (100 MHz)
	wire [NPORTS-1:0]            sp_req, sp_we, sp_ack;
	wire [NPORTS-1:0][SDR_AW:1]  sp_addr;
	wire [NPORTS-1:0][15:0]      sp_din;
	wire [NPORTS-1:0][1:0]       sp_be;
	wire [NPORTS-1:0][63:0]      sp_dout;

	m2_sdram_cdc #(
		.NP   ( NPORTS ),
		.AW   ( SDR_AW ),
		.FAST ( 8'b0000_0000 )
	) u_sdram_cdc (
		.clk_slow  ( clk_sys ),   .s_rst_n ( sys_rst_n ),
		.clk_fast  ( clk_mem ),   .f_rst_n ( mem_rst_n ),
		.s_req     ( sp_req ),    .s_addr  ( sp_addr ),
		.s_ack     ( sp_ack ),    .s_dout  ( sp_dout ),
		.s_we      ( sp_we ),     .s_din   ( sp_din ),    .s_be ( sp_be ),
		.s_wr_req  ( 1'b0 ),      .s_wr_addr ( 26'd0 ),   .s_wr_din ( 16'd0 ), .s_wr_be ( 2'b00 ), .s_wr_ack ( ),
		.f_req     ( p_req ),     .f_addr  ( p_addr ),
		.f_ack     ( p_ack ),     .f_dout  ( p_dout ),
		.f_we      ( p_we ),      .f_din   ( p_din ),     .f_be ( p_be ),
		.f_wr_req  ( ),           .f_wr_addr ( ),         .f_wr_din ( ),       .f_wr_be ( ),       .f_wr_ack ( 1'b0 )
	);
	assign p_long = {NPORTS{1'b0}};

	m2_sdram #(
		.COL_BITS ( 10 ),
		.ROW_BITS ( 13 ),
		.BA_BITS  ( 2 ),
		.DUAL     ( 1'b1 ),
		.NP       ( NPORTS ),
		.T_REFI   ( 780 ),
		.PRI      ( 8'b0000_0011 ),
		.PRI_TOP  ( 8'b0000_0001 )
	) u_sdram (
		.clk        ( clk_mem ),
		.rst_n      ( mem_rst_n ),
		.ready      ( sdram_ready ),
		.rd_lat_sel ( 3'd1 ),
		.sd_cke     ( sdram_cke ),
		.sd_cs_n    ( sdram_cs_n ),
		.sd_ras_n   ( sdram_ras_n ),
		.sd_cas_n   ( sdram_cas_n ),
		.sd_we_n    ( sdram_we_n ),
		.sd_ba      ( sdram_ba ),
		.sd_a       ( sdram_a ),
		.sd_dqm     ( ), // DUAL=1 carries DQM on sdram_a[12:11]
		.sd_dq_o    ( sd_dq_o ),
		.sd_dq_oe   ( sd_dq_oe ),
		.sd_dq_i    ( sdram_dq ),
		.wr_req     ( boot_wr_req ),
		.wr_addr    ( boot_wr_addr ),
		.wr_din     ( boot_wr_din ),
		.wr_be      ( 2'b11 ),
		.wr_ack     ( boot_wr_ack ),
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
	// 4. Intel i960KB + Full Subnormal FPU (25.000 MHz) + m2_cpu_bridge
	// -------------------------------------------------------------------------
	wire        bus_req, bus_ifetch, bus_we, bus_ack;
	wire [31:0] bus_addr, bus_wdata, bus_rdata;
	wire  [3:0] bus_be;
	wire  [3:0] cpu_irq;
	wire [31:0] dbg_pc;

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
		.irq(cpu_irq),
		.dbg_pc(dbg_pc), .dbg_ip(), .dbg_acc_cnt(), .trap(), .halted(),
		.dbg_sat(), .dbg_prcb(), .dbg_icr(), .dbg_intr_cnt(), .dbg_intr_work(),
		.dbg_insn(), .trap_op(), .dbg_rip(), .dbg_pfp(), .dbg_ts(), .dbg_rcache_pos(),
		.dbg_to_memory(), .dbg_rf_req(), .dbg_rf_ack(), .dbg_rf_addr(),
		.dbg_rf_we(), .dbg_rf_wdata()
	);

	// Bridge runs on clk_sys (50 MHz, exact 2:1 to clk_cpu=25 MHz -> ASYNC=0!)
	// Port 0 of u_sdram_cdc bridges clk_sys <-> clk_mem (100 MHz) cleanly.
	wire        cpu_sd_req, cpu_sd_we, cpu_sd_ack;
	wire [SDR_AW:1] cpu_sd_addr;
	wire [15:0] cpu_sd_din;
	wire  [1:0] cpu_sd_be;
	wire [63:0] cpu_sd_dout;

	assign sp_req[0]   = cpu_sd_req;
	assign sp_we[0]    = cpu_sd_we;
	assign sp_addr[0]  = cpu_sd_addr;
	assign sp_din[0]   = cpu_sd_din;
	assign sp_be[0]    = cpu_sd_be;
	assign cpu_sd_dout = sp_dout[0];
	assign cpu_sd_ack  = sp_ack[0];

	wire        oc_tram_we, oc_pal_we, oc_xlat_we, char_wr, col_inval, buf_inval, tex_inval;
	wire [14:0] oc_addr;
	wire [15:0] oc_din, oc_tram_q, oc_pal_q;
	wire [17:0] char_wr_addr;
	wire  [6:0] oc_xlat_addr;
	wire  [7:0] oc_xlat_din;

	wire        io_sel, io_we, io_stall;
	wire [31:0] io_addr, io_wdata, io_rdata;
	wire  [3:0] io_be;
	wire        geo_push_busy;

	// Local shadow RAMs for 0-wait i960 readbacks of TRAM/PAL
	m2_tdp_ram2c #(.DW(16), .AW(15)) u_tram_shadow (
		.a_clk(clk_sys), .a_addr(oc_addr), .a_din(oc_din), .a_we(oc_tram_we), .a_q(oc_tram_q),
		.b_clk(clk_sys), .b_addr(15'd0), .b_q()
	);
	m2_tdp_ram2c #(.DW(16), .AW(12)) u_pal_shadow (
		.a_clk(clk_sys), .a_addr(oc_addr[11:0]), .a_din(oc_din), .a_we(oc_pal_we), .a_q(oc_pal_q),
		.b_clk(clk_sys), .b_addr(12'd0), .b_q()
	);

	m2_cpu_bridge #(
		.DCACHE_EN ( 1'b1 ),
		.BUFFERRAM ( 1'b1 ),
		.AW        ( SDR_AW ),
		.BOARD_2A  ( 1'b1 ),
		.ASYNC     ( 1'b0 )
	) u_bridge (
		.clk_cpu(clk_cpu), .rst_n_cpu(cpu_rst_n),
		.bus_req(bus_req), .bus_ifetch(bus_ifetch), .bus_we(bus_we),
		.bus_addr(bus_addr), .bus_be(bus_be), .bus_wdata(bus_wdata),
		.bus_rdata(bus_rdata), .bus_ack(bus_ack),
		.clk_mem(clk_sys), .rst_n_mem(sys_rst_n),
		.base_prog(GAME_PROG), .prog_ext(prog_ext_sys), .base_progx(GAME_PROGXB_2A),
		.base_data(GAME_DATA), .base_work(GAME_WORK), .base_board(GAME_BOARD),
		.base_char(GAME_CHAR), .base_buffer(GAME_BUFFER),
		.base_pal3d(GAME_PAL3D), .base_xlat3d(GAME_XLAT3D),
		.base_texs0(GAME_TEXS0), .base_texs1(GAME_TEXS1), .base_luma(GAME_LUMA),
		.sd_req(cpu_sd_req), .sd_we(cpu_sd_we), .sd_addr(cpu_sd_addr),
		.sd_din(cpu_sd_din), .sd_be(cpu_sd_be), .sd_dout(cpu_sd_dout), .sd_ack(cpu_sd_ack),
		.oc_tram_we(oc_tram_we), .oc_pal_we(oc_pal_we), .oc_addr(oc_addr),
		.oc_din(oc_din), .oc_tram_q(oc_tram_q), .oc_pal_q(oc_pal_q),
		.char_wr(char_wr), .char_wr_addr(char_wr_addr),
		.oc_xlat_we(oc_xlat_we), .oc_xlat_addr(oc_xlat_addr), .oc_xlat_din(oc_xlat_din),
		.col_inval(col_inval), .buf_inval(buf_inval), .tex_inval(tex_inval),
		.io_rdata(io_rdata), .io_stall(io_stall), .buf_wr_stall(geo_push_busy),
		.io_sel(io_sel), .io_we(io_we), .io_addr(io_addr),
		.io_wdata(io_wdata), .io_be(io_be),
		.dbg_cpu_reads(), .dbg_cpu_writes(), .dbg_unmapped(),
		.dbg_last_addr(), .dbg_last_dout(), .dbg_probe6(), .dbg_probe2(),
		.dbg_tram_wr(), .dbg_pal_wr()
	);

	// -------------------------------------------------------------------------
	// 5. Fujitsu MB86233 TGP Coprocessor (m2_copro @ 50 MHz)
	// -------------------------------------------------------------------------
	wire sel_copro_ctl     = io_sel && (io_addr[27:2] == 26'h026_0000); // 0x00980000
	wire sel_copro_fifoctl = io_sel && (io_addr[27:2] == 26'h026_0001); // 0x00980004
	wire sel_copro_fn      = io_sel && (io_addr[27:14] == 14'h0220);    // 0x00880000-0x00883fff
	wire sel_copro_fifo    = io_sel && (io_addr[27:14] == 14'h0221);    // 0x00884000-0x00887fff

	wire [31:0] copro_rdata;
	wire        copro_stall;
	wire        tgp_tbl_req, tgp_tbl_ack;
	wire [15:0] tgp_tbl_addr;
	wire [63:0] tgp_tbl_dout;
	wire        tgp_dat_req, tgp_dat_we, tgp_dat_is_buf, tgp_dat_half, tgp_dat_ack;
	wire [19:0] tgp_dat_addr;
	wire [15:0] tgp_dat_wdata;
	wire [63:0] tgp_dat_dout;
	wire        tgp_bufw_req, tgp_bufw_ack;
	wire [18:0] tgp_bufw_addr;
	wire [15:0] tgp_bufw_data;

	m2_copro #(
		.PROG_WORDS ( 4096 ),
		.SUBNORM    ( 1'b1 ),
		.EARLY_ALU  ( 1'b1 ),
		.BUFW_Q     ( 32 ),
		.OUT_STALL  ( 1'b1 )
	) u_copro (
		.clk(clk_sys), .rst_n(cpu_rst_n),
		.sel_ctl(sel_copro_ctl), .sel_fifo(sel_copro_fifo),
		.sel_fn(sel_copro_fn), .fn_code(io_addr[11:4]), .sel_fifoctl(sel_copro_fifoctl),
		.we(io_we), .wdata(io_wdata), .rdata(copro_rdata), .stall(copro_stall),
		.tbl_req(tgp_tbl_req), .tbl_addr(tgp_tbl_addr),
		.tbl_rdata(tgp_tbl_dout[31:0]), .tbl_ack(tgp_tbl_ack),
		.dat_req(tgp_dat_req), .dat_addr(tgp_dat_addr),
		.dat_we(tgp_dat_we), .dat_wdata(tgp_dat_wdata),
		.dat_is_buf(tgp_dat_is_buf), .dat_half(tgp_dat_half),
		.bufw_req(tgp_bufw_req), .bufw_addr(tgp_bufw_addr), .bufw_data(tgp_bufw_data),
		.bufw_ack(tgp_bufw_ack),
		.dat_rdata(tgp_dat_dout[31:0]), .dat_ack(tgp_dat_ack)
	);

	// SDRAM Port 2: TGP Math Tables
	assign sp_req[2]    = tgp_tbl_req;
	assign sp_we[2]     = 1'b0;
	assign sp_addr[2]   = GAME_TBL + {9'd0, tgp_tbl_addr, 1'b0};
	assign sp_din[2]    = 16'd0;
	assign sp_be[2]     = 2'b11;
	assign tgp_tbl_dout = sp_dout[2];
	assign tgp_tbl_ack  = sp_ack[2];

	// SDRAM Port 3: TGP Copro Data / Buffer RAM
	wire [SDR_AW:1] tgp_dat_sdaddr = tgp_dat_is_buf
		? (GAME_BUFFER + {5'd0, tgp_dat_addr[19:0], tgp_dat_half})
		: (GAME_COPRO  + {5'd0, tgp_dat_addr[19:0], tgp_dat_half});

	assign sp_req[3]    = tgp_dat_req;
	assign sp_we[3]     = tgp_dat_we;
	assign sp_addr[3]   = tgp_dat_sdaddr;
	assign sp_din[3]    = tgp_dat_wdata;
	assign sp_be[3]     = 2'b11;
	assign tgp_dat_dout = sp_dout[3];
	assign tgp_dat_ack  = sp_ack[3];

	// -------------------------------------------------------------------------
	// 6. Full 3D Geometry Pipeline (m2_geo + m2_geo_view + m2_geometry @ 50 MHz)
	// -------------------------------------------------------------------------
	wire        cart_vsync;
	wire [31:0] cart_pad_key, cart_pad_joy;
	wire [15:0] cart_pad_trig;

	wire sel_geo_ctl   = io_sel && io_we && (io_addr[27:2] == 26'h026_0002); // 0x00980008
	wire sel_geo_setwp = io_sel && io_we && (io_addr[27:2] == 26'h020_0402); // 0x00801008
	wire sel_geo_setrp = io_sel && io_we && (io_addr[27:2] == 26'h020_0C02); // 0x00803008
	wire sel_geo_push  = io_sel && io_we && ((io_addr[27:12] == 16'h0080) || (io_addr[27:14] == 14'h0201));

	wire [31:0] geo_rd_wp, geo_rd_rp;
	wire        geo_sd_wr_req, geo_sd_wr_ack, geo_push_stall;
	wire [SDR_AW:1] geo_sd_wr_addr;
	wire [15:0] geo_sd_wr_din;

	wire        walk_rd_req, walk_rd_ack, walk_started;
	wire [18:0] walk_rd_addr;
	wire [31:0] walk_rd_data;
	wire        geo_mat_we, geo_tp_we, geo_tc_we, geo_obj_valid;
	wire  [3:0] geo_mat_idx, geo_obj_win;
	wire  [4:0] geo_tp_idx;
	wire  [7:0] geo_tp_diffuse, geo_tp_ambient, geo_zadj_e;
	wire [11:0] geo_tc_l, geo_lod_l;
	wire [31:0] geo_mat_data, geo_foc_x, geo_foc_y, geo_lit_x, geo_lit_y, geo_lit_z;
	wire [31:0] geo_win_vp_s, geo_win_vp_e, geo_win_c0;
	wire [31:0] geo_obj_tpa, geo_obj_tha, geo_obj_oba, geo_obj_obc;
	wire [15:0] geo_walk_frames;
	wire        eng_busy;

	m2_geo #(
		.AW           ( SDR_AW ),
		.DEPTH        ( 128 ),
		.AFTER_STRICT ( 1'b1 ),
		.LIST_WIN     ( 8192 )
	) u_geo (
		.clk(clk_sys), .rst_n(cpu_rst_n),
		.wr_ctl(sel_geo_ctl), .wr_setwp(sel_geo_setwp), .wr_setrp(sel_geo_setrp),
		.trig_mode(2'd2), .skip(2'd0), .wr_push(sel_geo_push), .wdata(io_wdata),
		.rd_wp(geo_rd_wp), .rd_rp(geo_rd_rp),
		.base_buffer(GAME_BUFFER),
		.sd_wr_req(geo_sd_wr_req), .sd_wr_addr(geo_sd_wr_addr),
		.sd_wr_din(geo_sd_wr_din), .sd_wr_ack(geo_sd_wr_ack), .sd_busy(),
		.frame_start(cart_vsync),
		.rd_req(walk_rd_req), .rd_addr(walk_rd_addr), .rd_data(walk_rd_data), .rd_ack(walk_rd_ack),
		.mat_we(geo_mat_we), .mat_idx(geo_mat_idx), .mat_data(geo_mat_data),
		.eng_busy(eng_busy),
		.base_pram0(GAME_PRAM0), .base_pram1(GAME_PRAM1), .base_texram(GAME_TEXRAM),
		.foc_x(geo_foc_x), .foc_y(geo_foc_y), .zadj_e(geo_zadj_e),
		.win_vp_s(geo_win_vp_s), .win_vp_e(geo_win_vp_e), .win_c0(geo_win_c0), .win_cnt(),
		.obj_win(geo_obj_win), .lit_x(geo_lit_x), .lit_y(geo_lit_y), .lit_z(geo_lit_z),
		.push_stall(geo_push_stall), .push_busy(geo_push_busy),
		.tp_we(geo_tp_we), .tc_we(geo_tc_we), .tc_l(geo_tc_l), .lod_l(geo_lod_l),
		.tp_idx(geo_tp_idx), .tp_diffuse(geo_tp_diffuse), .tp_ambient(geo_tp_ambient),
		.obj_tpa(geo_obj_tpa), .obj_tha(geo_obj_tha), .obj_oba(geo_obj_oba), .obj_obc(geo_obj_obc),
		.obj_valid(geo_obj_valid), .dbg_walk_frames(geo_walk_frames), .walk_started(walk_started)
	);

	wire [31:0] gv_xc, gv_yc, gv_a_left, gv_a_right, gv_a_bottom, gv_a_top;
	m2_geo_view #(.CRTC_X(0), .CRTC_Y(127), .LIVE(1'b0)) u_geo_view (
		.clk(clk_sys), .rst_n(cpu_rst_n),
		.crtc_x(16'sd0), .crtc_y(16'sd127),
		.win_vp_s(geo_win_vp_s), .win_vp_e(geo_win_vp_e), .win_c0(geo_win_c0),
		.xc(gv_xc), .yc(gv_yc),
		.a_left(gv_a_left), .a_right(gv_a_right), .a_bottom(gv_a_bottom), .a_top(gv_a_top)
	);

	wire        eng_mem_req, eng_mem_ack;
	wire [23:0] eng_mem_addr;
	wire  [1:0] eng_mem_space;
	wire [31:0] eng_mem_data;

	wire        q3d_valid, q3d_ready, q3d_tlinv, q3d_mipz;
	wire signed [15:0] q3d_x0, q3d_y0, q3d_x1, q3d_y1, q3d_x2, q3d_y2, q3d_x3, q3d_y3;
	wire [15:0] q3d_oz0, q3d_oz1, q3d_oz2, q3d_oz3, q3d_frac;
	wire [12:0] q3d_u0, q3d_v0, q3d_u1, q3d_v1, q3d_u2, q3d_v2, q3d_u3, q3d_v3;
	wire  [1:0] q3d_uvs;
	wire [23:0] q3d_tex, q3d_col;
	wire  [7:0] q3d_trow, q3d_lum;
	wire [31:0] q3d_z;

	m2_geometry #(
		.MIPZ   ( 1'b1 ),
		.MIPZ_B ( 3 ),
		.TEXLUT ( 1'b1 ),
		.WINKEY ( 1'b1 ),
		.UVSH   ( 1'b1 )
	) u_geometry (
		.clk(clk_sys), .rst_n(cpu_rst_n),
		.start(geo_obj_valid), .oba(geo_obj_oba), .obc(geo_obj_obc), .busy(eng_busy),
		.mat_we(geo_mat_we), .mat_idx(geo_mat_idx), .mat_data(geo_mat_data),
		.foc_x(geo_foc_x), .foc_y(geo_foc_y), .obj_win(geo_obj_win),
		.mem_req(eng_mem_req), .mem_addr(eng_mem_addr), .mem_data(eng_mem_data), .mem_ack(eng_mem_ack),
		.xc(gv_xc), .yc(gv_yc), .a_left(gv_a_left), .a_right(gv_a_right),
		.a_bottom(gv_a_bottom), .a_top(gv_a_top),
		.tha(geo_obj_tha), .tpa(geo_obj_tpa), .lit_x(geo_lit_x), .lit_y(geo_lit_y), .lit_z(geo_lit_z),
		.tp_we(geo_tp_we), .tp_idx(geo_tp_idx), .tp_diffuse(geo_tp_diffuse), .tp_ambient(geo_tp_ambient),
		.tc_we(geo_tc_we), .tc_l(geo_tc_l), .lod_l(geo_lod_l), .mz_exact(1'b1),
		.col_inval(col_inval), .tex_lum(2'd0), .gamma_sel(2'd0), .tex_off(1'b0),
		.mem_space(eng_mem_space), .dbg_col_miss(),
		.q_valid(q3d_valid), .q_ready(q3d_ready),
		.q_x0(q3d_x0), .q_y0(q3d_y0), .q_x1(q3d_x1), .q_y1(q3d_y1),
		.q_x2(q3d_x2), .q_y2(q3d_y2), .q_x3(q3d_x3), .q_y3(q3d_y3),
		.q_oz0(q3d_oz0), .q_oz1(q3d_oz1), .q_oz2(q3d_oz2), .q_oz3(q3d_oz3),
		.q_u0(q3d_u0), .q_v0(q3d_v0), .q_u1(q3d_u1), .q_v1(q3d_v1),
		.q_u2(q3d_u2), .q_v2(q3d_v2), .q_u3(q3d_u3), .q_v3(q3d_v3),
		.q_uvs(q3d_uvs), .q_tex(q3d_tex), .q_tlinv(q3d_tlinv), .q_trow(q3d_trow),
		.q_lum(q3d_lum), .q_mipz(q3d_mipz), .q_frac(q3d_frac), .q_col(q3d_col), .q_z(q3d_z),
		.zadj_e(geo_zadj_e)
	);

	// Port 1 (shared sequentially between walk_rd and eng_mem via eng_busy interlock)
	wire [SDR_AW:1] eng_sd_addr =
		(eng_mem_space == 2'd0) ? (GAME_POLY   + {1'b0, eng_mem_addr, 1'b0}) :
		(eng_mem_space == 2'd1) ? (GAME_TEX    + {1'b0, eng_mem_addr, 1'b0}) :
		(eng_mem_space == 2'd2) ? (GAME_PAL3D  + {15'd0, eng_mem_addr[9:0], 1'b0}) :
		                          (GAME_XLAT3D + {10'd0, eng_mem_addr[14:0], 1'b0});
	wire            p1_s_req  = eng_busy ? eng_mem_req : walk_rd_req;
	wire [SDR_AW:1] p1_s_addr = eng_busy ? eng_sd_addr : (GAME_BUFFER + {6'd0, walk_rd_addr, 1'b0});
	wire [63:0]     p1_s_dout;
	wire            p1_s_ack;
	assign eng_mem_data = p1_s_dout[31:0];
	assign walk_rd_data = p1_s_dout[31:0];
	assign eng_mem_ack  = eng_busy && p1_s_ack;
	assign walk_rd_ack  = !eng_busy && p1_s_ack;

	assign sp_req[1]  = p1_s_req;
	assign sp_we[1]   = 1'b0;
	assign sp_addr[1] = p1_s_addr;
	assign sp_din[1]  = 16'd0;
	assign sp_be[1]   = 2'b11;
	assign p1_s_dout  = sp_dout[1];
	assign p1_s_ack   = sp_ack[1];

	// Port 7: Shared posted SDRAM write port (geo_sd_wr > tgp_bufw)
	wire            p7_take_geo = geo_sd_wr_req;
	wire            p7_s_req    = geo_sd_wr_req || tgp_bufw_req;
	wire [SDR_AW:1] p7_s_addr   = p7_take_geo ? geo_sd_wr_addr : (GAME_BUFFER + {7'd0, tgp_bufw_addr});
	wire [15:0]     p7_s_din    = p7_take_geo ? geo_sd_wr_din  : tgp_bufw_data;
	wire            p7_s_ack;
	assign geo_sd_wr_ack =  p7_take_geo && p7_s_ack;
	assign tgp_bufw_ack  = !p7_take_geo && p7_s_ack;

	assign sp_req[7]  = p7_s_req;
	assign sp_we[7]   = 1'b1;
	assign sp_addr[7] = p7_s_addr;
	assign sp_din[7]  = p7_s_din;
	assign sp_be[7]   = 2'b11;
	assign p7_s_ack   = sp_ack[7];

	// Emit end-of-list sentinel quad when geo_walk_frames advances
	reg [15:0] prev_walk_frames = 16'd0;
	reg        qend_pend = 1'b0;
	always @(posedge clk_sys or negedge cpu_rst_n) begin
		if (!cpu_rst_n) begin
			prev_walk_frames <= 16'd0;
			qend_pend        <= 1'b0;
		end else begin
			prev_walk_frames <= geo_walk_frames;
			if (geo_walk_frames != prev_walk_frames) qend_pend <= 1'b1;
			else if (qend_pend && !q3d_valid && host_q_ready) qend_pend <= 1'b0;
		end
	end

	wire        host_q_ready;
	assign q3d_ready = host_q_ready;
	wire        ch0_q_valid = q3d_valid || qend_pend;
	wire        ch0_q_end   = !q3d_valid && qend_pend;
	wire [26:0] ch0_q_tex   = {q3d_tex[0], q3d_trow[1:0], q3d_tex[23:12], q3d_tlinv, q3d_tex[10:0]};

	// -------------------------------------------------------------------------
	// 7. Sega Model 2A Sound Board (68000 fx68k + SCSP + DSP @ 50 MHz)
	// -------------------------------------------------------------------------
	wire sel_uart = io_sel && (io_addr[27:4] == 24'h01C800); // 0x01c80000
	wire [7:0] uart_data_o, uart_stat_o;
	wire [7:0] u2s_data, s2u_data, snd_rx_d, snd_tx_d;
	wire       u2s_val, u2s_ack, s2u_val, s2u_ack, snd_rx_v, snd_rx_a, snd_tx_v, snd_tx_a;

	m2_i8251 u_uart (
		.clk(clk_sys), .rst_n(cpu_rst_n),
		.sel(sel_uart && (io_we || io_be[0])), .we(io_we), .addr(io_be[2]),
		.din(io_be[2] ? io_wdata[23:16] : io_wdata[7:0]), .dout(),
		.data_o(uart_data_o), .stat_o(uart_stat_o),
		.tx_data(u2s_data), .tx_valid(u2s_val), .tx_ack(u2s_ack),
		.rx_data(s2u_data), .rx_valid(s2u_val), .rx_ack(s2u_ack)
	);

	m2_sound_link #(.BYTE_CYCLES(1600)) u_snd_link (
		.clk(clk_sys), .rst_n(cpu_rst_n),
		.a_tx_data(u2s_data), .a_tx_valid(u2s_val), .a_tx_ack(u2s_ack),
		.a_rx_data(s2u_data), .a_rx_valid(s2u_val), .a_rx_ack(s2u_ack),
		.b_tx_data(snd_tx_d), .b_tx_valid(snd_tx_v), .b_tx_ack(snd_tx_a),
		.b_rx_data(snd_rx_d), .b_rx_valid(snd_rx_v), .b_rx_ack(snd_rx_a)
	);

	wire        sa_req, sa_we, sa_ack, sb_req, sb_ack, sc_req, sc_we, sc_ack;
	wire [SDR_AW:1] sa_addr, sb_addr, sc_addr;
	wire [15:0] sa_din, sc_din;
	wire  [1:0] sa_be;
	wire [63:0] sa_dout, sb_dout, sc_dout;
	wire signed [15:0] snd_l, snd_r;

	m2_2a_sound #(
		.AW       ( SDR_AW ),
		.RAM_BASE ( GAME_SNDRAM_2A ),
		.ROM_BASE ( GAME_SND_2A ),
		.SMP_BASE ( GAME_SMP_2A ),
		.PHI_NUM  ( 14112 ), // 2 x 11.2896 MHz / 50 MHz = 14112 / 31250
		.PHI_DEN  ( 31250 ),
		.T44_NUM  ( 441 ),   // 44,100 Hz / 50 MHz = 441 / 500000
		.T44_DEN  ( 500000 )
	) u_sound (
		.clk(clk_sys), .rst_n(cpu_rst_n),
		.rx_data(snd_rx_d), .rx_valid(snd_rx_v), .rx_ack(snd_rx_a),
		.tx_data(snd_tx_d), .tx_valid(snd_tx_v), .tx_ack(snd_tx_a),
		.a_req(sa_req), .a_addr(sa_addr), .a_we(sa_we), .a_din(sa_din), .a_be(sa_be), .a_ack(sa_ack), .a_dout(sa_dout),
		.b_req(sb_req), .b_addr(sb_addr), .b_ack(sb_ack), .b_dout(sb_dout),
		.c_req(sc_req), .c_addr(sc_addr), .c_we(sc_we), .c_din(sc_din), .c_ack(sc_ack), .c_dout(sc_dout),
		.snd_tarc(1'b0), .snd_boost(2'd0),
		.snd_l(snd_l), .snd_r(snd_r)
	);

	// SDRAM Ports 4, 5, 6: Sound 68000, SCSP Slots, SCSP DSP
	assign sp_req[4]  = sa_req;  assign sp_we[4] = sa_we;  assign sp_addr[4] = sa_addr;
	assign sp_din[4]  = sa_din;  assign sp_be[4] = sa_be;  assign sa_dout    = sp_dout[4]; assign sa_ack = sp_ack[4];

	assign sp_req[5]  = sb_req;  assign sp_we[5] = 1'b0;   assign sp_addr[5] = sb_addr;
	assign sp_din[5]  = 16'd0;   assign sp_be[5] = 2'b11;  assign sb_dout    = sp_dout[5]; assign sb_ack = sp_ack[5];

	assign sp_req[6]  = sc_req;  assign sp_we[6] = sc_we;  assign sp_addr[6] = sc_addr;
	assign sp_din[6]  = sc_din;  assign sp_be[6] = 2'b11;  assign sc_dout    = sp_dout[6]; assign sc_ack = sp_ack[6];

	// 48 kHz audio strobe generator from 50 MHz (48,000 / 50,000,000 = 3 / 3125)
	reg [11:0] aud_acc = 12'd0;
	reg        aud_stb = 1'b0;
	always @(posedge clk_sys or negedge sys_rst_n) begin
		if (!sys_rst_n) begin aud_acc <= 12'd0; aud_stb <= 1'b0; end
		else if (aud_acc >= 12'd3122) begin aud_acc <= aud_acc - 12'd3122; aud_stb <= 1'b1; end
		else begin aud_acc <= aud_acc + 12'd3; aud_stb <= 1'b0; end
	end

	// -------------------------------------------------------------------------
	// 8. Model 2A Timers, Backup SRAM, 315-5649 I/O & Interrupt Controller
	// -------------------------------------------------------------------------
	wire sel_timers = io_sel && (io_addr[27:4] == 24'h00F000); // 0x00f00000
	wire sel_backup = io_sel && (io_addr[27:14] == 14'h0740);  // 0x01d00000
	wire sel_io5649 = io_sel && (io_addr[27:5] == 23'h00E000); // 0x01c00000
	wire sel_intreq = io_sel && (io_addr[27:2] == 26'h03A_0000);
	wire sel_intena = io_sel && (io_addr[27:2] == 26'h03A_0001);

	wire [31:0] tmr_rdata, bkp_rdata, io5649_rdata;
	wire  [3:0] tmr_expire;

	m2_timers #(.TICK_NUM(1), .TICK_DEN(2)) u_timers (
		.clk(clk_sys), .rst_n(cpu_rst_n),
		.sel(sel_timers), .we(io_we), .idx(io_addr[3:2]), .be(io_be),
		.wdata(io_wdata), .rdata(tmr_rdata), .expire(tmr_expire)
	);

	m2_backup u_backup (
		.clk(clk_sys), .rst_n(cpu_rst_n),
		.sel(sel_backup), .we(io_we), .word(io_addr[13:2]), .be(io_be), .wdata(io_wdata),
		.hps_we(1'b0), .hps_word(12'd0), .hps_be(4'd0), .hps_wdata(32'd0),
		.dbg_word(12'd0), .dbg_rd_sel(4'd0), .dbg_q(), .dbg_first(), .rdata(bkp_rdata)
	);

	wire [7:0] cab_in0, cab_in1, cab_in2, cab_an0, cab_an1, cab_an2, pe_out;
	m2_2a_inputs #(.SYS_MHZ(50), .ANALOG(1'b1), .GUN(1'b0), .MOTION(1'b1)) u_2a_inputs (
		.clk(clk_sys), .rst_n(cpu_rst_n), .game(game_id_sys), // Loaded dynamically from MicroSD DOP2 header
		.joystick_0(cart_pad_key), .joystick_1(32'd0),
		.joy_analog(cart_pad_joy[15:0]), .joy_ranalog(cart_pad_joy[31:16]),
		.joy_analog_1(16'd0), .paddle(8'h80),
		.st_pedswap(1'b0), .st_ssens(2'd0), .st_ssm(2'd0), .st_rsteer(1'b0), .st_wheel(2'd0),
		.trig_rt(cart_pad_trig[7:0]), .trig_lt(cart_pad_trig[15:8]),
		.gun_in1(8'hFF), .pe(pe_out),
		.in0(cab_in0), .in1(cab_in1), .in2(cab_in2),
		.an0(cab_an0), .an1(cab_an1), .an2(cab_an2)
	);

	m2_315_5649 #(.GUN(1'b0)) u_io5649 (
		.clk(clk_sys), .por_n(por_n), .rst_n(cpu_rst_n),
		.sel(sel_io5649), .we(io_we), .word(io_addr[4:2]), .be(io_be),
		.wdata(io_wdata), .rdata(io5649_rdata),
		.in0(cab_in0), .in1(cab_in1), .in2(cab_in2), .sw(8'hFF),
		.an0(cab_an0), .an1(cab_an1), .an2(cab_an2),
		.gun_p1x(10'd0), .gun_p1y(10'd0), .gun_p2x(10'd0), .gun_p2y(10'd0), .gun_off(2'b11),
		.pe(pe_out)
	);

	// Interrupt controller (VBlank from Pocket CH3 + 4 Model 2A timers)
	reg [11:0] intreq = 12'd0, intena = 12'd0;
	always @(posedge clk_sys or negedge cpu_rst_n) begin
		if (!cpu_rst_n) begin
			intreq <= 12'd0;
			intena <= 12'd0;
		end else begin
			if (sel_intreq && io_we) intreq <= intreq & io_wdata[11:0];
			if (sel_intena && io_we) intena <= io_wdata[11:0];
			if (cart_vsync) intreq[0] <= intreq[0] | intena[0];
			if (tmr_expire[0]) intreq[2] <= intreq[2] | intena[2];
			if (tmr_expire[1]) intreq[3] <= intreq[3] | intena[3];
			if (tmr_expire[2]) intreq[4] <= intreq[4] | intena[4];
			if (tmr_expire[3]) intreq[5] <= intreq[5] | intena[5];
		end
	end
	assign cpu_irq = {|intreq[11:10], |intreq[9:2], intreq[1], intreq[0]};

	assign io_stall = copro_stall || geo_push_stall;
	assign io_rdata =
		(sel_copro_ctl || sel_copro_fifo || sel_copro_fn || sel_copro_fifoctl) ? copro_rdata :
		(io_addr[27:2] == 26'h020_0802) ? geo_rd_wp :
		(io_addr[27:2] == 26'h020_0C02) ? geo_rd_rp :
		sel_timers ? tmr_rdata :
		sel_backup ? bkp_rdata :
		sel_io5649 ? io5649_rdata :
		sel_uart   ? {8'd0, uart_stat_o, 8'd0, uart_data_o} :
		sel_intreq ? {20'd0, intreq} :
		sel_intena ? {20'd0, intena} :
		32'd0;

	// -------------------------------------------------------------------------
	// 9. Live Video-Write Snooper FIFO -> m2_cart_host (30-Pin Pocket Bus)
	// -------------------------------------------------------------------------
	wire cpu_sd_wr_fire = cpu_sd_req && cpu_sd_we && cpu_sd_ack;
	wire is_char_sd = cpu_sd_wr_fire && (cpu_sd_addr >= GAME_CHAR)  && (cpu_sd_addr < GAME_CHAR  + 26'h08_0000);
	wire is_tex0_sd = cpu_sd_wr_fire && (cpu_sd_addr >= GAME_TEXS0) && (cpu_sd_addr < GAME_TEXS0 + 26'h08_0000);
	wire is_tex1_sd = cpu_sd_wr_fire && (cpu_sd_addr >= GAME_TEXS1) && (cpu_sd_addr < GAME_TEXS1 + 26'h08_0000);

	wire        snoop_wr = oc_tram_we || oc_pal_we || oc_xlat_we || is_char_sd || is_tex0_sd || is_tex1_sd || tex_inval;
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
			snoop_kind = 4'd5; snoop_addr = 25'h080_0000 + (cpu_sd_addr[24:1] - GAME_CHAR[24:1]); snoop_data = cpu_sd_din;
		end else if (is_tex0_sd) begin
			snoop_kind = 4'd5; snoop_addr = 25'h000_0000 + (cpu_sd_addr[24:1] - GAME_TEXS0[24:1]); snoop_data = cpu_sd_din;
		end else if (is_tex1_sd) begin
			snoop_kind = 4'd5; snoop_addr = 25'h020_0000 + (cpu_sd_addr[24:1] - GAME_TEXS1[24:1]); snoop_data = cpu_sd_din;
		end else begin
			snoop_kind = 4'd6; snoop_addr = 25'd0; snoop_data = {15'd0, tex_inval};
		end
	end

	wire [44:0] sf_dout;
	wire        sf_empty, sf_full, host_w_ready;
	dcfifo #(
		.intended_device_family("Cyclone V"),
		.lpm_numwords(512), .lpm_showahead("ON"), .lpm_type("dcfifo"),
		.lpm_width(45), .lpm_widthu(9),
		.overflow_checking("ON"), .underflow_checking("ON"), .use_eab("ON")
	) u_snoop_fifo (
		.data({snoop_kind, snoop_addr, snoop_data}), .wrclk(clk_sys), .wrreq(snoop_wr && !sf_full),
		.rdclk(clk_sys), .rdreq(!sf_empty && host_w_ready), .q(sf_dout),
		.rdempty(sf_empty), .wrfull(sf_full), .aclr(!sys_rst_n),
		.eccstatus(), .rdfull(), .rdusedw(), .wrempty(), .wrusedw()
	);

	// Bidirectional 30-pin Pocket Cartridge Slot IOBs
	wire [7:0] hb1_o, hb2_o, hb3_o;
	wire       hb1_oe, hb2_oe, hb3_oe;
	assign cart_bank1 = hb1_oe ? hb1_o : 8'hzz;
	assign cart_bank2 = hb2_oe ? hb2_o : 8'hzz;
	assign cart_bank3 = hb3_oe ? hb3_o : 8'hzz;

	wire [31:0] dbg_tx_words;

	m2_cart_host u_cart_host (
		.clk_core      ( clk_sys ),
		.rst_n         ( sys_rst_n ),
		.cart_bank0_i  ( cart_bank0 ),
		.cart_pin30_i  ( cart_pin30 ),
		.cart_pin31_o  ( cart_pin31 ),
		.cart_bank1_i  ( cart_bank1 ), .cart_bank1_o(hb1_o), .cart_bank1_oe(hb1_oe),
		.cart_bank2_i  ( cart_bank2 ), .cart_bank2_o(hb2_o), .cart_bank2_oe(hb2_oe),
		.cart_bank3_i  ( cart_bank3 ), .cart_bank3_o(hb3_o), .cart_bank3_oe(hb3_oe),
		.frame_start   ( walk_started ),
		.frame_tag     ( geo_walk_frames[3:0] ),
		.q_valid       ( ch0_q_valid ),
		.q_ready       ( host_q_ready ),
		.q_x0(q3d_x0), .q_y0(q3d_y0), .q_x1(q3d_x1), .q_y1(q3d_y1),
		.q_x2(q3d_x2), .q_y2(q3d_y2), .q_x3(q3d_x3), .q_y3(q3d_y3),
		.q_col(q3d_col), .q_z(q3d_z), .q_moire(1'b0),
		.q_oz0(q3d_oz0), .q_oz1(q3d_oz1), .q_oz2(q3d_oz2), .q_oz3(q3d_oz3), .q_frac(q3d_frac),
		.q_u0(q3d_u0), .q_v0(q3d_v0), .q_u1(q3d_u1), .q_v1(q3d_v1),
		.q_u2(q3d_u2), .q_v2(q3d_v2), .q_u3(q3d_u3), .q_v3(q3d_v3),
		.q_tex(ch0_q_tex), .q_uvs(q3d_uvs), .q_mipz(q3d_mipz), .q_end(ch0_q_end),
		.w_valid       ( !sf_empty ),
		.w_ready       ( host_w_ready ),
		.w_kind        ( sf_dout[44:41] ),
		.w_addr        ( sf_dout[40:16] ),
		.w_data        ( sf_dout[15:0] ),
		.audio_stb     ( aud_stb ),
		.audio_l       ( snd_l ),
		.audio_r       ( snd_r ),
		.vsync_o       ( cart_vsync ),
		.pad_key_o     ( cart_pad_key ),
		.pad_joy_o     ( cart_pad_joy ),
		.pad_trig_o    ( cart_pad_trig ),
		.pad_valid_o   ( ),
		.dbg_tx_words  ( dbg_tx_words ),
		.dbg_tx_quads  ( ),
		.dbg_tx_ch1    ( ),
		.dbg_tx_audio  ( ),
		.dbg_rx_ch3    ( )
	);

	assign led_status = {dbg_tx_words[16], dbg_pc[8], sdram_ready, pll_locked};

endmodule
`default_nettype wire
