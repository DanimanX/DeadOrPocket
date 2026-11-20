# DeadOrPocket Hybrid Architecture: Sega Model 2 & Model 2A-CRX @ 60 fps on Analogue Pocket

This document records the quantitative **Phase 0** synthesis verification executed in **Intel Quartus Prime 25.1 Lite** targeting the Analogue Pocket's Cyclone V FPGA (`5CEBA4F23C8`), using **[SpaceFish](https://github.com/DanimanX/SpaceFish)** (Taito F3 System) as the openFPGA infrastructure reference, and specifies the **Compute-in-Cartridge / Render-in-Pocket** hybrid architecture designed to run **both Sega Model 2 and Model 2A-CRX** at full native arcade speed (**57.52 Hz / 60 fps**) with zero visual or audio compromises.

---

## 1. Phase 0 Benchmark Results (Quartus Prime 25.1 Lite · `5CEBA4F23C8`)

The reproducible script [`phase0_bench/run_phase0.py`](../phase0_bench/run_phase0.py) synthesized all 16 major subsystems from [`alphanu1/sega-model2-mister`](https://github.com/alphanu1/sega-model2-mister) (`main` and `model2a` branches) using the exact SpaceFish area-optimization flags (`OPTIMIZATION_MODE = "AGGRESSIVE AREA"`, `DEVICE = 5CEBA4F23C8`).

### Compiler & RAM Inference Verification
- **16 / 16 subsystems synthesized cleanly** in 33.8 seconds.
- **0 RAM-to-register inference warnings** in Quartus 25.1 Lite: every `(* ramstyle = "M10K" *)` and `MLAB` array mapped cleanly to `ALTSYNCRAM` / `ALTDPRAM`.

### Measured Per-Subsystem Resource Table (`phase0_bench/phase0_parsed.json`)

| RTL Target | Branch | Est. ALMs | Comb. ALUTs | Mem ALUTs | Registers | Block Mem Bits | Est. M10K* | MLAB Bits | DSP |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `i960_2a_full` (`FP_SUBN=2, RC_RING=1, DC=64`) | `model2a` | **8,387** | 12,471 | 898 | 4,519 | 98,304 | 13 | 18,896 | 7 |
| `i960_2a_trim` (`FP_SUBN=0, RC_RING=0, DC=0`) | `model2a` | **7,357** | 11,044 | 706 | 4,315 | 57,344 | 8 | 10,600 | 7 |
| `copro_m2` (MB86233, 2K prog) | `main` | **2,644** | 3,790 | 0 | 3,157 | 98,562 | 12 | 0 | 1 |
| `copro_2a` (MB86233, 4K prog, subnorm) | `model2a` | **2,945** | 4,307 | 79 | 2,863 | 164,098 | 19 | 2,016 | 1 |
| `geometry_2a` (walker+xform+light+clip+proj) | `model2a` | **6,200** | 6,907 | 301 | 8,815 | 10,532 | 2 | 6,652 | 3 |
| `raster3d_2a` (**full: bilinear+mip+2560q**) | `model2a` | **8,228** | 12,185 | 505 | 9,724 | 1,944,156 | **208** | 13,984 | **52** |
| └ `quad_store_2a` *(included inside `raster3d_2a`)* | `model2a` | *(728)* | *(1,204)* | *(22)* | *(465)* | *(1,484,800)* | *(151)* | *(352)* | *(0)* |
| `video_2d` (2D tilemap, 4-line ring) | `model2a` | **1,598** | 1,743 | 72 | 2,296 | 122,880 | 16 | 2,304 | 2 |
| `char_cache_8k` (8,192 lines) | `model2a` | **205** | 307 | 0 | 290 | 557,056 | 56 | 0 | 0 |
| `char_cache_2k` (2,048 lines) | `model2a` | **202** | 303 | 0 | 288 | 143,360 | 15 | 0 | 0 |
| `sound_m2` (`fx68k` + YM3438 + 2×MultiPCM) | `main` | **4,307** | 6,210 | 420 | 4,130 | 179,571 | 24 | 13,440 | 6 |
| `sound_2a` (`fx68k` + SCSP + SCSP DSP) | `model2a` | **4,449** | 6,385 | 212 | 3,838 | 228,128 | 40 | 5,440 | 6 |
| `ioz80_m2` (TV80 Z80 I/O board, Model 2 only) | `main` | **1,177** | 1,820 | 32 | 783 | 196,608 | 24 | 1,024 | 0 |
| `sdram_13p` (13 ports) | `model2a` | **1,219** | 782 | 0 | 2,087 | 0 | 0 | 0 | 0 |
| `sdram_8p` (8 ports) | `model2a` | **862** | 697 | 0 | 1,485 | 0 | 0 | 0 | 0 |
| `cpu_bridge_2a` (i960 bus + buffer RAM) | `model2a` | **893** | 1,382 | 0 | 911 | 169,984 | 17 | 0 | 0 |

*\*`Est. M10K` computed directly from every entry in each report's `Analysis & Synthesis RAM Summary` using native Cyclone V M10K geometries (`256×40` through `8192×1`).*

### Why Monolithic Porting Fails and Why the Hybrid Seam Fits Cleanly

- **Monolithic core (excluding MiSTer `sys/`):** `~34,400 ALMs` (Model 2A) / `~35,100 ALMs` (Model 2), `~420+ M10K`, `~71 DSP` vs. Pocket's `5CEBA4F23C8` ceiling of **18,480 ALMs / 308 M10K / 66 DSP**.
- **Natural Hybrid Seam ("Compute-in-Cartridge / Render-in-Pocket"):** Splitting cleanly at the **Geometry → 3D Rasterizer** boundary balances both FPGAs and minimizes cross-bus traffic:
  - **Analogue Pocket (`5CEBA4F23C8`)** hosts the **unmodified full-fidelity 3D + 2D video renderer** (bilinear filtering, mip-mapping, 2,560 quads/frame, 57.52 Hz), textures (64 MB SDRAM), ping-pong 3D framebuffers (32 MB PSRAM), and APF video/audio/input bridges: **~12,062 ALMs (65.3%) | 54 DSP (81.8%) | 160–247 M10K (52%–80%)**.
  - **Compute Cartridge** hosts all game simulation and audio synthesis (`i960KB + FPU`, `MB86233 TGP`, `m2_geometry`, `Sound Board M2/2A`, and `m2_ioz80`): **~24,180–24,915 ALMs (~57K–59K LUT4) | ~91–93 M10K | 17 DSP**.

---

## 2. Exact Resource & Memory Partitioning

### 2.1 Analogue Pocket Side (`5CEBA4F23C8` — Render, Video, Audio-Out, I/O)

| Pocket Subsystem | ALMs (Q25.1) | M10K | DSP | External Memory Mapped |
|---|---:|---:|---:|---|
| `m2_raster3d` (full: bilinear, mip, 2,560 quads) | 8,228 | 57 *(208 without SRAM offload)* | 52 | `dram_*` (Textures), `cram0/1_*` (3D FB), `sram_*` (160 KB Quad Store) |
| `m2_video` (2D tilemap, 4-line ring) | 1,598 | 16 | 2 | `dram_*` (2D Char RAM) |
| `m2_char_cache` (2K or 4K lines) | 202 | 15 *(30 at 4K)* | 0 | Glyph cache |
| `m2_tdp_ram2c` (64 KB Tile RAM + 16 KB Palette) | ~100 | 64 *(or in `sram_*`)* | 0 | Optional offload to `sram_*` (80 KB) |
| `m2_sdram` (8 ports dedicated to textures/2D/boot) | 862 | 0 | 0 | **64 MB SDR SDRAM** (`dram_*`) |
| `psram_phy` ×2 (reused from SpaceFish) | 222 | 0 | 0 | **16 MB CRAM0 + 16 MB CRAM1** (Ping-Pong 16-bit RGB565 FB, 2×381 KB) |
| APF Scaffolding (`apf_top` + `core_bridge_cmd` + `pk_io` + `sound_i2s` + Cart Bus PHY) | ~850 | 8 | 0 | Bridge + Pad + 48 kHz I2S + 30-pin Cart Slot |
| **ANALOGUE POCKET TOTAL** | **~12,062 / 18,480 (65.3%)** | **160 / 308 (52%)** *(or 247/308 offloading Tile+Pal only)* | **54 / 66 (81.8%)** | **96.25 MB total, zero DDR3** |

> **Comparison vs. SpaceFish:** SpaceFish closes timing on `5CEBA4F23C8` at **92% ALMs (17,050)** and **99% M10K (305/308)**. This hybrid partition leaves the Analogue Pocket at **65.3% ALMs** and **52%–80% M10K**, providing generous headroom for clean timing closure at 80/96 MHz and locked 57.52 Hz output.

### 2.2 Compute Cartridge Side

| Cartridge Subsystem | Model 2A-CRX (ALMs / M10K / DSP) | Model 2 Original (ALMs / M10K / DSP) |
|---|---|---|
| `i960_top` (80960KB + full `FP_SUBN=2` FPU) | 8,387 / 13 / 7 | 8,387 / 13 / 7 |
| `m2_geometry` (walker + xform + light + clip + proj) | 6,200 / 2 / 3 | 6,200 / 2 / 3 |
| `m2_copro` (Fujitsu MB86233 TGP) | 2,945 / 19 / 1 | 2,644 / 12 / 1 |
| Sound Board (`m2_2a_sound` or `m2_sound_board`) | 4,449 / 40 / 6 | 4,307 / 24 / 6 |
| `m2_ioz80` (Type 1 & Type 2 Z80 I/O Board) | 0 / 0 / 0 *(uses `m2_315_5649`)* | 1,177 / 24 / 0 |
| `m2_cpu_bridge` + SDRAM Ctrl + Cart Bus PHY | ~2,200 / 17 / 0 | ~2,200 / 18 / 0 |
| **CARTRIDGE TOTAL** | **~24,180 ALMs / 91 M10K / 17 DSP** | **~24,915 ALMs / 93 M10K / 17 DSP** |

#### Candidate Cartridge FPGAs

| Candidate Cartridge FPGA | Logic Capacity | BRAM | DSP | Node / Est. Power | Key Advantage |
|---|---|---|---|---|---|
| **Intel Cyclone V `5CEBA5F23C8` / `5CEBA7F23C8`** | 29,080 / 56,480 ALMs | 446 / 686 M10K | 150 / 156 | 28 nm · ~0.8–1.2 W | **Same vendor & Quartus 25.1**, zero RTL primitive porting |
| **Gowin Arora V `GW5AST-60` / `GW5AT-138`** | 59,904 / 138K LUT4 | 2.1 / 6.1 Mbits | 118 / 298 | **22 nm · ~0.4–0.7 W** | Lowest power envelope for the 5V/200 mA (1.0 W) slot rail |
| **Lattice ECP5 `LFE5U-85F`** | 83,640 LUT4 | 3.74 Mbits | 156 | 40 nm · ~0.6–0.9 W | **100% open-source toolchain** (Yosys + nextpnr) |

#### Cartridge Slot Electrical Budget
- The Analogue Pocket cartridge slot supplies up to **200 mA** (`0.66 W` @ 3.3V or **`1.0 W` @ 5V** in 5V mode via mechanical switch / `core.json`).
- **Mandatory Hardware Safety Rules:**
  1. Power the cartridge FPGA core through a high-efficiency (>92%) synchronous buck regulator from the 5V rail (or 3.3V for `GW5AST-60`), plus an **optional auxiliary USB-C power input with ideal-diode ORing** for higher-power FPGAs (`5CEBA7`) or Dock use without stressing the Pocket's internal regulator.
  2. Keep **all 30 bus I/O signals strictly at 3.3V** and coordinate `cart_tran_bank*_dir` cleanly to avoid bus contention across the Pocket's hardware level translators.

---

## 3. Cartridge Slot Bus Protocol (30 Physical Pins · 50–66 MB/s)

### 3.1 Real-Time Bandwidth Budget at 57.52 Hz (60 fps Arcade)

| Channel | Direction | Worst-Case Payload / Frame | Sustained Bandwidth |
|---|---|---|---:|
| **CH0: Projected 3D Quads** | Cart → Pocket | 2,560 quads × 64 B = 163.8 KB | **9.42 MB/s** |
| **CH1: 2D Write Deltas** | Cart → Pocket | Tile/Char/Palette writes (typ. 8 KB, max 80 KB) | **0.46 – 4.60 MB/s** |
| **CH2: Stereo PCM Audio** | Cart → Pocket | 48,000 Hz × 4 B/sample | **0.19 MB/s** |
| **CH3: Inputs + VSync + Status** | Pocket → Cart | 64 B/frame (pad, analog sticks/triggers, light gun, vblank) | **< 0.01 MB/s** |
| **PEAK TOTAL TRAFFIC** | Bidirectional | — | **~14.22 MB/s** |

### 3.2 Physical Pin Mapping (`apf_top.v`)

| `apf_top.v` Pins | Width | Direction | DeadOrPocket Signal |
|---|---:|---|---|
| `cart_tran_bank2[7:0]` + `cart_tran_bank3[7:0]` | 16 bits | Bidirectional (packet-switched) | `BUS_DATA[15:0]` (synchronous bursts) |
| `cart_tran_bank1[7:0]` | 8 bits | Cart → Pocket *(bidir at boot)* | `PKT_HDR[7:0]` (`[1:0]` channel, `[2]` SOP, `[3]` EOP, `[7:4]` seq/type) |
| `cart_tran_bank0[7:4]` | 4 bits | Pocket → Cart | `[7] BUS_CLK` (25–33 MHz), `[6] DIR` (0=Cart→Pocket, 1=Pocket→Cart), `[5] VSYNC_PULSE`, `[4] SOFT_RST_N` |
| `cart_tran_pin30` | 1 bit | Pocket → Cart | `POCKET_READY` (RX FIFO backpressure; `cart_pin30_pwroff_reset = 1'b1`) |
| `cart_tran_pin31` | 1 bit | Cart → Pocket | `CART_VALID / DRQ` (packet ready) |

- At **25 MHz × 16-bit** = **50 MB/s** (**3.5×** peak traffic).
- At **32–33.3 MHz × 16-bit** = **64–66.6 MB/s** (**4.5×–4.7×** peak traffic).
- **Boot ROM Loading:** At launch, `pk_io.sv` streams the `.rom` payload from the Pocket MicroSD, loading textures/2D data into Pocket SDRAM (`dram_*`) while bursting CPU/polygon/audio data across the cartridge bus into Cartridge SDRAM at ~40 MB/s (~1.5 s for *Dead or Alive*) — or optionally booting straight from a local MicroSD slot on the cartridge.

---

## 4. Clock Synthesis on Analogue Pocket (`clk_74a = 74.25 MHz`)

Using the integer-counter Cyclone V PLL pattern proven in [SpaceFish `f3_pll.sv`](https://github.com/DanimanX/SpaceFish) (`600 MHz ≤ f_vco ≤ 1300 MHz`, `PFD ≥ 5 MHz`):

- **PLL 1 (`m2_pll.sv`):** `N = 12`, `M = 155` → `PFD = 6.1875 MHz`, **`f_vco = 959.0625 MHz`**
  - `C0 = 10` → **`clk_mem = 95.906250 MHz`** (`dram_*` + `psram_phy` at `CLKDIV=2` → PSRAM K = `47.95 MHz`)
  - `C1 = 10` (+180° = `5,213 ps`) → **`clk_sdram_pin = 95.906250 MHz`**
  - `C2 = 13` → **`clk_sys = 73.774038 MHz`** (`m2_raster3d` + FB + Cart Bus; **verified `+0.752 ns` Slow 85°C / `+0.296 ns` Slow 0°C setup slack on `5CEBA4F23C8`**)
  - `C3 = 30` → **`clk_cart = 31.968750 MHz`** (cartridge bus clock → **63.9 MB/s**)
  - `C4 = 60` → **`clk_pix = 15.984375 MHz`** (−0.098% vs. 16.00 MHz → **57.47 Hz**)
  - `C5 = 60` (+90° = `15,640 ps`) → **`clk_pix_90 = 15.984375 MHz`** (APF DDR video sampling)
- **PLL 2 (`m2_audio_pll.sv`):** **`audio_mclk = 12.288 MHz`** (48 kHz I2S DAC, fractional-N PLL reused from SpaceFish `f3_audio_pll.sv`).

---

## 4.1 Phase 1 Verified Silicon Fit (`5CEBA4F23C8` · Quartus Prime 25.1 Lite)

Full place-and-route and 4-corner Static Timing Analysis of [`src/fpga/pocket_deadorpocket.qpf`](../src/fpga/pocket_deadorpocket.qpf) (`HIGH PERFORMANCE EFFORT`, `SYNTH_TIMING_DRIVEN_SYNTHESIS ON`):

- **Logic utilization (ALMs):** `10,373 / 18,480` (**56%**)
- **Total registers:** `14,149`
- **Total block memory bits:** `2,735,996 / 3,153,920` (**87%**)
- **Total M10K RAM blocks:** `303 / 308` (**98%**) — achieved by moving small span/CDC queues (`u_span_q` in `m2_raster3d.sv` and `q_tex`/`q_u`/`q_v` in `m2_texel_cdc.sv`) to MLABs, keeping **all 256 KB of Async SRAM (`sram_*`) free** for Phase 2!
- **Total DSP blocks:** `55 / 66` (**83%**)
- **Total PLLs:** `2 / 4` (**50%**)
- **4-Corner STA (`Slow 85C`, `Slow 0C`, `Fast 85C`, `Fast 0C`):** **0.000 ns TNS** across all 7 clock domains (`clk_sys` `+0.296 ns` min setup, `clk_mem` `+1.176 ns` min setup, all hold/recovery/removal/MPW positive).

---

## 5. Memory Map for >64 MB Titles (*Dead or Alive* `doaab` Case Study)

Because **Textures live in Pocket SDRAM** while **CPU/Polygons/Audio live in Cartridge SDRAM**, even Model 2A titles that require a 128 MB SDRAM module on MiSTer fit comfortably:

| *Dead or Alive* (`doaab`) Region | MiSTer MRA Size | Deduplicated Unique Size | DeadOrPocket Placement |
|---|---:|---:|---|
| `i960 prog` | 2 MB (1 MB + padding) | **1.00 MB** | Cartridge SDRAM |
| `i960 data` | 32 MB (mirrored) | **24.00 MB** *(mirror in RTL)* | Cartridge SDRAM |
| `polygons` | 24 MB | **24.00 MB** | Cartridge SDRAM |
| `SCSP samples` + `68000 sound` + `TGP tables` | 8.75 MB | **8.75 MB** | Cartridge SDRAM |
| **Cartridge SDRAM Subtotal** | — | **57.75 MB** | **Fits even inside a 64 MB Cartridge SDRAM!** |
| `textures` | 16 MB (mirrored) | **8.00 MB** *(mirror in RTL)* | **Analogue Pocket SDRAM (`dram_*`, 64 MB)** |
| `3D Framebuffer` (double-buffered 496×384 RGB565) | 1.52 MB (32-bit DDR3) | **0.76 MB** (2 × 381 KB) | **Pocket CRAM0 + CRAM1 (Zero-contention Ping-Pong)** |
| `Quad Store` (2,560 quads) | 151 M10K | **160 KB** | **Pocket Async SRAM (`sram_*`, 256 KB)** |
