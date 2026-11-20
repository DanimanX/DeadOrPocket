// m2_cart_host: Compute Cartridge Side of the 30-Pin Analogue Pocket Bus (v2)
//
// Symmetric counterpart to m2_cart_bus.sv running on the external Compute Cartridge
// FPGA (Cyclone V 5CEBA5/7, Gowin GW5AST-60, or Lattice ECP5-85F) and in Phase 2
// RTL co-simulation.
//
// Features:
//   - Priority packet arbiter on clk_cart (31.97 MHz, 16-bit = 63.9 MB/s):
//       1. CH2: 48 kHz Stereo PCM Audio (2 words/sample, lowest latency)
//       2. CH1: 2D Tile/Pal/Xlat + 3D LUT + auto-coalesced SDRAM Texture/Char bursts
//       3. CH0: Projected 3D Quads (27 words/quad) & Frame Start control
//   - Respects Pocket hardware backpressure (pin30 POCKET_READY) and clean Hi-Z
//     turnaround (bank0[6] BUS_DIR) with zero bus contention cycles.
//   - Receives CH3 VBlank controller snapshots ({pad_key, pad_joy, pad_trig}) and
//     VSync pulse from Pocket.
//
`default_nettype none

module m2_cart_host (
	input  wire        clk_core,       // Compute cartridge system clock
	input  wire        rst_n,

	// ---- Physical 30-pin Pocket Cartridge Slot (split _i/_o/_oe for clean IOB/sim) ----
	input  wire  [7:4] cart_bank0_i,   // [7]=BUS_CLK, [6]=BUS_DIR, [5]=VSYNC, [4]=SOFT_RST_N
	input  wire        cart_pin30_i,   // POCKET_READY (1 = Pocket RX FIFO ready)
	output wire        cart_pin31_o,   // CART_VALID
	input  wire  [7:0] cart_bank1_i,   // PKT_HDR in (during CH3)
	output wire  [7:0] cart_bank1_o,   // PKT_HDR out (during TX)
	output wire        cart_bank1_oe,
	input  wire  [7:0] cart_bank2_i,   // BUS_DATA[15:8] in
	output wire  [7:0] cart_bank2_o,
	output wire        cart_bank2_oe,
	input  wire  [7:0] cart_bank3_i,   // BUS_DATA[7:0] in
	output wire  [7:0] cart_bank3_o,
	output wire        cart_bank3_oe,

	// ---- CH0 Producer: 3D Quads & Frame Start (clk_core domain) ------------
	input  wire        frame_start,
	input  wire  [3:0] frame_tag,
	input  wire        q_valid,
	output wire        q_ready,
	input  wire signed [15:0] q_x0, q_y0, q_x1, q_y1, q_x2, q_y2, q_x3, q_y3,
	input  wire [23:0] q_col,
	input  wire [31:0] q_z,
	input  wire        q_moire,
	input  wire [15:0] q_oz0, q_oz1, q_oz2, q_oz3, q_frac,
	input  wire [12:0] q_u0, q_v0, q_u1, q_v1, q_u2, q_v2, q_u3, q_v3,
	input  wire [26:0] q_tex,
	input  wire  [1:0] q_uvs,
	input  wire        q_mipz,
	input  wire        q_end,

	// ---- CH1 Producer: 2D / LUT / Texture / Char RAM writes (clk_core) -----
	// w_kind: 0=TRAM, 1=PAL, 2=XLAT, 3=LUT({sel[1:0],addr[12:0]}),
	//         4=SDRAM_ADDR(addr[24:0], data[15:14]={char_inval,tex_inval}),
	//         5=SDRAM_DATA(auto-coalesced using w_addr[24:0]), 6=CTRL
	input  wire        w_valid,
	output wire        w_ready,
	input  wire  [3:0] w_kind,
	input  wire [24:0] w_addr,
	input  wire [15:0] w_data,

	// ---- CH2 Producer: 48 kHz Stereo PCM Audio (clk_core) ------------------
	input  wire        audio_stb,
	input  wire [15:0] audio_l,
	input  wire [15:0] audio_r,

	// ---- CH3 Consumer: Inputs & VSync from Pocket (clk_core) ---------------
	output reg         vsync_o     = 1'b0,
	output reg  [31:0] pad_key_o   = 32'd0,
	output reg  [31:0] pad_joy_o   = 32'd0,
	output reg  [15:0] pad_trig_o  = 16'd0,
	output reg         pad_valid_o = 1'b0,

	// ---- Telemetry ---------------------------------------------------------
	output reg  [31:0] dbg_tx_words = 32'd0,
	output reg  [31:0] dbg_tx_quads = 32'd0,
	output reg  [31:0] dbg_tx_ch1   = 32'd0,
	output reg  [31:0] dbg_tx_audio = 32'd0,
	output reg  [31:0] dbg_rx_ch3   = 32'd0
);

	wire clk_bus    = cart_bank0_i[7];
	wire bus_dir    = cart_bank0_i[6]; // 0=Cart TX, 1=Pocket TX (Cart must Hi-Z!)
	wire bus_vsync  = cart_bank0_i[5];
	wire bus_rst_n  = cart_bank0_i[4] & rst_n;

	// -------------------------------------------------------------------------
	// 1. Packet Generator (clk_core) -> Dual-Clock TX FIFO (512 x 24-bit)
	//    {hdr[7:0], data[15:0]}
	// -------------------------------------------------------------------------
	// Latch pending audio sample & frame_start so pulses are never lost
	reg        aud_pend = 1'b0;
	reg [15:0] aud_l_r  = 16'd0, aud_r_r = 16'd0;
	reg        fs_pend  = 1'b0;
	reg  [3:0] fs_tag_r = 4'd0;

	// Track last Pocket SDRAM burst address for auto-coalescing consecutive writes
	reg        sd_cur_valid = 1'b0;
	reg [24:0] sd_cur_addr  = 25'd0;

	// TX FIFO signals
	reg         txf_wr   = 1'b0;
	reg  [23:0] txf_din  = 24'd0;
	wire [23:0] txf_dout;
	wire        txf_empty, txf_full;
	wire  [8:0] txf_wrusedw;
	wire        txf_rd;

	dcfifo #(
		.intended_device_family("Cyclone V"),
		.lpm_numwords(512),
		.lpm_showahead("ON"),
		.lpm_type("dcfifo"),
		.lpm_width(24),
		.lpm_widthu(9),
		.overflow_checking("ON"),
		.underflow_checking("ON"),
		.use_eab("ON")
	) u_tx_fifo (
		.data(txf_din), .wrclk(clk_core), .wrreq(txf_wr),
		.rdclk(clk_bus), .rdreq(txf_rd), .q(txf_dout),
		.rdempty(txf_empty), .wrfull(txf_full), .wrusedw(txf_wrusedw),
		.aclr(!bus_rst_n), .eccstatus(), .rdfull(), .rdusedw(), .wrempty()
	);

	// Reserve top 64 words of u_tx_fifo exclusively for CH2 Audio / Frame Start
	// so 48 kHz PCM NEVER drops even when CH0 3D quads hit backpressure!
	wire txf_space_hi   = (txf_wrusedw < 9'd504);
	wire txf_space_data = (txf_wrusedw < 9'd440);

	// Packetizer FSM on clk_core
	localparam [2:0] P_IDLE = 3'd0, P_AUD1 = 3'd1, P_CH1_B1 = 3'd2,
	                 P_CH1_SD1 = 3'd3, P_CH1_SD2 = 3'd4, P_QUAD = 3'd5;
	reg [2:0]  p_st     = P_IDLE;
	reg [4:0]  p_qidx   = 5'd0;
	reg [3:0]  p_c1k    = 4'd0;
	reg [24:0] p_c1a    = 25'd0;
	reg [15:0] p_c1d    = 16'd0;

	// Latched quad snapshot for clean 27-beat serialization
	reg signed [15:0] lq_x0, lq_y0, lq_x1, lq_y1, lq_x2, lq_y2, lq_x3, lq_y3;
	reg [23:0] lq_col;
	reg [31:0] lq_z;
	reg        lq_moire, lq_mipz, lq_end;
	reg  [1:0] lq_uvs;
	reg [15:0] lq_oz0, lq_oz1, lq_oz2, lq_oz3, lq_frac;
	reg [12:0] lq_u0, lq_v0, lq_u1, lq_v1, lq_u2, lq_v2, lq_u3, lq_v3;
	reg [26:0] lq_tex;

	wire accept_ch1  = (p_st == P_IDLE) && txf_space_data && !aud_pend && !fs_pend && w_valid;
	wire accept_quad = (p_st == P_IDLE) && txf_space_data && !aud_pend && !fs_pend && !w_valid && q_valid;

	assign w_ready = accept_ch1;
	assign q_ready = accept_quad;

	// Helper mux for quad serialization beats 1..26
	reg [15:0] quad_word;
	always @(*) begin
		case (p_qidx)
			5'd0:  quad_word = lq_x0;
			5'd1:  quad_word = lq_y0;
			5'd2:  quad_word = lq_x1;
			5'd3:  quad_word = lq_y1;
			5'd4:  quad_word = lq_x2;
			5'd5:  quad_word = lq_y2;
			5'd6:  quad_word = lq_x3;
			5'd7:  quad_word = lq_y3;
			5'd8:  quad_word = lq_col[15:0];
			5'd9:  quad_word = {3'd0, lq_end, lq_uvs, lq_mipz, lq_moire, lq_col[23:16]};
			5'd10: quad_word = lq_z[15:0];
			5'd11: quad_word = lq_z[31:16];
			5'd12: quad_word = lq_oz0;
			5'd13: quad_word = lq_oz1;
			5'd14: quad_word = lq_oz2;
			5'd15: quad_word = lq_oz3;
			5'd16: quad_word = lq_frac;
			5'd17: quad_word = {3'd0, lq_u0};
			5'd18: quad_word = {3'd0, lq_v0};
			5'd19: quad_word = {3'd0, lq_u1};
			5'd20: quad_word = {3'd0, lq_v1};
			5'd21: quad_word = {3'd0, lq_u2};
			5'd22: quad_word = {3'd0, lq_v2};
			5'd23: quad_word = {3'd0, lq_u3};
			5'd24: quad_word = {3'd0, lq_v3};
			5'd25: quad_word = lq_tex[15:0];
			5'd26: quad_word = {5'd0, lq_tex[26:16]};
			default: quad_word = 16'd0;
		endcase
	end

	always @(posedge clk_core or negedge bus_rst_n) begin
		if (!bus_rst_n) begin
			aud_pend     <= 1'b0;
			aud_l_r      <= 16'd0;
			aud_r_r      <= 16'd0;
			fs_pend      <= 1'b0;
			fs_tag_r     <= 4'd0;
			sd_cur_valid <= 1'b0;
			sd_cur_addr  <= 25'd0;
			txf_wr       <= 1'b0;
			txf_din      <= 24'd0;
			p_st         <= P_IDLE;
			p_qidx       <= 5'd0;
			dbg_tx_quads <= 32'd0;
			dbg_tx_ch1   <= 32'd0;
			dbg_tx_audio <= 32'd0;
		end else begin
			txf_wr <= 1'b0;

			if (audio_stb) begin
				aud_pend <= 1'b1;
				aud_l_r  <= audio_l;
				aud_r_r  <= audio_r;
			end
			if (frame_start) begin
				fs_pend  <= 1'b1;
				fs_tag_r <= frame_tag;
			end

			case (p_st)
				P_IDLE: begin
					if (aud_pend && txf_space_hi) begin
						// Priority 0: CH2 Audio Left (SOP) — guaranteed headroom
						aud_pend <= 1'b0;
						txf_wr   <= 1'b1;
						txf_din  <= {8'b0000_0110, aud_l_r}; // ch=2, SOP=1
						p_st     <= P_AUD1;
					end else if (fs_pend && txf_space_hi) begin
						// Priority 0.5: CH0 Frame Start control beat (SOP+EOP, sub=0xF)
						fs_pend <= 1'b0;
						txf_wr  <= 1'b1;
						txf_din <= {8'b1111_1100, 12'd0, fs_tag_r}; // ch=0, SOP=1, EOP=1, sub=F
					end else if (txf_space_data) begin
						if (w_valid) begin
							// Priority 1: CH1 2D/LUT/SDRAM write
							p_c1k      <= w_kind;
							p_c1a      <= w_addr;
							p_c1d      <= w_data;
							dbg_tx_ch1 <= dbg_tx_ch1 + 32'd1;

							if (w_kind == 4'd6) begin
								// Single-word control pulse
								txf_wr  <= 1'b1;
								txf_din <= {4'd6, 4'b1101, w_data}; // ch=1, SOP=1, EOP=1
							end else if (w_kind == 4'd5) begin
								// Auto-coalesced SDRAM stream write
								if (sd_cur_valid && (w_addr == sd_cur_addr)) begin
									// Sequential hit: 1-word write, zero address overhead!
									txf_wr      <= 1'b1;
									txf_din     <= {4'd5, 4'b1101, w_data}; // ch=1, sub=5, SOP=1, EOP=1
									sd_cur_addr <= sd_cur_addr + 25'd1;
								end else begin
									// Discontiguous address: emit sub=4 (addr lo, addr hi), then sub=5 data
									txf_wr  <= 1'b1;
									txf_din <= {4'd4, 4'b0101, w_addr[15:0]}; // ch=1, sub=4, SOP=1
									p_st    <= P_CH1_SD1;
								end
							end else if (w_kind == 4'd4) begin
								txf_wr       <= 1'b1;
								txf_din      <= {4'd4, 4'b0101, w_addr[15:0]};
								sd_cur_valid <= 1'b1;
								sd_cur_addr  <= w_addr;
								p_st         <= P_CH1_B1;
							end else begin
								// Standard 2-word write (0=TRAM, 1=PAL, 2=XLAT, 3=LUT)
								txf_wr  <= 1'b1;
								txf_din <= {w_kind, 4'b0101, w_addr[15:0]}; // ch=1, SOP=1
								p_st    <= P_CH1_B1;
							end
						end else if (q_valid) begin
							// Priority 2: CH0 Projected 3D Quad (27 words)
							lq_x0 <= q_x0; lq_y0 <= q_y0; lq_x1 <= q_x1; lq_y1 <= q_y1;
							lq_x2 <= q_x2; lq_y2 <= q_y2; lq_x3 <= q_x3; lq_y3 <= q_y3;
							lq_col <= q_col; lq_z <= q_z; lq_moire <= q_moire;
							lq_oz0 <= q_oz0; lq_oz1 <= q_oz1; lq_oz2 <= q_oz2; lq_oz3 <= q_oz3;
							lq_frac <= q_frac;
							lq_u0 <= q_u0; lq_v0 <= q_v0; lq_u1 <= q_u1; lq_v1 <= q_v1;
							lq_u2 <= q_u2; lq_v2 <= q_v2; lq_u3 <= q_u3; lq_v3 <= q_v3;
							lq_tex <= q_tex; lq_uvs <= q_uvs; lq_mipz <= q_mipz; lq_end <= q_end;
							txf_wr       <= 1'b1;
							txf_din      <= {8'b0000_0100, q_x0}; // ch=0, SOP=1, word 0
							p_qidx       <= 5'd1;
							dbg_tx_quads <= dbg_tx_quads + 32'd1;
							p_st         <= P_QUAD;
						end
					end
				end

				P_AUD1: begin
					txf_wr       <= 1'b1;
					txf_din      <= {8'b0000_1010, aud_r_r}; // ch=2, EOP=1
					dbg_tx_audio <= dbg_tx_audio + 32'd1;
					p_st         <= P_IDLE;
				end

				P_CH1_B1: begin
					txf_wr  <= 1'b1;
					txf_din <= {p_c1k, 4'b1001, (p_c1k == 4'd4) ? {p_c1d[15:14], 5'd0, p_c1a[24:16]} : p_c1d};
					p_st    <= P_IDLE;
				end

				P_CH1_SD1: begin
					txf_wr  <= 1'b1;
					txf_din <= {4'd4, 4'b1001, 7'd0, p_c1a[24:16]}; // EOP of sub=4 address set
					p_st    <= P_CH1_SD2;
				end

				P_CH1_SD2: begin
					txf_wr       <= 1'b1;
					txf_din      <= {4'd5, 4'b1101, p_c1d}; // sub=5 data word
					sd_cur_valid <= 1'b1;
					sd_cur_addr  <= p_c1a + 25'd1;
					p_st         <= P_IDLE;
				end

				P_QUAD: begin
					txf_wr  <= 1'b1;
					txf_din <= {4'd0, (p_qidx == 5'd26), 3'b000, quad_word};
					if (p_qidx == 5'd26) begin
						p_st   <= P_IDLE;
						p_qidx <= 5'd0;
					end else begin
						p_qidx <= p_qidx + 5'd1;
					end
				end

				default: p_st <= P_IDLE;
			endcase
		end
	end

	// -------------------------------------------------------------------------
	// 2. Physical Bus TX & CH3 RX on clk_bus (31.97 MHz, zero contention)
	// -------------------------------------------------------------------------
	// Only drive the bus when Pocket sets bus_dir==0 AND signals pocket_ready==1
	wire can_tx = !bus_dir && cart_pin30_i && !txf_empty;
	assign txf_rd        = can_tx;
	assign cart_pin31_o  = can_tx;
	assign cart_bank1_oe = !bus_dir;
	assign cart_bank2_oe = !bus_dir;
	assign cart_bank3_oe = !bus_dir;
	assign cart_bank1_o  = can_tx ? txf_dout[23:16] : 8'd0;
	assign cart_bank2_o  = can_tx ? txf_dout[15:8]  : 8'd0;
	assign cart_bank3_o  = can_tx ? txf_dout[7:0]   : 8'd0;

	// Capture CH3 input packets during bus_dir == 1 on clk_bus
	reg [31:0] rx_key_b = 32'd0, rx_joy_b = 32'd0;
	reg [15:0] rx_trg_b = 16'd0;
	reg        rx_tog_b = 1'b0;
	reg        vs_tog_b = 1'b0;
	reg        vs_prev_b = 1'b0;

	wire [15:0] bus_din_b = {cart_bank2_i, cart_bank3_i};
	wire  [1:0] rx_ch_b   = cart_bank1_i[1:0];
	wire  [3:0] rx_sub_b  = cart_bank1_i[7:4];
	wire        rx_eop_b  = cart_bank1_i[3];

	always @(posedge clk_bus or negedge bus_rst_n) begin
		if (!bus_rst_n) begin
			dbg_tx_words <= 32'd0;
			rx_key_b     <= 32'd0;
			rx_joy_b     <= 32'd0;
			rx_trg_b     <= 16'd0;
			rx_tog_b     <= 1'b0;
			vs_tog_b     <= 1'b0;
			vs_prev_b    <= 1'b0;
		end else begin
			if (can_tx) dbg_tx_words <= dbg_tx_words + 32'd1;

			vs_prev_b <= bus_vsync;
			if (bus_vsync && !vs_prev_b) vs_tog_b <= ~vs_tog_b;

			if (bus_dir && rx_ch_b == 2'd3) begin
				case (rx_sub_b)
					4'd0: rx_key_b[15:0]  <= bus_din_b;
					4'd1: rx_key_b[31:16] <= bus_din_b;
					4'd2: rx_joy_b[15:0]  <= bus_din_b;
					4'd3: rx_joy_b[31:16] <= bus_din_b;
					4'd4: begin
						rx_trg_b <= bus_din_b;
						if (rx_eop_b) rx_tog_b <= ~rx_tog_b;
					end
					default: ;
				endcase
			end
		end
	end

	// Synchronize CH3 snapshot & VSync back into clk_core
	reg [2:0] rx_sync_c = 3'd0, vs_sync_c = 3'd0;
	always @(posedge clk_core or negedge bus_rst_n) begin
		if (!bus_rst_n) begin
			rx_sync_c   <= 3'd0;
			vs_sync_c   <= 3'd0;
			vsync_o     <= 1'b0;
			pad_valid_o <= 1'b0;
			pad_key_o   <= 32'd0;
			pad_joy_o   <= 32'd0;
			pad_trig_o  <= 16'd0;
			dbg_rx_ch3  <= 32'd0;
		end else begin
			rx_sync_c   <= {rx_sync_c[1:0], rx_tog_b};
			vs_sync_c   <= {vs_sync_c[1:0], vs_tog_b};
			vsync_o     <= vs_sync_c[2] ^ vs_sync_c[1];
			pad_valid_o <= 1'b0;
			if (rx_sync_c[2] ^ rx_sync_c[1]) begin
				pad_key_o   <= rx_key_b;
				pad_joy_o   <= rx_joy_b;
				pad_trig_o  <= rx_trg_b;
				pad_valid_o <= 1'b1;
				dbg_rx_ch3  <= dbg_rx_ch3 + 32'd1;
			end
		end
	end

endmodule
`default_nettype wire
