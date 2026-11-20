# DeadOrPocket Compute Cartridge Timing Constraints (Cyclone V 5CEBA5F23C8 / 5CEBA7F23C8)

create_clock -name clk_50m  -period 20.000 [get_ports {clk_50m}]
create_clock -name clk_bus  -period 31.280 [get_ports {cart_bank0[7]}]

derive_pll_clocks -create_base_clocks
derive_clock_uncertainty

# Asynchronous clock groups:
#   - Group 1: Onboard PLL family (clk_mem 100MHz, clk_sdram_pin 100MHz, clk_sys 50MHz, clk_cpu 25MHz)
#     Wait: clk_sys (50MHz) and clk_cpu (25MHz) are integer-synchronous (m2_cpu_bridge ASYNC=0),
#     while clk_mem (100MHz) crosses clk_sys via m2_cdc_port (2-FF handshake).
#   - Group 2: Pocket-driven 31.97 MHz Cartridge Bus clock (cart_bank0[7]) crossing via u_tx_fifo dcfifo.
set_clock_groups -asynchronous \
    -group [get_clocks {clk_50m *u_pll*counter[0].output_counter|divclk *u_pll*counter[1].output_counter|divclk}] \
    -group [get_clocks {*u_pll*counter[2].output_counter|divclk *u_pll*counter[3].output_counter|divclk}] \
    -group [get_clocks {clk_bus}]
