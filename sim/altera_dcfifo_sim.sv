// Behavioral dual-clock show-ahead dcfifo model for Verilator co-simulation
// Matches Intel/Altera Cyclone V dcfifo port signature & show-ahead semantics.
`default_nettype none

module dcfifo #(
	parameter string intended_device_family = "Cyclone V",
	parameter int    lpm_numwords           = 256,
	parameter string lpm_showahead          = "ON",
	parameter string lpm_type               = "dcfifo",
	parameter int    lpm_width              = 24,
	parameter int    lpm_widthu             = 8,
	parameter string overflow_checking      = "ON",
	parameter string underflow_checking     = "ON",
	parameter string use_eab                = "ON",
	parameter string add_ram_output_register = "OFF"
) (
	input  wire [lpm_width-1:0]  data,
	input  wire                  wrclk,
	input  wire                  wrreq,
	input  wire                  rdclk,
	input  wire                  rdreq,
	input  wire                  aclr,
	output wire [lpm_width-1:0]  q,
	output wire                  rdempty,
	output wire                  rdfull,
	output wire [lpm_widthu-1:0] rdusedw,
	output wire                  wrempty,
	output wire                  wrfull,
	output wire [lpm_widthu-1:0] wrusedw,
	output wire [1:0]            eccstatus
);
	localparam int DEPTH = (1 << lpm_widthu);
	reg [lpm_width-1:0] mem [0:DEPTH-1];
	reg [lpm_widthu:0]  wptr = '0;
	reg [lpm_widthu:0]  rptr = '0;

	wire [lpm_widthu:0] used = wptr - rptr;

	assign eccstatus = 2'b00;
	assign wrempty   = (used == '0);
	assign rdempty   = (used == '0);
	assign wrfull    = (used >= DEPTH[lpm_widthu:0]);
	assign rdfull    = wrfull;
	assign wrusedw   = used[lpm_widthu-1:0];
	assign rdusedw   = used[lpm_widthu-1:0];
	assign q         = mem[rptr[lpm_widthu-1:0]];

	always @(posedge wrclk or posedge aclr) begin
		if (aclr) begin
			wptr <= '0;
		end else if (wrreq && !wrfull) begin
			mem[wptr[lpm_widthu-1:0]] <= data;
			wptr <= wptr + 1'b1;
		end
	end

	always @(posedge rdclk or posedge aclr) begin
		if (aclr) begin
			rptr <= '0;
		end else if (rdreq && !rdempty) begin
			rptr <= rptr + 1'b1;
		end
	end
endmodule
`default_nettype wire
