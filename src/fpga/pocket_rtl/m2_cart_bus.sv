// m2_cart_bus: 30-pin Analogue Pocket Cartridge Slot Synchronous 16-bit Bus PHY (v2)
//
// Physical mapping on Analogue Pocket (3.3V translated banks in apf_top.v):
//   cart_tran_bank0[7:4] (dir=1, Pocket->Cart):
//     [7] BUS_CLK (31.97 MHz, clk_cart)
//     [6] BUS_DIR (0 = Cart->Pocket RX, 1 = Pocket->Cart TX during VBlank)
//     [5] VSYNC_PULSE
//     [4] SOFT_RST_N
//   cart_tran_pin30 (dir=1, Pocket->Cart): POCKET_READY (RX FIFO not almost-full & bus in RX)
//   cart_tran_pin31 (dir=0, Cart->Pocket): CART_VALID (packet beat valid)
//   cart_tran_bank1[7:0] (dir=0 during RX, dir=1 during TX):
//     PKT_HDR[7:0]: [1:0] channel (0=3D Quad, 1=2D/LUT/SDRAM Write, 2=Audio PCM, 3=Inputs/Status)
//                   [2]   SOP (start of packet)
//                   [3]   EOP (end of packet)
//                   [7:4] sub-command (CH0: F=frame_start; CH1: 0=TRAM,1=PAL,2=XLAT,3=LUT,4=SD_ADDR,5=SD_DATA,6=CTRL)
//   cart_tran_bank2[7:0] + cart_tran_bank3[7:0] (dir follows BUS_DIR):
//     BUS_DATA[15:0] (16-bit synchronous payload @ 31.97 MHz = 63.9 MB/s)
//
`default_nettype none

module m2_cart_bus (
	input  wire        clk_cart,       // 31.97 MHz bus clock
	input  wire        clk_sys,        // 73.77 MHz m2_raster3d domain
	input  wire        clk_mem,        // 95.91 MHz 2D RAM/SDRAM domain
	input  wire        rst_n,

	// ---- Physical Analogue Pocket Cartridge Slot pins ----------------------
	inout  wire  [7:4] cart_tran_bank0,
	output wire        cart_tran_bank0_dir,
	inout  wire  [7:0] cart_tran_bank1,
	output wire        cart_tran_bank1_dir,
	inout  wire  [7:0] cart_tran_bank2,
	output wire        cart_tran_bank2_dir,
	inout  wire  [7:0] cart_tran_bank3,
	output wire        cart_tran_bank3_dir,
	inout  wire        cart_tran_pin30,
	output wire        cart_tran_pin30_dir,
	output wire        cart_pin30_pwroff_reset,
	inout  wire        cart_tran_pin31,
	output wire        cart_tran_pin31_dir,

	// ---- Pocket -> Cartridge Inputs & Sync (clk_sys domain) ----------------
	input  wire        vsync_pulse_sys,
	input  wire [31:0] pad_key_sys,
	input  wire [31:0] pad_joy_sys,
	input  wire [15:0] pad_trig_sys,

	// ---- Status ------------------------------------------------------------
	output reg         cart_detected = 1'b0,
	output reg  [31:0] dbg_rx_words  = 32'd0,

	// ---- CH0: 3D Quads -> m2_raster3d (clk_sys domain) ---------------------
	output reg         q_valid = 1'b0,
	input  wire        q_ready,
	output reg  signed [15:0] q_x0 = 16'sd0, q_y0 = 16'sd0,
	output reg  signed [15:0] q_x1 = 16'sd0, q_y1 = 16'sd0,
	output reg  signed [15:0] q_x2 = 16'sd0, q_y2 = 16'sd0,
	output reg  signed [15:0] q_x3 = 16'sd0, q_y3 = 16'sd0,
	output reg  [23:0] q_col  = 24'd0,
	output reg  [31:0] q_z    = 32'd0,
	output reg         q_moire = 1'b0,
	output reg  [15:0] q_oz0  = 16'd0, q_oz1 = 16'd0, q_oz2 = 16'd0, q_oz3 = 16'd0,
	output reg  [15:0] q_frac = 16'd0,
	output reg  [12:0] q_u0   = 13'd0, q_v0  = 13'd0,
	output reg  [12:0] q_u1   = 13'd0, q_v1  = 13'd0,
	output reg  [12:0] q_u2   = 13'd0, q_v2  = 13'd0,
	output reg  [12:0] q_u3   = 13'd0, q_v3  = 13'd0,
	output reg  [26:0] q_tex  = 27'd0,
	output reg   [1:0] q_uvs  = 2'd0,
	output reg         q_mipz = 1'b0,
	output reg         q_end  = 1'b0,
	output reg   [3:0] q_tag  = 4'd0,
	output reg         frame_start_cart = 1'b0,

	// ---- CH1: 2D, LUT & Live Texture/Char SDRAM writes (clk_sys domain) ----
	output reg         tram_we   = 1'b0,
	output reg  [14:0] tram_addr = 15'd0,
	output reg  [15:0] tram_din  = 16'd0,
	output reg         pal_we    = 1'b0,
	output reg  [11:0] pal_addr  = 12'd0,
	output reg  [15:0] pal_din   = 16'd0,
	output reg         xlat_we   = 1'b0,
	output reg   [6:0] xlat_addr = 7'd0,
	output reg   [7:0] xlat_din  = 8'd0,
	output reg         lut_we    = 1'b0,
	output reg   [1:0] lut_sel   = 2'd0,
	output reg  [12:0] lut_addr  = 13'd0,
	output reg  [15:0] lut_data  = 16'd0,

	// Live Texture Sheet (TEXS0/TEXS1) & 2D Char RAM burst writes -> SDRAM Port 5
	output reg         sd_wreq   = 1'b0,
	output reg  [25:1] sd_waddr  = 25'd0,
	output reg  [15:0] sd_wdin   = 16'd0,
	input  wire        sd_wack,
	output reg         tex_inval_cart  = 1'b0,
	output reg         char_inval_cart = 1'b0,

	// ---- CH2: 48 kHz Stereo PCM (clk_sys domain -> sound_i2s) --------------
	output reg  [15:0] audio_l   = 16'd0,
	output reg  [15:0] audio_r   = 16'd0,
	output reg         audio_stb = 1'b0
);

	// -------------------------------------------------------------------------
	// 1. VSync & Input snapshot crossing clk_sys -> clk_cart
	// -------------------------------------------------------------------------
	reg        vs_tog_sys = 1'b0;
	reg [31:0] key_lat_sys = 32'd0, joy_lat_sys = 32'd0;
	reg [15:0] trg_lat_sys = 16'd0;
	always @(posedge clk_sys or negedge rst_n) begin
		if (!rst_n) begin
			vs_tog_sys  <= 1'b0;
			key_lat_sys <= 32'd0;
			joy_lat_sys <= 32'd0;
			trg_lat_sys <= 16'd0;
		end else if (vsync_pulse_sys) begin
			vs_tog_sys  <= ~vs_tog_sys;
			key_lat_sys <= pad_key_sys;
			joy_lat_sys <= pad_joy_sys;
			trg_lat_sys <= pad_trig_sys;
		end
	end

	reg [2:0]  vs_sync_c = 3'd0;
	wire       vs_pulse_c = vs_sync_c[2] ^ vs_sync_c[1];

	// Bus turnaround FSM on clk_cart (clean Hi-Z turnaround on DIR flip, latched VSync)
	localparam [2:0] B_RX = 3'd0, B_TA_TX = 3'd1, B_TX0 = 3'd2, B_TX1 = 3'd3,
	                 B_TX2 = 3'd4, B_TX3 = 3'd5, B_TX4 = 3'd6, B_TA_RX = 3'd7;
	reg [2:0]  b_st      = B_RX;
	reg        vs_pend_c = 1'b0;
	reg        dir_tx    = 1'b0;
	reg        oe_data   = 1'b0;
	reg  [7:0] tx_hdr    = 8'd0;
	reg [15:0] tx_data   = 16'd0;
	reg        vs_out    = 1'b0;
	reg [31:0] key_c     = 32'd0, joy_c = 32'd0;
	reg [15:0] trg_c     = 16'd0;

	// RX FIFO (clk_cart -> clk_sys): 256 x 24 bits {hdr[7:0], data[15:0]}
	wire [23:0] rx_din = {cart_tran_bank1, cart_tran_bank2, cart_tran_bank3};
	wire        rx_wr  = (b_st == B_RX) && cart_tran_pin31 && !rx_full;
	wire [23:0] rx_dout;
	wire        rx_empty, rx_full;
	wire  [7:0] rx_wrusedw;
	wire        rx_rd;

	dcfifo #(
		.intended_device_family("Cyclone V"),
		.lpm_numwords(256),
		.lpm_showahead("ON"),
		.lpm_type("dcfifo"),
		.lpm_width(24),
		.lpm_widthu(8),
		.overflow_checking("ON"),
		.underflow_checking("ON"),
		.use_eab("ON")
	) u_rx_fifo (
		.data(rx_din), .wrclk(clk_cart), .wrreq(rx_wr),
		.rdclk(clk_sys), .rdreq(rx_rd), .q(rx_dout),
		.rdempty(rx_empty), .wrfull(rx_full), .wrusedw(rx_wrusedw),
		.aclr(!rst_n), .eccstatus(), .rdfull(), .rdusedw(), .wrempty()
	);

	// Pause cartridge TX both when RX FIFO is nearly full AND when waiting to turn bus for CH3
	wire pocket_ready_c = (b_st == B_RX) && !vs_pend_c && !vs_pulse_c && (rx_wrusedw < 8'd220);

	always @(posedge clk_cart or negedge rst_n) begin
		if (!rst_n) begin
			vs_sync_c <= 3'd0;
			vs_pend_c <= 1'b0;
			b_st      <= B_RX;
			dir_tx    <= 1'b0;
			oe_data   <= 1'b0;
			tx_hdr    <= 8'd0;
			tx_data   <= 16'd0;
			vs_out    <= 1'b0;
			key_c     <= 32'd0;
			joy_c     <= 32'd0;
			trg_c     <= 16'd0;
		end else begin
			vs_sync_c <= {vs_sync_c[1:0], vs_tog_sys};
			vs_out    <= vs_pulse_c;
			if (vs_pulse_c) vs_pend_c <= 1'b1;

			case (b_st)
				B_RX: begin
					dir_tx  <= 1'b0;
					oe_data <= 1'b0;
					if ((vs_pend_c || vs_pulse_c) && !cart_tran_pin31) begin
						vs_pend_c <= 1'b0;
						key_c     <= key_lat_sys;
						joy_c     <= joy_lat_sys;
						trg_c     <= trg_lat_sys;
						dir_tx    <= 1'b1;
						b_st      <= B_TA_TX;
					end
				end
				B_TA_TX: begin
					// 1 full Hi-Z turnaround cycle after dir_tx=1 before driving bus
					oe_data <= 1'b1;
					tx_hdr  <= 8'b0000_0111; // CH3 SOP, word 0 = key_c[15:0]
					tx_data <= key_c[15:0];
					b_st    <= B_TX0;
				end
				B_TX0: begin tx_hdr <= 8'b0001_0011; tx_data <= key_c[31:16]; b_st <= B_TX1; end
				B_TX1: begin tx_hdr <= 8'b0010_0011; tx_data <= joy_c[15:0];  b_st <= B_TX2; end
				B_TX2: begin tx_hdr <= 8'b0011_0011; tx_data <= joy_c[31:16]; b_st <= B_TX3; end
				B_TX3: begin tx_hdr <= 8'b0100_1011; tx_data <= trg_c;        b_st <= B_TX4; end
				B_TX4: begin oe_data <= 1'b0; dir_tx <= 1'b0; b_st <= B_TA_RX; end
				B_TA_RX: begin b_st <= B_RX; end
			endcase
		end
	end

	// Physical pin assignments (strict 3.3V direction control)
	assign cart_pin30_pwroff_reset = 1'b1;
	assign cart_tran_bank0_dir     = 1'b1;
	assign cart_tran_bank0         = {clk_cart, dir_tx, vs_out, rst_n};
	assign cart_tran_pin30_dir     = 1'b1;
	assign cart_tran_pin30         = pocket_ready_c;
	assign cart_tran_pin31_dir     = 1'b0;
	assign cart_tran_pin31         = 1'bz;

	assign cart_tran_bank1_dir     = dir_tx;
	assign cart_tran_bank2_dir     = dir_tx;
	assign cart_tran_bank3_dir     = dir_tx;
	assign cart_tran_bank1         = oe_data ? tx_hdr        : 8'hzz;
	assign cart_tran_bank2         = oe_data ? tx_data[15:8] : 8'hzz;
	assign cart_tran_bank3         = oe_data ? tx_data[7:0]  : 8'hzz;

	// -------------------------------------------------------------------------
	// 2. Packet Demux on clk_sys (CH0: 3D Quads, CH1: 2D/LUT/SDRAM, CH2: PCM)
	// -------------------------------------------------------------------------
	wire  [7:0] p_hdr  = rx_dout[23:16];
	wire [15:0] p_dat  = rx_dout[15:0];
	wire  [1:0] p_ch   = p_hdr[1:0];
	wire        p_sop  = p_hdr[2];
	wire        p_eop  = p_hdr[3];
	wire  [3:0] p_sub  = p_hdr[7:4];

	reg        q_end_lat  = 1'b0;
	reg [4:0]  q_widx     = 5'd0;
	reg [1:0]  c1_widx    = 2'd0;
	reg [3:0]  c1_kind    = 4'd0;
	reg [15:0] c1_addr    = 16'd0;
	reg [25:1] sd_cur     = 25'd0;
	reg        c2_half    = 1'b0;
	reg [15:0] c2_left    = 16'd0;

	// Stall RX pop while holding an unaccepted 3D quad OR an unacknowledged SDRAM write
	assign rx_rd = !rx_empty && !(q_valid && !q_ready) && !(sd_wreq && !sd_wack);

	always @(posedge clk_sys or negedge rst_n) begin
		if (!rst_n) begin
			cart_detected    <= 1'b0;
			dbg_rx_words     <= 32'd0;
			q_valid          <= 1'b0;
			q_end            <= 1'b0;
			q_widx           <= 5'd0;
			frame_start_cart <= 1'b0;
			tram_we          <= 1'b0;
			pal_we           <= 1'b0;
			xlat_we          <= 1'b0;
			lut_we           <= 1'b0;
			sd_wreq          <= 1'b0;
			sd_waddr         <= 25'd0;
			sd_wdin          <= 16'd0;
			sd_cur           <= 25'd0;
			tex_inval_cart   <= 1'b0;
			char_inval_cart  <= 1'b0;
			c1_widx          <= 2'd0;
			c2_half          <= 1'b0;
			audio_l          <= 16'd0;
			audio_r          <= 16'd0;
			audio_stb        <= 1'b0;
		end else begin
			frame_start_cart <= 1'b0;
			tram_we          <= 1'b0;
			pal_we           <= 1'b0;
			xlat_we          <= 1'b0;
			lut_we           <= 1'b0;
			tex_inval_cart   <= 1'b0;
			char_inval_cart  <= 1'b0;
			audio_stb        <= 1'b0;
			if (q_valid && q_ready) begin
				q_valid <= 1'b0;
				q_end   <= 1'b0;
			end
			if (sd_wreq && sd_wack) sd_wreq <= 1'b0;

			if (rx_rd) begin
				cart_detected <= 1'b1;
				dbg_rx_words  <= dbg_rx_words + 32'd1;

				case (p_ch)
					// ---- CH0: 3D Projected Quad (27 x 16-bit words) ----
					2'd0: begin
						if (p_sop && p_sub == 4'hF) begin
							frame_start_cart <= 1'b1;
							q_tag            <= p_dat[3:0];
							q_widx           <= 5'd0;
						end else begin
							case (p_sop ? 5'd0 : q_widx)
								5'd0:  q_x0   <= p_dat;
								5'd1:  q_y0   <= p_dat;
								5'd2:  q_x1   <= p_dat;
								5'd3:  q_y1   <= p_dat;
								5'd4:  q_x2   <= p_dat;
								5'd5:  q_y2   <= p_dat;
								5'd6:  q_x3   <= p_dat;
								5'd7:  q_y3   <= p_dat;
								5'd8:  q_col[15:0]  <= p_dat;
								5'd9:  begin q_col[23:16] <= p_dat[7:0]; q_moire <= p_dat[8]; q_mipz <= p_dat[9]; q_uvs <= p_dat[11:10]; q_end_lat <= p_dat[12]; end
								5'd10: q_z[15:0]    <= p_dat;
								5'd11: q_z[31:16]   <= p_dat;
								5'd12: q_oz0        <= p_dat;
								5'd13: q_oz1        <= p_dat;
								5'd14: q_oz2        <= p_dat;
								5'd15: q_oz3        <= p_dat;
								5'd16: q_frac       <= p_dat;
								5'd17: q_u0         <= p_dat[12:0];
								5'd18: q_v0         <= p_dat[12:0];
								5'd19: q_u1         <= p_dat[12:0];
								5'd20: q_v1         <= p_dat[12:0];
								5'd21: q_u2         <= p_dat[12:0];
								5'd22: q_v2         <= p_dat[12:0];
								5'd23: q_u3         <= p_dat[12:0];
								5'd24: q_v3         <= p_dat[12:0];
								5'd25: q_tex[15:0]  <= p_dat;
								5'd26: q_tex[26:16] <= p_dat[10:0];
								default: ;
							endcase
							if (p_eop) begin
								q_valid <= 1'b1;
								q_end   <= q_end_lat;
								q_widx  <= 5'd0;
							end else begin
								q_widx  <= (p_sop ? 5'd1 : q_widx + 5'd1);
							end
						end
					end

					// ---- CH1: 2D Tile / Palette / Xlat / LUT / Live SDRAM Stream ----
					2'd1: begin
						if (p_sop && p_sub == 4'd5) begin
							// Streaming 16-bit SDRAM write burst (auto-incrementing sd_cur)
							c1_kind  <= 4'd5;
							c1_widx  <= p_eop ? 2'd0 : 2'd2;
							sd_wreq  <= 1'b1;
							sd_waddr <= sd_cur;
							sd_wdin  <= p_dat;
							sd_cur   <= sd_cur + 25'd1;
						end else if (p_sop) begin
							c1_kind <= p_sub;
							c1_addr <= p_dat;
							c1_widx <= 2'd1;
							if (p_sub == 4'd6) begin
								// Single-word control pulse: [0]=tex_inval, [1]=char_inval
								tex_inval_cart  <= p_dat[0];
								char_inval_cart <= p_dat[1];
								c1_widx         <= 2'd0;
							end
						end else if (c1_widx == 2'd2 && c1_kind == 4'd5) begin
							// Continuation beat of streaming SDRAM burst
							sd_wreq  <= 1'b1;
							sd_waddr <= sd_cur;
							sd_wdin  <= p_dat;
							sd_cur   <= sd_cur + 25'd1;
							if (p_eop) c1_widx <= 2'd0;
						end else if (c1_widx == 2'd1) begin
							case (c1_kind)
								4'd0: begin tram_we <= 1'b1; tram_addr <= c1_addr[14:0]; tram_din <= p_dat; end
								4'd1: begin pal_we  <= 1'b1; pal_addr  <= c1_addr[11:0]; pal_din  <= p_dat; end
								4'd2: begin xlat_we <= 1'b1; xlat_addr <= c1_addr[6:0];  xlat_din <= p_dat[7:0]; end
								4'd3: begin lut_we  <= 1'b1; lut_sel   <= c1_addr[14:13]; lut_addr <= c1_addr[12:0]; lut_data <= p_dat; end
								4'd4: begin
									sd_cur          <= {p_dat[8:0], c1_addr};
									tex_inval_cart  <= p_dat[14];
									char_inval_cart <= p_dat[15];
								end
								default: ;
							endcase
							c1_widx <= 2'd0;
						end
					end

					// ---- CH2: Stereo 48 kHz PCM Audio ----
					2'd2: begin
						if (p_sop || !c2_half) begin
							c2_left <= p_dat;
							c2_half <= 1'b1;
						end else begin
							audio_l   <= c2_left;
							audio_r   <= p_dat;
							audio_stb <= 1'b1;
							c2_half   <= 1'b0;
						end
					end

					default: ;
				endcase
			end
		end
	end

endmodule
`default_nettype wire
