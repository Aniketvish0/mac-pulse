#!/usr/bin/env python3
import argparse
import ctypes
import json
import os
import platform
import plistlib
import re
import shutil
import subprocess
import threading
import time
import webbrowser
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

TEMPLATE = Path(__file__).resolve().parent / "dashboard.html"
DATA_SLOT = "/*__MACPULSE_DATA__*/null"
ME = os.environ.get("USER") or Path.home().name
MB = 1024**2

SYSTEM_PREFIXES = ("/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/", "/private/", "/Library/PrivilegedHelperTools/")
CATEGORY_KEYWORDS = [
    ("browsers", ("brave", "chrome", "chromium", "safari", "firefox", "arc", "dia", "edge", "opera", "vivaldi", "orion", "zen")),
    ("ai", ("claude", "chatgpt", "ollama", "lm studio", "llama", "codex", "copilot", "perplexity", "gemini", "wispr", "superwhisper", "mlx")),
    ("comms", ("slack", "discord", "zoom", "teams", "messages", "mail", "telegram", "whatsapp", "signal", "facetime", "superhuman", "spark", "linear", "notion", "granola")),
    ("media", ("spotify", "music", "photos", "figma", "preview", "quicktime", "vlc", "iina", "sketch", "photoshop", "final cut", "logic", "obs", "podcasts", "tv", "canva")),
    ("dev", ("code", "cursor", "xcode", "t3", "zed", "iterm", "terminal", "ghostty", "warp", "wezterm", "alacritty", "kitty", "docker", "orbstack",
             "postman", "android studio", "intellij", "pycharm", "webstorm", "tower", "fork", "github", "simulator", "node", "python", "bun", "deno",
             "ruby", "java", "go", "cargo", "rustc", "rust-analyzer", "tsserver", "clangd", "git", "esbuild", "vite", "npm", "pnpm", "yarn", "postgres",
             "redis", "mongod", "mysqld", "qemu", "gopls", "sourcekit-lsp", "turbo", "next-server", "uv", "tmux", "zsh", "bash", "ssh")),
]
DEV_RUNTIMES = {"node", "python", "python3", "bun", "deno", "ruby", "java", "esbuild", "vite", "next-server", "turbo", "uv", "go"}


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True, errors="replace").stdout


def sysctl(name):
    return run("sysctl", "-n", name).strip()


def categorize(name):
    flat = name.lower()
    for cat, keys in CATEGORY_KEYWORDS:
        if any(re.search(rf"(^|[^a-z]){re.escape(key)}([^a-z]|$)", flat) for key in keys):
            return cat
    return "other"


class CpuTicks:
    def __init__(self):
        lib = ctypes.CDLL("/usr/lib/libSystem.dylib")
        lib.mach_host_self.restype = ctypes.c_uint
        lib.host_processor_info.argtypes = [
            ctypes.c_uint, ctypes.c_int, ctypes.POINTER(ctypes.c_uint),
            ctypes.POINTER(ctypes.POINTER(ctypes.c_uint)), ctypes.POINTER(ctypes.c_uint),
        ]
        lib.vm_deallocate.argtypes = [ctypes.c_uint, ctypes.c_size_t, ctypes.c_size_t]
        self.lib = lib
        self.host = lib.mach_host_self()
        self.task = ctypes.c_uint.in_dll(lib, "mach_task_self_").value

    def read(self):
        count, size = ctypes.c_uint(), ctypes.c_uint()
        info = ctypes.POINTER(ctypes.c_uint)()
        if self.lib.host_processor_info(self.host, 2, ctypes.byref(count), ctypes.byref(info), ctypes.byref(size)) != 0:
            return []
        ticks = [tuple(info[core * 4 + state] for state in range(4)) for core in range(count.value)]
        self.lib.vm_deallocate(self.task, ctypes.cast(info, ctypes.c_void_p).value, size.value * 4)
        return ticks


def parse_cputime(text):
    secs = 0.0
    for part in text.replace("-", ":").split(":"):
        secs = secs * 60 + float(part or 0)
    return secs


def parse_size(text):
    m = re.match(r"([\d.]+)([BKMGT])", text)
    if not m:
        return 0
    return int(float(m.group(1)) * {"B": 1, "K": 1024, "M": MB, "G": 1024**3, "T": 1024**4}[m.group(2)])


def read_processes():
    rows = {}
    for line in run("ps", "-axo", "pid=,ppid=,rss=,time=,user=,comm=").splitlines():
        parts = line.split(None, 5)
        if len(parts) < 6:
            continue
        pid, ppid, rss, cputime, user, comm = parts
        rows[int(pid)] = {"pid": int(pid), "ppid": int(ppid), "rss": int(rss) * 1024,
                          "cputime": parse_cputime(cputime), "user": user, "path": comm, "script": None}
    for line in run("ps", "-axo", "pid=,args=").splitlines():
        parts = line.split()
        if len(parts) > 2 and int(parts[0]) in rows:
            rows[int(parts[0])]["script"] = script_name(parts[2:])
    return rows


def script_name(args):
    for arg in args:
        if not arg.startswith("-") and re.search(r"\.(m?js|cjs|ts|py|rb)$", arg):
            return os.path.basename(arg)
    return None


def read_top():
    out = run("top", "-l", "1", "-n", "5000", "-stats", "pid,mem")
    footprints = {int(m.group(1)): parse_size(m.group(2)) for m in re.finditer(r"^\s*(\d+)\s+([\d.]+[BKMGT])", out, re.M)}
    threads = re.search(r"(\d+) threads", out)
    return footprints, int(threads.group(1)) if threads else 0


def read_memory():
    out = run("vm_stat")
    page = int(re.search(r"page size of (\d+)", out).group(1))
    pages = {k.strip('"'): int(v) * page for k, v in re.findall(r'^("?[^:\n]+"?):\s+(\d+)\.', out, re.M)}
    total = int(sysctl("hw.memsize"))
    app = pages["Anonymous pages"] - pages["Pages purgeable"]
    wired = pages["Pages wired down"]
    compressed = pages["Pages occupied by compressor"]
    cached = pages["File-backed pages"] + pages["Pages purgeable"]
    used = app + wired + compressed
    swap = re.findall(r"(total|used) = ([\d.]+)M", sysctl("vm.swapusage"))
    swap = {k: float(v) * MB for k, v in swap}
    level = sysctl("kern.memorystatus_vm_pressure_level")
    return {
        "total": total, "used": used, "app": app, "wired": wired, "compressed": compressed,
        "cached": cached, "free": max(total - used - cached, 0),
        "swapUsed": swap.get("used", 0), "swapTotal": swap.get("total", 0),
        "pressure": {"1": "normal", "2": "warning", "4": "critical"}.get(level, "normal"),
    }


def read_gpu():
    out = run("ioreg", "-r", "-d", "1", "-c", "IOAccelerator")
    util = re.search(r'"Device Utilization %"=(\d+)', out)
    if not util:
        return None
    in_use = re.search(r'"In use system memory"=(\d+)', out)
    alloc = re.search(r'"Alloc system memory"=(\d+)', out)
    return {"util": int(util.group(1)), "inUse": int(in_use.group(1)) if in_use else 0,
            "alloc": int(alloc.group(1)) if alloc else 0}


def read_disk_bytes():
    out = run("ioreg", "-c", "IOBlockStorageDriver", "-r", "-k", "Statistics")
    read = sum(map(int, re.findall(r'"Bytes \(Read\)"=(\d+)', out)))
    write = sum(map(int, re.findall(r'"Bytes \(Write\)"=(\d+)', out)))
    return read, write


def read_net_bytes():
    rx = tx = 0
    for line in run("netstat", "-ib").splitlines():
        fields = line.split()
        if len(fields) >= 10 and fields[0].startswith("en") and "<Link#" in line:
            rx += int(fields[-5])
            tx += int(fields[-2])
    return rx, tx


def read_battery():
    out = run("ioreg", "-rn", "AppleSmartBattery")
    if "CurrentCapacity" not in out:
        return None

    def top(key):
        m = re.search(rf'^\s*\|?\s*"{key}" = (\S+)', out, re.M)
        return m.group(1) if m else None

    def nested(key):
        m = re.search(rf'"{key}"=(\d+)', out)
        return int(m.group(1)) if m else None

    amps = int(top("InstantAmperage") or top("Amperage") or 0)
    amps = amps - 2**64 if amps >= 2**63 else amps
    volts = int(top("Voltage") or 0)
    full, design = nested("FullChargeCapacity"), nested("DesignCapacity")
    remaining = int(top("TimeRemaining") or 0)
    return {
        "percent": int(top("CurrentCapacity") or 0),
        "charging": top("IsCharging") == "Yes",
        "plugged": top("ExternalConnected") == "Yes",
        "minutesLeft": remaining if 0 < remaining < 6000 else None,
        "cycles": int(top("CycleCount") or 0),
        "health": round(full / design * 100) if full and design else None,
        "fullMah": full, "designMah": design,
        "watts": round(abs(amps) * volts / 1e6, 1),
    }


def read_thermal():
    out = run("pmset", "-g", "therm")
    limit = re.search(r"CPU_Speed_Limit\s*=\s*(\d+)", out)
    if limit and int(limit.group(1)) < 100:
        return f"throttled to {limit.group(1)}%"
    return "no throttling"


def read_host():
    perf = []
    for level in range(4):
        name = sysctl(f"hw.perflevel{level}.name")
        if not name:
            break
        perf.append({"name": name, "count": int(sysctl(f"hw.perflevel{level}.logicalcpu") or 0)})
    return {
        "chip": sysctl("machdep.cpu.brand_string"),
        "model": sysctl("hw.model"),
        "cores": int(sysctl("hw.ncpu")),
        "perf": perf,
        "os": platform.mac_ver()[0],
        "name": platform.node().split(".")[0],
        "boot": int(re.search(r"sec = (\d+)", sysctl("kern.boottime")).group(1)),
    }


_bundles = {}


def bundle_info(bundle):
    if bundle not in _bundles:
        try:
            with open(os.path.join(bundle, "Contents", "Info.plist"), "rb") as fh:
                _bundles[bundle] = plistlib.load(fh).get("CFBundleIdentifier")
        except (OSError, plistlib.InvalidFileException, ValueError):
            _bundles[bundle] = None
    return _bundles[bundle]


def classify(proc):
    path = proc["path"]
    bundle = re.match(r"(.*?/([^/]+)\.app)(/|$)", path)
    base = os.path.basename(path).strip("()") or path
    if bundle:
        name, bundle_path = bundle.group(2), bundle.group(1)
        user_app = "/Applications/" in bundle_path and proc["user"] == ME
        system = not user_app and (proc["user"] != ME or bundle_path.startswith(SYSTEM_PREFIXES))
        return {"id": f"app:{bundle_path}", "name": name, "kind": "app", "bundle": bundle_path, "system": system}
    system = proc["user"] != ME or path.startswith(SYSTEM_PREFIXES)
    return {"id": f"cmd:{base}:{'sys' if system else 'user'}", "name": base, "kind": "cmd", "bundle": None, "system": system}


def short_name(proc_name, app_name):
    trimmed = proc_name.replace(app_name, "").strip(" -")
    return trimmed or proc_name


class Sampler:
    def __init__(self):
        self.ticks = CpuTicks()
        self.host = read_host()
        self.prev = None
        self.history = deque(maxlen=150)
        self.latest = None
        self.lock = threading.Lock()

    def sample(self):
        now = time.time()
        with ThreadPoolExecutor(max_workers=8) as pool:
            jobs = {
                "procs": pool.submit(read_processes), "top": pool.submit(read_top),
                "mem": pool.submit(read_memory), "gpu": pool.submit(read_gpu),
                "disk": pool.submit(read_disk_bytes), "net": pool.submit(read_net_bytes),
                "battery": pool.submit(read_battery), "thermal": pool.submit(read_thermal),
            }
            r = {k: v.result() for k, v in jobs.items()}
        ticks = self.ticks.read()
        prev = self.prev
        dt = now - prev["t"] if prev else 0

        cores, agg = [], [0, 0, 0, 0]
        for i, cur in enumerate(ticks):
            old = prev["ticks"][i] if prev and i < len(prev["ticks"]) else (0, 0, 0, 0)
            d = [max(c - o, 0) for c, o in zip(cur, old)]
            agg = [a + b for a, b in zip(agg, d)]
            span = sum(d) or 1
            cores.append(round((d[0] + d[1] + d[3]) / span * 100, 1))
        span = sum(agg) or 1
        cpu = {
            "total": round((agg[0] + agg[1] + agg[3]) / span * 100, 1),
            "user": round((agg[0] + agg[3]) / span * 100, 1),
            "sys": round(agg[1] / span * 100, 1),
            "cores": cores,
            "load": [round(x, 2) for x in os.getloadavg()],
            "thermal": r["thermal"],
        }

        def rate(key, idx):
            return max(r[key][idx] - prev[key][idx], 0) / dt if prev and dt else 0

        disk_usage = shutil.disk_usage("/System/Volumes/Data")
        footprints, threads = r["top"]
        procs = r["procs"]
        prev_cpu = prev["cputime"] if prev else {}
        for p in procs.values():
            p["mem"] = footprints.get(p["pid"], p["rss"])
            last = prev_cpu.get(p["pid"])
            p["cpu"] = round(max(p["cputime"] - last, 0) / dt * 100, 1) if last is not None and dt else 0.0

        groups = self.build_groups(procs)
        data = {
            "ts": now, "live": True, "host": self.host,
            "cpu": cpu, "mem": r["mem"], "gpu": r["gpu"], "battery": r["battery"],
            "disk": {"total": disk_usage.total, "free": disk_usage.free,
                     "readRate": rate("disk", 0), "writeRate": rate("disk", 1)},
            "net": {"inRate": rate("net", 0), "outRate": rate("net", 1),
                    "inTotal": r["net"][0], "outTotal": r["net"][1]},
            "procs": {"count": len(procs), "threads": threads},
            "groups": groups,
            "recs": self.recommend(groups),
        }
        self.prev = {"t": now, "ticks": ticks, "disk": r["disk"], "net": r["net"],
                     "cputime": {pid: p["cputime"] for pid, p in procs.items()}}
        if prev:
            self.history.append({
                "t": now, "cpu": cpu["total"], "mem": r["mem"]["used"],
                "gpu": r["gpu"]["util"] if r["gpu"] else None,
                "netIn": data["net"]["inRate"], "netOut": data["net"]["outRate"],
                "diskR": data["disk"]["readRate"], "diskW": data["disk"]["writeRate"],
            })
        with self.lock:
            self.latest = data
        return data

    def build_groups(self, procs):
        groups, owner = {}, {}
        for p in procs.values():
            info = classify(p)
            g = groups.setdefault(info["id"], {**info, "cat": "system" if info["system"] else categorize(info["name"]),
                                               "mem": 0, "cpu": 0.0, "procs": []})
            g["mem"] += p["mem"]
            g["cpu"] += p["cpu"]
            g["procs"].append(p)
            owner[p["pid"]] = g

        protected = set()
        pid = os.getpid()
        while pid in procs and pid > 1:
            protected.add(owner[pid]["id"])
            pid = procs[pid]["ppid"]

        def parent_app(p):
            seen, pid = 0, p["ppid"]
            while pid in procs and pid > 1 and seen < 64:
                g = owner[pid]
                if g["kind"] == "app":
                    return g["name"]
                pid, seen = procs[pid]["ppid"], seen + 1
            return None

        out = []
        for g in groups.values():
            g["procs"].sort(key=lambda p: p["mem"], reverse=True)
            out.append({
                "id": g["id"], "name": g["name"], "kind": g["kind"], "cat": g["cat"], "system": g["system"],
                "bundle": g["bundle"], "bundleId": bundle_info(g["bundle"]) if g["kind"] == "app" and not g["system"] else None,
                "protected": g["id"] in protected,
                "mem": g["mem"], "cpu": round(g["cpu"], 1), "count": len(g["procs"]),
                "procs": [{
                    "pid": p["pid"], "ppid": p["ppid"], "name": f"{g['name']} {p['script']}" if g["kind"] == "cmd" and p["script"] else short_name(os.path.basename(p["path"]), g["name"]),
                    "path": p["path"], "mem": p["mem"], "cpu": p["cpu"],
                    "parentApp": parent_app(p) if g["kind"] == "cmd" else None,
                } for p in g["procs"][:80]],
            })
        out.sort(key=lambda g: g["mem"], reverse=True)
        return out

    def recommend(self, groups):
        recs = []
        for g in groups:
            if g["system"] or g["protected"]:
                continue
            if g["kind"] == "app":
                quit_cmd = (f"osascript -e 'quit app id \"{g['bundleId']}\"'" if g["bundleId"]
                            else f"osascript -e 'quit app \"{g['name']}\"'")
                base = {"id": g["id"], "groupId": g["id"], "title": g["name"], "mem": g["mem"], "cpu": g["cpu"],
                        "command": quit_cmd, "path": g["bundle"].replace(str(Path.home()), "~")}
                idle = g["cpu"] < 3
                if idle and g["cat"] in ("comms", "media", "other") and g["mem"] >= 200 * MB:
                    recs.append({**base, "section": "safe", "reason": f"Idle, {g['count']} processes"})
                elif g["mem"] >= 400 * MB or g["cpu"] >= 30:
                    reason = {"browsers": "Tabs come back on reopen", "dev": "Save open work first",
                              "ai": "Stops running agents or models"}.get(g["cat"], "In use" if not idle else "Idle but large")
                    if g["cpu"] >= 10:
                        reason = f"{g['cpu']:.0f}% CPU right now. {reason}"
                    recs.append({**base, "section": "review", "reason": reason})
                continue
            for p in g["procs"]:
                kill_cmd = f'[ "$(ps -o comm= -p {p["pid"]})" = "{p["path"]}" ] && kill {p["pid"]}'
                base = {"id": f"pid:{p['pid']}", "groupId": g["id"], "pid": p["pid"], "title": f"{p['name']} · pid {p['pid']}",
                        "mem": p["mem"], "cpu": p["cpu"], "command": kill_cmd, "path": p["path"].replace(str(Path.home()), "~")}
                if p["ppid"] == 1 and g["name"] in DEV_RUNTIMES and p["mem"] >= 50 * MB and p["cpu"] < 2:
                    recs.append({**base, "section": "review", "reason": "Detached from any app and idle. May be a background worker"})
                elif p["cpu"] >= 50 or p["mem"] >= 1024 * MB:
                    who = f"started by {p['parentApp']}" if p["parentApp"] else "no parent app"
                    load = f"{p['cpu']:.0f}% CPU" if p["cpu"] >= 50 else "over 1 GB"
                    recs.append({**base, "section": "review", "reason": f"{load}, {who}"})
        recs.sort(key=lambda r: (r["section"] != "safe", -r["mem"]))
        return recs

    def payload(self):
        with self.lock:
            return {**self.latest, "history": list(self.history)}


def render(data):
    return TEMPLATE.read_text().replace(DATA_SLOT, json.dumps(data).replace("</", "<\\/"))


def serve(port, open_browser, interval):
    sampler = Sampler()
    sampler.sample()
    time.sleep(1)
    sampler.sample()

    def loop():
        while True:
            time.sleep(interval)
            sampler.sample()

    threading.Thread(target=loop, daemon=True).start()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.startswith("/api/metrics"):
                body, kind = json.dumps(sampler.payload()).encode(), "application/json"
            elif self.path in ("/", "/index.html"):
                body, kind = TEMPLATE.read_bytes(), "text/html; charset=utf-8"
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", kind)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    url = f"http://127.0.0.1:{port}/"
    print(f"Mac Pulse live at {url}  (Ctrl+C to stop)")
    if open_browser:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


def snapshot(path):
    sampler = Sampler()
    sampler.sample()
    time.sleep(1.5)
    data = sampler.sample()
    data["live"] = False
    data["history"] = []
    Path(path).write_text(render(data))
    print(f"Wrote {path}")


def main():
    parser = argparse.ArgumentParser(description="Live RAM, CPU, GPU, disk, network and battery map for macOS.")
    parser.add_argument("--snapshot", metavar="FILE", help="write a self-contained HTML snapshot instead of serving")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--interval", type=float, default=2.5, help="seconds between live samples")
    parser.add_argument("--no-open", action="store_true", help="do not open a browser tab")
    args = parser.parse_args()
    if args.snapshot:
        snapshot(args.snapshot)
    else:
        serve(args.port, not args.no_open, args.interval)


if __name__ == "__main__":
    main()
