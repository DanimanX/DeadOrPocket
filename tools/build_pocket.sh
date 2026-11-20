#!/bin/sh
# Build the Analogue Pocket Phase 1 Render Core bitstream for DeadOrPocket.
# Needs Intel Quartus Prime 25.1 Lite with Cyclone V (5CEBA4F23C8) support.
set -eu

QUARTUS_BIN=${QUARTUS_BIN:-/opt/intelFPGA/25.1/quartus/bin}
if [ -d "$QUARTUS_BIN" ]; then
    PATH="$QUARTUS_BIN:$PATH"
    export PATH
fi
command -v quartus_sh >/dev/null 2>&1 || {
    echo "quartus_sh not found. Set QUARTUS_BIN or put Quartus on PATH." >&2
    exit 1
}

here=$(cd "$(dirname "$0")/.." && pwd)
cd "$here/src/fpga"

quartus_sh --flow compile pocket_deadorpocket

echo
echo "---- fit summary ----"
if [ -f output_files/pocket_deadorpocket.fit.summary ]; then
    sed -n '1,20p' output_files/pocket_deadorpocket.fit.summary
fi
