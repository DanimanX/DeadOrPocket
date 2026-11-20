#!/usr/bin/env python3
"""DeadOrPocket ROM Builder & Verifier (Sega Model 2 / Model 2A-CRX).

Parses standard MiSTer .mra descriptors and MAME .zip ROM sets from roms/
(never committed to git), verifies every ROM part's CRC32, and optionally
assembles flat .rom images (plus index-3 Z80 I/O ROMs where applicable) for
Phase 2 Verilator co-simulation and Analogue Pocket / Compute Cartridge boot.

Usage:
  python3 tools/build_rom.py --verify-all
  python3 tools/build_rom.py --mra "Dead or Alive (Model 2A).mra" --out roms/out/
"""
import argparse
import os
import re
import sys
import xml.etree.ElementTree as ET
import zipfile
import zlib


def parse_int(val: str) -> int:
    val = val.strip()
    return int(val, 16) if val.lower().startswith("0x") else int(val, 10)


def parse_hex_bytes(text: str) -> bytes:
    cleaned = re.sub(r"\s+", "", text or "")
    return bytes.fromhex(cleaned) if cleaned else b""


def find_part_in_zips(zip_paths: list[str], name: str, expected_crc: str | None) -> tuple[bytes, str]:
    """Search candidate MAME zip files by CRC32 first, then by filename."""
    target_crc = expected_crc.lower().zfill(8) if expected_crc else None
    fallback = None

    for zp in zip_paths:
        if not os.path.isfile(zp):
            continue
        with zipfile.ZipFile(zp, "r") as zf:
            for info in zf.infolist():
                if info.is_dir():
                    continue
                crc_hex = f"{info.CRC:08x}"
                base = os.path.basename(info.filename).lower()
                if target_crc and crc_hex == target_crc:
                    return zf.read(info), os.path.basename(zp)
                if base == name.lower() and fallback is None:
                    fallback = (zf.read(info), os.path.basename(zp), crc_hex)

    if fallback is not None:
        data, zname, got_crc = fallback
        if target_crc and got_crc != target_crc:
            raise ValueError(
                f"CRC mismatch for '{name}' in {zname}: expected {target_crc}, got {got_crc}"
            )
        return data, zname

    raise FileNotFoundError(
        f"Missing ROM part '{name}' (crc={expected_crc}) in {[os.path.basename(z) for z in zip_paths]}"
    )


def apply_interleave(out_bits: int, parts: list[tuple[bytes, str]]) -> bytes:
    """Interleave parts according to MiSTer MRA 'map' syntax (e.g. map='0021', '2100', '12')."""
    out_bytes = out_bits // 8
    # Each part produces slices of width = number of non-'0' digits in its map
    total_chunks = None
    decoded_parts = []

    for data, map_str in parts:
        # MiSTer MRA map strings are indexed MSB-left or LSB-right; each non-zero char '1','2','3','4'
        # designates which input byte goes to that output byte lane (1-based, right-to-left in little-endian).
        # Standard MRA convention: map has `out_bytes` chars; rightmost char is byte offset 0.
        m = map_str.strip()
        if len(m) != out_bytes:
            raise ValueError(f"Map '{m}' length does not match output={out_bits} ({out_bytes} bytes)")
        in_stride = sum(1 for c in m if c != "0")
        if in_stride == 0:
            raise ValueError(f"Empty map '{m}'")
        if len(data) % in_stride != 0:
            raise ValueError(f"Data len {len(data)} not divisible by stride {in_stride}")
        chunks = len(data) // in_stride
        if total_chunks is None:
            total_chunks = chunks
        elif chunks != total_chunks:
            raise ValueError(f"Interleave length mismatch: {chunks} vs {total_chunks} chunks")

        # Map each output byte lane (0 = rightmost char of map) to input byte offset (0-based)
        lane_map = []
        for pos_from_left, ch in enumerate(m):
            if ch != "0":
                out_lane = (out_bytes - 1) - pos_from_left
                in_idx = int(ch) - 1
                lane_map.append((out_lane, in_idx))
        decoded_parts.append((data, in_stride, lane_map))

    if total_chunks is None:
        return b""

    buf = bytearray(total_chunks * out_bytes)
    for data, in_stride, lane_map in decoded_parts:
        for out_lane, in_idx in lane_map:
            buf[out_lane::out_bytes] = data[in_idx::in_stride]
    return bytes(buf)


def process_rom_node(rom_node: ET.Element, roms_dir: str, build_data: bool) -> tuple[int, bytearray | None, int]:
    """Verify (and optionally assemble) a single <rom index="..."> block."""
    zip_attr = rom_node.attrib.get("zip", "")
    zip_names = [z.strip() for z in zip_attr.split("|") if z.strip()]
    zip_paths = [os.path.join(roms_dir, z) for z in zip_names]

    out = bytearray() if build_data else None
    total_len = 0
    parts_checked = 0

    for child in rom_node:
        tag = child.tag.lower()
        if tag == "part":
            if "name" in child.attrib:
                data, _ = find_part_in_zips(zip_paths, child.attrib["name"], child.attrib.get("crc"))
                off = parse_int(child.attrib["offset"]) if "offset" in child.attrib else 0
                length = parse_int(child.attrib["length"]) if "length" in child.attrib else (len(data) - off)
                seg = data[off : off + length]
                rep = parse_int(child.attrib["repeat"]) if "repeat" in child.attrib else 1
                total_len += len(seg) * rep
                parts_checked += 1
                if out is not None:
                    out.extend(seg * rep)
            else:
                raw = parse_hex_bytes(child.text)
                rep = parse_int(child.attrib["repeat"]) if "repeat" in child.attrib else 1
                total_len += len(raw) * rep
                if out is not None:
                    out.extend(raw * rep)
        elif tag == "interleave":
            out_bits = parse_int(child.attrib["output"])
            iparts = []
            for sub in child:
                if sub.tag.lower() != "part":
                    continue
                data, _ = find_part_in_zips(zip_paths, sub.attrib["name"], sub.attrib.get("crc"))
                off = parse_int(sub.attrib["offset"]) if "offset" in sub.attrib else 0
                length = parse_int(sub.attrib["length"]) if "length" in sub.attrib else (len(data) - off)
                seg = data[off : off + length]
                iparts.append((seg, sub.attrib["map"]))
                parts_checked += 1
            if build_data:
                inter = apply_interleave(out_bits, iparts)
                out.extend(inter)
                total_len += len(inter)
            else:
                # Fast size calc without allocating tens of MB during verify-all
                out_bytes = out_bits // 8
                first_data, first_map = iparts[0]
                stride = sum(1 for c in first_map.strip() if c != "0")
                total_len += (len(first_data) // stride) * out_bytes
        elif tag == "patch":
            if out is not None:
                off = parse_int(child.attrib["offset"])
                patch_bytes = parse_hex_bytes(child.text)
                out[off : off + len(patch_bytes)] = patch_bytes

    return total_len, out, parts_checked


def process_mra(mra_path: str, roms_dir: str, out_dir: str | None = None) -> dict:
    tree = ET.parse(mra_path)
    root = tree.getroot()
    name = (root.findtext("name") or os.path.basename(mra_path)).strip()
    setname = (root.findtext("setname") or "unknown").strip()
    rbf = (root.findtext("rbf") or "Model2").strip()

    build_data = out_dir is not None
    rom0_size = 0
    rom3_size = 0
    game_id = 0
    total_parts = 0

    for rom_node in root.findall("rom"):
        idx = parse_int(rom_node.attrib.get("index", "0"))
        if idx == 4:
            for p in rom_node.findall("part"):
                b = parse_hex_bytes(p.text)
                if b:
                    game_id = b[0]
            continue
        size, data, nparts = process_rom_node(rom_node, roms_dir, build_data)
        total_parts += nparts
        if idx == 0:
            rom0_size = size
            if build_data and data is not None:
                os.makedirs(out_dir, exist_ok=True)
                out_path = os.path.join(out_dir, f"{setname}.rom")
                with open(out_path, "wb") as f:
                    f.write(data)
        elif idx == 3:
            rom3_size = size
            if build_data and data is not None:
                os.makedirs(out_dir, exist_ok=True)
                out_path = os.path.join(out_dir, f"{setname}_ioz80.rom")
                with open(out_path, "wb") as f:
                    f.write(data)

    return {
        "name": name,
        "setname": setname,
        "rbf": rbf,
        "game_id": game_id,
        "rom0_mb": rom0_size / (1024 * 1024),
        "rom3_kb": rom3_size / 1024,
        "parts": total_parts,
    }


def main():
    ap = argparse.ArgumentParser(description="Verify & build Sega Model 2 / 2A-CRX ROM sets")
    ap.add_argument("--roms", default="roms", help="Directory containing MAME .zip sets")
    ap.add_argument(
        "--mra-dir",
        default="upstream/sega-model2a-mister/releases/mra",
        help="Directory containing MiSTer .mra descriptors",
    )
    ap.add_argument("--mra", help="Build a specific .mra file (filename or path)")
    ap.add_argument("--out", help="Output directory for assembled .rom images")
    ap.add_argument("--verify-all", action="store_true", help="Verify all non-CRT MRA ROM sets in --mra-dir")
    args = ap.parse_args()

    here = os.path.abspath(os.path.dirname(__file__) + "/..")
    roms_dir = args.roms if os.path.isabs(args.roms) else os.path.join(here, args.roms)
    mra_dir = args.mra_dir if os.path.isabs(args.mra_dir) else os.path.join(here, args.mra_dir)

    if args.verify_all:
        mras = sorted(
            f for f in os.listdir(mra_dir) if f.endswith(".mra") and "[15kHz CRT]" not in f
        )
        ok = 0
        fail = 0
        print(f"{'Set':10s} | {'Board':8s} | {'ID':4s} | {'Image MB':8s} | {'Parts':5s} | {'Status'}")
        print("-" * 78)
        for m in mras:
            p = os.path.join(mra_dir, m)
            try:
                info = process_mra(p, roms_dir, out_dir=args.out)
                print(
                    f"{info['setname']:10s} | {info['rbf']:8s} | 0x{info['game_id']:02X} | "
                    f"{info['rom0_mb']:8.2f} | {info['parts']:5d} | OK ({info['name']})"
                )
                ok += 1
            except Exception as e:
                print(f"{m[:10]:10s} | {'?':8s} | {'--':4s} | {'--':8s} | {'--':5s} | FAIL: {e}")
                fail += 1
        print("-" * 78)
        print(f"Verified: {ok} OK, {fail} FAILED")
        sys.exit(0 if fail == 0 else 1)

    if args.mra:
        mra_path = args.mra if os.path.isfile(args.mra) else os.path.join(mra_dir, args.mra)
        info = process_mra(mra_path, roms_dir, out_dir=args.out)
        print(
            f"OK: {info['name']} [{info['setname']}] ({info['rbf']}, id=0x{info['game_id']:02X}, "
            f"{info['rom0_mb']:.2f} MB, {info['parts']} CRC-verified parts)"
        )
        if args.out:
            print(f"Written to {args.out}")
    else:
        ap.print_help()


if __name__ == "__main__":
    main()
