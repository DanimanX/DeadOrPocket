#!/usr/bin/env bash
set -euo pipefail
QUARTUS_BIN="${QUARTUS_BIN:-/opt/intelFPGA/25.1/quartus/bin}"
export PATH="$QUARTUS_BIN:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/src/cart_fpga"

echo "=== Building DeadOrPocket Compute Cartridge (5CEBA5F23C8) ==="
quartus_sh --flow compile cart_deadorpocket

echo ""
echo "---- cart fit summary ----"
cat output_files/cart_deadorpocket.fit.summary
echo ""
echo "---- cart sta summary (Slow 85C & Slow 0C Setup) ----"
grep -A 2 "Slow 1100mV.*Model Setup" output_files/cart_deadorpocket.sta.summary | head -n 36
