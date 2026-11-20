// m2_pll: Exact integer Cyclone V PLL for DeadOrPocket (Sega Model 2 / 2A)
// Reference input: Analogue Pocket clk_74a (74.25 MHz)
//
// VCO = 74.25 MHz * 155 / 12 = 959.0625 MHz (PFD = 6.1875 MHz, valid 600..1300 MHz)
//
// Outputs:
//   outclk[0]: clk_mem       = 95.906250 MHz (C0 = 10, SDRAM + PSRAM PHY + 2D video)
//   outclk[1]: clk_sdram_pin = 95.906250 MHz (C1 = 10, +180 deg = 5213 ps -> dram_clk)
//   outclk[2]: clk_sys       = 73.774038 MHz (C2 = 13, m2_raster3d + FB + Cart Bus, 100% C8 timing closure)
//   outclk[3]: clk_cart      = 31.968750 MHz (C3 = 30, 16-bit Cartridge Slot Bus -> 63.9 MB/s)
//   outclk[4]: clk_pix       = 15.984375 MHz (C4 = 60, APF pixel clock 496x384 @ 57.47 Hz)
//   outclk[5]: clk_pix_90    = 15.984375 MHz (C5 = 60, +90 deg = 15640 ps for APF DDR video)
//
`default_nettype none

module m2_pll (
	input  wire refclk,
	input  wire rst,
	output wire clk_mem,
	output wire clk_sdram_pin,
	output wire clk_sys,
	output wire clk_cart,
	output wire clk_pix,
	output wire clk_pix_90,
	output wire locked
);
	wire [5:0] outclk;

	assign clk_mem       = outclk[0];
	assign clk_sdram_pin = outclk[1];
	assign clk_sys       = outclk[2];
	assign clk_cart      = outclk[3];
	assign clk_pix       = outclk[4];
	assign clk_pix_90    = outclk[5];

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("74.25 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(6),
		.output_clock_frequency0("95.906250 MHz"),
		.output_clock_frequency1("95.906250 MHz"),
		.phase_shift1("5213 ps"),
		.output_clock_frequency2("73.774038 MHz"),
		.output_clock_frequency3("31.968750 MHz"),
		.output_clock_frequency4("15.984375 MHz"),
		.output_clock_frequency5("15.984375 MHz"),
		.phase_shift5("15640 ps"),
		.pll_type("Cyclone V"),
		.pll_subtype("General"),
		.m_cnt_hi_div(78), .m_cnt_lo_div(77), // M = 155
		.n_cnt_hi_div(6),  .n_cnt_lo_div(6),  // N = 12
		.m_cnt_bypass_en("false"), .n_cnt_bypass_en("false"),
		.m_cnt_odd_div_duty_en("true"), .n_cnt_odd_div_duty_en("false"),
		.c_cnt_hi_div0(5),  .c_cnt_lo_div0(5),  .c_cnt_odd_div_duty_en0("false"), // C0 = 10
		.c_cnt_hi_div1(5),  .c_cnt_lo_div1(5),  .c_cnt_odd_div_duty_en1("false"), // C1 = 10
		.c_cnt_hi_div2(7),  .c_cnt_lo_div2(6),  .c_cnt_odd_div_duty_en2("true"),  // C2 = 13
		.c_cnt_hi_div3(15), .c_cnt_lo_div3(15), .c_cnt_odd_div_duty_en3("false"), // C3 = 30
		.c_cnt_hi_div4(30), .c_cnt_lo_div4(30), .c_cnt_odd_div_duty_en4("false"), // C4 = 60
		.c_cnt_hi_div5(30), .c_cnt_lo_div5(30), .c_cnt_odd_div_duty_en5("false"), // C5 = 60
		.pll_vco_div(1),
		.pll_cp_current(20),
		.pll_bwctrl(4000),
		.pll_output_clk_frequency("959.0625 MHz"),
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
