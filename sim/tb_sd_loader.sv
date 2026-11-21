// tb_sd_loader.sv: Verilator testbench for real SD/SDHC SPI Boot Loader (m2_sd_loader)
// Verifies CMD0 -> CMD8 -> CMD55/ACMD41 -> CMD58 (SDHC) -> CMD17 (MBR Partition 1 follow)
// -> CMD17 (DOP2 header) -> CMD18 (Multi-block stream w/ SDRAM backpressure) -> CMD12!
`timescale 1ns/1ps
`default_nettype none

module tb_sd_loader (
	input  wire        clk,
	input  wire        rst_n,
	input  wire        sdram_ready,

	// SPI bus exposed to behavioral SDHC card model in C++
	output wire        sd_sck,
	output wire        sd_cs_n,
	output wire        sd_mosi,
	input  wire        sd_miso,

	// SDRAM write port exposed to C++ SDRAM verifier (with variable latency backpressure)
	output wire        wr_req,
	output wire [26:1] wr_addr,
	output wire [15:0] wr_din,
	input  wire        wr_ack,

	output wire        boot_done,
	output wire        boot_err,
	output wire  [6:0] boot_game_id,
	output wire        boot_prog_ext,
	output wire [25:0] boot_words_loaded
);

	m2_sd_loader #(
		.INIT_DIV ( 2 ), // Fast sim divider (real silicon uses 128 -> 390 kHz)
		.FAST_DIV ( 1 )  // Fast sim divider (real silicon uses 2 -> 25 MHz)
	) u_dut (
		.clk               ( clk ),
		.rst_n             ( rst_n ),
		.sdram_ready       ( sdram_ready ),
		.sd_sck            ( sd_sck ),
		.sd_cs_n           ( sd_cs_n ),
		.sd_mosi           ( sd_mosi ),
		.sd_miso           ( sd_miso ),
		.wr_req            ( wr_req ),
		.wr_addr           ( wr_addr ),
		.wr_din            ( wr_din ),
		.wr_ack            ( wr_ack ),
		.boot_done         ( boot_done ),
		.boot_err          ( boot_err ),
		.boot_game_id      ( boot_game_id ),
		.boot_prog_ext     ( boot_prog_ext ),
		.boot_words_loaded ( boot_words_loaded )
	);

endmodule
`default_nettype wire
