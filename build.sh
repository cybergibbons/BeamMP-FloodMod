#!/usr/bin/env bash
# Rebuild Resources/Client/floodBeamMP.zip from the unpacked client source.
# Run this after editing files under Resources/Client/floodBeamMP/.
set -euo pipefail
cd "$(dirname "$0")/Resources/Client/floodBeamMP"
out="../floodBeamMP.zip"
rm -f "$out"
if command -v zip >/dev/null 2>&1; then
  zip -r -X "$out" scripts lua >/dev/null
else
  python3 - "$out" <<'PY'
import sys, zipfile, os
out = sys.argv[1]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root in ("scripts", "lua"):
        for dp, _, files in os.walk(root):
            for f in files:
                full = os.path.join(dp, f)
                z.write(full, full)
PY
fi
echo "Built $(cd .. && pwd)/floodBeamMP.zip"
