// DeadOrPocket Phase 2: REAL Sega Model 2A-CRX ROM Boot Co-Simulation
// Boots REAL Dead or Alive (doaab.rom) / Virtua Fighter 2 (vf2.rom) on real i960_top +
// m2_cpu_bridge and streams live CPU video writes across the 30-pin Pocket Cartridge Bus!

#include "Vtb_m2a_cart_top.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static uint32_t intreq = 0, intena = 0, videoctl = 0;
static uint64_t vblanks = 0;
static uint8_t  io_dp[0x800];

static uint32_t io_read(uint32_t a) {
    a &= ~3u;
    if (a == 0x00980004u) return 1; // copro drained
    if (a >= 0x00980030u && a < 0x00980040u) {
        static const uint8_t ID[16] = {0,'T','A','H',0,'A','K','O',0,'Z','A','K',0,'M','T','K'};
        uint32_t o = a & 0xfu;
        return uint32_t(ID[o]) | (uint32_t(ID[o|1]) << 8) | (uint32_t(ID[o|2]) << 16) | (uint32_t(ID[o|3]) << 24);
    }
    if (a == 0x0098000cu) {
        uint32_t fn = uint32_t(vblanks);
        return (videoctl & 1u) ? (((fn & 1u) << 2) | (videoctl & 3u)) : (((fn & 2u) << 1) | (videoctl & 3u));
    }
    if (a == 0x00e80000u) return intreq;
    if (a == 0x00e80004u) return intena;
    if (a >= 0x01c00000u && a < 0x01c01000u) {
        uint32_t k = (a - 0x01c00000u) >> 2;
        return uint32_t(io_dp[2*k]) | (uint32_t(io_dp[2*k+1]) << 16);
    }
    if (a >= 0x01d00000u && a <= 0x01d03fffu) return 0xffffffffu; // backup SRAM
    if (a == 0x01c00000u || a == 0x01c00004u || a == 0x01c00008u) return 0xffffffffu;
    return 0;
}

static void io_write(uint32_t a, uint32_t v, uint8_t be) {
    a &= ~3u;
    if (a == 0x00e80000u) { intreq &= v; return; }
    if (a == 0x00e80004u) { intena  = v; return; }
    if (a == 0x0098000cu) { videoctl = v; return; }
    if (a >= 0x01c00000u && a < 0x01c01000u) {
        uint32_t k = (a - 0x01c00000u) >> 2;
        if (be & 1) io_dp[2*k]   = v & 0xFF;
        if (be & 4) io_dp[2*k+1] = (v >> 16) & 0xFF;
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) {
        std::fprintf(stderr, "Usage: %s <rom_file> [max_mem_cycles] [out_ppm]\n", argv[0]);
        return 2;
    }
    const char* rom_path = argv[1];
    uint64_t max_cycles = (argc >= 3) ? std::strtoull(argv[2], nullptr, 10) : 2'500'000ULL;
    const char* out_ppm = (argc >= 4) ? argv[3] : "out/m2a_boot_frame.ppm";

    // Allocate 128 MB Cartridge SDRAM (64M x 16-bit words)
    constexpr size_t SDR_WORDS = 64u * 1024u * 1024u;
    std::vector<uint16_t> cart_sdram(SDR_WORDS, 0);

    FILE* rf = std::fopen(rom_path, "rb");
    if (!rf) {
        std::fprintf(stderr, "ERROR: Cannot open ROM '%s'\n", rom_path);
        return 1;
    }
    std::fseek(rf, 0, SEEK_END);
    size_t rsz = std::ftell(rf);
    std::fseek(rf, 0, SEEK_SET);
    std::vector<uint8_t> raw(rsz);
    if (std::fread(raw.data(), 1, rsz, rf) != rsz) {
        std::fclose(rf);
        return 1;
    }
    std::fclose(rf);

    // Load ROM into Cartridge 128 MB SDRAM matching Model2A layout:
    //   0x0000000..0x2540000 -> direct byte offset (prog0 + main_data + tex/poly + tables + snd)
    //   If image > 0x2D40000 (extended 2A layout like doaab/srallyc):
    //     0x2D40000..0x2EC0000 (1.5 MB prog_ext) -> SDRAM byte 0x2600000 (word 0x130_0000)
    //     0x32C0000..0x42C0000 (16 MB tex)       -> SDRAM byte 0x4000000
    //     0x42C0000..end       (polygons)        -> SDRAM byte 0x5000000
    auto copy_region = [&](size_t src_byte, size_t dst_byte, size_t len_bytes) {
        if (src_byte >= raw.size()) return;
        size_t n = std::min(len_bytes, raw.size() - src_byte);
        size_t w0 = dst_byte >> 1;
        for (size_t i = 0; i + 1 < n; i += 2) {
            if (w0 + (i >> 1) < SDR_WORDS) {
                cart_sdram[w0 + (i >> 1)] = uint16_t(raw[src_byte + i]) | (uint16_t(raw[src_byte + i + 1]) << 8);
            }
        }
    };
    copy_region(0x0000000, 0x0000000, 0x2540000);
    bool has_prog_ext = (rsz > 0x2D40000);
    if (has_prog_ext) {
        copy_region(0x2D40000, 0x2600000, 0x0180000); // i960 prog 512KB..2MB
        copy_region(0x32C0000, 0x4000000, 0x1000000); // tex ROM
        copy_region(0x42C0000, 0x5000000, rsz - 0x42C0000); // polygons
    }
    std::printf("[M2A-CART] Loaded %s (%.2f MB, prog_ext=%d)\n",
                rom_path, double(rsz) / (1024.0 * 1024.0), int(has_prog_ext));

    auto* dut = new Vtb_m2a_cart_top;
    dut->clk_mem = 0; dut->clk_sys = 0; dut->clk_cart = 0; dut->clk_cpu = 0;
    dut->rst_n = 0; dut->cpu_rst_n = 0;
    dut->csd_dout_i = 0; dut->csd_ack_i = 0;
    dut->io_rdata_i = 0; dut->io_stall_i = 0; dut->irq_i = 0;
    dut->prog_ext_i = has_prog_ext ? 1 : 0;
    dut->p_pad_key = 0xDEADBEEF;
    dut->p_pad_joy = 0x11223344;
    dut->p_pad_trig = 0x55AA;

    constexpr int W = 496, H = 384;
    std::vector<uint8_t> fb(W * H * 3, 0);

    int cart_div = 0, cpu_div = 0;
    uint64_t sys_acc = 0;
    bool prev_c_vs = false;
    bool prev_io_sel = false;
    uint64_t sd_latency = 0;
    uint64_t sd_reads = 0, sd_writes = 0;
    uint64_t ch3_ok = 0;

    for (uint64_t cyc = 0; cyc < max_cycles; cyc++) {
        if (cyc == 32)  dut->rst_n = 1;
        if (cyc == 128) dut->cpu_rst_n = 1;

        // Rising edges: clk_mem=96MHz, clk_cart=32MHz (/3), clk_cpu=24MHz (/4), clk_sys=73.77MHz (10/13)
        dut->clk_mem = 1;
        if (cart_div == 0) dut->clk_cart = 1; else if (cart_div == 1) dut->clk_cart = 0;
        cart_div = (cart_div + 1) % 3;

        bool cpu_rise = (cpu_div == 0);
        if (cpu_div == 0) dut->clk_cpu = 1; else if (cpu_div == 2) dut->clk_cpu = 0;
        cpu_div = (cpu_div + 1) % 4;

        sys_acc += 10;
        bool sys_rise = (sys_acc >= 13);
        if (sys_rise) { sys_acc -= 13; dut->clk_sys = 1; }

        dut->eval();

        // Service Cartridge 128 MB SDRAM (2-cycle latency behavioral model)
        if (dut->rst_n) {
            dut->csd_ack_i = 0;
            if (dut->csd_req_o) {
                uint32_t wa = dut->csd_addr_o & (SDR_WORDS - 1);
                if (dut->csd_we_o) {
                    uint16_t cur = cart_sdram[wa];
                    uint16_t din = dut->csd_din_o;
                    if (dut->csd_be_o & 1) cur = (cur & 0xFF00) | (din & 0x00FF);
                    if (dut->csd_be_o & 2) cur = (cur & 0x00FF) | (din & 0xFF00);
                    cart_sdram[wa] = cur;
                    sd_writes++;
                } else {
                    uint64_t d = uint64_t(cart_sdram[wa]) |
                                 (uint64_t(cart_sdram[(wa + 1) & (SDR_WORDS - 1)]) << 16) |
                                 (uint64_t(cart_sdram[(wa + 2) & (SDR_WORDS - 1)]) << 32) |
                                 (uint64_t(cart_sdram[(wa + 3) & (SDR_WORDS - 1)]) << 48);
                    dut->csd_dout_i = d;
                    sd_reads++;
                }
                dut->csd_ack_i = 1;
            }

            // Service Model 2A I/O window
            bool io_now = dut->io_sel_o;
            if (io_now && !prev_io_sel) {
                if (dut->io_we_o) io_write(dut->io_addr_o, dut->io_wdata_o, dut->io_be_o);
                else              dut->io_rdata_i = io_read(dut->io_addr_o);
            }
            prev_io_sel = io_now;

            // VSync arriving across 30-pin bus from Pocket triggers Model 2A VBlank IRQ!
            if (dut->c_vsync_o && !prev_c_vs) {
                vblanks++;
                intreq |= (intena & 1u);
            }
            prev_c_vs = dut->c_vsync_o;
            dut->irq_i = uint8_t(((intreq & 0x001u) ? 1u : 0u) | ((intreq & 0x002u) ? 2u : 0u) |
                                 ((intreq & 0x3fcu) ? 4u : 0u) | ((intreq & 0xc00u) ? 8u : 0u));

            if (dut->c_pad_valid_o && dut->c_pad_key_o == dut->p_pad_key) ch3_ok++;

            // Capture Pocket 496x384 2D video output
            if (dut->ce_pix_o && dut->vid_de_o) {
                int x = dut->vid_x_o, y = dut->vid_y_o;
                if (x >= 0 && x < W && y >= 0 && y < H) {
                    uint32_t rgb = dut->vid_rgb_o;
                    size_t idx = (size_t(y) * W + x) * 3;
                    fb[idx + 0] = (rgb >> 16) & 0xFF;
                    fb[idx + 1] = (rgb >> 8)  & 0xFF;
                    fb[idx + 2] = rgb & 0xFF;
                }
            }
        }

        // Falling edges
        dut->clk_mem = 0;
        if (sys_rise) dut->clk_sys = 0;
        dut->eval();

        if (dut->trap_o || dut->halted_o) {
            std::printf("[M2A-CART] STOP: CPU trap=%u halted=%u at PC=0x%08X IP=0x%08X (cyc=%llu)\n",
                        dut->trap_o, dut->halted_o, dut->dbg_pc_o, dut->dbg_ip_o, (unsigned long long)cyc);
            break;
        }
    }

    FILE* pf = std::fopen(out_ppm, "wb");
    if (pf) {
        std::fprintf(pf, "P6\n%d %d\n255\n", W, H);
        std::fwrite(fb.data(), 1, fb.size(), pf);
        std::fclose(pf);
    }

    std::printf("\n========== DeadOrPocket Phase 2 Real Model 2A-CRX ROM Boot ==========\n");
    std::printf("ROM Image                : %s\n", rom_path);
    std::printf("i960 CPU Progress        : PC=0x%08X IP=0x%08X acc=%u trap=%u halted=%u\n",
                dut->dbg_pc_o, dut->dbg_ip_o, dut->dbg_acc_cnt_o, dut->trap_o, dut->halted_o);
    std::printf("Cartridge SDRAM Traffic  : %llu reads, %llu writes\n",
                (unsigned long long)sd_reads, (unsigned long long)sd_writes);
    std::printf("Cartridge Video Writes   : TRAM=%u, PAL=%u (CH1 emitted=%u)\n",
                dut->dbg_tram_wr_o, dut->dbg_pal_wr_o, dut->dbg_tx_ch1_o);
    std::printf("30-Pin Bus Contention    : %u cycles (MUST BE 0)\n", dut->bus_contention_cnt);
    std::printf("Bus Words TX / RX        : %u TX / %u RX\n", dut->dbg_tx_words_o, dut->dbg_rx_words_o);
    std::printf("Pocket Video RAM Updates : TRAM=%u, PAL=%u, SDRAM(Char/Tex)=%u\n",
                dut->pocket_tram_writes, dut->pocket_pal_writes, dut->pocket_sd_writes);
    std::printf("CH3 Pocket->Cart VBlank  : %u received (%llu pad verified)\n",
                dut->dbg_rx_ch3_o, (unsigned long long)ch3_ok);
    std::printf("=====================================================================\n");

    bool pass = !dut->trap_o && !dut->halted_o &&
                (dut->dbg_acc_cnt_o > 50000) &&
                (dut->bus_contention_cnt == 0) &&
                (dut->pocket_tram_writes + dut->pocket_pal_writes + dut->pocket_sd_writes > 100);
    std::printf("REAL ROM CO-SIM RESULT   : %s\n", pass ? "PASS" : "FAIL");
    delete dut;
    return pass ? 0 : 1;
}
