# DeadOrPocket Phase 2 Verilator Co-Simulation Makefile
VERILATOR ?= verilator
VFLAGS    = --cc --exe --build -j 0 --Wno-fatal --Wno-UNOPTFLAT --Wno-WIDTH \
            --Wno-PINMISSING --Wno-CASEINCOMPLETE --Wno-BLKSEQ --Wno-SYNCASYNCNET \
            --Wno-LATCH --Wno-MULTIDRIVEN --Wno-CMPCONST --Wno-UNSIGNED --Wno-LITENDIAN \
            --Wno-INITIALDLY -O3 --x-assign 0 --x-initial 0

POCKET_RTL = ../src/fpga/pocket_rtl
M2_RTL     = ../src/fpga/m2_rtl
CART_RTL   = ../src/cart_rtl

BUS_SV = \
	altera_dcfifo_sim.sv \
	psram_cell_model.sv \
	sdram_model.sv \
	$(CART_RTL)/m2_cart_host.sv \
	$(POCKET_RTL)/m2_cart_bus.sv \
	$(POCKET_RTL)/m2_fb_psram.sv \
	$(POCKET_RTL)/psram_phy.sv \
	$(M2_RTL)/m2_cdc_port.sv \
	$(M2_RTL)/m2_cdc_pulse.sv \
	$(M2_RTL)/m2_char_cache.sv \
	$(M2_RTL)/m2_ddr3_arb.sv \
	$(M2_RTL)/m2_fb_read.sv \
	$(M2_RTL)/m2_fb_wcomb.sv \
	$(M2_RTL)/m2_fb_write.sv \
	$(M2_RTL)/m2_fifo_m10k.sv \
	$(M2_RTL)/m2_handshake_cdc.sv \
	$(M2_RTL)/m2_palette.sv \
	$(M2_RTL)/m2_persp_recip.sv \
	$(M2_RTL)/m2_quad_store.sv \
	$(M2_RTL)/m2_raster3d.sv \
	$(M2_RTL)/m2_raster_band.sv \
	$(M2_RTL)/m2_raster_div.sv \
	$(M2_RTL)/m2_raster_fill.sv \
	$(M2_RTL)/m2_recip_rom.sv \
	$(M2_RTL)/m2_sdram.sv \
	$(M2_RTL)/m2_span_tex.sv \
	$(M2_RTL)/m2_tdp_ram2c.sv \
	$(M2_RTL)/m2_texel.sv \
	$(M2_RTL)/m2_texel_addr.sv \
	$(M2_RTL)/m2_texel_bl.sv \
	$(M2_RTL)/m2_texel_cdc.sv \
	$(M2_RTL)/m2_tile_decode.sv \
	$(M2_RTL)/m2_tile_fetch.sv \
	$(M2_RTL)/m2_tile_mixer.sv \
	$(M2_RTL)/m2_video.sv \
	$(M2_RTL)/m2_video_timing.sv \
	tb_hybrid_bus_top.sv

UPSTREAM_RTL = ../upstream/sega-model2a-mister/rtl
I960_SV = $(wildcard $(UPSTREAM_RTL)/cpu/i960/*.sv)
M2A_CART_SV = \
	altera_dcfifo_sim.sv \
	$(I960_SV) \
	$(UPSTREAM_RTL)/io/m2_cpu_bridge.sv \
	$(CART_RTL)/m2_cart_host.sv \
	$(POCKET_RTL)/m2_cart_bus.sv \
	$(M2_RTL)/m2_palette.sv \
	$(M2_RTL)/m2_tdp_ram2c.sv \
	$(M2_RTL)/m2_tile_decode.sv \
	$(M2_RTL)/m2_tile_fetch.sv \
	$(M2_RTL)/m2_tile_mixer.sv \
	$(M2_RTL)/m2_video.sv \
	$(M2_RTL)/m2_video_timing.sv \
	tb_m2a_cart_top.sv

.PHONY: all run_bus run_m2a run_sd clean

all: run_bus run_sd

obj_sd/Vtb_sd_loader: ../src/cart_fpga/cart_rtl/m2_sd_loader.sv tb_sd_loader.sv tb_sd_loader.cpp
	$(VERILATOR) $(VFLAGS) --Mdir obj_sd --top-module tb_sd_loader ../src/cart_fpga/cart_rtl/m2_sd_loader.sv tb_sd_loader.sv tb_sd_loader.cpp

run_sd: obj_sd/Vtb_sd_loader
	./obj_sd/Vtb_sd_loader

obj_bus/Vtb_hybrid_bus_top: $(BUS_SV) tb_hybrid_bus.cpp
	mkdir -p out
	$(VERILATOR) $(VFLAGS) --Mdir obj_bus --top-module tb_hybrid_bus_top $(BUS_SV) tb_hybrid_bus.cpp

run_bus: obj_bus/Vtb_hybrid_bus_top
	./obj_bus/Vtb_hybrid_bus_top
	python3 -c "from PIL import Image; Image.open('out/phase2_cosim_frame.ppm').save('out/phase2_cosim_frame.png'); print('Saved out/phase2_cosim_frame.png')"

obj_m2a/Vtb_m2a_cart_top: $(M2A_CART_SV) tb_m2a_cart.cpp
	mkdir -p out
	$(VERILATOR) $(VFLAGS) -I$(UPSTREAM_RTL)/cpu/i960 --Mdir obj_m2a --top-module tb_m2a_cart_top $(M2A_CART_SV) tb_m2a_cart.cpp

run_m2a: obj_m2a/Vtb_m2a_cart_top
	./obj_m2a/Vtb_m2a_cart_top ../roms/out/vf2.rom 20000000 out/vf2_boot_frame.ppm
	python3 -c "from PIL import Image; Image.open('out/vf2_boot_frame.ppm').save('out/vf2_boot_frame.png'); print('Saved out/vf2_boot_frame.png')"

clean:
	rm -rf obj_bus obj_m2a obj_sd out
