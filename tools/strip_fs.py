"""Print the entries of a full Boxedwine file system zip that a web build doesn't need.

    python3 strip_fs.py FULL.zip WEB.zip [--keep PATH]... [--keep-module NAME]...

A path is kept when the stripped web file system (WEB.zip, from a Boxedwine web
release) has the same path: both are the same TinyCore 15 base, so this drops what
upstream drops for the web (libGL/libvulkan, which the web build can't serve, compilers,
headers, PE copies of the builtin DLLs, wineboot, ...). On top of that:
  --keep PATH          keep this exact path
  --keep-module NAME   keep opt/wine/lib/wine/i386-unix/NAME (a builtin DLL the app needs)
and a unix library i386-unix/X.so is kept whenever a kept builtin X.*.so needs it
(Wine 9 still ships those separately).
The names to delete go to stdout, one per line, for `zip -d -nw FULL.zip -@`.
"""
import sys
import zipfile

UNIX = "opt/wine/lib/wine/i386-unix/"


def main(argv):
    full, web = argv[0], argv[1]
    keep_paths, keep_modules = set(), set()
    args = argv[2:]
    while args:
        flag, value, args = args[0], args[1], args[2:]
        if flag == "--keep":
            keep_paths.add(value)
        elif flag == "--keep-module":
            keep_modules.add(value)
        else:
            sys.exit("unknown option " + flag)

    names = zipfile.ZipFile(full).namelist()
    web_names = set(zipfile.ZipFile(web).namelist())
    kept = {n for n in names
            if n in web_names or n in keep_paths
            or (n.startswith(UNIX) and n[len(UNIX):] in keep_modules)}
    # unix side libraries (X.so) of kept builtin modules (X.dll.so, X.sys.so, ...)
    stems = {n[len(UNIX):].split(".", 1)[0] for n in kept
             if n.startswith(UNIX) and n.count(".") >= 2 and n.endswith(".so")}
    for n in names:
        base = n[len(UNIX):] if n.startswith(UNIX) else None
        if base and base.endswith(".so") and base.count(".") == 1 and base[:-3] in stems:
            kept.add(n)
    for n in names:
        # Info-ZIP spells non-ASCII names differently from Python, so `zip -d` couldn't
        # match them anyway (two CA certificate files in the Wine 9.0 file system); they stay.
        if n not in kept and n.isascii():
            print(n)


if __name__ == "__main__":
    main(sys.argv[1:])
