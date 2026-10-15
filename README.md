# Mac Pulse

A live map of what is using your Mac's memory and CPU, with a cleanup list that turns into a script you can paste into Terminal.

![Mac Pulse running on an M5 Pro MacBook](docs/screenshot.png)

## What it shows

- Every running app and process as a treemap, grouped by category (browsers, dev tools, AI apps, communication, media, other apps, macOS). Size the tiles by memory or by current CPU. Click a tile to drill from category to app to single processes, or switch to a table.
- Memory used, split into app, wired, compressed, cached and free, plus swap and the macOS memory pressure level.
- CPU load per core, user and system time, load average and thermal throttling.
- GPU utilization and GPU memory.
- Disk free space and read/write speed.
- Network download and upload speed.
- Battery charge, health, cycle count, capacity and power draw in watts.

## Cleanup suggestions

The right-hand list sorts apps and processes into two groups:

- **Safe to quit**: communication, media and other apps that use at least 200 MB and are idle (under 3% CPU). These start out ticked.
- **Review first**: any other app over 400 MB or 30% CPU (browsers, editors and AI apps always land here), single processes over 1 GB or 50% CPU, and idle node or Python workers over 50 MB with no parent app. Detached workers are often background services on purpose, so they never go in the safe group.

macOS processes are never suggested, and neither is the app that launched Mac Pulse.

**Copy script** builds a zsh script from what you ticked. Apps get a normal quit through `osascript`, the same as choosing Quit from the menu. Single processes get `kill`, guarded by a check that the process ID still shows the same command name in `ps`, so a reused ID can't take down something else. Nothing runs until you paste the script yourself.

## Run it

It needs macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`). There are no other dependencies.

```sh
swift build -c release
.build/release/macpulse                       # live view at http://127.0.0.1:8765, refreshes every 2.5 s
.build/release/macpulse --snapshot out.html   # one self-contained HTML file of the current state
.build/release/macpulse --port 9000 --interval 5 --no-open
```

Keep the binary next to the `MacPulse_MacPulse.bundle` folder that `swift build` puts beside it, since the dashboard page ships inside that bundle.

The server listens on 127.0.0.1 only. A snapshot file embeds your process list, hostname and app paths, so check it before you share one.

## What it costs to leave running

Measured on an M5 Pro with about 870 processes, sampling every 2.5 s: about 1% of one CPU core and 10 MB of memory, with or without the dashboard open. Every metric comes from a direct system call, so no sampling step starts another program. The first version was written in Python and ran `top`, `ps`, `ioreg` and friends on every sample, which cost about 29% of a core and 32 MB.

## Processes owned by root

macOS only lets a process read the memory and CPU time of processes owned by the same user. Run as yourself, Mac Pulse measures every app and tool you started and shows the rest (WindowServer, kernel_task and other root or system daemons) as one "Root & system processes" group. Its CPU is the total CPU load minus what your own processes used. Kernel and driver memory appears as its own tile, sized by wired memory. To measure every process one by one, run it with `sudo`.

## How it reads the numbers

| Metric | Source |
| --- | --- |
| Process list, parents and owners | `sysctl` `KERN_PROC_ALL` |
| Per-process memory | `proc_pid_rusage` physical footprint, the figure Activity Monitor shows |
| Per-process CPU | change in `proc_pid_rusage` CPU time between samples (100% = one core) |
| Per-core CPU | `host_processor_info` |
| Memory breakdown | `host_statistics64`, `vm.swapusage`, `kern.memorystatus_vm_pressure_level` |
| Thermal state | `ProcessInfo.thermalState` |
| GPU | IOKit `IOAccelerator` performance statistics |
| Disk | IOKit `IOBlockStorageDriver` counters, `statfs` on the data volume |
| Network | `sysctl` `NET_RT_IFLIST2` 64-bit counters on `en*` interfaces |
| Battery | IOKit `AppleSmartBattery` |

Shared memory counts once for every process that maps it, so an app's total can read a little higher than its real share.

## License

MIT
