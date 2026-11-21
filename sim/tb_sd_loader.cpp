// tb_sd_loader.cpp — Real Behavioral SDHC SPI Card Model + Verilator verifier for m2_sd_loader.sv
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <deque>
#include <vector>
#include "Vtb_sd_loader.h"
#include "verilated.h"

struct SdCardSpiModel {
    std::vector<uint8_t> disk; // 512-byte sectors
    bool prev_sck = false;
    uint8_t rx_shift = 0;
    int rx_bits = 0;
    uint8_t tx_byte = 0xFF;
    int tx_bits = 0;

    std::vector<uint8_t> cmd_bytes;
    std::deque<uint8_t> tx_queue;
    bool app_cmd = false;
    bool initialized = false;
    int acmd41_count = 0;
    bool multi_read = false;
    uint32_t multi_lba = 0;
    int cmds_seen = 0;

    void init_test_image(uint32_t part1_lba, uint32_t num_words, uint32_t sdram_base, uint8_t game_id) {
        uint32_t payload_sectors = (num_words * 2 + 511) / 512;
        disk.assign((part1_lba + 1 + payload_sectors + 2) * 512, 0);

        // Sector 0: Standard FAT32-style MBR pointing Partition 1 -> part1_lba
        disk[454] = (part1_lba >> 0) & 0xFF;
        disk[455] = (part1_lba >> 8) & 0xFF;
        disk[456] = (part1_lba >> 16) & 0xFF;
        disk[457] = (part1_lba >> 24) & 0xFF;
        disk[510] = 0x55;
        disk[511] = 0xAA;

        // Sector part1_lba: DeadOrPocket "DOP2" Boot Descriptor
        uint8_t* hdr = &disk[part1_lba * 512];
        hdr[0] = 'D'; hdr[1] = 'O'; hdr[2] = 'P'; hdr[3] = '2';
        auto put32 = [](uint8_t* p, uint32_t v) {
            p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF;
            p[2] = (v >> 16) & 0xFF; p[3] = (v >> 24) & 0xFF;
        };
        put32(hdr + 4,  num_words);
        put32(hdr + 8,  part1_lba + 1); // payload_lba
        put32(hdr + 12, sdram_base);
        hdr[16] = game_id;
        hdr[17] = 0x03; // prog_ext=1, board_2a=1

        // Payload sectors starting at part1_lba + 1: deterministic 16-bit pattern
        uint8_t* pl = &disk[(part1_lba + 1) * 512];
        for (uint32_t i = 0; i < num_words; i++) {
            uint16_t w = uint16_t(((i * 0x1337u) ^ 0xA55Au) + (i >> 8));
            pl[i * 2 + 0] = w & 0xFF;
            pl[i * 2 + 1] = (w >> 8) & 0xFF;
        }
    }

    void queue_sector(uint32_t lba) {
        tx_queue.push_back(0xFF);
        tx_queue.push_back(0xFE); // Data start token
        size_t off = size_t(lba) * 512;
        for (size_t i = 0; i < 512; i++) {
            tx_queue.push_back((off + i < disk.size()) ? disk[off + i] : 0x00);
        }
        tx_queue.push_back(0xCA); // CRC16 hi
        tx_queue.push_back(0xFE); // CRC16 lo
    }

    void handle_command() {
        uint8_t cmd = cmd_bytes[0] & 0x3F;
        uint32_t arg = (uint32_t(cmd_bytes[1]) << 24) | (uint32_t(cmd_bytes[2]) << 16) |
                       (uint32_t(cmd_bytes[3]) << 8)  | uint32_t(cmd_bytes[4]);
        cmds_seen++;

        if (cmd == 12) { // CMD12 STOP_TRANSMISSION
            multi_read = false;
            tx_queue.clear();
            tx_queue.push_back(0xFF); // stuff byte
            tx_queue.push_back(0x00); // R1
            tx_queue.push_back(0x00); // busy 1 byte
            tx_queue.push_back(0xFF); // unbusy
            return;
        }

        if (app_cmd && cmd == 41) { // ACMD41
            app_cmd = false;
            acmd41_count++;
            if (acmd41_count >= 2) {
                initialized = true;
                tx_queue.push_back(0x00);
            } else {
                tx_queue.push_back(0x01); // still busy first time
            }
            return;
        }
        app_cmd = false;

        switch (cmd) {
            case 0: // CMD0 GO_IDLE_STATE
                initialized = false;
                acmd41_count = 0;
                tx_queue.push_back(0x01);
                break;
            case 8: // CMD8 SEND_IF_COND
                tx_queue.push_back(0x01);
                tx_queue.push_back(0x00); tx_queue.push_back(0x00);
                tx_queue.push_back(0x01); tx_queue.push_back(0xAA);
                break;
            case 55: // CMD55 APP_CMD
                app_cmd = true;
                tx_queue.push_back(initialized ? 0x00 : 0x01);
                break;
            case 58: // CMD58 READ_OCR (SDHC CCS=1)
                tx_queue.push_back(0x00);
                tx_queue.push_back(0xC0); tx_queue.push_back(0xFF);
                tx_queue.push_back(0x80); tx_queue.push_back(0x00);
                break;
            case 17: // CMD17 READ_SINGLE_BLOCK
                tx_queue.push_back(0x00);
                queue_sector(arg);
                break;
            case 18: // CMD18 READ_MULTIPLE_BLOCK
                tx_queue.push_back(0x00);
                multi_read = true;
                multi_lba = arg;
                queue_sector(multi_lba++);
                break;
            default:
                tx_queue.push_back(0x04); // illegal cmd
                break;
        }
    }

    uint8_t step(bool cs_n, bool sck, bool mosi) {
        if (cs_n) {
            prev_sck = sck;
            rx_bits = 0;
            tx_bits = 0;
            cmd_bytes.clear();
            return 1;
        }
        if (sck && !prev_sck) { // Rising edge: sample MOSI
            rx_shift = uint8_t((rx_shift << 1) | (mosi ? 1 : 0));
            rx_bits++;
            if (rx_bits == 8) {
                rx_bits = 0;
                if (!cmd_bytes.empty() || ((rx_shift & 0xC0) == 0x40)) {
                    cmd_bytes.push_back(rx_shift);
                    if (cmd_bytes.size() == 6) {
                        handle_command();
                        cmd_bytes.clear();
                    }
                }
            }
        } else if (!sck && prev_sck) { // Falling edge: advance MISO
            tx_bits++;
            if (tx_bits == 8) {
                tx_bits = 0;
                if (tx_queue.empty() && multi_read) {
                    queue_sector(multi_lba++);
                }
                if (!tx_queue.empty()) {
                    tx_byte = tx_queue.front();
                    tx_queue.pop_front();
                } else {
                    tx_byte = 0xFF;
                }
            }
        }
        prev_sck = sck;
        return (tx_byte >> (7 - tx_bits)) & 1;
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vtb_sd_loader dut;

    const uint32_t PART1_LBA  = 2048;
    const uint32_t NUM_WORDS  = 4096; // 8 KB (16 SDHC blocks)
    const uint32_t SDRAM_BASE = 0x001000;
    const uint8_t  GAME_ID    = 0x16; // Dead or Alive

    SdCardSpiModel sd;
    sd.init_test_image(PART1_LBA, NUM_WORDS, SDRAM_BASE, GAME_ID);

    std::vector<uint16_t> sdram(SDRAM_BASE + NUM_WORDS + 64, 0xDEAD);
    int sdram_wait = 0;
    bool prev_wr_req = false;
    uint32_t wr_count = 0;

    dut.rst_n = 0;
    dut.sdram_ready = 0;
    dut.sd_miso = 1;
    dut.wr_ack = 0;

    for (int cyc = 0; cyc < 1500000; cyc++) {
        if (cyc == 10) dut.rst_n = 1;
        if (cyc == 20) dut.sdram_ready = 1;

        // Variable-latency SDRAM ack (3 to 7 cycles) to exercise SPI clock-stretching backpressure
        dut.wr_ack = 0;
        if (dut.wr_req) {
            if (!prev_wr_req) sdram_wait = 3 + (wr_count % 5);
            if (sdram_wait > 0) sdram_wait--;
            else {
                uint32_t addr = dut.wr_addr;
                if (addr < sdram.size()) sdram[addr] = dut.wr_din;
                dut.wr_ack = 1;
                wr_count++;
            }
        }
        prev_wr_req = dut.wr_req;

        dut.sd_miso = sd.step(dut.sd_cs_n, dut.sd_sck, dut.sd_mosi);
        dut.clk = 0; dut.eval();
        dut.clk = 1; dut.eval();

        if (dut.boot_err) {
            printf("[FAIL] m2_sd_loader asserted boot_err at cycle %d!\n", cyc);
            return 1;
        }
        if (dut.boot_done) {
            printf("[INFO] boot_done asserted at cycle %d (cmds=%d, words=%u, game_id=0x%02X, prog_ext=%d)\n",
                   cyc, sd.cmds_seen, dut.boot_words_loaded, dut.boot_game_id, dut.boot_prog_ext);
            break;
        }
    }

    if (!dut.boot_done) {
        printf("[FAIL] Timed out waiting for boot_done!\n");
        return 1;
    }

    int mismatches = 0;
    for (uint32_t i = 0; i < NUM_WORDS; i++) {
        uint16_t exp = uint16_t(((i * 0x1337u) ^ 0xA55Au) + (i >> 8));
        uint16_t got = sdram[SDRAM_BASE + i];
        if (got != exp) {
            if (mismatches < 8)
                printf("[FAIL] SDRAM[0x%X] = 0x%04X, expected 0x%04X\n", SDRAM_BASE + i, got, exp);
            mismatches++;
        }
    }

    if (dut.boot_game_id != GAME_ID || !dut.boot_prog_ext || dut.boot_words_loaded != NUM_WORDS || mismatches != 0) {
        printf("[FAIL] Verification failed: mismatches=%d words=%u/%u gid=0x%02X\n",
               mismatches, dut.boot_words_loaded, NUM_WORDS, dut.boot_game_id);
        return 1;
    }

    printf("[PASS] m2_sd_loader Verilator test: MBR->Part1(LBA %u)->DOP2->CMD18(%u/4096 words bit-exact)->CMD12!\n",
           PART1_LBA, wr_count);
    return 0;
}
