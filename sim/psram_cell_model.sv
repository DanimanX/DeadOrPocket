// Behavioral CellularRAM 1.5 (AS1C8M16PL) device model for Verilator co-simulation
// Matches SpaceFish's psram_phy.sv (LC=2, CLKDIV=2, RDLAT=2, ADMUX bursts).
`default_nettype none

module psram_cell_model #(
	parameter int LC = 2,
	parameter int WORDS = 262144 // 512 KB backing store (covers full 384 KB 496x384 RGB555 FB)
) (
	input  wire [21:16] p_a,
	input  wire [15:0]  p_dq_out,
	input  wire         p_dq_oe,
	output reg  [15:0]  p_dq_in = 16'd0,
	input  wire         p_clk,
	input  wire         p_adv_n,
	input  wire         p_cre,
	input  wire         p_ce0_n,
	input  wire         p_ce1_n,
	input  wire         p_oe_n,
	input  wire         p_we_n,
	input  wire         p_ub_n,
	input  wire         p_lb_n,
	output reg          p_wait = 1'b1
);
	reg [15:0] mem [0:WORDS-1];
	initial begin
		for (int i = 0; i < WORDS; i++) mem[i] = 16'd0;
	end

	wire ce_active = (!p_ce0_n) || (!p_ce1_n);
	reg        active = 1'b0;
	reg        we_r   = 1'b0;
	reg [17:0] addr_r = 18'd0;
	reg  [6:0] cyc    = 7'd0;

	always @(posedge p_clk) begin
		if (!ce_active || p_cre) begin
			active  <= 1'b0;
			cyc     <= 7'd0;
			p_wait  <= 1'b1;
			p_dq_in <= 16'd0;
		end else if (!p_adv_n) begin
			// Address cycle (K_0): latch ADMUX address and R/W direction
			active <= 1'b1;
			we_r   <= !p_we_n;
			addr_r <= {p_a[17:16], p_dq_out};
			cyc    <= 7'd1;
			p_wait <= 1'b1;
		end else if (active) begin
			cyc <= cyc + 7'd1;
			if (!we_r) begin
				// Read burst: drive word starting at K_LC (cyc == LC), sampled at K_(LC+1)
				if (cyc >= LC[6:0]) begin
					p_wait  <= 1'b0;
					p_dq_in <= mem[addr_r];
					addr_r  <= addr_r + 18'd1;
				end else begin
					p_wait <= 1'b1;
				end
			end else begin
				// Write burst: fixed latency, first word sampled at K_(LC+1) (cyc == LC + 1)
				p_wait <= (cyc < (LC[6:0] + 7'd1));
				if (cyc >= (LC[6:0] + 7'd1)) begin
					if (!p_lb_n) mem[addr_r][7:0]  <= p_dq_out[7:0];
					if (!p_ub_n) mem[addr_r][15:8] <= p_dq_out[15:8];
					addr_r <= addr_r + 18'd1;
				end
			end
		end
	end
endmodule
`default_nettype wire
