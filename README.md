# The Geometer's Sketchpad in the browser (Boxedwine)

Runs the Windows field-test release of The Geometer's Sketchpad 5.11
(<https://gsptest.scratchconsortium.com/>) in a web page on
[Boxedwine](https://github.com/danoon2/Boxedwine)'s multi-threaded WebAssembly build.

```
./build.sh                                   # -> dist/
cd dist && python3 -m http.server 8000       # open http://localhost:8000/
```

`dist/` is a static site: upload it to any web host (GitHub Pages works). The
multi-threaded build needs a cross-origin isolated page; `coi-serviceworker.js` takes
care of that on hosts that can't send the COOP/COEP headers (the page reloads once).

## Files

| | |
|---|---|
| `build.sh` | builds `dist/`: compiles Boxedwine, strips the Wine file system, packs Sketchpad |
| `patches/26R1.0/` | Boxedwine source fixes (below) |
| `tools/strip_fs.py` | picks what a web file system keeps from a full Boxedwine one |
| `web/index.html`, `web/shell.js` | the page and launcher |
| `web/coi-serviceworker.js` | cross-origin isolation for static hosts |

`dist/` ends up with `boxedwine.js` + `boxedwine.wasm` (~3 MB), `boxedwine.zip`
(Wine, ~48 MB) and `gsp.zip` (Sketchpad, ~55 MB).

## Using it

- The first start downloads ~105 MB, then it takes a minute or two until Sketchpad's
  window appears. Later starts in the same browser reuse the browser cache.
- Sketchpad starts maximized in a 1024×768 screen. `?resolution=1280x800` picks another
  size; `?sound=false` mutes.
- Files: Sketchpad's Open/Save dialogs start in `Documents`
  (`C:\users\username\Documents`). **Import sketches...** (or dropping files on the page)
  copies files from your computer into it; they show up in File > Open right away.
  **List Documents** lists what's saved there, each with a download link.
- Everything Sketchpad writes is kept in the browser (IndexedDB) and is there next time.

## What the build changes, and why

Boxedwine is compiled from the 26R1.0 source like upstream's `make multiThreaded`, plus:

- **Memory growth** (512 MB growing to 2 GB) instead of a fixed 512 MB heap.
- **`-fwasm-exceptions` when compiling.** Upstream passes it only when linking, so every
  C++ `catch` is compiled out. Boxedwine delivers guest page faults to Wine as C++
  exceptions; without catch blocks the first fault Wine would handle (Sketchpad hits one
  at startup) ends the emulator with `Uncaught [object WebAssembly.Exception]`.
- `patches/26R1.0/main-loop-unwind.patch`: with exceptions on, the stack unwind of
  `emscripten_set_main_loop(..., 1)` runs destructors, which freed the open zip file
  systems right after launch (a null mutex in `FsZipOpenNode::readNative` then corrupted
  memory, reported as "Stack overflow! Stack cookie has been overwritten"). They are kept
  in statics on the web build.
- `patches/26R1.0/host-dir-refresh.patch`: Boxedwine lists a host directory only once, so
  files the page writes into `Documents` while Sketchpad runs never appeared. A directory
  listing now adds host entries it hasn't seen (only when the directory's mtime changed).
- `patches/26R1.0/audio-callback-lock.patch` (from elona-boxedwine-web): the
  "memory access out of bounds" crash once sound plays.

**Wine 9.0 instead of 11.** Under the release's Wine 11 file system Sketchpad's main window
is only half created: "Debug Assertion Failed ... wincore.cpp Line: 744", then
"SketchMouseUpdate() doesn't know what to do with tool0" and no toolbox. Under Wine 9.0
(Boxedwine's own build, and stock Wine 9.0 on Linux) it starts normally. Boxedwine only
publishes the full desktop Wine 9.0 file system, which includes `libGL.so.1`, and that
crashes the web build (it has no OpenGL). `tools/strip_fs.py` keeps from it exactly the paths
the web Wine 11 file system keeps (same TinyCore base), plus:

- the unix halves (`X.so`) of kept Wine 9 modules, and `opt/wine/bin/wine-preloader`
- modules Sketchpad needs that the web set lacks: `oledlg`, `glu32`, `d3d9` (its "DX"
  drawing path), `windowscodecs` (GDI+ images), `usp10`

This drops `wineboot` too, so there is no slow prefix update on first start, as in the web
release.

## Options

Environment variables for `build.sh`:

| | |
|---|---|
| `GSP_ZIP=/path/GSP_W3062.zip` | use a downloaded Sketchpad zip instead of `GSP_URL` |
| `GSP_URL=...` | Windows field-test zip (default: build 3062 from the download page) |
| `WINE_FS_URL=...` | full Boxedwine Wine file system (default: Wine 9.0) |
| `EMSDK_DIR=...` | reuse an existing emsdk checkout |
| `MAX_MEMORY_MB=2048` | heap growth limit |
| `JOBS=n` | parallel compile jobs |

Needs bash, git, make, curl, unzip, zip and python3. The first run installs emsdk 5.0.6
(~1 GB) and compiles Boxedwine (10-30 min); later runs reuse `cache/`. emscripten's zlib
and SDL2 ports are cloned with git (some networks block GitHub archive downloads).

## Notes

- This is a field-test (beta) build of Sketchpad, with the beta watermark and debug
  checks. Report Sketchpad bugs to the address on the download page, not upstream.
- Sketchpad is proprietary software. `dist/` contains it, so check the download page's terms
  before publishing a copy for others; the build itself downloads it from the official page.
- No OpenGL in the web build; Sketchpad doesn't need it.

Credits: The Geometer's Sketchpad by KCP Technologies; Boxedwine
([GPL-2.0](https://github.com/danoon2/Boxedwine/blob/master/license.txt)); Wine;
coi-serviceworker (MIT).
