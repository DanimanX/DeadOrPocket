#!/usr/bin/env python3
"""
Phase 0 Benchmark: Standalone Quartus Prime 25.1 Lite (quartus_map) synthesis
of Sega Model 2 (main) and Model 2A-CRX (model2a) subsystems targeting the
Analogue Pocket Cyclone V FPGA (5CEBA4F23C8), matching SpaceFish QSF settings.
"""
import concurrent.futures
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

QUARTUS_MAP = "/opt/intelFPGA/25.1/quartus/bin/quartus_map"
ROOT = Path("/PROCESOS/DeadOrPocket")
UP_M2 = ROOT / "upstream" / "sega-model2-mister"
UP_M2A = ROOT / "upstream" / "sega-model2a-mister"
OUT_DIR = ROOT / "phase0_bench" / "runs"

def parse_qsf_files(repo: Path):
    qsf = (repo / "Model2.qsf").read_text(errors="ignore")
    files = []
    for m in re.finditer(
        r"^set_global_assignment\s+-name\s+(SYSTEMVERILOG_FILE|VERILOG_FILE|VHDL_FILE)\s+(\S+)",
        qsf,
        re.M,
    ):
        kind, rel = m.group(1), m.group(2).strip('"')
        if rel.startswith("sys/") or rel in ("Model2.sv", "build_id.v"):
            continue
        p = (repo / rel).resolve()
        if p.exists():
            files.append((kind, str(p)))
    return files

def search_paths(repo: Path):
    dirs = [str(repo.resolve()), str((repo / "rtl").resolve())]
    for root, subdirs, _ in os.walk(repo / "rtl"):
        for d in subdirs:
            dirs.append(os.path.abspath(os.path.join(root, d)))
    return sorted(set(dirs))

TARGETS = [
    # (name, repo, top_entity, params_dict, macros_list)
    ("i960_2a_full", UP_M2A, "i960_top", {
        "VC": "1'b1", "FR": "1'b1", "F2A": "1'b1",
        "RC_RING": "1'b1", "RC_FRAMES": "8",
        "DC_LINES": "64", "DC_2A": "1'b1", "DC_LANES": "1'b0",
        "IC_PAIR": "1'b1", "DC_ROMS": "1'b1", "LSU_ST1": "1'b1", "LSU_POST": "1'b1",
        "FP_SUBN": "2",
    }, []),
    ("i960_2a_trim", UP_M2A, "i960_top", {
        "VC": "1'b1", "FR": "1'b1", "F2A": "1'b1",
        "RC_RING": "1'b0", "RC_FRAMES": "4",
        "DC_LINES": "0", "DC_2A": "1'b1", "DC_LANES": "1'b0",
        "IC_LINES": "256", "FP_SUBN": "0",
    }, []),
    ("copro_m2", UP_M2, "m2_copro", {
        "PROG_WORDS": "2048",
    }, []),
    ("copro_2a", UP_M2A, "m2_copro", {
        "PROG_WORDS": "4096", "SUBNORM": "1'b1", "EARLY_ALU": "1'b1",
        "BUFW_Q": "32", "OUT_STALL": "1'b1",
    }, []),
    ("geometry_2a", UP_M2A, "m2_geometry", {
        "MIPZ": "1'b1", "MIPZ_B": "3", "TEXLUT": "1'b1", "WINKEY": "1'b1", "UVSH": "1'b1",
    }, []),
    ("raster3d_2a", UP_M2A, "m2_raster3d", {
        "SCR_W": "496", "SCR_H": "384", "BAND_H": "8", "NBUF": "6",
        "FTB": "1'b1", "FB_DDR3": "1'b1", "FB_WCOMB": "1'b1", "SPLIT_TRI": "1'b1",
        "PXC": "1'b1", "PIXSTEP": "4", "FRB": "2", "M2COV": "1'b1",
        "DIL": "1'b1", "UVCL": "1'b1", "NEGZ": "1'b1",
        "TXLATE": "3", "TXNS": "4", "TXRSP": "4", "TXK": "16", "TXLW8": "1'b1",
        "TXREUSE": "1'b0", "SPCULL": "1'b1", "MIP": "1'b1",
        "TWO_CLOCKS": "1'b1", "TEX_AW": "26", "TEXLUT": "1'b1",
        "KW": "20", "UVSH": "1'b1", "QNX": "512",
    }, []),
    ("quad_store_2a", UP_M2A, "m2_quad_store", {
        "NQ": "2048", "BAND_H": "8", "NBANDS": "48", "BW": "6",
        "NBANK": "2", "KW": "20", "RAWCOL": "1'b1", "FRB": "2",
    }, []),
    ("video_2d", UP_M2A, "m2_video", {
        "LB_RING": "1'b1", "HSCR_FIX": "1'b1", "SCR_SYNC": "1'b1",
        "SCR_STEP": "1'b1", "SCR_DEPTH": "2", "MASK_SKIP": "1'b1",
    }, []),
    ("char_cache_8k", UP_M2A, "m2_char_cache", {
        "IDX_BITS": "13", "SIBLING": "1'b0",
    }, []),
    ("char_cache_2k", UP_M2A, "m2_char_cache", {
        "IDX_BITS": "11", "SIBLING": "1'b0",
    }, []),
    ("sound_m2", UP_M2, "m2_sound_board", {
        "PCM_CACHE": "1'b1", "PCM_RATE": "1'b1", "TICK_DEN": "80",
        "PCM_SHARED": "1'b1", "YM_STUB": "1'b0", "LERP": "1'b1",
    }, []),
    ("sound_2a", UP_M2A, "m2_2a_sound", {
        "AW": "26", "ROM_SWAP": "1'b1",
        "PHI_NUM": "225792", "PHI_DEN": "800000",
        "T44_NUM": "441", "T44_DEN": "800000",
        "POST_WR": "1'b1", "EXACT": "1'b1", "TIMER": "2", "LERP": "1'b1",
    }, []),
    ("ioz80_m2", UP_M2, "m2_ioz80", {
        "TICK_NUM": "4", "TICK_DEN": "80", "TYPE2": "1'b1",
        "T2_SCALE": "625", "T2_NUM": "6144",
    }, []),
    ("sdram_13p", UP_M2A, "m2_sdram", {
        "COL_BITS": "10", "NP": "13", "T_REFI": "770",
    }, []),
    ("sdram_8p", UP_M2A, "m2_sdram", {
        "COL_BITS": "10", "NP": "8", "T_REFI": "770",
    }, []),
    ("cpu_bridge_2a", UP_M2A, "m2_cpu_bridge", {
        "BUFFERRAM": "1'b1", "BUFFERRAM_WRONLY": "1'b0",
        "AW": "26", "BOARD_2A": "1'b1", "DCACHE_EN": "1'b1",
    }, []),
]

def parse_map_reports(workdir: Path, name: str):
    summary_p = workdir / f"{name}.map.summary"
    rpt_p = workdir / f"{name}.map.rpt"
    res = {"name": name, "ok": False}
    if not summary_p.exists():
        return res
    s = summary_p.read_text(encoding="latin-1", errors="ignore")
    res["ok"] = "Successful" in s

    def grab(pat):
        m = re.search(pat, s)
        return m.group(1).strip().replace(",", "") if m else "?"

    res["alms_est"] = grab(r"Estimate of Logic utilization \(in ALMs needed\)\s*:\s*([\d,]+)")
    res["aluts"] = grab(r"Combinational ALUTs\s*:\s*([\d,]+)")
    res["regs"] = grab(r"Total registers\s*:\s*([\d,]+)")
    res["mem_bits"] = grab(r"Total block memory bits\s*:\s*([\d,]+)")
    res["dsp"] = grab(r"Total DSP Blocks\s*:\s*([\d,]+)")

    # Parse RAM Summary & exact ALM estimate from .map.rpt (Quartus 25.1 format)
    import math
    def calc_m10k(depth: int, width: int, tdp: bool = False) -> int:
        cfgs = [(512, 20), (1024, 10), (2048, 5), (4096, 2), (8192, 1)] if tdp else \
               [(256, 40), (512, 20), (1024, 10), (2048, 5), (4096, 2), (8192, 1)]
        return min(math.ceil(depth / d) * math.ceil(width / w) for d, w in cfgs)

    m10k_total = 0
    mlab_count = 0
    ram_instances = 0
    reg_warnings = []
    if rpt_p.exists():
        rpt = rpt_p.read_text(encoding="latin-1", errors="ignore")
        m_alm = re.search(r";\s*Estimate of Logic utilization \(ALMs needed\)\s*;\s*([\d,]+)", rpt)
        if m_alm:
            res["alms_est"] = m_alm.group(1).replace(",", "")
        m_alut = re.search(r";\s*Combinational ALUT usage for logic\s*;\s*([\d,]+)", rpt)
        if m_alut:
            res["aluts"] = m_alut.group(1).replace(",", "")
        # Analysis & Synthesis RAM Summary
        m = re.search(
            r"; Analysis & Synthesis RAM Summary\s*;\n\+[-+]+\+\n;.*?\n\+[-+]+\+\n(.*?)\n\+[-+]+\+\n",
            rpt,
            re.S,
        )
        if m:
            for ln in m.group(1).splitlines():
                if not ln.startswith(";"):
                    continue
                cols = [c.strip() for c in ln.split(";")]
                if len(cols) >= 10:
                    ram_instances += 1
                    rtype, rmode = cols[2], cols[3]
                    try:
                        da, wa = int(cols[4]), int(cols[5])
                    except ValueError:
                        continue
                    if "M10K" in rtype or ("AUTO" in rtype and da * wa >= 2048):
                        m10k_total += calc_m10k(da, wa, "True Dual" in rmode)
                    elif "MLAB" in rtype:
                        mlab_count += 1
        mrom = re.search(
            r"; Analysis & Synthesis ROM Summary\s*;\n\+[-+]+\+\n;.*?\n\+[-+]+\+\n(.*?)\n\+[-+]+\+\n",
            rpt,
            re.S,
        )
        if mrom:
            for ln in mrom.group(1).splitlines():
                cols = [c.strip() for c in ln.split(";")]
                if len(cols) >= 6:
                    try:
                        m10k_total += calc_m10k(int(cols[3]), int(cols[4]), False)
                    except ValueError:
                        pass
        # Check Quartus RAM inference warnings (e.g., ramstyle ignored, converted to registers)
        for w in re.finditer(r"Warning.*(?:ramstyle|RAM logic|not inferred|registers|M10K|megafunction).*", rpt, re.I):
            txt = w.group(0).strip()
            if any(k in txt.lower() for k in ("not inferred", "ignored", "registers", "unmapped", "cannot be implemented")):
                reg_warnings.append(txt[:160])

    res["m10k"] = m10k_total
    res["ram_insts"] = ram_instances
    res["mlabs"] = mlab_count
    res["ram_warnings"] = reg_warnings[:5]
    return res

def run_target(spec):
    name, repo, top, params, macros = spec
    workdir = OUT_DIR / name
    workdir.mkdir(parents=True, exist_ok=True)
    files = parse_qsf_files(repo)
    spaths = search_paths(repo)

    qpf = workdir / f"{name}.qpf"
    qsf = workdir / f"{name}.qsf"
    qpf.write_text(f'PROJECT_REVISION = "{name}"\n')

    lines = [
        'set_global_assignment -name FAMILY "Cyclone V"',
        'set_global_assignment -name DEVICE 5CEBA4F23C8',
        f'set_global_assignment -name TOP_LEVEL_ENTITY {top}',
        'set_global_assignment -name VERILOG_INPUT_VERSION SYSTEMVERILOG_2005',
        'set_global_assignment -name OPTIMIZATION_MODE "AGGRESSIVE AREA"',
        'set_global_assignment -name OPTIMIZATION_TECHNIQUE AREA',
        'set_global_assignment -name SYNTH_TIMING_DRIVEN_SYNTHESIS OFF',
        'set_global_assignment -name NUM_PARALLEL_PROCESSORS 2',
        'set_global_assignment -name PROJECT_OUTPUT_DIRECTORY .',
    ]
    for sp in spaths:
        lines.append(f'set_global_assignment -name SEARCH_PATH "{sp}"')
    for m in macros:
        lines.append(f'set_global_assignment -name VERILOG_MACRO "{m}"')
    for k, v in params.items():
        lines.append(f'set_parameter -name {k} {v}')
    for kind, p in files:
        lines.append(f'set_global_assignment -name {kind} "{p}"')

    qsf.write_text("\n".join(lines) + "\n")

    t0 = time.time()
    # Run from repo dir? No, run from workdir; some hex/mif use relative paths like rtl/sound/scsp/scsp_eg.hex!
    # Symlink rtl/ into workdir so relative $readmemh("rtl/...") works seamlessly!
    rtl_link = workdir / "rtl"
    if rtl_link.is_symlink() or rtl_link.exists():
        rtl_link.unlink()
    rtl_link.symlink_to(repo / "rtl")

    proc = subprocess.run(
        [QUARTUS_MAP, name, "-c", name],
        cwd=str(workdir),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    dt = time.time() - t0
    (workdir / "quartus_map.log").write_text(proc.stdout)
    res = parse_map_reports(workdir, name)
    res["rc"] = proc.returncode
    res["sec"] = round(dt, 1)
    if not res["ok"]:
        errs = [ln for ln in proc.stdout.splitlines() if "Error (" in ln or "Error:" in ln]
        res["errors"] = errs[:6]
    return res

def main():
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    t_start = time.time()
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        futs = [ex.submit(run_target, t) for t in TARGETS]
        for f in concurrent.futures.as_completed(futs):
            r = f.result()
            results.append(r)
            status = "OK" if r["ok"] else f"FAIL(rc={r['rc']})"
            print(
                f"[{status:10s}] {r['name']:16s} | ALM_est={str(r.get('alms_est','?')):>6s} | "
                f"Regs={str(r.get('regs','?')):>6s} | MemBits={str(r.get('mem_bits','?')):>9s} | "
                f"M10K={str(r.get('m10k','?')):>3s} | DSP={str(r.get('dsp','?')):>2s} | "
                f"warn={len(r.get('ram_warnings',[]))} | {r['sec']}s",
                flush=True,
            )
            if not r["ok"]:
                for e in r.get("errors", []):
                    print("   ERR:", e, flush=True)

    # Sort back in TARGETS order
    order = {t[0]: i for i, t in enumerate(TARGETS)}
    results.sort(key=lambda r: order[r["name"]])
    out_json = ROOT / "phase0_bench" / "phase0_results.json"
    out_json.write_text(json.dumps(results, indent=2))
    print(f"\nDone in {time.time() - t_start:.1f}s -> {out_json}")

if __name__ == "__main__":
    main()
