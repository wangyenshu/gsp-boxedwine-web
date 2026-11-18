#!/usr/bin/env bash
# Build The Geometer's Sketchpad (Windows field-test release) for the browser on
# Boxedwine's multi-threaded web build.
#
# boxedwine.js / boxedwine.wasm are compiled from the Boxedwine source (release tag)
# with emscripten, as upstream's "make multiThreaded" does, plus:
#   - memory growth (upstream links that target with a fixed 512 MB heap)
#   - -fwasm-exceptions when compiling (upstream passes it only when linking, so every
#     C++ catch block is compiled out and the first page fault that Wine would handle,
#     e.g. a stack guard page, kills the emulator: "Uncaught WebAssembly.Exception")
#   - the source fixes in patches/<tag>/:
#       audio-callback-lock.patch  the "memory access out of bounds" crash once sound is on
#       main-loop-unwind.patch     with wasm exceptions, emscripten_set_main_loop's stack
#                                  unwind ran destructors and freed the open zip file systems
#       host-dir-refresh.patch     files the page imports into Documents show up in
#                                  Sketchpad's Open dialog without a reload
#
# Wine: Boxedwine's Wine 9.0 file system, stripped for the web the way the release strips
# its Wine 11 one (tools/strip_fs.py). Under Wine 11 Sketchpad's main window is created
# half-way (MFC "Debug Assertion Failed ... wincore.cpp Line: 744", then "SketchMouseUpdate()
# doesn't know what to do with tool0" and no toolbox); under Wine 9.0 it starts normally.
#
#   ./build.sh            -> dist/ (serve it over http(s))
#
# Options (environment variables):
#   BOXEDWINE_VERSION=26R1    Boxedwine release: source tag <version>.0 (its web Wine 11 file
#                             system is the template for stripping the Wine 9.0 one)
#   WINE_FS_URL=https://boxedwine.org/v2/5/TinyCore15Wine9.0.zip   full Boxedwine Wine file system
#   EMSDK_VERSION=5.0.6       emscripten used to compile (the one the 26R1 release was built with)
#   EMSDK_DIR=cache/emsdk     reuse an existing emsdk checkout instead of installing one
#   MAX_MEMORY_MB=2048        heap growth limit (512..4096; above 2048 costs some speed)
#   JOBS=<cpu count>          parallel compile jobs
#   GSP_URL=https://gsptest.scratchconsortium.com/downloads/GSP_W3062.zip
#                             Sketchpad Windows field-test zip (see https://gsptest.scratchconsortium.com/download.html)
#   GSP_ZIP=/path/GSP_W3062.zip   use a local copy instead of downloading
#
# Needs: bash, git, make, curl, unzip, zip, python3.
# First run downloads emsdk (~1 GB on disk) and compiles Boxedwine (10-30 minutes);
# later runs reuse both from cache/.
set -euo pipefail

BOXEDWINE_VERSION="${BOXEDWINE_VERSION:-26R1}"
BOXEDWINE_TAG="${BOXEDWINE_TAG:-$BOXEDWINE_VERSION.0}"
EMSDK_VERSION="${EMSDK_VERSION:-5.0.6}"
MAX_MEMORY_MB="${MAX_MEMORY_MB:-2048}"
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)}"
GSP_URL="${GSP_URL:-https://gsptest.scratchconsortium.com/downloads/GSP_W3062.zip}"
GSP_ZIP="${GSP_ZIP:-}"

HERE="$(cd "$(dirname "$0")" && pwd)"
CACHE="$HERE/cache"   # downloads, emsdk, Boxedwine source and objects; reused between runs
WORK="$HERE/work"     # scratch, rebuilt every run
OUT="$HERE/dist"      # the website
WEB="$HERE/web"       # index.html, shell.js, coi-serviceworker.js
EMSDK_DIR="${EMSDK_DIR:-$CACHE/emsdk}"

BW_GIT="https://github.com/danoon2/Boxedwine.git"
EMSDK_GIT="https://github.com/emscripten-core/emsdk.git"
# Only the web Wine 11 file system (Wine11/boxedwine.zip) is taken from the release, as the
# list of what a web file system keeps.
BW_RELEASE_URL="https://github.com/danoon2/Boxedwine/releases/download/$BOXEDWINE_TAG/Boxedwine${BOXEDWINE_VERSION}Web.zip"
# What the Boxedwine desktop app downloads for "Wine 9.0".
WINE_FS_URL="${WINE_FS_URL:-https://boxedwine.org/v2/5/TinyCore15Wine9.0.zip}"
# Kept on top of what the web file system has (see tools/strip_fs.py):
WINE_KEEP=(
    --keep opt/wine/bin/wine-preloader                  # Wine 9's loader wants it next to bin/wine
    --keep opt/wine/lib/wine/i386-windows/usp10.dll     # imported by Sketchpad (PE-only module)
    --keep-module oledlg.dll.so                         # imported by Sketchpad (OLE object dialogs)
    --keep-module glu32.dll.so                          # imported by Sketchpad
    --keep-module d3d9.dll.so                           # delay-loaded by Sketchpad (its DX drawing path)
    --keep-module windowscodecs.dll.so                  # image loading (gdiplus -> WIC)
)
APP_DIR="home/username/.wine/drive_c/GSP"   # C:\GSP inside Wine
APP_EXE="Sketchpad.exe"                     # the release's GSP_W<build>_R1.exe, renamed

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

for tool in git make curl unzip zip python3; do
    command -v "$tool" >/dev/null || die "missing '$tool'"
done
[ -f "$WEB/index.html" ] && [ -f "$WEB/shell.js" ] || die "web/index.html and web/shell.js must be next to build.sh"
[[ "$MAX_MEMORY_MB" =~ ^[0-9]+$ ]] && [ "$MAX_MEMORY_MB" -ge 512 ] && [ "$MAX_MEMORY_MB" -le 4096 ] \
    || die "MAX_MEMORY_MB must be between 512 and 4096"

mkdir -p "$CACHE"
rm -rf "$WORK" "$OUT"
mkdir -p "$WORK" "$OUT"

# fetch URL FILE: download once into the cache.
fetch() {
    if [ -s "$CACHE/$2" ]; then
        echo "cached: $2"
    else
        echo "downloading: $1"
        curl -fL --retry 3 -o "$CACHE/$2.part" "$1"
        mv "$CACHE/$2.part" "$CACHE/$2"
    fi
}

# zip_ok ZIP: the archive tests clean. unzip exits 1 for warnings only (the Wine file
# system has a few non-ASCII names it complains about), which is fine.
zip_ok() {
    local rc=0
    unzip -tq "$1" >/dev/null 2>&1 || rc=$?
    [ "$rc" -le 1 ]
}

# seed_port NAME ARCHIVE_URL SUBDIR GIT_URL GIT_TAG
# emscripten downloads its zlib and SDL2 ports as GitHub archive URLs, which some
# networks block while git clone works. Clone the same tag and put it where emscripten
# unpacks the archive, with the marker file it checks, so it never downloads. Harmless
# where the archive download would have worked.
seed_port() {
    local name="$1" url="$2" subdir="$3" git_url="$4" tag="$5"
    local ports dir
    ports="$(em-config CACHE)/ports"
    dir="$ports/$name"
    if [ -f "$dir/.emscripten_url" ] && [ "$(cat "$dir/.emscripten_url")" = "$url" ] && [ -d "$dir/$subdir" ]; then
        echo "port ready: $name"
        return
    fi
    echo "port from git: $name $tag"
    rm -rf "$dir" "$CACHE/ports-git/$name"
    mkdir -p "$dir" "$CACHE/ports-git"
    git clone -q -c advice.detachedHead=false --depth 1 --branch "$tag" "$git_url" "$CACHE/ports-git/$name"
    rm -rf "$CACHE/ports-git/$name/.git"
    mv "$CACHE/ports-git/$name" "$dir/$subdir"
    printf '%s\n' "$url" > "$dir/.emscripten_url"
}

# port_field PORT FIELD: a VERSION = '...' style value from emscripten's port definition.
port_field() {
    python3 - "$PORTS_PY/$1.py" "$2" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"^%s = f?'([^']*)'" % sys.argv[2], text, re.M)
print(m.group(1) if m else "")
PY
}

log "emscripten $EMSDK_VERSION"
[ -d "$EMSDK_DIR/.git" ] || git clone --depth 1 "$EMSDK_GIT" "$EMSDK_DIR"
"$EMSDK_DIR/emsdk" install "$EMSDK_VERSION"
"$EMSDK_DIR/emsdk" activate "$EMSDK_VERSION" >/dev/null
set +u
# shellcheck disable=SC1091
source "$EMSDK_DIR/emsdk_env.sh" >/dev/null 2>&1
set -u
emcc --version | head -n1 | grep -qF "$EMSDK_VERSION" || die "emcc is not version $EMSDK_VERSION"

log "emscripten ports (zlib, SDL2)"
PORTS_PY="$(em-config EMSCRIPTEN_ROOT)/tools/ports"   # emsdk_env.sh unsets EMSDK_DIR
ZLIB_VERSION="$(port_field zlib VERSION)"
SDL2_VERSION="$(port_field sdl2 VERSION)"
if grep -qF "madler/zlib/archive/refs/tags/v{VERSION}.tar.gz" "$PORTS_PY/zlib.py" && [ -n "$ZLIB_VERSION" ]; then
    seed_port zlib "https://github.com/madler/zlib/archive/refs/tags/v$ZLIB_VERSION.tar.gz" "zlib-$ZLIB_VERSION" \
        https://github.com/madler/zlib.git "v$ZLIB_VERSION"
else
    echo "zlib port layout not recognized; emscripten will download it"
fi
if grep -qF "libsdl-org/SDL/archive/{TAG}.zip" "$PORTS_PY/sdl2.py" && [ -n "$SDL2_VERSION" ]; then
    seed_port sdl2 "https://github.com/libsdl-org/SDL/archive/release-$SDL2_VERSION.zip" "SDL-release-$SDL2_VERSION" \
        https://github.com/libsdl-org/SDL.git "release-$SDL2_VERSION"
else
    echo "SDL2 port layout not recognized; emscripten will download it"
fi

log "Boxedwine $BOXEDWINE_TAG from source (multi-threaded, wasm exceptions, heap 512 MB growing to $MAX_MEMORY_MB MB)"
SRC="$CACHE/boxedwine-$BOXEDWINE_TAG"
[ -d "$SRC/.git" ] || git clone -c advice.detachedHead=false --depth 1 --branch "$BOXEDWINE_TAG" "$BW_GIT" "$SRC"
# Source fixes for this tag (patches/<tag>/*.patch), each applied once.
for patch in "$HERE/patches/$BOXEDWINE_TAG"/*.patch; do
    [ -e "$patch" ] || continue
    if git -C "$SRC" apply --reverse --check "$patch" 2>/dev/null; then
        echo "patch already applied: ${patch#"$HERE"/}"
    else
        git -C "$SRC" apply "$patch" || die "could not apply ${patch#"$HERE"/}"
        echo "patch applied: ${patch#"$HERE"/}"
    fi
done
# Same compile and link settings as upstream's multiThreaded target, plus wasm exceptions
# for the compile step and memory growth for the link step.
# The makefile's own -s TOTAL_MEMORY=536870912 becomes the initial heap size.
# -Wno-pthreads-mem-growth silences emcc's warning that JS heap access is slower with
# pthreads + growth; Boxedwine's emulation runs in wasm, which isn't affected.
BUILD_DIR="Build/MultiThreaded-grow-eh-em$EMSDK_VERSION"
rm -f "$SRC/project/emscripten/$BUILD_DIR"/boxedwine.{html,js,wasm,worker.js}   # always relink
make -C "$SRC/project/emscripten" -j"$JOBS" \
    BUILD_DIR="$BUILD_DIR" \
    SHELL_FILE=shell.html \
    EXTRA_CPP_FLAGS="-DBOXEDWINE_MULTI_THREADED -pthread -fwasm-exceptions" \
    EXTRA_LD_FLAGS="-pthread -sPTHREAD_POOL_SIZE=32 -sALLOW_MEMORY_GROWTH -sMAXIMUM_MEMORY=$((MAX_MEMORY_MB * 1024 * 1024)) -Wno-pthreads-mem-growth"
BUILT="$SRC/project/emscripten/$BUILD_DIR"
[ -f "$BUILT/boxedwine.js" ] && [ -f "$BUILT/boxedwine.wasm" ] || die "build finished without boxedwine.js/boxedwine.wasm"
cp "$BUILT/boxedwine.js" "$BUILT/boxedwine.wasm" "$OUT/"
[ ! -f "$BUILT/boxedwine.worker.js" ] || cp "$BUILT/boxedwine.worker.js" "$OUT/"   # older emscripten only
cp "$SRC/license.txt" "$OUT/license.txt"

log "Web Wine 11 file system from the Boxedwine $BOXEDWINE_VERSION release (the strip template)"
fetch "$BW_RELEASE_URL" "Boxedwine${BOXEDWINE_VERSION}Web.zip"
unzip -p "$CACHE/Boxedwine${BOXEDWINE_VERSION}Web.zip" Wine11/boxedwine.zip > "$WORK/web-wine11.zip"
[ -s "$WORK/web-wine11.zip" ] || die "Wine11/boxedwine.zip not found in the release zip"

WINE_FS_NAME="$(basename "$WINE_FS_URL")"
log "Wine file system $WINE_FS_NAME, stripped for the web"
fetch "$WINE_FS_URL" "$WINE_FS_NAME"
zip_ok "$CACHE/$WINE_FS_NAME" || { rm -f "$CACHE/$WINE_FS_NAME"; die "$WINE_FS_NAME is corrupt, run again"; }
python3 -I "$HERE/tools/strip_fs.py" "$CACHE/$WINE_FS_NAME" "$WORK/web-wine11.zip" "${WINE_KEEP[@]}" > "$WORK/strip.txt"
cp "$CACHE/$WINE_FS_NAME" "$OUT/boxedwine.zip"
zip -q -d -nw "$OUT/boxedwine.zip" -@ < "$WORK/strip.txt"
for need in bin/wine.link opt/wine/bin/wine opt/wine/bin/wine-preloader opt/wine/bin/wineserver \
            opt/wine/lib/wine/i386-unix/ntdll.so opt/wine/lib/wine/i386-unix/winex11.drv.so \
            home/username/.wine/system.reg; do
    unzip -l "$OUT/boxedwine.zip" "$need" >/dev/null || die "stripped file system lacks $need"
done
for gone in lib/libGL.so.1 lib/libvulkan.so.1; do   # the web build has no OpenGL/Vulkan: they'd kpanic
    ! unzip -l "$OUT/boxedwine.zip" "$gone" >/dev/null 2>&1 || die "stripped file system still has $gone"
done
echo "removed $(wc -l < "$WORK/strip.txt") entries: $(du -h "$CACHE/$WINE_FS_NAME" | cut -f1) -> $(du -h "$OUT/boxedwine.zip" | cut -f1)"
STAGE="$WORK/stage"
mkdir -p "$STAGE"

log "The Geometer's Sketchpad (Windows)"
GSP_NAME="$(basename "${GSP_ZIP:-$GSP_URL}")"
if [ -n "$GSP_ZIP" ]; then
    cp "$GSP_ZIP" "$CACHE/$GSP_NAME"
else
    fetch "$GSP_URL" "$GSP_NAME"
fi
zip_ok "$CACHE/$GSP_NAME" || { rm -f "$CACHE/$GSP_NAME"; die "$GSP_NAME is corrupt, run again"; }
mkdir -p "$WORK/gsp"
unzip -q "$CACHE/$GSP_NAME" -d "$WORK/gsp"
GSP_EXE="$(find "$WORK/gsp" -maxdepth 3 -type f -iname 'GSP*.exe' ! -path '*/__MACOSX/*' | head -n1)"
[ -n "$GSP_EXE" ] || die "no GSP*.exe found in $GSP_NAME (is it the Windows release?)"
GSP_DIR="$(dirname "$GSP_EXE")"
echo "found: ${GSP_EXE#"$WORK/gsp/"}"

log "Assembling C:\\GSP"
mkdir -p "$STAGE/$APP_DIR"
cp -a "$GSP_DIR/." "$STAGE/$APP_DIR/"
chmod -R u+w "$STAGE/$APP_DIR"
mv "$STAGE/$APP_DIR/$(basename "$GSP_EXE")" "$STAGE/$APP_DIR/$APP_EXE"
find "$STAGE/$APP_DIR" \( -name .DS_Store -o -name '._*' \) -delete

log "Packing gsp.zip"
(cd "$STAGE" && zip -q -r -X -n .gif:.jpg:.png:.zip "$OUT/gsp.zip" home)

log "Web assets"
cp "$WEB"/index.html "$WEB"/shell.js "$WEB"/coi-serviceworker.js "$OUT/"

rm -rf "$WORK"
log "Done: $OUT"
ls -lh "$OUT"
cat <<EOF

Test locally:  cd dist && python3 -m http.server 8000   then open http://localhost:8000/
Publish:       upload the contents of dist/ to any static host (GitHub Pages works,
               coi-serviceworker.js supplies the headers the multi-threaded build needs).
EOF
