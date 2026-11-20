// m2_cart_pll: Exact integer Cyclone V PLL for DeadOrPocket Compute Cartridge (5CEBA5F23C8 / 5CEBA7F23C8)
// Reference input: Onboard 50.000 MHz TCXO (clk_50m)
//
// VCO = 50.000 MHz * 16 / 1 = 800.000 MHz (PFD = 50 MHz, valid VCO 600..1300 MHz)
//
// Outputs:
//   outclk[0]: clk_mem       = 100.000 MHz (C0 = 8,  128 MB Dual-Chip SDR SDRAM + Bridge)
//   outclk[1]: clk_sdram_pin = 100.000 MHz (C1 = 8,  +180 deg = 5000 ps -> sdram_clk)
//   outclk[2]: clk_sys       =  50.000 MHz (C2 = 16, m2_geometry + m2_geo + m2_copro + m2_2a_sound + m2_cart_host)
//   outclk[3]: clk_cpu       =  25.000 MHz (C3 = 32, Intel i960KB + FPU, exact arcade clock!)
//
`default_nettype none

module m2_cart_pll (
	input  wire refclk,
	input  wire rst,
	output wire clk_mem,
	output wire clk_sdram_pin,
	output wire clk_sys,
	output wire clk_cpu,
	output wire locked
);
	wire [3:0] outclk;

	assign clk_mem       = outclk[0];
	assign clk_sdram_pin = outclk[1];
	assign clk_sys       = outclk[2];
	assign clk_cpu       = outclk[3];

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(4),
		.output_clock_frequency0("100.000000 MHz"),
		.output_clock_frequency1("100.000000 MHz"),
		.phase_shift1("5000 ps"),
		.output_clock_frequency2("50.000000 MHz"),
		.output_clock_frequency3("25.000000 MHz"),
		.pll_type("Cyclone V"),
		.pll_subtype("General"),
		.m_cnt_hi_div(8),  .m_cnt_lo_div(8),  // M = 16
		.n_cnt_hi_div(1),  .n_cnt_lo_div(1),  // N = 1 (bypassed)
		.m_cnt_bypass_en("false"), .n_cnt_bypass_en("true"),
		.m_cnt_odd_div_duty_en("false"), .n_cnt_odd_div_duty_en("false"),
		.c_cnt_hi_div0(4),  .c_cnt_lo_div0(4),  .c_cnt_odd_div_duty_en0("false"), // C0 = 8
		.c_cnt_hi_div1(4),  .c_cnt_lo_div1(4),  .c_cnt_odd_div_duty_en1("false"), // C1 = 8
		.c_cnt_hi_div2(8),  .c_cnt_lo_div2(8),  .c_cnt_odd_div_duty_en2("false"), // C2 = 16
		.c_cnt_hi_div3(16), .c_cnt_lo_div3(16), .c_cnt_odd_div_duty_en3("false"), // C3 = 32
		.pll_vco_div(1),
		.pll_cp_current(20),
		.pll_bwctrl(4000),
		.pll_output_clk_frequency("800.0 MHz"),
		.mimic_fbclk_type("GCLK"),
		.pll_fbclk_mux_1("glb"),
		.pll_fbclk_mux_2("m_cnt"),
		.pll_m_cnt_in_src("ph_mux_clk"),
		.pll_slf_rst("true")
	) pll_i (
		.refclk(refclk),
		.rst(rst),
		.fbclk(1'b0),
		.outclk(outclk),
		.locked(locked),
		.zdbclk(),
		.fboutclk()
	);

endmodule
`default_nettype wire
