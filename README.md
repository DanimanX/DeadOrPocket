# DeadOrPocket

<p align="center">
  <img src="banner.png" alt="DeadOrPocket - Sega Model 2 & Model 2A-CRX openFPGA Hybrid Core" width="700">
</p>

**Sega Model 2 & Model 2A-CRX @ 60 fps (57.52 Hz) for Analogue Pocket — Hybrid openFPGA Architecture**

Based on the [`alphanu1/sega-model2-mister`](https://github.com/alphanu1/sega-model2-mister) FPGA recreation (GPL-3.0) and built upon the openFPGA architecture and Cellular PSRAM methodology proven in [`DanimanX/SpaceFish`](https://github.com/DanimanX/SpaceFish).

---

## Phase 3 Milestone — Dual-Board Compute Cartridge (`Model 2` & `Model 2A-CRX`) Verified on `5CEBA5F23C8N` (PASS)

All **three complete FPGA bitstreams** of the hybrid **DeadOrPocket** system are now **fully implemented, pin-locked, placed, routed, and timing-closed in Intel Quartus Prime 25.1 Lite** with **0 errors, 0 STA warnings, and `0.000 ns` TNS across all 4 PVT corners (`Slow 85°C`, `Slow 0°C`, `Fast 85°C`, `Fast 0°C`)**:

- **Compute Cartridge FPGA — Sega Model 2A-CRX (`cart_deadorpocket`, `5CEBA5F23C8N` · 77 Balls Locked):** `i960_top` full FPU + `m2_cpu_bridge` + `m2_copro` 4K TGP + `m2_geo` / `m2_geometry` + `m2_2a_sound` (68000 + SCSP + DSP) + `m2_315_5649` + real SD/SDHC SPI boot loader (`m2_sd_loader`) + 128 MB dual-chip `m2_sdram` + `m2_cart_host` — **84% ALMs (`24,311 / 29,080`)**, **43% M10K**, **9% DSP**, **`+1.653 ns` worst setup slack (`0.000 ns` TNS)**.
- **Compute Cartridge FPGA — Sega Model 2 Original (`cart_deadorpocket_m2`, `5CEBA5F23C8N` · Exact Same 77-Pin PCB):** `i960_top` + `m2_copro` 2K + `m2_geometry` + **`m2_sound_board` (68000 + YM3438 + 2× MultiPCM)** + **`m2_ioz80` (TV80 Type 1 & Type 2) + `m2_ioboard`** + real `m2_sd_loader` + 128 MB dual `m2_sdram` + `m2_cart_host` (for *Daytona USA*, *Virtua Cop*, *Desert Tank*) — **85% ALMs (`24,794 / 29,080`)**, **45% M10K**, **12% DSP**, **`+1.679 ns` worst setup slack (`0.000 ns` TNS)**.
- **Complete Hardware & PCB Fabrication Package ([`hardware/`](hardware/), [`docs/CARTRIDGE_HARDWARE.md`](docs/CARTRIDGE_HARDWARE.md)):**
  - **Production Gerbers Archive (ZIP):** [`DeadOrPocket_Cartridge_RevA_Gerbers.zip`](hardware/gerbers/DeadOrPocket_Cartridge_RevA_Gerbers.zip) (Mirror: [`Release/DeadOrPocket_Cartridge_RevA_Gerbers.zip`](Release/DeadOrPocket_Cartridge_RevA_Gerbers.zip)) with all 13 standard RS-274X copper/mask/silk/paste/outline layers + Excellon PTH/NPTH drills + `.gbrjob` stackup metadata.
  - **Manufacturing Specs:** 6-Layer 1.0 mm ENIG PCB (`JLC06101H-3313`), 32 gold edge fingers (1.50 mm pitch) with **30° chamfer bevel**, locked 77-ball FBGA-484 pinout ([`cart_pinout.tcl`](src/cart_fpga/cart_pinout.tcl)), KiCad 8 schematic/PCB floorplan ([`hardware/deadorpocket_cart/`](hardware/deadorpocket_cart/)), JLCPCB SMT BOM & CPL ([`bom_jlcpcb.csv`](hardware/bom_jlcpcb.csv)), and 3D-printable OpenSCAD shell ([`deadorpocket_cart_shell.scad`](hardware/shell/deadorpocket_cart_shell.scad)).
  - **Pin-Compatible Upgrade Path:** Drop-in upgrade from `5CEBA5F23C8N` (`29,080` ALMs) to `5CEBA7F23C8N` (`56,480` ALMs) with identical ballout.
- **Analogue Pocket Render FPGA (`src/fpga/`, `5CEBA4F23C8`):** Unmodified `m2_raster3d` (bilinear + mip + 2,560 quads) + `m2_video` + Dual Cellular PSRAM Ping-Pong FB + 8-port SDRAM + 30-pin Cart Bus PHY v2 at **57% ALMs (`10,563 / 18,480`)**, **98% M10K (`303 / 308`)**, **83% DSP (`55 / 66`)**, and **`0.000 ns` TNS across all 4 corners**.

<p align="center">
  <img src="docs/cartridge_pcb_3d.png" alt="DeadOrPocket Compute Cartridge Rev A — 3D PCB Render (6-Layer ENIG, Cyclone V 5CEBA5F23C8N, 128 MB Dual SDR SDRAM)" width="760">
</p>
<p align="center"><em>3D hardware render of the <strong>DeadOrPocket Compute Cartridge Rev A</strong> (57.5 × 76.0 mm 6-layer ENIG PCB): central Intel Cyclone V <code>5CEBA5F23C8N</code> (FBGA-484), dual 64 MB ISSI <code>IS42S16320F-6TL</code> SDRAMs, 3× buck power tree, side USB-C auxiliary power, 33 Ω series bus damping bank, and chamfered gold edge fingers.</em></p>

<p align="center">
  <img src="docs/cartridge_pcb_layout.svg" alt="DeadOrPocket Compute Cartridge 6-Layer ENIG PCB Floorplan" width="760">
</p>

### Verified 3-Bitstream Silicon Fit Matrix (Quartus Prime 25.1 Lite · All 77 Cart Pins Locked)

| Metric | Cart: Model 2A-CRX (`5CEBA5F23C8N`) | Cart: Model 2 Orig. (`5CEBA5F23C8N`) | Analogue Pocket (`5CEBA4F23C8`) |
|---|---:|---:|---:|
| **Logic Utilization (ALMs)** | **24,311 / 29,080 (84%)** | **24,794 / 29,080 (85%)** | **10,563 / 18,480 (57%)** |
| **Registers** | **24,784** | **25,683** | **14,495** |
| **M10K RAM Blocks** | **190 / 446 (43%)** | **201 / 446 (45%)** | **303 / 308 (98%)** |
| **DSP Blocks** | **13 / 150 (9%)** | **18 / 150 (12%)** | **55 / 66 (83%)** |
| **PLLs** | **1 / 6 (17%)** | **1 / 6 (17%)** | **2 / 4 (50%)** |
| **External Memory** | **128 MB Dual SDRAM + MicroSD** | **128 MB Dual SDRAM + MicroSD** | **64 MB SDRAM + 32 MB Dual PSRAM** |
| **Worst Setup Slack / 4-Corner TNS** | **`+1.653 ns` / `0.000 ns`** | **`+1.679 ns` / `0.000 ns`** | **`+0.149 ns` / `0.000 ns`** |

### Compute Cartridge 4-Corner Static Timing Closure (`5CEBA5F23C8N` — Both Revisions, All 77 Balls Locked)

| Clock Domain | Target Freq | Model 2A-CRX Fmax / Setup (85°C) | Model 2 Orig. Fmax / Setup (85°C) | Worst Hold (Fast 0°C) | TNS (All 4 Corners) |
|---|---:|---:|---:|---:|---:|
| `clk_mem` (128 MB Dual SDRAM + `m2_sd_loader`) | **100.000 MHz** | **119.80 MHz** (`+1.653 ns`) | **120.18 MHz** (`+1.679 ns`) | `+0.166 ns` | **0.000 ns** |
| `clk_sys` (TGP + Geometry + Sound + I/O + Bridge) | **50.000 MHz** | **71.67 MHz** (`+6.047 ns`) | **63.54 MHz** (`+2.131 ns`) | `+0.117 ns` | **0.000 ns** |
| `clk_cpu` (Intel i960KB + Full Subnormal FPU) | **25.000 MHz** | **34.45 MHz** (`+7.783 ns`) | **33.52 MHz** (`+7.127 ns`) | `+0.125 ns` | **0.000 ns** |
| `clk_bus` (30-Pin Pocket Bus → **63.9 MB/s**) | **31.969 MHz** | **217.49 MHz** (`+26.682 ns`) | **161.37 MHz** (`+25.083 ns`) | `+0.155 ns` | **0.000 ns** |

---

## Phase 2 Milestone — 30-Pin Cartridge Bus v2 & Full Verilator Co-Simulation (PASS)

Both sides of the hybrid **Compute Cartridge ↔ 30-Pin Analogue Pocket Cartridge Bus ↔ Pocket Render Core** ([`src/cart_rtl/m2_cart_host.sv`](src/cart_rtl/m2_cart_host.sv) ↔ [`src/fpga/pocket_rtl/m2_cart_bus.sv`](src/fpga/pocket_rtl/m2_cart_bus.sv)) have been verified end-to-end in **Verilator 5.054** AND re-verified in **Quartus Prime 25.1 Lite (`5CEBA4F23C8`)** with **0 errors and `0.000 ns` TNS across all 4 PVT corners**:

<p align="center">
  <img src="docs/phase2_cosim_frame.png" alt="DeadOrPocket Phase 2 Verilator Co-Simulation Output (496x384 RGB24)" width="496">
</p>
<p align="center"><em>Real 496×384 RGB24 frame rendered by unmodified <code>m2_raster3d</code> + Dual Cellular PSRAM Ping-Pong FB + <code>m2_video</code> from 3D shaded &amp; live SDRAM-textured quads streamed across the virtual 30-pin Pocket Cartridge Bus (0 bus contention, 0 JEDEC SDRAM violations).</em></p>

### Phase 2 Verilator Co-Simulation Scorecards ([`sim/`](sim/))

| Co-Simulation Benchmark | Scope Exercised | Verified Result |
|---|---|---|
| **1. Full 4-Channel Render Co-Sim (`make -C sim run_bus`)** | `m2_cart_host` ↔ 30-pin bus ↔ `m2_cart_bus` ↔ `m2_raster3d` (bilinear+mip+FTB) + `m2_fb_psram` + 2×`psram_phy` + 2×`psram_cell_model` + `m2_video` + `m2_char_cache` + `m2_sdram` (8p) + JEDEC `sdram_model` | **PASS** · `7,445 TX / 7,445 RX` words · **0 contention** · **0 JEDEC SDRAM violations** (`1,040 reads`, `1,024 writes`) · **2,441/2,441 CH2 PCM bit-exact** · **3/3 CH3 inputs bit-exact** · **189,115 / 190,080 3D pixels rendered** |
| **2. Real Sega Model 2A-CRX ROM Boot (`make -C sim run_m2a`)** | Real Intel `i960_top` (`FP_SUBN=2, RC_RING=1, FR=1, F2A=1`) + `m2_cpu_bridge` booting real **`vf2.rom` (*Virtua Fighter 2*)** → live CPU write snooper → `m2_cart_host` → 30-pin bus → `m2_cart_bus` → Pocket `u_tram`/`u_pal`/`m2_video` | **PASS** · **1,698,138 i960 accesses** (`0 traps`, `0 halts`) · **80,121 live CH1 video writes** (`30,738` TRAM, `5,056` PAL, `44,135` Char/Tex SDRAM) · `145,547 TX / 145,547 RX` words · **0 contention** · **12/12 CH3 VBlank roundtrips** |
| **3. Real *Dead or Alive* (`doaab.rom`) i960 Boot Check** | Real 90.75 MB `doaab.rom` on `i960_top` (`FR=1, F2A=1`) + `m2_cpu_bridge` (`BOARD_2A=1, prog_ext=1`) | **3,185,370 i960 accesses**, `0 traps`, `0 halts`, `30/30` CH3 VBlank input roundtrips, **0 contention** |
| **4. Real SD/SDHC SPI Boot Loader (`make -C sim run_sd`)** | `m2_sd_loader.sv` vs behavioral SDHC SPI card (`CMD0/8/55/41/58/17/18/12`, MBR Partition 1 follow, DOP2 header, variable SDRAM backpressure) | **PASS** · **4,096 / 4,096 16-bit words bit-exact** (`game_id=0x16`, `prog_ext=1`, `0 errors`) |

#### Real Silicon Bugs Caught & Fixed by Phase 2 Co-Simulation
1. **Head-of-line `frame_start` deadlock:** Driving `u_raster3d.frame_start` directly from Pocket's `vblank_pulse_sys` (instead of gating it behind `u_rx_fifo`) eliminated a deadlock when `m2_raster3d` paused `q_ready`.
2. **Stuck `q_end` pulse:** `m2_cart_bus` now clears `q_end` on the cycle `q_valid && q_ready` completes so `m2_raster3d` never prematurely closes subsequent frames with 0 quads.
3. **27-bit `q_tex` (`TEXLUT=1` `in_vx`) & live Texture/Char SDRAM streaming:** Widened `q_tex` to `[26:0]` (fitting in spare bits of word 26 with zero extra bus words) and added auto-coalesced CH1 burst streaming (`sub=4/5/6`) into Pocket SDRAM Port 5 (`TEXS0`, `TEXS1`, `CHAR_RAM`) with automatic `tex_inval` / `char_cache` line invalidation.

---

## Verified `5CEBA4F23C8` Silicon Fit & 4-Corner Timing (`v0.2.0-phase2`)

Compiled in **Intel Quartus Prime 25.1 Lite** (`HIGH PERFORMANCE EFFORT`, `SYNTH_TIMING_DRIVEN_SYNTHESIS ON`) targeting the Analogue Pocket's Cyclone V `5CEBA4F23C8` — **0 errors, 0.000 ns TNS across all four PVT corners (`Slow 85°C`, `Slow 0°C`, `Fast 85°C`, `Fast 0°C`)**:

| Metric (`5CEBA4F23C8`) | Verified Phase 2 Fit | Pocket Ceiling | Utilization |
|---|---:|---:|---:|
| **Logic Utilization (ALMs)** | **10,563** | 18,480 | **57%** |
| **Registers** | **14,495** | — | — |
| **M10K RAM Blocks** | **303** (2,740,092 bits) | 308 (3,153,920 bits) | **98% (87% bits)** |
| **DSP Blocks** | **55** | 66 | **83%** |
| **PLLs** | **2** (`m2_pll` + `m2_audio_pll`) | 4 | **50%** |
| **External Memories Used** | `dram_*` (64 MB) + `cram0_*` (16 MB) + `cram1_*` (16 MB) | + 256 KB Async SRAM free | **Zero DDR3** |

### Verified 4-Corner Static Timing Closure (`pocket_deadorpocket.sta.summary`)

| Clock Domain | Frequency | Slow 85°C Setup | Slow 0°C Setup | Slow 0°C Hold | TNS (All 4 Corners) |
|---|---:|---:|---:|---:|---:|
| `clk_sys` (`m2_raster3d` + FB + Cart Bus) | **73.774 MHz** | `+0.587 ns` | `+0.149 ns` | `+0.151 ns` | **0.000 ns** |
| `clk_mem` (`m2_sdram` 8p + 2×`psram_phy` + `m2_video`) | **95.906 MHz** | `+1.607 ns` | `+1.121 ns` | `+0.159 ns` | **0.000 ns** |
| `clk_cart` (30-pin 16-bit Cart Bus → **63.9 MB/s**) | **31.969 MHz** | `+25.610 ns` | `+25.643 ns` | `+0.538 ns` | **0.000 ns** |
| `clk_pix` (APF Video 496×384 @ 57.47 Hz) | **15.984 MHz** | `+5.783 ns` | `+5.886 ns` | `+0.584 ns` | **0.000 ns** |
| `clk_74a` (APF Bridge / `m2_pk_io`) | **74.250 MHz** | `+6.579 ns` | `+6.667 ns` | `+0.368 ns` | **0.000 ns** |
| `audio_mclk` (48 kHz Stereo I2S DAC) | **12.288 MHz** | `+76.101 ns` | `+76.423 ns` | `+0.325 ns` | **0.000 ns** |

---

## Hybrid Architecture Overview

![DeadOrPocket Hybrid Architecture](docs/architecture_diagram.svg)

### Why a Hybrid Architecture? (Phase 0 Quartus 25.1 Verification)

The Analogue Pocket's main Intel Cyclone V FPGA (`5CEBA4F23C8`) provides **18,480 ALMs, 308 M10K blocks, and 66 DSP blocks** (~44% of the MiSTer DE10-Nano's logic fabric). Synthesizing all **16 real RTL subsystems** from both Model 2 (`main`) and Model 2A-CRX (`model2a`) in **Quartus Prime 25.1 Lite** ([`phase0_bench/run_phase0.py`](phase0_bench/run_phase0.py)) proved:

- **A monolithic single-chip port is physically impossible:** even with the entire MiSTer framework (`sys/`) stripped out, the core requires **~34,400–35,100 ALMs (~1.9× the Pocket)**, **~420+ M10K (~1.4×)**, and **~71 DSP (~1.1×)**.
- **The "Compute-in-Cartridge / Render-in-Pocket" split fits cleanly at full 60 fps (57.52 Hz) with zero visual or audio compromises:**
  - **Analogue Pocket (`5CEBA4F23C8`)** runs the complete 3D + 2D video pipeline (`m2_raster3d` + `m2_video`), stores live 2×1 MB texture sheets (`TEXS0`/`TEXS1`) and 2D char RAM in its **64 MB SDR SDRAM**, double-buffers the 3D framebuffer in **ping-pong across both 16 MB Cellular PSRAMs (`cram0`/`cram1`)**, and keeps all **256 KB of Async SRAM (`sram_*`)** free — proven in real Quartus 25.1 routing at **57% ALMs (10,563 / 18,480)**, **98% M10K (303 / 308)**, and **83% DSP (55 / 66)**.
  - **Compute Cartridge** (plugged into the Pocket's 30-pin cartridge slot) runs all game computation and audio (`i960KB + FPU`, `MB86233 TGP`, `m2_geometry`, `Sound Board M2/2A`, and `m2_ioz80`), streaming only **~14.2 MB/s peak** of projected quads, 2D/texture deltas, and 48 kHz stereo PCM over the **16-bit synchronous bus @ 31.97 MHz (63.9 MB/s)**.

```mermaid
flowchart LR
    subgraph CART["Compute Cartridge · Cyclone V 5CEBA5F23C8 (Verified: 23,673 ALMs · 81% · 13 DSP · 0.000 TNS)"]
        direction TB
        I960["Intel i960KB + FPU @ 25 MHz<br/>(Fmax 36.5 MHz · +8.25 ns)"]
        TGP["Fujitsu MB86233 TGP @ 50 MHz<br/>4K Prog + Subnormal FPU"]
        GEO["m2_geometry 3D @ 50 MHz<br/>(Fmax 73.3 MHz · +6.18 ns)"]
        SND["Sound Board M2 / 2A @ 50 MHz<br/>68000 + SCSP + DSP"]
        IO["cpu_bridge + m2_cart_host<br/>+ Timers/Backup/315-5649"]
        CSDRAM[("128 MB Dual SDR SDRAM<br/>@ 100 MHz (Fmax 127.6 MHz)<br/>+ MicroSD Boot Slot")]
        I960 <--> TGP
        I960 --> GEO
        I960 --> SND
        I960 <--> CSDRAM
        GEO <--> CSDRAM
        SND <--> CSDRAM
    end

    subgraph BUS["Pocket Cartridge Slot · 30 Pins · 16-bit @ 31.97 MHz (63.9 MB/s · 0 Contention Verified)"]
        CH0["CH0: 3D Quads (9.42 MB/s)"]
        CH1["CH1: 2D Tile/Pal/LUT + TEXS0/1 Stream"]
        CH2["CH2: 48 kHz Stereo PCM (0.19 MB/s)"]
        CH3["CH3: Inputs + VSync (<0.01 MB/s)"]
    end

    subgraph POCKET["Analogue Pocket · Cyclone V 5CEBA4F23C8 (Verified: 10,563 ALMs · 57% · 55 DSP · 0.000 TNS)"]
        direction TB
        R3D["Full m2_raster3d<br/>Bilinear + Mip + 4 Tex Ports<br/>73.77 MHz (0.000 TNS)"]
        V2D["m2_video + char_cache<br/>64KB Tram + 16KB Pal<br/>95.91 MHz"]
        APF["APF + m2_pk_io + sound_i2s<br/>+ 2x psram_phy + m2_sdram 8p<br/>+ m2_cart_bus v2 + m2_demo_gen"]
        PDRAM[("64 MB SDRAM<br/>TEXS0/1 + 2D Chars")]
        PCRAM[("32 MB PSRAM<br/>CRAM0/1 FB Ping-Pong")]
        PSRAM[("256 KB Async SRAM<br/>Free Reserve")]
        R3D <--> PDRAM
        R3D <--> PCRAM
        V2D <--> PDRAM
    end

    GEO --> CH0 --> R3D
    IO --> CH1 --> V2D
    SND --> CH2 --> APF
    APF --> CH3 --> IO
    R3D --> VID["APF Video 496x384 @ 57.47 Hz"]
    V2D --> VID
    APF --> AUD["APF Audio I2S 48 kHz"]
```

---

## Installation & Testing (Analogue Pocket MicroSD)

1. Download [`Release/DeadOrPocket_Pocket_v0.2.0-phase2.zip`](Release/DeadOrPocket_Pocket_v0.2.0-phase2.zip).
2. Extract its contents directly to the root of your Analogue Pocket MicroSD card:
   ```text
   /
   ├── Assets/
   │   └── model2/
   │       ├── common/
   │       └── danimanx.DeadOrPocket/
   │           ├── 3D Hardware Self-Test.json
   │           └── Dead or Alive (Model 2A).json
   ├── Cores/
   │   └── danimanx.DeadOrPocket/
   │       ├── audio.json, core.json, data.json, info.txt, input.json, interact.json, variants.json, video.json
   │       ├── bitstream.rbf_r
   │       └── icon.bin
   └── Platforms/
       ├── _images/
       │   └── model2.bin
       └── model2.json
   ```
3. On your Analogue Pocket, launch **openFPGA → Sega Model 2 → DeadOrPocket → 3D Hardware Self-Test** to run the live 57.47 Hz `m2_raster3d` + Dual-PSRAM Ping-Pong Framebuffer pipeline directly on hardware (no ROMs required).

---

## Building from Source & Running Verilator Co-Simulations

Requirements: Intel Quartus Prime 25.1 Lite (`5CEBA4F23C8`), Verilator 5.x, `g++`, `make`, and Python 3 (with Pillow).

```bash
# 1. Compile the Analogue Pocket Render Core (5CEBA4F23C8: map + fit + asm + sta)
./tools/build_pocket.sh

# 2. Generate bit-reversed bitstream.rbf_r and Release/DeadOrPocket_Pocket_v0.2.0-phase2.zip
python3 tools/package_pocket.py --version v0.2.0-phase2

# 3. Compile BOTH Compute Cartridge FPGA bitstreams (5CEBA5F23C8N, all 77 balls locked)
./tools/build_cart.sh 2a    # Sega Model 2A-CRX (DOA, VF2, Sega Rally, VC2, Dynamite Cop...)
./tools/build_cart.sh m2    # Sega Model 2 Original (Daytona USA, Virtua Cop, Desert Tank)

# 4. Export Complete 6-Layer Production Gerbers & Excellon Drills (ZIP)
python3 tools/export_gerbers.py

# 5. Run Verilator co-simulations (4-channel 30-pin Bus + m2_raster3d + SD/SDHC Boot Loader)
make -C sim run_bus
make -C sim run_sd

# 6. (Optional) Verify local MAME .zip ROM sets in roms/, pack MicroSD image & run i960 ROM boot co-sim
python3 tools/build_rom.py --verify-all
python3 tools/build_rom.py --mra "Virtua Fighter 2 (Version 2.1).mra" --out roms/out
python3 tools/make_sd_image.py --rom roms/out/vf2.rom --game-id 0x16 --board 2a --out roms/out/vf2_sd.img
make -C sim run_m2a
```

---

## Target Games (Model 2 & Model 2A-CRX)

| Arcade Board | Target Titles |
|---|---|
| **Sega Model 2** | *Daytona USA* (Deluxe '93 & Rev A), *Desert Tank*, *Virtua Cop* |
| **Sega Model 2A-CRX** | *Dead or Alive*, *Virtua Fighter 2*, *Sega Rally Championship*, *Virtua Cop 2*, *Manx TT Superbike*, *Zero Gunner*, *Dynamite Cop*, *Motor Raid*, *Sky Target*, *Pilot Kids*, *Hanguk Pro Yagu 98* |

---

## Roadmap

- [x] **Phase 0:** Feasibility audit against SpaceFish + real Quartus Prime 25.1 Lite (`5CEBA4F23C8`) synthesis benchmark across all 16 Model 2 and Model 2A-CRX subsystems.
- [x] **Phase 1 — Pocket Render Core (`src/fpga/`):** Full Analogue Pocket `5CEBA4F23C8` render core (`m2_raster3d` + `m2_video` + Dual-PSRAM Ping-Pong FB + 8-port SDRAM + 30-pin Cart Bus PHY + built-in 3D Self-Test + Kasumi SpaceFish APF assets), fitted with **100% 4-corner timing closure (`0.000 ns TNS`)**.
- [x] **Phase 2 — Cartridge Bus Protocol v2 & Verilator Co-Simulation (`src/cart_rtl/`, `sim/`):** Implemented symmetric `m2_cart_host.sv` + upgraded `m2_cart_bus.sv` (auto-coalesced live Texture/Char SDRAM streaming, 27-bit `q_tex`, latched VBlank CH3 turnaround), verified end-to-end in Verilator across all 4 channels (0 contention, 0 JEDEC SDRAM violations, 189k+ 3D pixels rendered, real *Virtua Fighter 2* & *Dead or Alive* i960 ROM boot), and re-verified `5CEBA4F23C8` Quartus 25.1 timing closure (`57% ALMs`, `98% M10K`, `0.000 ns TNS`).
- [x] **Phase 3 — Compute Cartridge FPGA & Hardware Design (`src/cart_fpga/`, [`docs/CARTRIDGE_HARDWARE.md`](docs/CARTRIDGE_HARDWARE.md)):** Finalized Intel Cyclone V **`5CEBA5F23C8`** (pin-compatible with `5CEBA7F23C8`, FBGA-484), completed the full Model 2A-CRX Compute Cartridge FPGA (`i960_top` + `m2_copro` + `m2_geometry` + `m2_2a_sound` + 128 MB dual-chip `m2_sdram` + `m2_cart_host`) verified in Quartus Prime 25.1 Lite at **81% ALMs (`23,673 / 29,080`)**, **43% M10K**, **9% DSP**, and **`0.000 ns` TNS across all 4 PVT corners** (`+2.160 ns` worst setup slack), and authored the 6-layer ENIG PCB, dual-source safe power tree (`TPS2552` 180 mA slot limiter + `TPS2116` USB-C priority mux), and ~$62 prototype BOM.
- [x] **Phase 4 — KiCad PCB Layout, Production Gerbers & 3D Render ([`hardware/gerbers/`](hardware/gerbers/)):** Complete KiCad 8 schematic/PCB floorplan, verified 77 locked pins in silicon, photorealistic 3D PCB render, dual Model 2 + Model 2A bitstream synthesis, and generated complete production RS-274X Gerber & Excellon drill archive ([`DeadOrPocket_Cartridge_RevA_Gerbers.zip`](hardware/gerbers/DeadOrPocket_Cartridge_RevA_Gerbers.zip)) ready for JLCPCB/PCBWay fabrication.
- [ ] **Phase 5 — Physical Assembly & Hardware Bring-Up:** Fabricate prototype PCBs, SMT assembly with Cyclone V + dual SDRAMs, test boot loader via MicroSD and run full 57.52 Hz hardware playback on Analogue Pocket and Pocket Dock.

---

## License & Credits

- Hybrid Analogue Pocket architecture & port: **DanimanX**.
- Upstream Sega Model 2 / Model 2A-CRX MiSTer core: **alphanu1** ([`alphanu1/sega-model2-mister`](https://github.com/alphanu1/sega-model2-mister)).
- Reference openFPGA scaffolding & Cellular PSRAM PHY: **SpaceFish** ([`DanimanX/SpaceFish`](https://github.com/DanimanX/SpaceFish)).
- Licensed under the **GNU General Public License v3.0 (GPL-3.0)**. This repository does not contain and will never contain ROM files.
