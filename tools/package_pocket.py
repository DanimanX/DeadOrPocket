#!/usr/bin/env python3
"""Assemble a deployable Analogue Pocket openFPGA release package for DeadOrPocket.
Generates bit-reversed bitstream.rbf_r and packages Release/DeadOrPocket_Pocket_<ver>.zip.
Adapted directly from SpaceFish tools/package_pocket.py.
"""
import argparse
import os
import shutil
import zipfile


def reverse_bits(data: bytes) -> bytes:
    table = bytes(int(f"{b:08b}"[::-1], 2) for b in range(256))
    return data.translate(table)


def main():
    ap = argparse.ArgumentParser(description="Package DeadOrPocket core for Analogue Pocket")
    ap.add_argument("--rbf", default="src/fpga/output_files/pocket_deadorpocket.rbf")
    ap.add_argument("--apf", default="apf")
    ap.add_argument("--out", default="Release")
    ap.add_argument("--version", default="v0.1.0-phase1")
    args = ap.parse_args()

    here = os.path.abspath(os.path.dirname(__file__) + "/..")
    rbf_path = os.path.join(here, args.rbf)
    apf_path = os.path.join(here, args.apf)
    out_path = os.path.join(here, args.out)
    sd_path = os.path.join(out_path, "sd_card")
    os.makedirs(sd_path, exist_ok=True)

    for item in ["Cores", "Platforms", "Assets"]:
        src_item = os.path.join(apf_path, item)
        dst_item = os.path.join(sd_path, item)
        if os.path.exists(dst_item):
            shutil.rmtree(dst_item)
        shutil.copytree(src_item, dst_item)

    core_dir = os.path.join(sd_path, "Cores", "danimanx.DeadOrPocket")
    rbf_r_path = os.path.join(core_dir, "bitstream.rbf_r")
    if os.path.isfile(rbf_path):
        raw_rbf = open(rbf_path, "rb").read()
        rbf_r = reverse_bits(raw_rbf)
        open(rbf_r_path, "wb").write(rbf_r)
        print(f"Wrote {rbf_r_path} ({len(rbf_r)} bytes)")
    else:
        raise SystemExit(f"ERROR: RBF bitstream not found at {rbf_path}")

    common_readme = os.path.join(sd_path, "Assets", "model2", "common", "README.txt")
    os.makedirs(os.path.dirname(common_readme), exist_ok=True)
    with open(common_readme, "w") as f:
        f.write(
            "Place Sega Model 2 / 2A-CRX .rom packages in Assets/model2/common/.\n"
            "Phase 1 includes a built-in 3D Hardware Self-Test that runs without ROMs.\n"
        )

    zip_path = os.path.join(out_path, f"DeadOrPocket_Pocket_{args.version}.zip")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for root, _, files in os.walk(sd_path):
            for fn in files:
                abs_f = os.path.join(root, fn)
                zf.write(abs_f, os.path.relpath(abs_f, sd_path))
    print(f"Assembled {zip_path}")


if __name__ == "__main__":
    main()
