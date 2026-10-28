#!/bin/bash
# Reproduces the working Resident Evil 2 setup (Steam copy, DirectX 12 through
# D3DMetal) on a fresh Whisky install. docs/ResidentEvil2.md explains why each
# step exists and lists the parts that stay manual (Apple's GPTK, Steam login,
# downloading the game).
#
# Usage: scripts/re2-setup.sh engine          install the fixed 4.0.0-beta.2 engine
#        scripts/re2-setup.sh bottle <name>   apply the RE2 tweaks to a bottle
#        scripts/re2-setup.sh all <name>      both, engine first
#
# Quit Whisky before running it against your real install.
set -euo pipefail

# ---- pinned inputs ----------------------------------------------------------
ENGINE_TAG="v4.0.0-beta.2"   # CrossOver 25 / wine-10.0 lineage, GPTK-capable
ENGINE_SHA256="492b1304172de5d51f8026398a90255ecb99a4fd0409df0bc674fdaad642c2b3"
REPO="frankea/Whisky"
# -----------------------------------------------------------------------------

DEFAULT_SUPPORT_DIR="$HOME/Library/Application Support/com.franke.Whisky"
SUPPORT_DIR="${WHISKY_SUPPORT_DIR:-$DEFAULT_SUPPORT_DIR}"
DEFAULT_CONTAINER_DIR="$HOME/Library/Containers/com.franke.Whisky"
CONTAINER_DIR="${WHISKY_CONTAINER_DIR:-$DEFAULT_CONTAINER_DIR}"
WORKDIR=""
trap '[ -n "$WORKDIR" ] && rm -rf "$WORKDIR"' EXIT

die() { echo "error: $*" >&2; exit 1; }

usage() {
  sed -n '7,9p' "$0" | sed 's/^# //' >&2
  exit 64
}

# Swapping the engine or editing a bottle under a running Whisky or Wine
# session gets overwritten (Whisky rewrites Metadata.plist) or leaves processes
# on the old engine.
require_quiet() {
  pgrep -f "Whisky.app/Contents/MacOS/Whisky" >/dev/null && die "quit Whisky first"
  pgrep -x wineserver >/dev/null && die "a Wine session is still running; quit Steam and wait a few seconds"
  return 0
}

require_tools() {
  local tool
  for tool in curl shasum otool nm install_name_tool codesign plutil; do
    command -v "$tool" >/dev/null || die "$tool not found (install the Xcode command line tools: xcode-select --install)"
  done
}

# The 4.0.0-beta.2 build links glib, ffmpeg and a few others against its
# bundled libiconv, which only exports the _libiconv* names, while they import
# _iconv*. dlopen fails, so GStreamer and winedmo never load: no H.264, and RE2
# crashes on the first video. Later engines link these against the system
# libiconv, which exports _iconv*; do the same here.
fix_iconv() {
  local wine_dir="$1" lib count=0
  while IFS= read -r -d '' lib; do
    otool -L "$lib" | grep -q '@loader_path/./libiconv.2.dylib' || continue
    nm -u "$lib" | grep -qx '_iconv' || continue
    install_name_tool -change "@loader_path/./libiconv.2.dylib" /usr/lib/libiconv.2.dylib "$lib" 2>/dev/null
    codesign -f -s - "$lib" 2>/dev/null
    echo "  relinked $(basename "$lib") to the system libiconv"
    count=$((count + 1))
  done < <(find "$wine_dir" -type f \( -name '*.dylib' -o -name '*.so' \) -print0)
  [ "$count" -gt 0 ] || die "no library needed the libiconv fix; is this the expected engine?"
}

# Loads the media stack the way Wine does (x86_64, under Rosetta), so a bad
# relink fails here instead of as a crash at the first in-game video.
verify_media_stack() {
  arch -x86_64 /usr/bin/python3 -I -c '
import ctypes, sys
for name in ("libglib-2.0.0.dylib", "libgstreamer-1.0.0.dylib", "libavformat.61.dylib",
             "gstreamer-1.0/libgstlibav.dylib", "gstreamer-1.0/libgstopenh264.dylib"):
    ctypes.CDLL(sys.argv[1] + "/" + name, mode=ctypes.RTLD_GLOBAL)
' "$1" || die "the media libraries still fail to load after the fix"
}

install_engine() {
  [ "$SUPPORT_DIR" = "$DEFAULT_SUPPORT_DIR" ] && require_quiet
  require_tools
  WORKDIR="$(mktemp -d)"

  echo "1. Downloading engine $ENGINE_TAG from $REPO..."
  curl -fL --retry 3 --progress-bar -o "$WORKDIR/Libraries.tar.gz" \
    "https://github.com/$REPO/releases/download/$ENGINE_TAG/Libraries.tar.gz"
  echo "$ENGINE_SHA256  $WORKDIR/Libraries.tar.gz" | shasum -a 256 -c - >/dev/null \
    || die "engine digest mismatch"

  echo "2. Unpacking and fixing the libiconv linkage..."
  tar -xzf "$WORKDIR/Libraries.tar.gz" -C "$WORKDIR"
  [ -x "$WORKDIR/Libraries/Wine/bin/wine" ] || die "unexpected engine layout"
  fix_iconv "$WORKDIR/Libraries/Wine"
  verify_media_stack "$WORKDIR/Libraries/Wine/lib"

  echo "3. Installing into $SUPPORT_DIR..."
  mkdir -p "$SUPPORT_DIR"
  if [ -e "$SUPPORT_DIR/Libraries" ]; then
    local backup
    backup="$SUPPORT_DIR/Libraries-backup-$(date +%Y%m%d-%H%M%S)"
    mv "$SUPPORT_DIR/Libraries" "$backup"
    echo "  previous engine kept as $(basename "$backup")"
  fi
  mv "$WORKDIR/Libraries" "$SUPPORT_DIR/Libraries"
  echo "Engine ready. Open Whisky > Settings > Game Porting Toolkit so it deploys"
  echo "D3DMetal into the new engine (import Apple's GPTK .dmg there if you have not yet)."
}

# Prints the path of the bottle whose Metadata.plist carries the given name.
bottle_path() {
  /usr/bin/python3 -I - "$CONTAINER_DIR/BottleVM.plist" "$1" <<'EOF'
import os, plistlib, sys, urllib.parse
registry, wanted = sys.argv[1], sys.argv[2]
try:
    with open(registry, "rb") as f:
        entries = plistlib.load(f).get("paths", [])
except OSError:
    sys.exit(1)
for entry in entries:
    url = entry.get("relative", "") if isinstance(entry, dict) else str(entry)
    path = urllib.parse.unquote(urllib.parse.urlparse(url).path).rstrip("/")
    try:
        with open(os.path.join(path, "Metadata.plist"), "rb") as f:
            name = plistlib.load(f).get("info", {}).get("name")
    except OSError:
        continue
    if name == wanted:
        print(path)
        sys.exit(0)
sys.exit(1)
EOF
}

apply_bottle() {
  local name="$1" bottle meta
  [ "$CONTAINER_DIR" = "$DEFAULT_CONTAINER_DIR" ] && require_quiet
  bottle="$(bottle_path "$name")" || die "no bottle named \"$name\" (create it in Whisky first)"
  meta="$bottle/Metadata.plist"
  local wine="$SUPPORT_DIR/Libraries/Wine/bin/wine"
  [ -x "$wine" ] || die "engine not installed; run: $0 engine"

  echo "1. Bottle settings ($bottle)..."
  # The combination RE2 was validated with on this engine.
  plutil -replace wineConfig.enhancedSync -json '{"msync":{}}' "$meta"
  plutil -replace wineConfig.avxEnabled -bool NO "$meta"
  plutil -replace metalConfig.metal4Enabled -bool NO "$meta"
  plutil -replace graphicsConfig.metalFX -bool NO "$meta"

  echo "2. Registry..."
  export WINEPREFIX="$bottle" WINEDEBUG=-all WINEMSYNC=1 WINEESYNC=1
  # The GStreamer media source fails on the video RE2 opens when a cutscene
  # ends or is skipped, and the game dereferences the missing source. The
  # ffmpeg-based winedmo source handles it.
  "$wine" reg add 'HKCU\Software\Wine\MediaFoundation' \
    /v DisableGstByteStreamHandler /t REG_DWORD /d 1 /f >/dev/null
  # Steam injects its overlay renderer even with the overlay disabled for the
  # game, and its hooks destabilise RE2 under D3DMetal. An empty value disables
  # the DLL for re2.exe only.
  "$wine" reg add 'HKCU\Software\Wine\AppDefaults\re2.exe\DllOverrides' \
    /v gameoverlayrenderer64 /t REG_SZ /d "" /f >/dev/null
  "$SUPPORT_DIR/Libraries/Wine/bin/wineserver" -w
  echo "Bottle \"$name\" ready. Install Steam in it (if needed), log in and play RE2."
}

case "${1:-}" in
  engine) install_engine ;;
  bottle) [ -n "${2:-}" ] || usage; apply_bottle "$2" ;;
  all) [ -n "${2:-}" ] || usage; install_engine; apply_bottle "$2" ;;
  *) usage ;;
esac
