// m2_demo_gen: Built-in 57.52 Hz 3D + 2D Hardware Self-Test Generator (Phase 1)
//
// Exercises the FULL m2_raster3d -> m2_fb_psram -> CRAM0/CRAM1 -> APF 496x384
// pipeline on real Analogue Pocket hardware even before a Compute Cartridge is
// connected. Emits an animated perspective 3D checkerboard floor + floating
// shaded quads every video frame (57.52 Hz).
//
`default_nettype none

module m2_demo_gen (
	input  wire        clk,        // clk_sys (79.92 MHz)
	input  wire        rst_n,
	input  wire        enable,
	input  wire        vblank_pulse,

	output reg         frame_start = 1'b0,
	output reg         q_valid     = 1'b0,
	input  wire        q_ready,
	output reg  signed [15:0] q_x0 = 16'sd0, q_y0 = 16'sd0,
	output reg  signed [15:0] q_x1 = 16'sd0, q_y1 = 16'sd0,
	output reg  signed [15:0] q_x2 = 16'sd0, q_y2 = 16'sd0,
	output reg  signed [15:0] q_x3 = 16'sd0, q_y3 = 16'sd0,
	output reg  [23:0] q_col  = 24'd0,
	output reg  [31:0] q_z    = 32'd0,
	output reg         q_end  = 1'b0,
	output reg   [3:0] q_tag  = 4'd0
);

	// 16 animated flat-shaded quads per frame (sky band, perspective floor tiles,
	// and bouncing Sega Model 2 diamond centerpiece)
	localparam [1:0] S_IDLE = 2'd0, S_START = 2'd1, S_EMIT = 2'd2, S_DONE = 2'd3;
	reg [1:0]  st     = S_IDLE;
	reg [4:0]  idx    = 5'd0;
	reg [8:0]  anim   = 9'd0;

	// Simple triangle-wave oscillator from anim[7:0] (0..127..0)
	wire [6:0] tri_x = anim[7] ? ~anim[6:0] : anim[6:0];
	wire [6:0] tri_y = anim[6] ? ~anim[5:0] : anim[5:0];
	wire signed [15:0] cx = 16'sd184 + $signed({9'd0, tri_x});
	wire signed [15:0] cy = 16'sd120 + $signed({10'd0, tri_y[5:0]});

	always @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			st          <= S_IDLE;
			idx         <= 5'd0;
			anim        <= 9'd0;
			frame_start <= 1'b0;
			q_valid     <= 1'b0;
			q_end       <= 1'b0;
			q_tag       <= 4'd0;
		end else begin
			frame_start <= 1'b0;

			if (!enable) begin
				st      <= S_IDLE;
				q_valid <= 1'b0;
				q_end   <= 1'b0;
			end else begin
				case (st)
					S_IDLE: begin
						q_valid <= 1'b0;
						if (vblank_pulse) begin
							anim        <= anim + 9'd1;
							q_tag       <= q_tag + 4'd1;
							frame_start <= 1'b1;
							idx         <= 5'd0;
							st          <= S_START;
						end
					end

					S_START: begin
						// Wait 1 cycle after frame_start before presenting quad 0
						st <= S_EMIT;
					end

					S_EMIT: begin
						if (!q_valid || q_ready) begin
							q_valid <= 1'b1;
							q_end   <= (idx == 5'd11);

							case (idx)
								// Far horizon backdrop (deep midnight blue)
								5'd0: begin
									q_x0 <= 16'sd0;   q_y0 <= 16'sd0;
									q_x1 <= 16'sd495; q_y1 <= 16'sd0;
									q_x2 <= 16'sd495; q_y2 <= 16'sd200;
									q_x3 <= 16'sd0;   q_y3 <= 16'sd200;
									q_col <= 24'h000818; // BGR/RGB565 -> deep navy
									q_z   <= 32'h000F_0000;
								end
								// Ground plane base (dark slate)
								5'd1: begin
									q_x0 <= 16'sd0;   q_y0 <= 16'sd200;
									q_x1 <= 16'sd495; q_y1 <= 16'sd200;
									q_x2 <= 16'sd495; q_y2 <= 16'sd383;
									q_x3 <= 16'sd0;   q_y3 <= 16'sd383;
									q_col <= 24'h001020;
									q_z   <= 32'h000E_0000;
								end
								// Perspective floor strips (6 alternating cyan/blue quads)
								5'd2, 5'd3, 5'd4, 5'd5, 5'd6, 5'd7: begin
									// Horizontal scrolling perspective bands
									q_x0 <= 16'sd24 + $signed({11'd0, idx - 5'd2}) * 16'sd74;
									q_y0 <= 16'sd210;
									q_x1 <= 16'sd88 + $signed({11'd0, idx - 5'd2}) * 16'sd74;
									q_y1 <= 16'sd210;
									q_x2 <= 16'sd64 + $signed({11'd0, idx - 5'd2}) * 16'sd86;
									q_y2 <= 16'sd360;
									q_x3 <= 16'sd0  + $signed({11'd0, idx - 5'd2}) * 16'sd86;
									q_y3 <= 16'sd360;
									q_col <= idx[0] ? 24'h002858 : 24'h004888;
									q_z   <= 32'h000A_0000;
								end
								// Floating animated centerpiece - Outer frame (Kasumi cobalt blue)
								5'd8: begin
									q_x0 <= cx;            q_y0 <= cy - 16'sd68;
									q_x1 <= cx + 16'sd84;  q_y1 <= cy;
									q_x2 <= cx;            q_y2 <= cy + 16'sd68;
									q_x3 <= cx - 16'sd84;  q_y3 <= cy;
									q_col <= 24'h0020E8;
									q_z   <= 32'h0005_0000;
								end
								// Inner diamond (bright white/silver)
								5'd9: begin
									q_x0 <= cx;            q_y0 <= cy - 16'sd42;
									q_x1 <= cx + 16'sd52;  q_y1 <= cy;
									q_x2 <= cx;            q_y2 <= cy + 16'sd42;
									q_x3 <= cx - 16'sd52;  q_y3 <= cy;
									q_col <= 24'h00E8F0;
									q_z   <= 32'h0003_0000;
								end
								// Left accent prism (crimson)
								5'd10: begin
									q_x0 <= 16'sd40;  q_y0 <= 16'sd60;
									q_x1 <= 16'sd110; q_y1 <= 16'sd80;
									q_x2 <= 16'sd90;  q_y2 <= 16'sd170;
									q_x3 <= 16'sd30;  q_y3 <= 16'sd150;
									q_col <= 24'h00E030;
									q_z   <= 32'h0004_0000;
								end
								// Right accent prism (gold)
								default: begin
									q_x0 <= 16'sd386; q_y0 <= 16'sd80;
									q_x1 <= 16'sd456; q_y1 <= 16'sd60;
									q_x2 <= 16'sd466; q_y2 <= 16'sd150;
									q_x3 <= 16'sd406; q_y3 <= 16'sd170;
									q_col <= 24'h00F8C0;
									q_z   <= 32'h0004_0000;
								end
							endcase

							if (idx == 5'd11) begin
								st <= S_DONE;
							end else begin
								idx <= idx + 5'd1;
							end
						end
					end

					S_DONE: begin
						if (q_ready) begin
							q_valid <= 1'b0;
							q_end   <= 1'b0;
							st      <= S_IDLE;
						end
					end
				endcase
			end
		end
	end

endmodule
`default_nettype wire
