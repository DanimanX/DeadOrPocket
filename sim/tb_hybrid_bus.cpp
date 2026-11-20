// DeadOrPocket Phase 2 Verilator Co-Simulation Testbench
// Exercises the FULL Compute Cartridge <-> 30-Pin Pocket Bus <-> Pocket Render Core:
//   - CH0: Projected 3D Quads (flat-shaded + perspective-textured via live TEXS0!)
//   - CH1: Auto-coalesced live SDRAM Texture Sheet (TEXS0) + 2D Tile/Pal/Char HUD + 3D LUTs
//   - CH2: 48 kHz Stereo PCM Audio bit-exact roundtrip
//   - CH3: VBlank Controller Snapshot roundtrip (Pocket -> Cartridge)
//   - Live bus contention monitor (assert == 0) + JEDEC SDRAM checker (assert == 0)
//   - Saves real composited 496x384 RGB24 output frame to sim/out/phase2_cosim_frame.ppm

#include "Vtb_hybrid_bus_top.h"
#include "verilated.h"
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <string>
#include <vector>

struct Ch1Cmd {
    uint8_t  kind;
    uint32_t addr;
    uint16_t data;
};

struct QuadCmd {
    int16_t  x0, y0, x1, y1, x2, y2, x3, y3;
    uint32_t col;
    uint32_t z;
    bool     moire;
    uint16_t oz0, oz1, oz2, oz3, frac;
    uint16_t u0, v0, u1, v1, u2, v2, u3, v3;
    uint32_t tex;
    uint8_t  uvs;
    bool     mipz;
    bool     end;
};

static inline uint16_t rgb565(uint8_t r, uint8_t g, uint8_t b) {
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
}

static QuadCmd make_flat_quad(int16_t x0, int16_t y0, int16_t x1, int16_t y1,
                              int16_t x2, int16_t y2, int16_t x3, int16_t y3,
                              uint16_t col565, uint32_t z, bool is_end = false) {
    QuadCmd q{};
    q.x0 = x0; q.y0 = y0; q.x1 = x1; q.y1 = y1;
    q.x2 = x2; q.y2 = y2; q.x3 = x3; q.y3 = y3;
    q.col = col565;
    q.z = z;
    q.oz0 = q.oz1 = q.oz2 = q.oz3 = 0x3C00;
    q.mipz = true;
    q.end = is_end;
    return q;
}

static QuadCmd make_tex_quad(int16_t x0, int16_t y0, int16_t x1, int16_t y1,
                             int16_t x2, int16_t y2, int16_t x3, int16_t y3,
                             uint32_t z, uint32_t tex_hdr, uint8_t luma, uint16_t col_base) {
    QuadCmd q{};
    q.x0 = x0; q.y0 = y0; q.x1 = x1; q.y1 = y1;
    q.x2 = x2; q.y2 = y2; q.x3 = x3; q.y3 = y3;
    // With TEXLUT=1: q_col = {7'd0, luma[7:0], col_base[9:1]}, q_tex[11] = col_base[0]
    q.col = (uint32_t(luma) << 9) | ((col_base >> 1) & 0x1FF);
    q.z = z;
    q.oz0 = q.oz1 = q.oz2 = q.oz3 = 0x3C00;
    q.u0 = 0 << 4;  q.v0 = 0 << 4;
    q.u1 = 63 << 4; q.v1 = 0 << 4;
    q.u2 = 63 << 4; q.v2 = 63 << 4;
    q.u3 = 0 << 4;  q.v3 = 63 << 4;
    q.tex = tex_hdr | ((col_base & 1) << 11);
    q.uvs = 0;
    q.mipz = true;
    q.end = false;
    return q;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    bool stress_mode = false;
    for (int i = 1; i < argc; i++) {
        if (std::string(argv[i]) == "--stress") stress_mode = true;
    }
    auto* dut = new Vtb_hybrid_bus_top;

    // Initialize inputs
    dut->clk_mem = 0; dut->clk_sys = 0; dut->clk_cart = 0; dut->clk_core = 0;
    dut->rst_n = 0;
    dut->c_frame_start = 0; dut->c_frame_tag = 0;
    dut->c_q_valid = 0; dut->c_w_valid = 0; dut->c_audio_stb = 0;
    dut->p_pad_key = 0xCAFE0001;
    dut->p_pad_joy = 0x12345678;
    dut->p_pad_trig = 0xBEEF;

    // Pre-build CH1 workload:
    //  1) Upload a 64x64 4-bit checkerboard texture tile into TEXS0 (SDRAM word 0x000_0000)
    //     Each 16-bit word holds 4 x 4-bit texels. Stride in Model 2 sheet is 512 words/row (2048 texels).
    //     Write a 64x64 patch (64 rows x 16 words/row = 1,024 words = 2 KB burst!)
    std::deque<Ch1Cmd> ch1_q;
    for (int ty = 0; ty < 64; ty++) {
        uint32_t row_base = uint32_t(ty) * 512u; // word address in TEXS0 (base 0x000_0000)
        for (int wx = 0; wx < 16; wx++) {
            uint16_t w = 0;
            for (int k = 0; k < 4; k++) {
                int tx = wx * 4 + k;
                bool chk = ((tx >> 3) ^ (ty >> 3)) & 1;
                uint8_t nib = chk ? 0xE : 0x3;
                w |= uint16_t(nib) << (k * 4);
            }
            ch1_q.push_back({5, row_base + uint32_t(wx), w});
        }
    }
    // Invalidate texel cache after uploading texture sheet
    ch1_q.push_back({6, 0, 0x0001});

    //  2) Populate all 3D LUTs in m2_raster3d (TEXLUT=1):
    //     sel=0: luma RAM ({slot[2:0], index[6:0]} -> 6-bit luma 0..63)
    //     sel=1: 3D palette (entry[9:0] -> 15-bit BGR555)
    //     sel=2: colorxlat ({ch[1:0], c5[4:0], luma[5:0]} -> 8-bit output)
    for (uint16_t i = 0; i < 128; i++) {
        ch1_q.push_back({3, uint32_t((0u << 13) | i), uint16_t(i >> 1)});
    }
    ch1_q.push_back({3, uint32_t((1u << 13) | 0), 0x7FFF}); // white base color (modulated by luma/texel)
    ch1_q.push_back({3, uint32_t((1u << 13) | 1), 0x7E08}); // bright cyan/gold
    for (uint16_t ch = 0; ch < 3; ch++) {
        for (uint16_t lum = 0; lum < 64; lum++) {
            uint16_t val = (ch == 0) ? (lum * 4) : (ch == 1) ? ((lum * 3) + 32) : (255 - lum * 3);
            if (val > 255) val = 255;
            // Populate c5 = 31 (max channel) for all 64 luma levels
            ch1_q.push_back({3, uint32_t((2u << 13) | (ch << 11) | (31u << 6) | lum), val});
        }
    }
    //  3) Populate 2D Palette (pal[1] = bright cyan, pal[2] = gold) & 2D Tilemap top HUD strip
    ch1_q.push_back({1, 0, 0x0000}); // bg black
    ch1_q.push_back({1, 1, 0x7FE0}); // cyan-ish RGB555
    ch1_q.push_back({1, 2, 0x03FF}); // yellow/gold RGB555

    // Audio verification queue
    std::deque<uint32_t> expected_audio;
    uint64_t audio_matched = 0;
    uint64_t audio_mismatched = 0;

    // CH3 controller verification
    uint64_t ch3_received = 0;
    uint64_t ch3_matched = 0;

    // Framebuffer capture (496x384 RGB24)
    constexpr int W = 496, H = 384;
    std::vector<uint8_t> fb(W * H * 3, 0);
    int frames_captured = 0;
    bool prev_vs = false;
    uint64_t active_pixels_3d = 0;
    uint64_t active_pixels_total = 0;

    // Quad queue for frames
    std::deque<QuadCmd> quad_q;
    auto enqueue_scene = [&](int fidx) {
        // 1. Deep navy-to-indigo background panels
        quad_q.push_back(make_flat_quad(0, 0, 495, 0, 495, 191, 0, 191, rgb565(16, 22, 54), 0x000F0000));
        quad_q.push_back(make_flat_quad(0, 192, 495, 192, 495, 383, 0, 383, rgb565(28, 18, 42), 0x000F0000));
        // 2. Central crimson/gold DeadOrPocket 3D diamond + side wings (animated per frame)
        int dx = (fidx - 1) * 18;
        quad_q.push_back(make_flat_quad(248 + dx, 48, 368 + dx, 192, 248 + dx, 336, 128 + dx, 192,
                                        rgb565(220, 36, 68), 0x00040000));
        quad_q.push_back(make_flat_quad(248 + dx, 96, 320 + dx, 192, 248 + dx, 288, 176 + dx, 192,
                                        rgb565(245, 198, 48), 0x00020000));
        // 3. Textured quad using TEXS0 uploaded live over CH1!
        //    tex_hdr: bit[0]=1 (textured), wcode[3:1]=1 (64px), hcode[6:4]=1 (64px), sheet[12]=0 (TEXS0)
        uint32_t tex_hdr = (1u << 0) | (1u << 1) | (1u << 4);
        quad_q.push_back(make_tex_quad(36, 84, 156, 72, 168, 220, 44, 212, 0x00030000, tex_hdr, 0x3F, 0));
        // 4. Right emerald 3D panel
        quad_q.push_back(make_flat_quad(340, 96, 456, 124, 444, 268, 332, 248,
                                        rgb565(32, 196, 152), 0x00030000));
        if (stress_mode) {
            // Stress mode: push a full 2,044-quad frame (fills entire 2,048-quad store = ~55K bus words/frame!)
            for (int i = 0; i < 2040; i++) {
                int16_t gx = int16_t((i * 19) % 480);
                int16_t gy = int16_t((i * 13) % 368);
                uint16_t c = rgb565((i * 7) & 0xFF, (i * 11) & 0xFF, (i * 17) & 0xFF);
                quad_q.push_back(make_flat_quad(gx, gy, gx + 10, gy, gx + 10, gy + 10, gx, gy + 10,
                                                c, 0x00080000 + uint32_t(i << 4)));
            }
        }
        // 5. End-of-list sentinel quad
        quad_q.push_back(make_flat_quad(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, true));
    };

    // Multi-clock scheduler (integer ps ticks):
    //   clk_mem  = 96 MHz -> half-period 5208 ps (tick = 1)
    //   clk_core = 80 MHz -> ~5:6 of clk_mem
    //   clk_sys  = 74 MHz -> ~3:4 of clk_mem
    //   clk_cart = 32 MHz -> 1:3 of clk_mem (exact integer ratio like m2_pll C0=10, C3=30!)
    //   Wait: to keep sim fast & deterministic, step in half-periods of clk_mem (192 MHz ticks):
    uint64_t mem_edges = 0;
    uint64_t sys_acc = 0, core_acc = 0;
    int cart_div = 0;
    bool ch1_done = false;
    int scenes_sent = 0;
    int aud_div = 0;
    uint16_t aud_seq = 0x1000;
    bool prev_c_vsync = false;

    const int TARGET_FRAMES = stress_mode ? 4 : 3;
    const uint64_t MAX_MEM_CYCLES = stress_mode ? 8'500'000ULL : 6'500'000ULL;
    bool frame_pending = false;

    for (uint64_t cyc = 0; cyc < MAX_MEM_CYCLES && frames_captured < TARGET_FRAMES; cyc++) {
        if (cyc == 40) dut->rst_n = 1;

        // Sample combinational ready signals BEFORE rising clk_core edge!
        bool was_w_ready = dut->c_w_ready;
        bool was_q_ready = dut->c_q_ready;

        // Rising edge of clk_mem
        dut->clk_mem = 1;
        // Exact /3 for clk_cart (95.91 / 3 = 31.97 MHz)
        bool cart_rise = (cart_div == 0);
        if (cart_div == 0) dut->clk_cart = 1;
        else if (cart_div == 1) dut->clk_cart = 0;
        cart_div = (cart_div + 1) % 3;

        // Bresenham phase accumulator for clk_sys (73.77 / 95.91 = 10 / 13)
        sys_acc += 10;
        bool sys_tick = (sys_acc >= 13);
        if (sys_tick) { sys_acc -= 13; dut->clk_sys = 1; }

        // Bresenham phase accumulator for clk_core (80.0 / 95.91 = 5 / 6)
        core_acc += 5;
        bool core_tick = (core_acc >= 6);
        if (core_tick) { core_acc -= 6; dut->clk_core = 1; }

        dut->eval();

        // Sample Pocket pixel output on clk_mem rising edge (ce_pix)
        if (dut->rst_n && dut->ce_pix_o) {
            bool vs = dut->vid_vs_o;
            if (vs && !prev_vs) {
                if (scenes_sent >= 1 && active_pixels_total > 100000) {
                    frames_captured++;
                    std::printf("[SIM] Completed frame #%d (3D hit pixels = %llu / %llu)\n",
                                frames_captured,
                                (unsigned long long)active_pixels_3d,
                                (unsigned long long)active_pixels_total);
                }
                if (frames_captured < TARGET_FRAMES) {
                    active_pixels_3d = 0;
                    active_pixels_total = 0;
                }
            }
            prev_vs = vs;

            if (dut->vid_de_o) {
                int x = dut->vid_x_o;
                int y = dut->vid_y_o;
                if (x >= 0 && x < W && y >= 0 && y < H) {
                    uint32_t rgb = dut->vid_rgb_o;
                    size_t idx = (size_t(y) * W + x) * 3;
                    fb[idx + 0] = (rgb >> 16) & 0xFF;
                    fb[idx + 1] = (rgb >> 8)  & 0xFF;
                    fb[idx + 2] = rgb & 0xFF;
                    active_pixels_total++;
                    if (dut->scan_hit_o) active_pixels_3d++;
                }
            }
        }

        // Check Pocket CH2 audio reception on clk_sys rising edge
        if (sys_tick && dut->rst_n && dut->p_audio_stb_o) {
            uint32_t got = (uint32_t(dut->p_audio_l_o) << 16) | uint32_t(dut->p_audio_r_o);
            if (!expected_audio.empty() && expected_audio.front() == got) {
                audio_matched++;
                expected_audio.pop_front();
            } else {
                audio_mismatched++;
            }
        }

        // Drive Compute Cartridge producers on clk_core rising edge
        if (core_tick && dut->rst_n) {
            // Check CH3 controller reception from Pocket
            if (dut->c_pad_valid_o) {
                ch3_received++;
                if (dut->c_pad_key_o == dut->p_pad_key &&
                    dut->c_pad_joy_o == dut->p_pad_joy &&
                    dut->c_pad_trig_o == dut->p_pad_trig) {
                    ch3_matched++;
                }
                // Rotate pad test vector for next VBlank
                dut->p_pad_key  ^= 0x00FF00FF;
                dut->p_pad_joy  += 0x01010101;
                dut->p_pad_trig ^= 0x5A5A;
            }

            // Trigger a new 3D scene after SDRAM+PSRAM ready and CH1 upload finishes
            if (dut->sdram_ready_o && dut->fb_ready_o && ch1_done) {
                bool vs_now = dut->c_vsync_o;
                if ((scenes_sent == 0) || (vs_now && !prev_c_vsync && quad_q.empty())) {
                    scenes_sent++;
                    frame_pending = true;
                    enqueue_scene(scenes_sent);
                }
                prev_c_vsync = vs_now;
            }

            // Clear 1-cycle strobes from previous cycle
            dut->c_frame_start = 0;
            dut->c_audio_stb = 0;

            // Stream 48 kHz Stereo PCM audio (~1 sample every 1666 clk_core cycles)
            if (dut->sdram_ready_o && dut->fb_ready_o) {
                aud_div++;
                if (aud_div >= 1666) {
                    aud_div = 0;
                    uint16_t l = aud_seq;
                    uint16_t r = uint16_t(~aud_seq);
                    aud_seq += 0x0137;
                    dut->c_audio_l = l;
                    dut->c_audio_r = r;
                    dut->c_audio_stb = 1;
                    expected_audio.push_back((uint32_t(l) << 16) | uint32_t(r));
                }
            }

            // Drive CH1 writes (SDRAM textures + LUTs + 2D)
            if (dut->c_w_valid && was_w_ready) {
                ch1_q.pop_front();
                dut->c_w_valid = 0;
            }
            if (!dut->c_w_valid && dut->sdram_ready_o && dut->fb_ready_o) {
                if (!ch1_q.empty()) {
                    const auto& c = ch1_q.front();
                    dut->c_w_kind  = c.kind;
                    dut->c_w_addr  = c.addr;
                    dut->c_w_data  = c.data;
                    dut->c_w_valid = 1;
                } else {
                    ch1_done = true;
                }
            }

            // Drive CH0 frame_start + 3D Quads
            if (frame_pending) {
                dut->c_frame_start = 1;
                dut->c_frame_tag   = scenes_sent & 0xF;
                frame_pending = false;
            }
            if (dut->c_q_valid && was_q_ready) {
                quad_q.pop_front();
                dut->c_q_valid = 0;
            }
            if (!dut->c_q_valid && !quad_q.empty()) {
                const auto& q = quad_q.front();
                dut->c_q_x0 = q.x0; dut->c_q_y0 = q.y0;
                dut->c_q_x1 = q.x1; dut->c_q_y1 = q.y1;
                dut->c_q_x2 = q.x2; dut->c_q_y2 = q.y2;
                dut->c_q_x3 = q.x3; dut->c_q_y3 = q.y3;
                dut->c_q_col   = q.col;
                dut->c_q_z     = q.z;
                dut->c_q_moire = q.moire;
                dut->c_q_oz0   = q.oz0; dut->c_q_oz1 = q.oz1;
                dut->c_q_oz2   = q.oz2; dut->c_q_oz3 = q.oz3;
                dut->c_q_frac  = q.frac;
                dut->c_q_u0 = q.u0; dut->c_q_v0 = q.v0;
                dut->c_q_u1 = q.u1; dut->c_q_v1 = q.v1;
                dut->c_q_u2 = q.u2; dut->c_q_v2 = q.v2;
                dut->c_q_u3 = q.u3; dut->c_q_v3 = q.v3;
                dut->c_q_tex   = q.tex;
                dut->c_q_uvs   = q.uvs;
                dut->c_q_mipz  = q.mipz;
                dut->c_q_end   = q.end;
                dut->c_q_valid = 1;
            }
        }

        // Falling edges
        dut->clk_mem = 0;
        if (sys_tick)  dut->clk_sys = 0;
        if (core_tick) dut->clk_core = 0;
        dut->eval();
        mem_edges++;
    }

    // Write captured 496x384 RGB24 PPM
    FILE* f = std::fopen("out/phase2_cosim_frame.ppm", "wb");
    if (f) {
        std::fprintf(f, "P6\n%d %d\n255\n", W, H);
        std::fwrite(fb.data(), 1, fb.size(), f);
        std::fclose(f);
    }

    std::printf("\n================ DeadOrPocket Phase 2 Co-Sim Scorecard ================\n");
    std::printf("Simulated clk_mem cycles : %llu (~%.2f ms @ 95.91 MHz)\n",
                (unsigned long long)mem_edges, double(mem_edges) / 95906.25);
    std::printf("Cartridge detected       : %s\n", dut->cart_detected_o ? "YES" : "NO");
    std::printf("30-pin Bus Contention    : %u cycles (MUST BE 0)\n", dut->bus_contention_cnt);
    std::printf("JEDEC SDRAM Violations   : %u (MUST BE 0)\n", dut->sdram_violations_o);
    std::printf("SDRAM Traffic Served     : %u reads, %u writes\n", dut->sdram_reads_o, dut->sdram_writes_o);
    std::printf("Bus Words TX / RX        : %u TX / %u RX\n", dut->dbg_tx_words_o, dut->dbg_rx_words_o);
    std::printf("CH0 3D Quads Sent        : %u\n", dut->dbg_tx_quads_o);
    std::printf("CH1 2D/LUT/Tex Writes    : %u\n", dut->dbg_tx_ch1_o);
    std::printf("CH2 Audio PCM Verified   : %llu matched, %llu mismatched\n",
                (unsigned long long)audio_matched, (unsigned long long)audio_mismatched);
    std::printf("CH3 Inputs Roundtrip     : %llu matched / %llu received\n",
                (unsigned long long)ch3_matched, (unsigned long long)ch3_received);
    std::printf("3D Framebuffer Pixels    : %llu 3D hits / %llu active pixels (frames=%d)\n",
                (unsigned long long)active_pixels_3d, (unsigned long long)active_pixels_total, frames_captured);
    uint32_t ds = dut->dbg_state_o;
    std::printf("DBG State                : q_val=%u q_rdy=%u sd_wreq=%u sd_wack=%u b_st=%u rx_emp=%u rx_full=%u rx_used=%u\n",
                (ds>>31)&1, (ds>>30)&1, (ds>>29)&1, (ds>>28)&1, (ds>>25)&7, (ds>>24)&1, (ds>>23)&1, ds&0xFF);
    std::printf("DBG FB/PSRAM             : cs_st=%u ms_st=%u fb_req=%u fb_we=%u wf_emp=%u rf_emp=%u c0_st=%u c1_st=%u\n",
                (ds>>21)&3, (ds>>18)&7, (ds>>17)&1, (ds>>16)&1, (ds>>15)&1, (ds>>14)&1, (ds>>11)&7, (ds>>8)&7);
    uint32_t r0 = dut->dbg_r3d_0_o, r1 = dut->dbg_r3d_1_o;
    std::printf("DBG m2_raster3d          : quads=%u qend_fr=%u bands_done=%u fb_clears=%u fb_lines=%u fb_pix_lo=%u\n",
                (r0>>16)&0xFFFF, (r0>>8)&0xFF, r0&0xFF, (r1>>24)&0xFF, (r1>>12)&0xFFF, r1&0xFFF);
    std::printf("=======================================================================\n");

    // Allow up to a few words still in transit in RX FIFO when simulation stops on VBlank
    int64_t inflight = int64_t(dut->dbg_tx_words_o) - int64_t(dut->dbg_rx_words_o);
    bool pass = (dut->cart_detected_o == 1) &&
                (dut->bus_contention_cnt == 0) &&
                (dut->sdram_violations_o == 0) &&
                (inflight >= 0 && inflight <= 256) &&
                (audio_matched > 100 && audio_mismatched == 0) &&
                (ch3_received >= 1 && ch3_matched == ch3_received) &&
                (dut->sdram_writes_o >= 1024) &&
                (active_pixels_3d > 50000);

    std::printf("OVERALL PHASE 2 CO-SIM   : %s\n", pass ? "PASS" : "FAIL");
    delete dut;
    return pass ? 0 : 1;
}
