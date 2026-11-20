// m2_fb_psram: Dual-PSRAM (CRAM0 / CRAM1) Ping-Pong Framebuffer Controller
// Replaces MiSTer's m2_ddr3.sv for Analogue Pocket with ZERO modifications to m2_raster3d.
//
// Bank mapping:
//   fb_addr[17] == 1'b0 -> CRAM0 (psram_phy #0, Bank A, 384 KB used of 16 MB)
//   fb_addr[17] == 1'b1 -> CRAM1 (psram_phy #1, Bank B, 384 KB used of 16 MB)
//
// Pixel packing (2x bandwidth gain over 32-bit MiSTer DDR3):
//   Each 64-bit m2_raster3d beat holds two 25-bit pixels:
//     pix0 = fb_din[24:0]  = {hit0, R0[7:0], G0[7:0], B0[7:0]} -> w0 = {hit0, R0[7:3], G0[7:3], B0[7:3]}
//     pix1 = fb_din[56:32] = {hit1, R1[7:0], G1[7:0], B1[7:0]} -> w1 = {hit1, R1[7:3], G1[7:3], B1[7:3]}
//   So 1 beat = 2 x 16-bit PSRAM words. A full 496-pixel scanline (248 beats)
//   is 496 PSRAM words = 16 aligned 32-word bursts (~12 us at 48 MHz PSRAM).
//
`default_nettype none

module m2_fb_psram (
	input  wire        clk_sys,
	input  wire        clk_mem,
	input  wire        rst_n,

	// ---- m2_raster3d consumer port (clk_sys domain) ------------------------
	input  wire        fb_req,
	input  wire        fb_we,
	input  wire [24:0] fb_addr,
	input  wire  [7:0] fb_blen,
	input  wire [63:0] fb_din,
	input  wire  [7:0] fb_be,
	output reg         fb_wnext  = 1'b0,
	output wire        fb_wacc,
	output reg         fb_rvalid = 1'b0,
	output reg         fb_ack    = 1'b0,
	output reg  [63:0] fb_dout   = 64'd0,

	// ---- CRAM0 psram_phy port (clk_mem domain, Bank 0) ---------------------
	input  wire        c0_cfg_done,
	output reg         c0_cmd_valid = 1'b0,
	input  wire        c0_cmd_ready,
	output reg         c0_cmd_we    = 1'b0,
	output reg  [22:0] c0_cmd_addr  = 23'd0,
	output reg   [4:0] c0_cmd_len   = 5'd0,
	input  wire        c0_wd_pop,
	output wire [15:0] c0_wd_data,
	output wire  [1:0] c0_wd_be,
	input  wire        c0_rd_valid,
	input  wire [15:0] c0_rd_data,
	input  wire        c0_rd_last,

	// ---- CRAM1 psram_phy port (clk_mem domain, Bank 1) ---------------------
	input  wire        c1_cfg_done,
	output reg         c1_cmd_valid = 1'b0,
	input  wire        c1_cmd_ready,
	output reg         c1_cmd_we    = 1'b0,
	output reg  [22:0] c1_cmd_addr  = 23'd0,
	output reg   [4:0] c1_cmd_len   = 5'd0,
	input  wire        c1_wd_pop,
	output wire [15:0] c1_wd_data,
	output wire  [1:0] c1_wd_be,
	input  wire        c1_rd_valid,
	input  wire [15:0] c1_rd_data,
	input  wire        c1_rd_last,

	output wire        ready_o
);

	// Helper pack / unpack RGB555 + hit
	function automatic [15:0] pack_px(input [24:0] p);
		pack_px = {p[24], p[23:19], p[15:11], p[7:3]};
	endfunction

	function automatic [24:0] unpack_px(input [15:0] w);
		unpack_px = {w[15], w[14:10], w[14:12], w[9:5], w[9:7], w[4:0], w[4:2]};
	endfunction

	// Synchronize PSRAM init complete to clk_sys
	reg [1:0] cfg_s = 2'b00;
	always @(posedge clk_sys or negedge rst_n) begin
		if (!rst_n) cfg_s <= 2'b00;
		else        cfg_s <= {cfg_s[0], c0_cfg_done & c1_cfg_done};
	end
	assign ready_o = cfg_s[1];

	// -------------------------------------------------------------------------
	// Write beat FIFO (clk_sys -> clk_mem): 256 x 34 bits {be1, be0, w1[15:0], w0[15:0]}
	// -------------------------------------------------------------------------
	wire        wf_wrreq;
	wire [33:0] wf_din = {fb_be[4], fb_be[0], pack_px(fb_din[56:32]), pack_px(fb_din[24:0])};
	wire [33:0] wf_dout;
	wire        wf_rdreq, wf_empty, wf_full;

	dcfifo #(
		.intended_device_family("Cyclone V"),
		.lpm_numwords(256),
		.lpm_showahead("ON"),
		.lpm_type("dcfifo"),
		.lpm_width(34),
		.lpm_widthu(8),
		.overflow_checking("ON"),
		.underflow_checking("ON"),
		.use_eab("ON")
	) u_wbuf (
		.data(wf_din), .wrclk(clk_sys), .wrreq(wf_wrreq),
		.rdclk(clk_mem), .rdreq(wf_rdreq), .q(wf_dout),
		.rdempty(wf_empty), .wrfull(wf_full),
		.aclr(!rst_n), .eccstatus(), .rdfull(), .rdusedw(), .wrempty(), .wrusedw()
	);

	// -------------------------------------------------------------------------
	// Read beat FIFO (clk_mem -> clk_sys): 256 x 32 bits {w1[15:0], w0[15:0]}
	// -------------------------------------------------------------------------
	reg         rf_wrreq = 1'b0;
	reg  [31:0] rf_din   = 32'd0;
	wire [31:0] rf_dout;
	wire        rf_rdreq, rf_empty, rf_full;

	dcfifo #(
		.intended_device_family("Cyclone V"),
		.lpm_numwords(256),
		.lpm_showahead("ON"),
		.lpm_type("dcfifo"),
		.lpm_width(32),
		.lpm_widthu(8),
		.overflow_checking("ON"),
		.underflow_checking("ON"),
		.use_eab("ON")
	) u_rbuf (
		.data(rf_din), .wrclk(clk_mem), .wrreq(rf_wrreq),
		.rdclk(clk_sys), .rdreq(rf_rdreq), .q(rf_dout),
		.rdempty(rf_empty), .wrfull(rf_full),
		.aclr(!rst_n), .eccstatus(), .rdfull(), .rdusedw(), .wrempty(), .wrusedw()
	);

	// -------------------------------------------------------------------------
	// clk_sys side: accept m2_raster3d burst, push writes or pull reads
	// -------------------------------------------------------------------------
	localparam [1:0] CS_IDLE = 2'd0, CS_WR = 2'd1, CS_RD = 2'd2, CS_WAIT = 2'd3;
	reg [1:0]  cs_st    = CS_IDLE;
	reg [7:0]  cs_rem   = 8'd0;
	reg        cmd_tog  = 1'b0;
	reg        cmd_we_r = 1'b0;
	reg        cmd_bk_r = 1'b0;
	reg [16:0] cmd_ba_r = 17'd0;
	reg [7:0]  cmd_bl_r = 8'd0;

	reg        done_tog_m = 1'b0;
	reg [2:0]  done_sync  = 3'd0;

	assign fb_wacc  = (cs_st == CS_WR) && !wf_full;
	assign wf_wrreq = fb_wacc;
	assign rf_rdreq = (cs_st == CS_RD) && !rf_empty;

	always @(posedge clk_sys or negedge rst_n) begin
		if (!rst_n) begin
			cs_st     <= CS_IDLE;
			cs_rem    <= 8'd0;
			cmd_tog   <= 1'b0;
			cmd_we_r  <= 1'b0;
			cmd_bk_r  <= 1'b0;
			cmd_ba_r  <= 17'd0;
			cmd_bl_r  <= 8'd0;
			done_sync <= 3'd0;
			fb_wnext  <= 1'b0;
			fb_rvalid <= 1'b0;
			fb_ack    <= 1'b0;
			fb_dout   <= 64'd0;
		end else begin
			done_sync <= {done_sync[1:0], done_tog_m};
			fb_wnext  <= 1'b0;
			fb_rvalid <= 1'b0;
			fb_ack    <= 1'b0;

			case (cs_st)
				CS_IDLE: begin
					if (fb_req && ready_o && !fb_ack) begin
						cmd_we_r <= fb_we;
						cmd_bk_r <= fb_addr[17];
						cmd_ba_r <= fb_addr[16:0];
						cmd_bl_r <= (fb_blen == 8'd0) ? 8'd1 : fb_blen;
						cs_rem   <= (fb_blen == 8'd0) ? 8'd1 : fb_blen;
						cmd_tog  <= ~cmd_tog;
						cs_st    <= fb_we ? CS_WR : CS_RD;
					end
				end

				CS_WR: begin
					if (!wf_full) begin
						fb_wnext <= 1'b1;
						if (cs_rem == 8'd1) begin
							cs_st <= CS_WAIT;
						end else begin
							cs_rem <= cs_rem - 8'd1;
						end
					end
				end

				CS_RD: begin
					if (!rf_empty) begin
						fb_dout   <= {7'd0, unpack_px(rf_dout[31:16]), 7'd0, unpack_px(rf_dout[15:0])};
						fb_rvalid <= 1'b1;
						if (cs_rem == 8'd1) begin
							fb_ack <= 1'b1;
							cs_st  <= CS_IDLE;
						end else begin
							cs_rem <= cs_rem - 8'd1;
						end
					end
				end

				CS_WAIT: begin
					if (done_sync[2] ^ done_sync[1]) begin
						fb_ack <= 1'b1;
						cs_st  <= CS_IDLE;
					end
				end
			endcase
		end
	end

	// -------------------------------------------------------------------------
	// clk_mem side: split into <=32-word aligned bursts onto CRAM0 or CRAM1 PHY
	// -------------------------------------------------------------------------
	reg [2:0]  cmd_sync = 3'd0;
	localparam [2:0] MS_IDLE = 3'd0, MS_PREP = 3'd1, MS_ISSUE = 3'd2, MS_WR_RUN = 3'd3, MS_RD_RUN = 3'd4;
	reg [2:0]  ms_st     = MS_IDLE;
	reg        ms_we     = 1'b0;
	reg        ms_bk     = 1'b0;
	reg [17:0] ms_waddr  = 18'd0; // 16-bit word address = {beat_addr[16:0], 1'b0}
	reg [8:0]  ms_wrem   = 9'd0;  // remaining 16-bit words (2 * beats)
	reg [5:0]  ms_chunk  = 6'd0;  // words in current burst (1..32)
	reg        ms_whalf  = 1'b0;  // 0 = low word w0, 1 = high word w1
	reg        ms_rhalf  = 1'b0;
	reg [15:0] ms_rlo    = 16'd0;

	wire       phy_ready = ms_bk ? c1_cmd_ready : c0_cmd_ready;
	wire       phy_wpop  = ms_bk ? c1_wd_pop    : c0_wd_pop;
	wire       phy_rval  = ms_bk ? c1_rd_valid  : c0_rd_valid;
	wire [15:0] phy_rdat = ms_bk ? c1_rd_data   : c0_rd_data;
	wire       phy_rlast = ms_bk ? c1_rd_last   : c0_rd_last;

	// Current write word & byte enable (00 = masked write when pixel disabled)
	wire [15:0] cur_wdata = ms_whalf ? wf_dout[31:16] : wf_dout[15:0];
	wire        cur_wen   = ms_whalf ? wf_dout[33]    : wf_dout[32];
	assign c0_wd_data = cur_wdata;
	assign c1_wd_data = cur_wdata;
	assign c0_wd_be   = {2{cur_wen}};
	assign c1_wd_be   = {2{cur_wen}};

	// Pop 34-bit beat from write FIFO after the high word (ms_whalf==1) is taken
	assign wf_rdreq = (ms_st == MS_WR_RUN) && phy_wpop && ms_whalf;

	// Max words until 32-word alignment boundary
	wire [5:0] to_bound = 6'd32 - {1'b0, ms_waddr[4:0]};
	wire [5:0] next_len = ({3'd0, to_bound} < ms_wrem) ? to_bound : ms_wrem[5:0];

	always @(posedge clk_mem or negedge rst_n) begin
		if (!rst_n) begin
			cmd_sync     <= 3'd0;
			ms_st        <= MS_IDLE;
			ms_we        <= 1'b0;
			ms_bk        <= 1'b0;
			ms_waddr     <= 18'd0;
			ms_wrem      <= 9'd0;
			ms_chunk     <= 6'd0;
			ms_whalf     <= 1'b0;
			ms_rhalf     <= 1'b0;
			ms_rlo       <= 16'd0;
			done_tog_m   <= 1'b0;
			c0_cmd_valid <= 1'b0;
			c1_cmd_valid <= 1'b0;
			rf_wrreq     <= 1'b0;
			rf_din       <= 32'd0;
		end else begin
			cmd_sync <= {cmd_sync[1:0], cmd_tog};
			rf_wrreq <= 1'b0;

			case (ms_st)
				MS_IDLE: begin
					c0_cmd_valid <= 1'b0;
					c1_cmd_valid <= 1'b0;
					if (cmd_sync[2] ^ cmd_sync[1]) begin
						ms_we    <= cmd_we_r;
						ms_bk    <= cmd_bk_r;
						ms_waddr <= {cmd_ba_r, 1'b0};
						ms_wrem  <= {cmd_bl_r, 1'b0};
						ms_whalf <= 1'b0;
						ms_rhalf <= 1'b0;
						ms_st    <= MS_PREP;
					end
				end

				MS_PREP: begin
					// For writes, ensure at least 1 beat is present in wf before starting
					if (!ms_we || !wf_empty) begin
						ms_chunk <= next_len;
						if (ms_bk) begin
							c1_cmd_we    <= ms_we;
							c1_cmd_addr  <= {5'd0, ms_waddr};
							c1_cmd_len   <= next_len[4:0] - 5'd1;
							c1_cmd_valid <= 1'b1;
						end else begin
							c0_cmd_we    <= ms_we;
							c0_cmd_addr  <= {5'd0, ms_waddr};
							c0_cmd_len   <= next_len[4:0] - 5'd1;
							c0_cmd_valid <= 1'b1;
						end
						ms_st <= MS_ISSUE;
					end
				end

				MS_ISSUE: begin
					if (phy_ready) begin
						c0_cmd_valid <= 1'b0;
						c1_cmd_valid <= 1'b0;
						ms_st        <= ms_we ? MS_WR_RUN : MS_RD_RUN;
					end
				end

				MS_WR_RUN: begin
					if (phy_wpop) begin
						ms_whalf <= ~ms_whalf;
						ms_waddr <= ms_waddr + 18'd1;
						ms_wrem  <= ms_wrem  - 9'd1;
						if (ms_chunk == 6'd1) begin
							if (ms_wrem == 9'd1) begin
								done_tog_m <= ~done_tog_m;
								ms_st      <= MS_IDLE;
							end else begin
								ms_st <= MS_PREP;
							end
						end else begin
							ms_chunk <= ms_chunk - 6'd1;
						end
					end
				end

				MS_RD_RUN: begin
					if (phy_rval) begin
						if (!ms_rhalf) begin
							ms_rlo   <= phy_rdat;
							ms_rhalf <= 1'b1;
						end else begin
							rf_din   <= {phy_rdat, ms_rlo};
							rf_wrreq <= 1'b1;
							ms_rhalf <= 1'b0;
						end
						ms_waddr <= ms_waddr + 18'd1;
						ms_wrem  <= ms_wrem  - 9'd1;
						if (phy_rlast) begin
							if (ms_wrem == 9'd1) begin
								ms_st <= MS_IDLE;
							end else begin
								ms_st <= MS_PREP;
							end
						end
					end
				end

				default: ms_st <= MS_IDLE;
			endcase
		end
	end

endmodule
`default_nettype wire
