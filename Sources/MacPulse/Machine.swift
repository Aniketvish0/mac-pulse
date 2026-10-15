import Darwin
import Foundation
import IOKit

enum Sysctl {
    static func string(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
        return String(cString: buf)
    }

    static func value<T: BitwiseCopyable>(_ name: String, _ fallback: T) -> T {
        var value = fallback
        var size = MemoryLayout<T>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : fallback
    }
}

enum Machine {
    static let host = mach_host_self()
    static let pageSize = UInt64(getpagesize())

    static func readHost() -> HostInfo {
        var perf: [PerfLevel] = []
        for level in 0..<4 {
            let name = Sysctl.string("hw.perflevel\(level).name")
            if name.isEmpty { break }
            perf.append(PerfLevel(name: name, count: Int(Sysctl.value("hw.perflevel\(level).logicalcpu", Int32(0)))))
        }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let boot = Sysctl.value("kern.boottime", timeval())
        return HostInfo(
            chip: Sysctl.string("machdep.cpu.brand_string"),
            model: Sysctl.string("hw.model"),
            cores: Int(Sysctl.value("hw.ncpu", Int32(0))),
            perf: perf,
            os: v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)",
            name: hostName(),
            boot: Int(boot.tv_sec)
        )
    }

    static func hostName() -> String {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0 else { return "" }
        return String(cString: buf).components(separatedBy: ".").first ?? ""
    }

    static func coreTicks() -> [[UInt32]] {
        var count: natural_t = 0
        var size: mach_msg_type_number_t = 0
        var info: processor_info_array_t?
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &count, &info, &size) == KERN_SUCCESS, let info else { return [] }
        let ticks = (0..<Int(count)).map { core in
            (0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[core * Int(CPU_STATE_MAX) + $0]) }
        }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(size) * MemoryLayout<integer_t>.stride))
        return ticks
    }

    static func readMemory() -> MemoryInfo {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        let total = Sysctl.value("hw.memsize", UInt64(0))
        let purgeable = UInt64(stats.purgeable_count)
        let app = (UInt64(stats.internal_page_count) - min(purgeable, UInt64(stats.internal_page_count))) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let cached = (UInt64(stats.external_page_count) + purgeable) * pageSize
        let used = app + wired + compressed
        let swap = Sysctl.value("vm.swapusage", xsw_usage())
        let level = Sysctl.value("kern.memorystatus_vm_pressure_level", Int32(1))
        return MemoryInfo(
            total: total, used: used, app: app, wired: wired, compressed: compressed, cached: cached,
            free: total > used + cached ? total - used - cached : 0,
            swapUsed: swap.xsu_used, swapTotal: swap.xsu_total,
            pressure: level == 4 ? "critical" : level == 2 ? "warning" : "normal"
        )
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "thermal nominal"
        case .fair: "thermal fair"
        case .serious: "thermal serious, throttling"
        case .critical: "thermal critical, throttling"
        @unknown default: "thermal unknown"
        }
    }

    static func ioServices(_ cls: String) -> [NSDictionary] {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }
        var out: [NSDictionary] = []
        while case let entry = IOIteratorNext(iter), entry != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS, let props {
                out.append(props.takeRetainedValue() as NSDictionary)
            }
            IOObjectRelease(entry)
        }
        return out
    }

    static func int(_ dict: NSDictionary?, _ key: String) -> Int64? {
        (dict?[key] as? NSNumber)?.int64Value
    }

    static func readGPU() -> GPUInfo? {
        guard let stats = ioServices("IOAccelerator").first?["PerformanceStatistics"] as? NSDictionary,
              let util = int(stats, "Device Utilization %") else { return nil }
        return GPUInfo(util: Int(util), inUse: UInt64(int(stats, "In use system memory") ?? 0), alloc: UInt64(int(stats, "Alloc system memory") ?? 0))
    }

    static func diskBytes() -> (read: UInt64, write: UInt64) {
        ioServices("IOBlockStorageDriver").reduce((UInt64(0), UInt64(0))) { sum, props in
            let stats = props["Statistics"] as? NSDictionary
            return (sum.0 + UInt64(int(stats, "Bytes (Read)") ?? 0), sum.1 + UInt64(int(stats, "Bytes (Write)") ?? 0))
        }
    }

    static func diskSpace() -> (total: UInt64, free: UInt64) {
        var fs = statfs()
        guard statfs("/System/Volumes/Data", &fs) == 0 else { return (0, 0) }
        return (UInt64(fs.f_blocks) * UInt64(fs.f_bsize), UInt64(fs.f_bavail) * UInt64(fs.f_bsize))
    }

    static func netBytes() -> (rx: UInt64, tx: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0 else { return (0, 0) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return (0, 0) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        buf.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= len {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                if header.ifm_msglen == 0 { break }
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let msg = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if if_indextoname(UInt32(msg.ifm_index), &name) != nil, name[0] == 0x65, name[1] == 0x6e {
                        rx += msg.ifm_data.ifi_ibytes
                        tx += msg.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (rx, tx)
    }

    static func readBattery() -> BatteryInfo? {
        guard let b = ioServices("AppleSmartBattery").first, let percent = int(b, "CurrentCapacity") else { return nil }
        let data = b["BatteryData"] as? NSDictionary
        let full = int(data, "FullChargeCapacity") ?? int(b, "AppleRawMaxCapacity")
        let design = int(data, "DesignCapacity") ?? int(b, "DesignCapacity")
        let amps = abs(int(b, "InstantAmperage") ?? int(b, "Amperage") ?? 0)
        let volts = int(b, "Voltage") ?? 0
        let remaining = int(b, "TimeRemaining") ?? 0
        return BatteryInfo(
            percent: Int(percent),
            charging: (b["IsCharging"] as? Bool) ?? false,
            plugged: (b["ExternalConnected"] as? Bool) ?? false,
            minutesLeft: remaining > 0 && remaining < 6000 ? Int(remaining) : nil,
            cycles: Int(int(b, "CycleCount") ?? 0),
            health: full.flatMap { f in design.map { d in d > 0 ? Int((Double(f) / Double(d) * 100).rounded()) : 0 } },
            fullMah: full.map(Int.init), designMah: design.map(Int.init),
            watts: (Double(amps) * Double(volts) / 1e6 * 10).rounded() / 10
        )
    }
}
