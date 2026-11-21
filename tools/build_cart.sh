#!/usr/bin/env bash
set -euo pipefail
QUARTUS_BIN="${QUARTUS_BIN:-/opt/intelFPGA/25.1/quartus/bin}"
export PATH="$QUARTUS_BIN:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/src/cart_fpga"

REV="cart_deadorpocket"
LABEL="Model 2A-CRX"
if [[ "${1:-2a}" == "m2" ]]; then
    REV="cart_deadorpocket_m2"
    LABEL="Model 2 Original (Daytona / Virtua Cop / Desert Tank)"
fi

echo "=== Building DeadOrPocket Compute Cartridge — ${LABEL} (5CEBA5F23C8N, 77 Pins Locked) ==="
quartus_sh --flow compile cart_deadorpocket -c "$REV"

echo ""
echo "---- ${REV} fit summary ----"
cat "output_files/${REV}.fit.summary"
echo ""
echo "---- ${REV} sta summary (Slow 85C & Slow 0C Setup) ----"
grep -A 2 "Slow 1100mV.*Model Setup" "output_files/${REV}.sta.summary" | head -n 36
