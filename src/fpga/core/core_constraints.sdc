# DeadOrPocket (Sega Model 2 / 2A-CRX Hybrid Render Core) timing constraints
# Loaded by apf/apf_constraints.sdc after clk_74a/clk_74b and derive_pll_clocks.

set_clock_groups -asynchronous \
    -group [get_clocks {clk_74a clk_74b}] \
    -group [get_clocks {*u_pll*counter[0].output_counter|divclk *u_pll*counter[1].output_counter|divclk *u_pll*counter[4].output_counter|divclk *u_pll*counter[5].output_counter|divclk}] \
    -group [get_clocks {*u_pll*counter[2].output_counter|divclk}] \
    -group [get_clocks {*u_pll*counter[3].output_counter|divclk}] \
    -group [get_clocks {*u_audio_pll*counter[0].output_counter|divclk}]
