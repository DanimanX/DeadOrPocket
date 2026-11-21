#!/usr/bin/env python3
"""
make_sd_image.py — Pack a compiled Model 2 / Model 2A-CRX .rom image into a
DeadOrPocket Compute Cartridge MicroSD raw boot image (DOP2 512-byte header +
512-byte-aligned payload).

Usage:
  python3 tools/make_sd_image.py --rom roms/out/doaab.rom --game-id 0x16 --board 2a --out roms/out/doaab_sd.img
"""

import argparse
import struct
from pathlib import Path


def main():
    ap = argparse.ArgumentParser(description="Create DeadOrPocket MicroSD boot image (DOP2 format)")
    ap.add_argument("--rom", required=True, help="Input .rom payload (built by tools/build_rom.py)")
    ap.add_argument("--out", required=True, help="Output raw MicroSD image (.img)")
    ap.add_argument("--game-id", default="0x16", help="Model 2/2A game ID (hex or dec, default 0x16)")
    ap.add_argument("--board", choices=["2a", "m2"], default="2a", help="Board variant (2a or m2)")
    ap.add_argument("--prog-ext", action="store_true", default=True, help="Enable extended program ROM bank")
    ap.add_argument("--sdram-base", default="0x0", help="Starting 16-bit word address in Cartridge SDRAM")
    args = ap.parse_args()

    rom_path = Path(args.rom)
    data = rom_path.read_bytes()
    if len(data) % 2 != 0:
        data += b"\x00"
    total_words = len(data) // 2
    game_id = int(args.game_id, 0) & 0x7F
    sdram_base = int(args.sdram_base, 0) & 0x03FFFFFF
    flags = (1 if args.prog_ext else 0) | ((1 if args.board == "2a" else 0) << 1)

    # 512-byte DOP2 header at LBA 0, payload begins at LBA 1
    hdr = bytearray(512)
    struct.pack_into("<4sIIIBB", hdr, 0, b"DOP2", total_words, 1, sdram_base, game_id, flags)

    # Pad payload to 512-byte sector boundary
    rem = len(data) % 512
    pad = b"\x00" * ((512 - rem) % 512)

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("wb") as f:
        f.write(hdr)
        f.write(data)
        f.write(pad)

    print(
        f"[OK] Wrote {out_path} ({(len(hdr) + len(data) + len(pad)) / (1024*1024):.2f} MiB, "
        f"{total_words:,} 16-bit words, game_id=0x{game_id:02X}, board={args.board})"
    )


if __name__ == "__main__":
    main()
