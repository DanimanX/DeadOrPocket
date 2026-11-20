// m2_pk_io: APF Bridge, interact.json, Pad, and ROM Loader adapter for DeadOrPocket
// Adapted from SpaceFish's proven pk_io.sv for Sega Model 2 / 2A-CRX.
`default_nettype none

module m2_pk_io #(
	parameter [31:0] INTERACT_BASE = 32'hF000_0000
) (
	// ---- APF side (clk_74a) ------------------------------------------------
	input  wire        clk_74a,
	input  wire        apf_reset_n,
	input  wire [31:0] bridge_addr,
	input  wire        bridge_wr,
	input  wire [31:0] bridge_wr_data,

	input  wire [31:0] pad_key,
	input  wire [31:0] pad_joy,
	input  wire [15:0] pad_trig,
	input  wire        apf_dataslot_complete,

	// ---- Core side ---------------------------------------------------------
	input  wire        clk_sys,        // 79.92 MHz
	input  wire        clk_mem,        // 95.91 MHz (SDRAM / loader domain)
	input  wire        pll_locked,

	output reg         core_reset_btn = 1'b0,
	output reg         demo_mode      = 1'b1,
	output reg         tex_bilinear   = 1'b1,
	output reg         dbg_overlay    = 1'b0,
	output reg  [1:0]  tex_mip_mode   = 2'd1,
	output reg  [31:0] game_cfg       = 32'd0,

	output reg  [31:0] pad_key_sys    = 32'd0,
	output reg  [31:0] pad_joy_sys    = 32'd0,
	output reg  [15:0] pad_trig_sys   = 16'd0,

	// ---- Texture / 2D ROM stream into Pocket SDRAM (clk_mem) ---------------
	output reg         dl_active      = 1'b0,
	output reg         dl_wr          = 1'b0,
	output reg  [25:1] dl_addr        = 25'd0,
	output reg  [15:0] dl_din         = 16'd0,
	input  wire        dl_ack,

	output reg         boot_done      = 1'b0,
	output reg         fifo_ovf       = 1'b0
);

	// -------------------------------------------------------------------------
	// 1. APF interact.json register handler (clk_74a)
	// -------------------------------------------------------------------------
	reg       reset_tog_74 = 1'b0;
	reg       demo_mode_74 = 1'b1;
	reg       bilinear_74  = 1'b1;
	reg       overlay_74   = 1'b0;
	reg [1:0] mip_mode_74  = 2'd1;

	reg apf_reset_n_d = 1'b0;
	always @(posedge clk_74a) begin
		apf_reset_n_d <= apf_reset_n;
		if (apf_reset_n && !apf_reset_n_d) reset_tog_74 <= ~reset_tog_74;
		else if (bridge_wr) begin
			case (bridge_addr)
				(INTERACT_BASE + 32'h00): if (bridge_wr_data[0] || bridge_wr_data[24]) reset_tog_74 <= ~reset_tog_74;
				(INTERACT_BASE + 32'h04): demo_mode_74 <= bridge_wr_data[0] | bridge_wr_data[24];
				(INTERACT_BASE + 32'h08): bilinear_74  <= bridge_wr_data[0] | bridge_wr_data[24];
				(INTERACT_BASE + 32'h0C): overlay_74   <= bridge_wr_data[0] | bridge_wr_data[24];
				(INTERACT_BASE + 32'h10): mip_mode_74  <= bridge_wr_data[1:0];
				default: ;
			endcase
		end
	end

	// Synchronize settings & controller state into clk_sys
	reg [2:0]  rst_sync = 3'd0;
	reg [15:0] rst_stretch = 16'd0;
	reg [1:0]  demo_s = 2'b11, bilin_s = 2'b11, ovl_s = 2'b00;
	reg [1:0]  mip_s0 = 2'd1, mip_s1 = 2'd1;
	reg [31:0] pk_s0 = 32'd0, pj_s0 = 32'd0;
	reg [15:0] pt_s0 = 16'd0;

	always @(posedge clk_sys) begin
		rst_sync <= {rst_sync[1:0], reset_tog_74};
		if (rst_sync[2] ^ rst_sync[1]) rst_stretch <= 16'hFFFF;
		else if (rst_stretch != 16'd0) rst_stretch <= rst_stretch - 16'd1;
		core_reset_btn <= (rst_stretch != 16'd0);

		demo_s  <= {demo_s[0], demo_mode_74};
		bilin_s <= {bilin_s[0], bilinear_74};
		ovl_s   <= {ovl_s[0], overlay_74};
		mip_s0  <= mip_mode_74;
		mip_s1  <= mip_s0;

		demo_mode    <= demo_s[1];
		tex_bilinear <= bilin_s[1];
		dbg_overlay  <= ovl_s[1];
		tex_mip_mode <= mip_s1;

		pk_s0 <= pad_key;  pad_key_sys  <= pk_s0;
		pj_s0 <= pad_joy;  pad_joy_sys  <= pj_s0;
		pt_s0 <= pad_trig; pad_trig_sys <= pt_s0;
	end

	// -------------------------------------------------------------------------
	// 2. Slot 1 ROM Stream CDC (clk_74a -> clk_mem)
	//    Header [0..31]: Magic SM2\x01 (0x00), game_cfg (0x04), sdram_len (0x08)...
	//    Payload [32..]: 32-bit words written linearly to Pocket SDRAM (dram_*)
	// -------------------------------------------------------------------------
	wire is_slot1   = (bridge_addr < 32'h0800_0000) && bridge_wr;
	wire is_header  = is_slot1 && (bridge_addr < 32'h20);
	wire is_payload = is_slot1 && (bridge_addr >= 32'h20);

	reg [31:0] cfg_74 = 32'd0;
	reg        ovf_74 = 1'b0;
	always @(posedge clk_74a) begin
		if (is_header && bridge_addr[4:0] == 5'h00) ovf_74 <= 1'b0;
		else if (is_payload && fifo_full)           ovf_74 <= 1'b1;
		if (is_header && bridge_addr[4:0] == 5'h04) cfg_74 <= bridge_wr_data;
	end

	wire [24:0] pay_dw_addr = bridge_addr[26:2] - 25'd8; // subtract 32-byte header
	wire [56:0] fifo_din    = {pay_dw_addr, bridge_wr_data};
	wire [56:0] fifo_dout;
	wire        fifo_empty, fifo_full;
	reg         fifo_rd = 1'b0;

	dcfifo #(
		.intended_device_family("Cyclone V"),
		.lpm_numwords(512),
		.lpm_showahead("OFF"),
		.lpm_type("dcfifo"),
		.lpm_width(57),
		.lpm_widthu(9),
		.overflow_checking("ON"),
		.underflow_checking("OFF"),
		.use_eab("ON")
	) rom_fifo (
		.data(fifo_din), .wrclk(clk_74a), .wrreq(is_payload),
		.rdclk(clk_mem), .rdreq(fifo_rd), .q(fifo_dout),
		.rdempty(fifo_empty), .wrfull(fifo_full),
		.aclr(1'b0), .eccstatus(), .rdfull(), .rdusedw(), .wrempty(), .wrusedw()
	);

	// Drain FIFO on clk_mem into two 16-bit SDRAM writes per 32-bit bridge word
	reg [1:0]  dsc_sync = 2'd0;
	reg [1:0]  ovf_sync = 2'd0;
	reg [31:0] cfg_m0 = 32'd0;

	localparam [2:0] S_IDLE = 3'd0, S_POP = 3'd1, S_WLO = 3'd2, S_WHI = 3'd3;
	reg [2:0]  st = S_IDLE;
	reg [24:0] cur_dw = 25'd0;
	reg [31:0] cur_data = 32'd0;

	always @(posedge clk_mem) begin
		dsc_sync <= {dsc_sync[0], apf_dataslot_complete};
		ovf_sync <= {ovf_sync[0], ovf_74};
		fifo_ovf <= ovf_sync[1];
		cfg_m0   <= cfg_74;
		game_cfg <= cfg_m0;

		fifo_rd <= 1'b0;

		if (!pll_locked) begin
			st        <= S_IDLE;
			dl_active <= 1'b0;
			dl_wr     <= 1'b0;
			boot_done <= 1'b0;
		end else begin
			if (dsc_sync[1] && fifo_empty && st == S_IDLE) begin
				boot_done <= 1'b1;
				dl_active <= 1'b0;
			end

			case (st)
				S_IDLE: begin
					dl_wr <= 1'b0;
					if (!fifo_empty) begin
						fifo_rd   <= 1'b1;
						dl_active <= 1'b1;
						st        <= S_POP;
					end
				end
				S_POP: begin
					cur_dw   <= fifo_dout[56:32];
					cur_data <= fifo_dout[31:0];
					dl_addr  <= {fifo_dout[55:32], 1'b0};
					dl_din   <= fifo_dout[15:0];
					dl_wr    <= 1'b1;
					st       <= S_WLO;
				end
				S_WLO: begin
					if (dl_ack) begin
						dl_addr <= {cur_dw[23:0], 1'b1};
						dl_din  <= cur_data[31:16];
						dl_wr   <= 1'b1;
						st      <= S_WHI;
					end
				end
				S_WHI: begin
					if (dl_ack) begin
						dl_wr <= 1'b0;
						st    <= S_IDLE;
					end
				end
				default: st <= S_IDLE;
			endcase
		end
	end

endmodule
`default_nettype wire
