#!/usr/bin/env bash
#
# deploy.sh - install the flood mod into a BeamMP server (Linux).
#
# Usage:
#   ./deploy.sh /path/to/BeamMP-Server         # explicit target
#   BEAMMP_SERVER_DIR=/path/to/srv ./deploy.sh # via env var
#
# Options:
#   --no-build   skip rebuilding floodBeamMP.zip (use the committed one)
#   -h, --help   show this help
#
# It copies:
#   Resources/Client/floodBeamMP.zip  -> <server>/Resources/Client/
#   Resources/Server/Flood/           -> <server>/Resources/Server/Flood/
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD=1
TARGET="${BEAMMP_SERVER_DIR:-}"

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) BUILD=0 ;;
    -h|--help)  usage 0 ;;
    -*)         echo "Unknown option: $1" >&2; usage 1 ;;
    *)          TARGET="$1" ;;
  esac
  shift
done

if [ -z "$TARGET" ]; then
  echo "ERROR: no target server directory given." >&2
  echo "Usage: ./deploy.sh /path/to/BeamMP-Server" >&2
  exit 1
fi

# Resolve and sanity-check the target.
if [ ! -d "$TARGET" ]; then
  echo "ERROR: target '$TARGET' is not a directory." >&2
  exit 1
fi
TARGET="$(cd "$TARGET" && pwd)"

if [ ! -e "$TARGET/BeamMP-Server" ] && [ ! -e "$TARGET/ServerConfig.toml" ]; then
  echo "WARNING: '$TARGET' has no BeamMP-Server binary or ServerConfig.toml." >&2
  echo "         Continuing anyway (it will be created on first server run)." >&2
fi

# Rebuild the client zip from source unless --no-build.
if [ "$BUILD" -eq 1 ]; then
  echo "[1/3] Rebuilding client zip..."
  bash "$SCRIPT_DIR/build.sh"
else
  echo "[1/3] Skipping rebuild (--no-build); using committed zip."
fi

ZIP="$SCRIPT_DIR/Resources/Client/floodBeamMP.zip"
FLOOD_SRV="$SCRIPT_DIR/Resources/Server/Flood"
[ -f "$ZIP" ]        || { echo "ERROR: missing $ZIP" >&2; exit 1; }
[ -d "$FLOOD_SRV" ]  || { echo "ERROR: missing $FLOOD_SRV" >&2; exit 1; }

# Install client.
echo "[2/3] Installing client mod -> $TARGET/Resources/Client/"
mkdir -p "$TARGET/Resources/Client"
cp -f "$ZIP" "$TARGET/Resources/Client/floodBeamMP.zip"

# Install server plugin.
echo "[3/3] Installing server plugin -> $TARGET/Resources/Server/Flood/"
mkdir -p "$TARGET/Resources/Server/Flood"
cp -f "$FLOOD_SRV"/*.lua "$TARGET/Resources/Server/Flood/"

echo
echo "Done. Installed:"
echo "  $TARGET/Resources/Client/floodBeamMP.zip"
echo "  $TARGET/Resources/Server/Flood/{main,flood,multiplayer}.lua"
echo
echo "Restart the BeamMP server to load it, then in chat/console:"
echo "  /flood_speed 0.1"
echo "  /flood_start"
