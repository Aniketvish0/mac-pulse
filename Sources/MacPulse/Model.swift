struct PerfLevel: Encodable { let name: String; let count: Int }

struct HostInfo: Encodable {
    let chip: String
    let model: String
    let cores: Int
    let perf: [PerfLevel]
    let os: String
    let name: String
    let boot: Int
}

struct CPUInfo: Encodable {
    let total: Double
    let user: Double
    let sys: Double
    let cores: [Double]
    let load: [Double]
    let thermal: String
}

struct MemoryInfo: Encodable {
    let total: UInt64
    let used: UInt64
    let app: UInt64
    let wired: UInt64
    let compressed: UInt64
    let cached: UInt64
    let free: UInt64
    let swapUsed: UInt64
    let swapTotal: UInt64
    let pressure: String
}

struct GPUInfo: Encodable { let util: Int; let inUse: UInt64; let alloc: UInt64 }

struct BatteryInfo: Encodable {
    let percent: Int
    let charging: Bool
    let plugged: Bool
    let minutesLeft: Int?
    let cycles: Int
    let health: Int?
    let fullMah: Int?
    let designMah: Int?
    let watts: Double
}

struct DiskInfo: Encodable { let total: UInt64; let free: UInt64; let readRate: Double; let writeRate: Double }

struct NetInfo: Encodable { let inRate: Double; let outRate: Double; let inTotal: UInt64; let outTotal: UInt64 }

struct ProcCounts: Encodable { let count: Int; let unmeasured: Int }

struct GroupProc: Encodable {
    let pid: Int32
    let ppid: Int32
    let name: String
    let path: String
    let argv0: String
    let mem: UInt64
    let cpu: Double
    let parentApp: String?
}

struct Group: Encodable {
    let id: String
    let name: String
    let kind: String
    let cat: String
    let system: Bool
    let bundle: String?
    let bundleId: String?
    let protected: Bool
    let unmeasured: Bool
    let mem: UInt64
    let cpu: Double
    let count: Int
    let procs: [GroupProc]
}

struct Rec: Encodable {
    let id: String
    let groupId: String
    let pid: Int32?
    let title: String
    let mem: UInt64
    let cpu: Double
    let command: String
    let path: String
    let section: String
    let reason: String
}

struct HistoryPoint: Encodable {
    let t: Double
    let cpu: Double
    let mem: UInt64
    let gpu: Int?
    let netIn: Double
    let netOut: Double
    let diskR: Double
    let diskW: Double
}

struct Payload: Encodable {
    let ts: Double
    var live: Bool
    let host: HostInfo
    let cpu: CPUInfo
    let mem: MemoryInfo
    let gpu: GPUInfo?
    let battery: BatteryInfo?
    let disk: DiskInfo
    let net: NetInfo
    let procs: ProcCounts
    let groups: [Group]
    let recs: [Rec]
    var history: [HistoryPoint]
}

func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
