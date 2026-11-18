// Launcher for The Geometer's Sketchpad on the Boxedwine multi-threaded web build.
var ROOT = "/root";                                   // Boxedwine's writable layer, kept in IndexedDB
var ZIPS = ["boxedwine.zip", "gsp.zip"];              // Wine root file system, then Sketchpad
var EXE = "C:\\GSP\\Sketchpad.exe";
var WORK_DIR = "/home/username/.wine/drive_c/users/username/Documents";   // C:\users\username\Documents
var DOCS = ROOT + WORK_DIR;      // the same folder in Boxedwine's writable layer
var RESOLUTION = "1024x768";

var statusEl = document.getElementById("status");
var filesStatusEl = document.getElementById("filesStatus");
function setStatus(text) { statusEl.textContent = text; }
function setFilesStatus(text) { filesStatusEl.textContent = text; }
function param(name) { return new URLSearchParams(location.search).get(name); }

async function download(name) {
    var res = await fetch(name);
    if (!res.ok) throw new Error(name + ": HTTP " + res.status);
    var total = Number(res.headers.get("Content-Length")) || 0;
    var reader = res.body.getReader(), chunks = [], got = 0;
    for (;;) {
        var part = await reader.read();
        if (part.done) break;
        chunks.push(part.value);
        got += part.value.length;
        setStatus("Downloading " + name + ": " + (got >> 20) + (total ? " / " + (total >> 20) : "") + " MB");
    }
    var data = new Uint8Array(got), offset = 0;
    for (var chunk of chunks) { data.set(chunk, offset); offset += chunk.length; }
    return data;
}

function emulatorArgs() {
    var args = ["-root", ROOT];
    for (var zip of ZIPS) args.push("-zip", zip);
    if (param("sound") === "false") args.push("-nosound");
    args.push("-resolution", param("resolution") || RESOLUTION);
    if (param("winedebug")) args.push("-env", "WINEDEBUG=" + param("winedebug").replace(/ /g, "+"));  // e.g. ?winedebug=+seh
    // Start in Documents so Sketchpad's Open and Save dialogs default to it, and maximized.
    args.push("-w", WORK_DIR, "/bin/wine", "start", "/max", "/wait", EXE);
    return args;
}

// ---- Moving sketches between the browser and C:\users\username\Documents ----
// Boxedwine stores ':' and '@' in host file names as (_colon_) and (_at_).
function toHostName(name) { return name.replace(/[\\/:*?"<>|\x00-\x1f]/g, "_").replace(/@/g, "(_at_)"); }
function fromHostName(name) { return name.replace(/\(_at_\)/g, "@").replace(/\(_colon_\)/g, ":"); }

var fsReady = false, pendingImports = [];

function persist(callback) {
    FS.syncfs(false, function (err) {
        if (err) console.error("IndexedDB:", err);
        if (callback) callback(err);
    });
}

async function importFiles(fileList) {
    var files = Array.from(fileList || []);
    if (!files.length) return;
    if (!fsReady) {
        pendingImports.push.apply(pendingImports, files);
        setFilesStatus(files.length + " file(s) will be imported once Sketchpad's files are ready.");
        return;
    }
    FS.mkdirTree(DOCS);
    var names = [];
    for (var file of files) {
        var name = toHostName(file.name);
        FS.writeFile(DOCS + "/" + name, new Uint8Array(await file.arrayBuffer()));
        names.push(fromHostName(name));
    }
    persist();
    listDocuments();
    setFilesStatus("Imported to Documents: " + names.join(", "));
}

function listDocuments() {
    var list = document.getElementById("docs");
    list.textContent = "";
    if (!fsReady) { setFilesStatus("Sketchpad's files are not loaded yet."); return; }
    var entries = [];
    try {
        entries = FS.readdir(DOCS).filter(function (name) {
            return name !== "." && name !== ".." && !/\.(link|user\.DOSATTRIB)$/.test(name) &&
                FS.isFile(FS.stat(DOCS + "/" + name).mode);
        });
    } catch (e) { /* Documents not written yet */ }
    if (!entries.length) {
        setFilesStatus("Nothing saved in Documents yet.");
        return;
    }
    setFilesStatus("");
    entries.sort();
    for (var hostName of entries) {
        var li = document.createElement("li");
        var a = document.createElement("a");
        var name = fromHostName(hostName).replace(/\.mixed$/, "");
        a.textContent = name;
        a.href = "#";
        a.onclick = (function (hostName, name) {
            return function (event) {
                event.preventDefault();
                var data = FS.readFile(DOCS + "/" + hostName);
                var url = URL.createObjectURL(new Blob([data], { type: "application/octet-stream" }));
                var link = document.createElement("a");
                link.href = url;
                link.download = name;
                document.body.appendChild(link);
                link.click();
                link.remove();
                setTimeout(function () { URL.revokeObjectURL(url); }, 10000);
            };
        })(hostName, name);
        li.appendChild(a);
        list.appendChild(li);
    }
}

document.getElementById("import").addEventListener("change", function (event) {
    importFiles(event.target.files);
    event.target.value = "";
});
document.getElementById("refresh").addEventListener("click", listDocuments);
document.addEventListener("dragover", function (event) { event.preventDefault(); });
document.addEventListener("drop", function (event) {
    event.preventDefault();
    if (event.dataTransfer) importFiles(event.dataTransfer.files);
});
// ---------------------------------------------------------------------------------

var Module = {
    arguments: [],
    canvas: document.getElementById("canvas"),
    print: function (text) { console.log(text); },
    printErr: function (text) { console.error(text); },
    setStatus: function (text) { if (text) setStatus(text); },
    preRun: [function () {
        Module.addRunDependency("files");
        FS.mkdir(ROOT);
        FS.mount(IDBFS, { autoPersist: true }, ROOT);
        FS.syncfs(true, async function (err) {
            if (err) console.error("IndexedDB:", err);
            try {
                for (var zip of ZIPS) FS.writeFile("/" + zip, await download(zip));
            } catch (e) {
                setStatus("Error: " + e.message);
                return;
            }
            fsReady = true;
            if (pendingImports.length) await importFiles(pendingImports.splice(0));
            Module.arguments.push.apply(Module.arguments, emulatorArgs());
            setStatus("Starting Wine and Sketchpad... (the first start takes a few minutes)");
            Module.removeRunDependency("files");
        });
    }]
};

window.onerror = function (msg) { setStatus("Error: " + msg); };
// Save anything still in memory when the tab goes away.
window.addEventListener("pagehide", function () { if (fsReady) persist(); });

// The multi-threaded build needs SharedArrayBuffer, i.e. a cross-origin isolated page.
// coi-serviceworker.js provides that on hosts that can't send COOP/COEP headers.
if (window.crossOriginIsolated) {
    sessionStorage.removeItem("coiRetry");
    var script = document.createElement("script");
    script.src = "boxedwine.js";
    document.body.appendChild(script);
} else if (location.protocol === "file:") {
    setStatus("Serve this folder over http(s); it does not work from file://");
} else if (!("serviceWorker" in navigator)) {
    setStatus("This browser can't run the multi-threaded build here (no service workers, e.g. private mode).");
} else {
    setStatus("Waiting for cross-origin isolation (the page reloads once)...");
    navigator.serviceWorker.ready.then(function () {
        // Reload if the page loaded before the service worker took control.
        var tries = Number(sessionStorage.getItem("coiRetry")) || 0;
        if (tries < 3) {
            sessionStorage.setItem("coiRetry", tries + 1);
            location.reload();
        } else {
            setStatus("Cross-origin isolation failed; reload the page or try another browser.");
        }
    });
}
